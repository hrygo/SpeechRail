"""Resolve managed model selection into runtime settings while preserving user configuration."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from speechrail.config import Settings
from speechrail.config.model_catalog import (
    ModelArtifact,
    ModelCatalog,
    RuntimeLock,
    load_catalog,
    load_runtime_lock,
)
from speechrail.service.profile_store import SelectionRecord


@dataclass(frozen=True, slots=True)
class ActiveModelCatalog:
    """Public model identity matched from already-resolved managed paths."""

    profile: str | None
    asr: ModelArtifact | None
    tts: ModelArtifact | None


def active_model_catalog(
    settings: Settings,
    catalog: ModelCatalog | None = None,
) -> ActiveModelCatalog:
    """Match active model directories to the packaged immutable catalog."""

    resolved_catalog = catalog or load_catalog()
    artifacts = {artifact.key: artifact for artifact in resolved_catalog.artifacts}
    asr_key = settings.qwen3_model_dir.name if settings.qwen3_model_dir else None
    tts_key = settings.qwen3_tts_model_dir.name if settings.qwen3_tts_model_dir else None
    asr = artifacts.get(asr_key) if asr_key else None
    tts = artifacts.get(tts_key) if tts_key else None
    profile = next(
        (
            preset.id
            for preset in resolved_catalog.presets
            if preset.asr == asr_key and preset.tts == tts_key
        ),
        None,
    )
    return ActiveModelCatalog(profile=profile, asr=asr, tts=tts)


def resolve_selection(
    settings: Settings,
    selection: Mapping[str, object] | None,
    catalog: ModelCatalog,
    app_home: Path,
    *,
    runtime_lock: RuntimeLock | None = None,
) -> Settings:
    """Overlay managed model selection on existing settings without altering other configs."""
    if selection is None:
        return settings

    if not isinstance(selection, Mapping):
        raise ValueError("selection must be a mapping or None")

    try:
        record = SelectionRecord.model_validate(selection)
    except Exception as exc:
        raise ValueError(f"invalid selection record: {exc}") from exc

    if runtime_lock is None:
        runtime_lock = load_runtime_lock()
    elif not isinstance(runtime_lock, RuntimeLock):
        raise ValueError("runtime_lock must be a RuntimeLock")
    if record.runtime_lock_id != runtime_lock.id:
        raise ValueError(
            f"selection runtime lock does not match published lock: {record.runtime_lock_id}"
        )

    resolved_app_home = Path(app_home).resolve()
    if not resolved_app_home.is_absolute():
        raise ValueError("app_home must be an absolute path")

    if not isinstance(catalog, ModelCatalog):
        raise ValueError("catalog must be a ModelCatalog")
    artifacts_map = {a.key: a for a in catalog.artifacts}

    asr_key = record.asr
    tts_key = record.tts

    if asr_key not in artifacts_map:
        raise ValueError(f"unknown ASR artifact key: {asr_key}")
    if tts_key not in artifacts_map:
        raise ValueError(f"unknown TTS artifact key: {tts_key}")

    asr_artifact = artifacts_map[asr_key]
    tts_artifact = artifacts_map[tts_key]

    if asr_artifact.family != "qwen3_asr" or asr_artifact.variant != "asr":
        raise ValueError("ASR artifact must use family=qwen3_asr and variant=asr")
    if tts_artifact.family != "qwen3_tts" or tts_artifact.variant not in {
        "voice_design",
        "custom_voice",
    }:
        raise ValueError(
            "TTS artifact must use family=qwen3_tts and variant=voice_design or custom_voice"
        )

    expected_preset = catalog.preset(record.preset)
    if expected_preset.asr != asr_key or expected_preset.tts != tts_key:
        raise ValueError(f"selection artifacts do not match preset: {record.preset}")

    models_dir = (resolved_app_home / "models").resolve()
    asr_dir = (models_dir / asr_key).resolve()
    tts_dir = (models_dir / tts_key).resolve()
    vendor_current = resolved_app_home / "vendor" / "current"
    vendor_python = vendor_current / "bin" / "python"
    vendor_ffmpeg = vendor_current / "ffmpeg" / "bin" / "ffmpeg"

    try:
        asr_dir.relative_to(models_dir)
        tts_dir.relative_to(models_dir)
    except ValueError as exc:
        raise ValueError("model path escapes models directory") from exc

    if ".staging" in asr_dir.parts or ".staging" in tts_dir.parts:
        raise ValueError("staging models cannot be used as active selection")

    if not asr_dir.is_dir():
        raise ValueError(f"ASR model snapshot directory is missing: {asr_dir}")

    # TTS: Only overlay if TTS was already enabled in settings or configured with a runtime.
    # Old installations without TTS enabled must not have it automatically enabled.
    tts_configured = (
        settings.qwen3_tts_model_dir is not None
        or settings.qwen3_tts_python is not None
    )

    final_tts_dir: Path | None = None
    if tts_configured:
        if not tts_dir.is_dir():
            raise ValueError(f"TTS model snapshot directory is missing: {tts_dir}")
        final_tts_dir = tts_dir

    updates: dict[str, object] = {
        "qwen3_model_dir": asr_dir,
        "qwen3_python": vendor_python,
        "ffmpeg_path": vendor_ffmpeg,
    }
    if asr_artifact.quantization.bits == 8:
        updates["dtype"] = "int8"

    if tts_configured:
        updates["qwen3_tts_model_dir"] = final_tts_dir
        updates["qwen3_tts_python"] = vendor_python

    return settings.model_copy(update=updates)


__all__ = ["ActiveModelCatalog", "active_model_catalog", "resolve_selection"]
