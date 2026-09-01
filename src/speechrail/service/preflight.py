"""Read-only checks for a packaged SpeechRail installation."""

from __future__ import annotations

import os
import shutil
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from speechrail.backends.qwen3_native import MODEL_FILES
from speechrail.config import Settings
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
    name: str, model_dir: Path | None, required_files: tuple[str, ...]
) -> PreflightCheck:
    if model_dir is None:
        return _check(name, False, "model snapshot path is not configured")
    if not model_dir.is_absolute() or not model_dir.is_dir():
        return _check(name, False, "model snapshot directory is missing")
    if any(not (model_dir / filename).is_file() for filename in required_files):
        return _check(name, False, "model snapshot is incomplete")
    return _check(name, True, "model snapshot is complete")


def run_preflight(
    layout: ServiceLayout,
    *,
    require_tts: bool,
    runner: CommandRunner = subprocess.run,
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
    ffmpeg = shutil.which("ffmpeg")
    ffmpeg_path = Path(ffmpeg) if ffmpeg else next(
        (
            candidate
            for candidate in FFMPEG_FALLBACKS
            if candidate.is_file() and os.access(candidate, os.X_OK)
        ),
        None,
    )
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
        return PreflightResult(ok=all(check.ok for check in checks), checks=tuple(checks))

    try:
        settings = Settings.from_env_file(layout.config_file)
    except Exception:
        checks.append(_check("settings", False, "configuration validation failed"))
        checks.append(_check("asr_config", False, "ASR configuration validation failed"))
        checks.append(_check("tts_config", not require_tts, "TTS configuration validation failed"))
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
        checks.append(_snapshot_check("asr_snapshot", settings.qwen3_model_dir, MODEL_FILES))
        checks.append(_runtime_check("asr_runtime", settings.qwen3_python, "qwen_asr", runner))
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

    return PreflightResult(ok=all(check.ok for check in checks), checks=tuple(checks))


__all__ = [
    "FFMPEG_FALLBACKS",
    "CommandRunner",
    "PreflightCheck",
    "PreflightResult",
    "run_preflight",
]
