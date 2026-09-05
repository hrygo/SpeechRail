"""Read-only checks for a packaged SpeechRail installation."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import cast

from speechrail.backends.qwen3_native import MODEL_FILES, WEIGHT_FILE_SETS
from speechrail.config import Settings
from speechrail.config.model_catalog import load_runtime_lock
from speechrail.runtime.executable import resolve_configured_executable
from speechrail.service.bootstrap import (
    PreparedRuntime,
    RuntimeBootstrapError,
    load_prepared_runtime,
)
from speechrail.service.paths import ServiceLayout

FFMPEG_FALLBACKS = (Path("/opt/homebrew/bin/ffmpeg"), Path("/usr/local/bin/ffmpeg"))
CommandRunner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]


@dataclass(frozen=True, slots=True)
class PreflightCheck:
    name: str
    ok: bool
    message: str


@dataclass(frozen=True, slots=True)
class PreflightResult:
    ok: bool
    checks: tuple[PreflightCheck, ...]


def _check(name: str, ok: bool, message: str) -> PreflightCheck:
    return PreflightCheck(name=name, ok=ok, message=message)


def _runtime_check(
    name: str,
    executable: Path | None,
    import_name: str,
    runner: CommandRunner,
) -> PreflightCheck:
    if executable is None:
        return _check(name, False, "runtime path is not configured")
    if (
        not executable.is_absolute()
        or not executable.is_file()
        or not os.access(executable, os.X_OK)
    ):
        return _check(name, False, "runtime executable is missing or not executable")
    completed = runner((str(executable), "-c", f"import {import_name}"))
    return _check(
        name,
        completed.returncode == 0,
        "runtime import is available"
        if completed.returncode == 0
        else "runtime import failed",
    )


def _snapshot_check(
    name: str,
    model_dir: Path | None,
    required_files: tuple[str, ...],
    weight_sets: tuple[tuple[str, ...], ...] = (),
) -> PreflightCheck:
    if model_dir is None:
        return _check(name, False, "model snapshot path is not configured")
    if not model_dir.is_absolute() or not model_dir.is_dir():
        return _check(name, False, "model snapshot directory is missing")
    if any(not (model_dir / filename).is_file() for filename in required_files):
        return _check(name, False, "model snapshot is incomplete")
    if weight_sets and not any(
        all((model_dir / filename).is_file() for filename in layout) for layout in weight_sets
    ):
        return _check(name, False, "model snapshot weights are missing")
    return _check(name, True, "model snapshot is complete")


def _file_check(name: str, model_path: Path | None, *, label: str) -> PreflightCheck:
    if model_path is None:
        return _check(name, False, f"{label} path is not configured")
    if not model_path.is_absolute() or not model_path.is_file():
        return _check(name, False, f"{label} file is missing")
    return _check(name, True, f"{label} file is available")


def _controlled_pythonpath(prepared: PreparedRuntime, role: str) -> tuple[str, ...]:
    raw = prepared.metadata.get("pythonpath")
    if not isinstance(raw, Mapping):
        raise RuntimeBootstrapError("prepared runtime Python path is invalid")
    entries = raw.get(role)
    if not isinstance(entries, (list, tuple)):
        raise RuntimeBootstrapError("prepared runtime Python path is invalid")
    resolved: list[str] = []
    release = prepared.paths.release.resolve()
    for entry in entries:
        if not isinstance(entry, str) or not entry or "\x00" in entry:
            raise RuntimeBootstrapError("prepared runtime Python path is invalid")
        candidate = (prepared.paths.release / entry).resolve()
        try:
            candidate.relative_to(release)
        except ValueError as exc:
            raise RuntimeBootstrapError("prepared runtime Python path escapes release") from exc
        if not candidate.is_dir():
            raise RuntimeBootstrapError("prepared runtime Python path is missing")
        resolved.append(str(candidate))
    return tuple(resolved)


def _package_map(prepared: PreparedRuntime, role: str) -> dict[str, str]:
    packages = prepared.metadata.get("packages")
    if not isinstance(packages, Mapping):
        raise RuntimeBootstrapError("prepared runtime package identity is missing")
    values = packages.get(role)
    if not isinstance(values, Mapping):
        raise RuntimeBootstrapError("prepared runtime package identity is invalid")
    if any(
        not isinstance(name, str) or not isinstance(version, str)
        for name, version in values.items()
    ):
        raise RuntimeBootstrapError("prepared runtime package identity is invalid")
    return dict(cast(Mapping[str, str], values))


def _runtime_probe_code(
    python_version: str,
    packages: Mapping[str, str],
    module: str,
    pythonpath: Sequence[str],
) -> str:
    version = tuple(int(part) for part in python_version.split("."))
    return (
        "import importlib, importlib.metadata, sys\n"
        f"assert sys.version_info[:3] == {version!r}\n"
        f"sys.path[:0] = {tuple(pythonpath)!r}\n"
        f"expected = {dict(packages)!r}\n"
        "for name, expected_version in expected.items():\n"
        "    assert importlib.metadata.version(name) == expected_version\n"
        f"importlib.import_module({module!r})\n"
    )


def _managed_runtime_checks(
    layout: ServiceLayout, runner: CommandRunner
) -> tuple[PreflightCheck, ...]:
    """Check an installed lock-keyed runtime without loading a model or using the network."""
    try:
        lock = load_runtime_lock()
        prepared = load_prepared_runtime(layout.app_home, lock)
        asr_packages = _package_map(prepared, "asr")
        tts_packages = _package_map(prepared, "tts")
        asr_path = _controlled_pythonpath(prepared, "asr")
        tts_path = _controlled_pythonpath(prepared, "tts")
    except Exception:
        message = "prepared runtime is unavailable"
        return tuple(
            _check(name, False, message)
            for name in (
                "managed_runtime",
                "managed_runtime_identity",
                "managed_asr_runtime",
                "managed_tts_runtime",
                "managed_ffmpeg",
            )
        )

    paths = prepared.paths
    ffmpeg_ok = (
        paths.ffmpeg.is_absolute()
        and paths.ffmpeg.is_file()
        and os.access(paths.ffmpeg, os.X_OK)
    )
    checks = [
        _check("managed_runtime", True, "prepared vendor runtime is available"),
        _check("managed_runtime_identity", True, "runtime lock and manifest identity match"),
        _check(
            "managed_ffmpeg",
            ffmpeg_ok,
            "prepared ffmpeg is available" if ffmpeg_ok else "prepared ffmpeg is missing",
        ),
    ]
    for name, role, module, path, packages in (
        ("managed_asr_runtime", "ASR", "mlx_qwen3_asr", asr_path, asr_packages),
        ("managed_tts_runtime", "TTS", "mlx_audio", tts_path, tts_packages),
    ):
        try:
            completed = runner(
                (
                    str(paths.asr_python if role == "ASR" else paths.tts_python),
                    "-c",
                    _runtime_probe_code(lock.python, packages, module, path),
                )
            )
            ok = completed.returncode == 0
        except Exception:
            ok = False
        checks.append(
            _check(
                name,
                ok,
                f"prepared {role} runtime identity and worker import are available"
                if ok
                else f"prepared {role} runtime package or worker import failed",
            )
        )
    return tuple(checks)


def _resolve_ffmpeg(configured_path: Path | str | None = None) -> Path | None:
    """Resolve the configured executable using the same strict path policy."""

    if configured_path is not None:
        try:
            return Path(
                resolve_configured_executable(
                    configured_path,
                    error_code="ffmpeg_unavailable",
                )
            )
        except ValueError:
            return None
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg:
        return Path(ffmpeg)
    return next(
        (
            candidate
            for candidate in FFMPEG_FALLBACKS
            if candidate.is_file() and os.access(candidate, os.X_OK)
        ),
        None,
    )


def run_preflight(
    layout: ServiceLayout,
    *,
    require_tts: bool,
    runner: CommandRunner = subprocess.run,
    host_python: Path | None = None,
) -> PreflightResult:
    """Validate an installed service without starting workers or downloading models."""
    checks: list[PreflightCheck] = []
    checks.append(
        _check(
            "app_home",
            layout.app_home.is_absolute() and layout.app_home.is_dir(),
            "app home is available" if layout.app_home.is_dir() else "app home is missing",
        )
    )
    config_exists = layout.config_file.is_file()
    checks.append(
        _check(
            "config_file",
            config_exists,
            "configuration file is present" if config_exists else "configuration file is missing",
        )
    )
    config_private = config_exists and layout.config_file.stat().st_mode & 0o777 == 0o600
    checks.append(
        _check(
            "config_permissions",
            config_private,
            "configuration file is private"
            if config_private
            else "configuration file must have mode 0600",
        )
    )
    settings: Settings | None = None
    if config_exists:
        try:
            settings = Settings.from_env_file(layout.config_file)
            from speechrail.config.model_catalog import load_catalog
            from speechrail.config.selection import resolve_selection
            from speechrail.service.profile_store import recover_selection

            selection = recover_selection(layout.app_home)
            if selection is not None:
                settings = resolve_selection(settings, selection, load_catalog(), layout.app_home)
        except Exception:
            settings = None

    ffmpeg_path = _resolve_ffmpeg(settings.ffmpeg_path if settings is not None else None)
    checks.append(
        _check(
            "ffmpeg",
            ffmpeg_path is not None,
            "ffmpeg is available" if ffmpeg_path is not None else "ffmpeg executable is missing",
        )
    )

    if not config_exists:
        checks.append(_check("settings", False, "cannot validate settings without configuration"))
        checks.append(_check("asr_config", False, "cannot validate ASR without configuration"))
        checks.append(_check("tts_config", not require_tts, "configuration file is missing"))
        checks.append(
            _check(
                "diarization_config",
                True,
                "optional diarization profile is not configured",
            )
        )
        return PreflightResult(ok=all(check.ok for check in checks), checks=tuple(checks))

    if settings is None:
        checks.append(_check("settings", False, "configuration validation failed"))
        checks.append(_check("asr_config", False, "ASR configuration validation failed"))
        checks.append(_check("tts_config", not require_tts, "TTS configuration validation failed"))
        checks.append(
            _check(
                "diarization_config",
                False,
                "diarization configuration validation failed",
            )
        )
        return PreflightResult(ok=all(check.ok for check in checks), checks=tuple(checks))

    checks.append(
        _check(
            "settings",
            not settings.allow_model_downloads and not settings.tts_allow_model_downloads,
            "configuration is valid and model downloads are disabled"
            if not settings.allow_model_downloads and not settings.tts_allow_model_downloads
            else "model downloads must be disabled",
        )
    )
    asr_configured = settings.qwen3_model_dir is not None and settings.qwen3_python is not None
    checks.append(
        _check(
            "asr_config",
            asr_configured,
            "ASR runtime and snapshot are configured"
            if asr_configured
            else "ASR model and Python paths must be configured together",
        )
    )
    if asr_configured:
        checks.append(
            _snapshot_check("asr_snapshot", settings.qwen3_model_dir, MODEL_FILES, WEIGHT_FILE_SETS)
        )
        checks.append(_runtime_check("asr_runtime", settings.qwen3_python, "mlx_qwen3_asr", runner))
    else:
        checks.extend(
            [
                _check("asr_snapshot", False, "ASR snapshot cannot be checked"),
                _check("asr_runtime", False, "ASR runtime cannot be checked"),
            ]
        )

    tts_configured = (
        settings.qwen3_tts_model_dir is not None and settings.qwen3_tts_python is not None
    )
    tts_ok = tts_configured or not require_tts
    checks.append(
        _check(
            "tts_config",
            tts_ok,
            "TTS runtime and snapshot are configured"
            if tts_configured
            else "TTS is not configured; use explicit ASR-only mode",
        )
    )
    if tts_configured:
        checks.append(
            _snapshot_check("tts_snapshot", settings.qwen3_tts_model_dir, ("config.json",))
        )
        checks.append(
            _runtime_check("tts_runtime", settings.qwen3_tts_python, "mlx_audio", runner)
        )
    elif require_tts:
        checks.extend(
            [
                _check("tts_snapshot", False, "TTS snapshot cannot be checked"),
                _check("tts_runtime", False, "TTS runtime cannot be checked"),
            ]
        )

    if not asr_configured and not tts_configured:
        checks.extend(_managed_runtime_checks(layout, runner))

    optional_profile_python = host_python or Path(sys.executable)
    diarization_configured = settings.diarization_model_path is not None
    checks.append(
        _check(
            "diarization_config",
            True,
            "diarization profile is configured"
            if diarization_configured
            else "optional diarization profile is not configured",
        )
    )
    if diarization_configured:
        checks.append(
            _file_check(
                "diarization_snapshot",
                settings.diarization_model_path,
                label="diarization model",
            )
        )
        checks.append(
            _runtime_check(
                "diarization_runtime",
                optional_profile_python,
                "nemo.collections.asr.models",
                runner,
            )
        )
        if settings.diarization_embedding_model_path is not None:
            checks.append(
                _file_check(
                    "diarization_embedding_snapshot",
                    settings.diarization_embedding_model_path,
                    label="diarization embedding model",
                )
            )
            checks.append(
                _runtime_check(
                    "diarization_embedding_runtime",
                    optional_profile_python,
                    "onnxruntime",
                    runner,
                )
            )

    return PreflightResult(ok=all(check.ok for check in checks), checks=tuple(checks))


__all__ = [
    "FFMPEG_FALLBACKS",
    "CommandRunner",
    "PreflightCheck",
    "PreflightResult",
    "run_preflight",
]
