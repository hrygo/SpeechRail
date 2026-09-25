"""Independent ASR/TTS spec listing, selection, application and rollback.

The command group is still called ``profile`` for operators, but it never
accepts the removed preset names: a selection is exactly two spec tiers plus an
explicit ``auto`` policy, and auxiliary assets such as alignment or diarization
are opt-in per task instead of being bound to a tier.
"""

from __future__ import annotations

import asyncio
import os
import re
import tempfile
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import httpx

from speechrail.config import Settings
from speechrail.config.model_catalog import ModelCatalog, load_catalog, load_runtime_lock
from speechrail.domain.model_spec import ModelRole, required_spec_artifact
from speechrail.service import vad_model
from speechrail.service.diarization_assets import (
    prepare_diarization_assets,
)
from speechrail.service.launchd import create_launch_agent_manager
from speechrail.service.model_store import prepare_spec_models, resolve_prepared_selection
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

SpecTier = Literal["fast", "quality", "reference"]
PrepareSelection = Callable[[str, str, Path], str]
SwitchPrepared = Callable[[str, Path], ApplyResult]
ResolvePrevious = Callable[[Mapping[str, object], Path], str]
PrepareVadModel = Callable[[Path], None]
PrepareDiarization = Callable[[Path, str], None]
_ORDER: tuple[SpecTier, ...] = ("fast", "quality", "reference")
_SUMMARY_ROLES: tuple[tuple[str, ModelRole], ...] = (
    ("asr", "asr"),
    ("tts", "tts_custom_voice"),
    ("tts_base", "tts_base"),
    ("voice_design", "voice_design"),
    ("aligner", "alignment"),
)
_DIARIZATION_ENV_KEYS = (
    "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH",
    "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR",
)
_ENV_ASSIGNMENT_RE = re.compile(
    r"^\s*(?P<export>export\s+)?(?P<key>[^\s=]+)\s*="
)


class ProfileCommandError(RuntimeError):
    """A profile command could not complete without changing public settings."""


@dataclass(frozen=True, slots=True)
class ProfileSummary:
    """One spec tier's explicit artifact bindings, with ``None`` for gaps."""

    id: SpecTier
    asr: str | None
    tts: str | None
    download_bytes: int
    tts_base: str | None = None
    voice_design: str | None = None
    aligner: str | None = None

    def required_keys(self) -> tuple[str, ...]:
        return tuple(
            key
            for key in (self.asr, self.tts, self.tts_base, self.voice_design, self.aligner)
            if key is not None
        )


@dataclass(frozen=True, slots=True)
class ProfileStatus:
    """The committed independent selection, or an empty status when unconfigured."""

    asr_spec: str | None
    tts_spec: str | None
    auto: str | None
    generation: int | None

    @property
    def label(self) -> str | None:
        if self.asr_spec is None or self.tts_spec is None:
            return None
        suffix = "" if self.auto in (None, "off") else f" (auto={self.auto})"
        return f"{self.asr_spec}/{self.tts_spec}{suffix}"


def _bound_key(tier: SpecTier, role: ModelRole) -> str | None:
    return required_spec_artifact(tier, role)


def list_profiles(catalog: ModelCatalog | None = None) -> tuple[ProfileSummary, ...]:
    """List the three spec tiers with their explicit role bindings and sizes."""

    selected_catalog = catalog or load_catalog()
    artifacts = {artifact.key: artifact for artifact in selected_catalog.artifacts}
    summaries: list[ProfileSummary] = []
    for tier in _ORDER:
        bindings = {name: _bound_key(tier, role) for name, role in _SUMMARY_ROLES}
        download_bytes = sum(
            item.size
            for key in bindings.values()
            if key is not None and key in artifacts
            for item in artifacts[key].files
        )
        summaries.append(
            ProfileSummary(
                id=tier,
                asr=bindings["asr"],
                tts=bindings["tts"],
                download_bytes=download_bytes,
                tts_base=bindings["tts_base"],
                voice_design=bindings["voice_design"],
                aligner=bindings["aligner"],
            )
        )
    return tuple(summaries)


def _spec_value(profile: ProfileSummary | Mapping[str, object], name: str) -> object:
    if isinstance(profile, Mapping):
        return profile.get(name)
    return getattr(profile, name)


def model_changes(
    old: ProfileSummary | Mapping[str, object],
    new: ProfileSummary | Mapping[str, object],
) -> frozenset[str]:
    """Return the public spec fields that differ between two selections."""

    return frozenset(
        name
        for name in ("asr", "tts", "tts_base", "voice_design", "aligner")
        if _spec_value(old, name) != _spec_value(new, name)
    )


def recommend_selection(total_memory_bytes: int) -> tuple[SpecTier, SpecTier]:
    """Return a memory-based starting (ASR spec, TTS spec) suggestion only.

    The tiers remain the user's explicit choice; this helper merely maps physical
    memory to a safe starting point and keeps the historical 10/16 GiB thresholds.
    """
    if total_memory_bytes <= 0:
        raise ValueError("physical memory must be positive")
    if total_memory_bytes < 10 * 1024**3:
        return "fast", "fast"
    if total_memory_bytes < 16 * 1024**3:
        return "quality", "fast"
    return "quality", "quality"


# Kept for operators who still ask for a single tier; it names the ASR spec.
def recommend_profile(total_memory_bytes: int) -> SpecTier:
    """Return the recommended ASR spec tier for the installed physical memory."""

    return recommend_selection(total_memory_bytes)[0]


def profile_status(app_home: Path) -> ProfileStatus:
    selection = ProfileStore(app_home.resolve()).recover()
    if selection is None:
        return ProfileStatus(None, None, None, None)
    generation = selection["generation"]
    if type(generation) is not int:
        raise ProfileCommandError("profile selection is invalid")
    asr_spec = selection.get("asr_spec")
    tts_spec = selection.get("tts_spec")
    auto = selection.get("auto", "off")
    if not isinstance(asr_spec, str) or not isinstance(tts_spec, str):
        raise ProfileCommandError("profile selection is invalid")
    if not isinstance(auto, str):
        raise ProfileCommandError("profile selection is invalid")
    return ProfileStatus(
        asr_spec=asr_spec,
        tts_spec=tts_spec,
        auto=auto,
        generation=generation,
    )


def _prepare_profile(asr_spec: str, tts_spec: str, app_home: Path) -> str:
    catalog = load_catalog()
    runtime_lock = load_runtime_lock()
    timeout = httpx.Timeout(connect=30.0, read=300.0, write=30.0, pool=30.0)
    with httpx.Client(timeout=timeout) as client:
        downloader = ModelScopeDownloader(client=client)
        try:
            return asyncio.run(
                prepare_spec_models(
                    asr_spec,  # type: ignore[arg-type]
                    tts_spec,  # type: ignore[arg-type]
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


def _env_assignment(line: str) -> tuple[str, str] | None:
    """Return ``(export_prefix, key)`` for an assignment line, else ``None``.

    Recognizes ``KEY=...``, ``KEY = ...`` and ``export KEY=...`` so a spaced or
    exported assignment is replaced in place instead of appended as a duplicate.
    """
    match = _ENV_ASSIGNMENT_RE.match(line)
    if match is None:
        return None
    prefix = "export " if match.group("export") else ""
    return prefix, match.group("key")


def _update_env_keys(config_file: Path, updates: Mapping[str, str | None]) -> None:
    """Set, replace or remove env keys, preserving every unrelated line."""
    content = config_file.read_text(encoding="utf-8") if config_file.is_file() else ""
    lines: list[str] = []
    seen: set[str] = set()
    for line in content.splitlines():
        assignment = _env_assignment(line)
        if assignment is not None and assignment[1] in updates:
            prefix, key = assignment
            seen.add(key)
            value = updates[key]
            if value is not None:
                lines.append(f"{prefix}{key}={value}")
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


def _prepare_diarization_assets(app_home: Path, aligner_key: str) -> None:
    """Opt-in diarization provisioning: CoreML asset plus one explicit aligner.

    Diarization is a task-time option, not a spec tier, so the caller must name
    the aligner artifact it actually wants. A failure here must surface as
    :class:`ProfileCommandError` rather than being silently skipped.
    """
    catalog = load_catalog()
    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}
    if aligner_key not in artifacts:
        raise ProfileCommandError("unknown aligner artifact")

    timeout = httpx.Timeout(connect=30.0, read=300.0, write=30.0, pool=30.0)
    with httpx.Client(timeout=timeout) as client:
        downloader = ModelScopeDownloader(client=client)
        try:
            paths = prepare_diarization_assets(
                app_home,
                aligner_key=aligner_key,
                downloader=downloader,
                catalog=catalog,
            )
        except Exception as exc:
            raise ProfileCommandError("diarization asset preparation failed") from exc
    if paths is None:
        raise ProfileCommandError("diarization assets were not prepared")
    updates: Mapping[str, str | None] = {
        "SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH": str(paths.coreml_model_path),
        "SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR": str(paths.aligner_model_dir),
    }
    layout = ServiceLayout.for_app_home(app_home)
    config_file = layout.config_file
    try:
        _update_env_keys(config_file, updates)
    except Exception as exc:
        raise ProfileCommandError("diarization configuration update failed") from exc


def apply_profile(
    asr_spec: SpecTier,
    tts_spec: SpecTier,
    *,
    app_home: Path,
    prepare: PrepareSelection = _prepare_profile,
    switch: SwitchPrepared = _switch_prepared,
    prepare_vad: PrepareVadModel = _prepare_optional_vad_model,
    prepare_diarization: PrepareDiarization | None = None,
) -> ApplyResult:
    """Prepare two explicit specs, then atomically switch the single service."""
    if asr_spec not in _ORDER or tts_spec not in _ORDER:
        raise ProfileCommandError("unknown spec tier")
    resolved_home = app_home.resolve()
    prepared_id = prepare(asr_spec, tts_spec, resolved_home)
    prepare_vad(resolved_home)
    if prepare_diarization is not None:
        aligner_key = _bound_key(tts_spec, "alignment") or _bound_key(asr_spec, "alignment")
        if aligner_key is None:
            raise ProfileCommandError("no aligner artifact is bound to the selected specs")
        prepare_diarization(resolved_home, aligner_key)
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
    "SpecTier",
    "apply_profile",
    "list_profiles",
    "model_changes",
    "profile_status",
    "recommend_profile",
    "recommend_selection",
    "rollback_profile",
]
