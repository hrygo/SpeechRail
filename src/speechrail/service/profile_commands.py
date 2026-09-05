"""Three-tier profile listing, selection, application and rollback."""

from __future__ import annotations

import asyncio
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import httpx

from speechrail.config import Settings
from speechrail.config.model_catalog import ModelCatalog, load_catalog, load_runtime_lock
from speechrail.service.launchd import create_launch_agent_manager
from speechrail.service.model_store import prepare_models, resolve_prepared_selection
from speechrail.service.modelscope import ModelScopeDownloader
from speechrail.service.paths import ServiceLayout
from speechrail.service.preflight import run_preflight
from speechrail.service.profile_smoke import PublicApiSmokeProbe
from speechrail.service.profile_store import ProfileStore
from speechrail.service.profile_switch import (
    ApplyResult,
    LaunchAgentServiceController,
    apply_prepared_profile,
)

PresetId = Literal["quality", "balanced", "light"]
PrepareProfile = Callable[[str, Path], str]
SwitchPrepared = Callable[[str, Path], ApplyResult]
ResolvePrevious = Callable[[Mapping[str, object], Path], str]
_ORDER: tuple[PresetId, ...] = ("quality", "balanced", "light")


class ProfileCommandError(RuntimeError):
    """A profile command could not complete without changing public settings."""


@dataclass(frozen=True, slots=True)
class ProfileSummary:
    id: PresetId
    asr: str
    tts: str
    download_bytes: int


@dataclass(frozen=True, slots=True)
class ProfileStatus:
    preset: str | None
    generation: int | None
    asr: str | None
    tts: str | None


def list_profiles(catalog: ModelCatalog | None = None) -> tuple[ProfileSummary, ...]:
    selected_catalog = catalog or load_catalog()
    artifacts = {artifact.key: artifact for artifact in selected_catalog.artifacts}
    summaries: list[ProfileSummary] = []
    for preset_id in _ORDER:
        preset = selected_catalog.preset(preset_id)
        summaries.append(
            ProfileSummary(
                id=preset_id,
                asr=preset.asr,
                tts=preset.tts,
                download_bytes=sum(
                    item.size
                    for key in (preset.asr, preset.tts)
                    for item in artifacts[key].files
                ),
            )
        )
    return tuple(summaries)


def _model_value(profile: ProfileSummary | Mapping[str, object], name: str) -> object:
    if isinstance(profile, Mapping):
        return profile.get(name)
    return getattr(profile, name)


def model_changes(
    old: ProfileSummary | Mapping[str, object],
    new: ProfileSummary | Mapping[str, object],
) -> frozenset[str]:
    return frozenset(
        name
        for name in ("asr", "tts")
        if _model_value(old, name) != _model_value(new, name)
    )


def recommend_profile(total_memory_bytes: int) -> PresetId:
    """Recommend by physical memory only; no marketing-model detection."""
    if total_memory_bytes <= 0:
        raise ValueError("physical memory must be positive")
    if total_memory_bytes < 10 * 1024**3:
        return "light"
    if total_memory_bytes < 16 * 1024**3:
        return "balanced"
    return "quality"


def profile_status(app_home: Path) -> ProfileStatus:
    selection = ProfileStore(app_home.resolve()).recover()
    if selection is None:
        return ProfileStatus(None, None, None, None)
    generation = selection["generation"]
    if type(generation) is not int:
        raise ProfileCommandError("profile selection is invalid")
    return ProfileStatus(
        preset=str(selection["preset"]),
        generation=generation,
        asr=str(selection["asr"]),
        tts=str(selection["tts"]),
    )


def _prepare_profile(preset: str, app_home: Path) -> str:
    catalog = load_catalog()
    runtime_lock = load_runtime_lock()
    timeout = httpx.Timeout(connect=30.0, read=300.0, write=30.0, pool=30.0)
    with httpx.Client(timeout=timeout) as client:
        downloader = ModelScopeDownloader(client=client)
        try:
            return asyncio.run(
                prepare_models(
                    preset,
                    app_home=app_home,
                    downloader=downloader,
                    catalog=catalog,
                    runtime_lock=runtime_lock,
                )
            )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            raise ProfileCommandError("profile preparation failed") from exc


def _loopback_url(settings: Settings) -> str:
    host = "[::1]" if settings.host == "::1" else "127.0.0.1"
    return f"http://{host}:{settings.port}"


def _switch_prepared(prepared_id: str, app_home: Path) -> ApplyResult:
    layout = ServiceLayout.for_app_home(app_home)
    preflight = run_preflight(layout, require_tts=True)
    if not preflight.ok:
        raise ProfileCommandError("managed runtime preflight failed")
    settings = Settings.from_env_file(layout.config_file)
    manager = create_launch_agent_manager(working_directory=app_home)
    controller = LaunchAgentServiceController(manager)
    timeout = httpx.Timeout(settings.request_timeout_seconds)
    with httpx.Client(base_url=_loopback_url(settings), timeout=timeout) as client:
        smoke = PublicApiSmokeProbe(client=client, api_key=settings.api_key)
        return apply_prepared_profile(
            prepared_id,
            app_home=app_home,
            service=controller,
            smoke=smoke,
        )


def apply_profile(
    preset: PresetId,
    *,
    app_home: Path,
    prepare: PrepareProfile = _prepare_profile,
    switch: SwitchPrepared = _switch_prepared,
) -> ApplyResult:
    resolved_home = app_home.resolve()
    prepared_id = prepare(preset, resolved_home)
    return switch(prepared_id, resolved_home)


def _resolve_previous_id(previous: Mapping[str, object], app_home: Path) -> str:
    return resolve_prepared_selection(previous, app_home=app_home).prepared_id


def rollback_profile(
    *,
    app_home: Path,
    switch: SwitchPrepared = _switch_prepared,
    resolve_previous: ResolvePrevious = _resolve_previous_id,
) -> ApplyResult:
    resolved_home = app_home.resolve()
    previous = ProfileStore(resolved_home).previous()
    if previous is None:
        raise ProfileCommandError("no previous profile is available")
    try:
        prepared_id = resolve_previous(previous, resolved_home)
    except Exception as exc:
        raise ProfileCommandError("previous profile is unavailable") from exc
    return switch(prepared_id, resolved_home)


__all__ = [
    "ProfileCommandError",
    "ProfileStatus",
    "ProfileSummary",
    "apply_profile",
    "list_profiles",
    "model_changes",
    "profile_status",
    "recommend_profile",
    "rollback_profile",
]
