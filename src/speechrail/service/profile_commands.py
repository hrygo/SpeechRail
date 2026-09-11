"""Three-tier profile listing, selection, application and rollback."""

from __future__ import annotations

import asyncio
import os
import tempfile
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import httpx

from speechrail.config import Settings
from speechrail.config.model_catalog import ModelCatalog, load_catalog, load_runtime_lock
from speechrail.service import vad_model
from speechrail.service.diarization_assets import (
    _COREML_FILE_SIZES,
    prepare_diarization_assets,
)
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
PrepareVadModel = Callable[[Path], None]
PrepareDiarization = Callable[[str, Path], None]
_ORDER: tuple[PresetId, ...] = ("quality", "balanced", "light")
_DIARIZATION_ENV_KEYS = (
    "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH",
    "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR",
)


class ProfileCommandError(RuntimeError):
    """A profile command could not complete without changing public settings."""


@dataclass(frozen=True, slots=True)
class ProfileSummary:
    id: PresetId
    asr: str
    tts: str
    download_bytes: int
    aligner: str | None = None


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
        artifact_keys = [preset.asr, preset.tts]
        if preset.aligner is not None:
            artifact_keys.append(preset.aligner)
        download_bytes = sum(
            item.size for key in artifact_keys for item in artifacts[key].files
        )
        if preset.diarization:
            download_bytes += sum(_COREML_FILE_SIZES)
        summaries.append(
            ProfileSummary(
                id=preset_id,
                asr=preset.asr,
                tts=preset.tts,
                download_bytes=download_bytes,
                aligner=preset.aligner,
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
        for name in ("asr", "tts", "aligner")
        if _model_value(old, name) != _model_value(new, name)
    )


def recommend_profile(total_memory_bytes: int) -> PresetId:
    """Return a memory fallback suggestion (内存兜底建议) only.

    The tier is the user's explicit choice; this helper merely maps physical
    memory to a starting point and keeps the historical 10/16 GiB thresholds.
    """
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
    preflight = run_preflight(
        layout,
        require_tts=True,
        host_python=layout.current_python,
    )
    if not preflight.ok:
        raise ProfileCommandError("managed runtime preflight failed")
    settings = Settings.from_env_file(layout.config_file)
    manager = create_launch_agent_manager(working_directory=app_home)
    controller = LaunchAgentServiceController(manager, port=settings.port)
    timeout = httpx.Timeout(settings.request_timeout_seconds)
    with httpx.Client(base_url=_loopback_url(settings), timeout=timeout) as client:
        smoke = PublicApiSmokeProbe(client=client, api_key=settings.api_key)
        return apply_prepared_profile(
            prepared_id,
            app_home=app_home,
            service=controller,
            smoke=smoke,
        )


def _prepare_optional_vad_model(app_home: Path) -> None:
    """Best-effort Silero VAD model download; never blocks a profile apply.

    On success the model path is recorded in the private config so the ``auto``
    engine resolves to Silero. On failure the engine falls back to the
    zero-dependency legacy VAD and the apply continues unchanged.
    """
    try:
        model_path = vad_model.ensure_vad_model(app_home)
        if model_path is None:
            return
        layout = ServiceLayout.for_app_home(app_home)
        if layout.config_file.is_file():
            vad_model.write_vad_model_path(layout.config_file, model_path)
    except Exception:  # optional dependency must never fail a profile apply
        vad_model.logger.exception("optional Silero VAD model preparation failed")


def _atomic_write_private(target: Path, content: bytes) -> None:
    """Atomically replace a private file, leaving mode 0600 and no partial file."""
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(dir=target.parent, prefix=".env.")
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        temporary.chmod(0o600)
        temporary.replace(target)
        dir_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        temporary.unlink(missing_ok=True)


def _update_env_keys(config_file: Path, updates: Mapping[str, str | None]) -> None:
    """Set, replace or remove env keys, preserving every unrelated line."""
    content = config_file.read_text(encoding="utf-8") if config_file.is_file() else ""
    lines: list[str] = []
    seen: set[str] = set()
    for line in content.splitlines():
        key = line.split("=", 1)[0] if "=" in line else None
        if key is not None and key in updates:
            seen.add(key)
            value = updates[key]
            if value is not None:
                lines.append(f"{key}={value}")
            continue
        lines.append(line)
    appended = False
    for key, value in updates.items():
        if value is None or key in seen:
            continue
        if not appended and lines and lines[-1] != "":
            lines.append("")
        lines.append(f"{key}={value}")
        appended = True
    _atomic_write_private(config_file, ("\n".join(lines) + "\n").encode("utf-8"))


def _prepare_diarization_assets(preset: str, app_home: Path) -> None:
    """Provision the tier's diarization assets and mirror them into the private config.

    Unlike the optional Silero VAD, diarization is a hard tier capability: a
    failure here must surface as :class:`ProfileCommandError` rather than being
    silently skipped when the preset declares ``diarization``.
    """
    try:
        catalog = load_catalog()
        preset_model = catalog.preset(preset)
    except KeyError as exc:
        raise ProfileCommandError("unknown profile preset") from exc

    timeout = httpx.Timeout(connect=30.0, read=300.0, write=30.0, pool=30.0)
    with httpx.Client(timeout=timeout) as client:
        downloader = ModelScopeDownloader(client=client)
        try:
            paths = prepare_diarization_assets(
                app_home, preset_id=preset, downloader=downloader
            )
        except Exception as exc:
            raise ProfileCommandError("diarization asset preparation failed") from exc

    updates: Mapping[str, str | None]
    if not preset_model.diarization:
        updates = dict.fromkeys(_DIARIZATION_ENV_KEYS)
    else:
        if paths is None:
            raise ProfileCommandError("diarization assets were not prepared")
        updates = {
            "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH": str(paths.coreml_model_path),
            "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR": str(paths.aligner_model_dir),
        }

    layout = ServiceLayout.for_app_home(app_home)
    config_file = layout.config_file
    if not config_file.is_file() and not preset_model.diarization:
        return
    try:
        _update_env_keys(config_file, updates)
    except Exception as exc:
        raise ProfileCommandError("diarization configuration update failed") from exc


def apply_profile(
    preset: PresetId,
    *,
    app_home: Path,
    prepare: PrepareProfile = _prepare_profile,
    switch: SwitchPrepared = _switch_prepared,
    prepare_vad: PrepareVadModel = _prepare_optional_vad_model,
    prepare_diarization: PrepareDiarization = _prepare_diarization_assets,
) -> ApplyResult:
    resolved_home = app_home.resolve()
    prepared_id = prepare(preset, resolved_home)
    prepare_vad(resolved_home)
    prepare_diarization(preset, resolved_home)
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
