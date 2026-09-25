"""Resolve independent ASR/TTS specs into runtime settings without name guessing."""

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
from speechrail.domain.model_spec import ModelRole, SpecTier, required_spec_artifact
from speechrail.service.profile_store import SelectionRecord


class SelectionError(ValueError):
    """Managed selection cannot be resolved into one explicit artifact identity."""


@dataclass(frozen=True, slots=True)
class ActiveModelCatalog:
    """Explicit model identity published by the resolved service settings."""

    profile: str | None
    asr: ModelArtifact | None
    tts: ModelArtifact | None
    tts_clone: ModelArtifact | None
    aligner: str | None
    diarization: bool
    asr_spec: SpecTier | None = None
    tts_spec: SpecTier | None = None
    auto: str = "off"
    generation: int | None = None
    voice_design: ModelArtifact | None = None


def _artifact_for_spec(
    catalog: ModelCatalog,
    tier: SpecTier,
    role: ModelRole,
    *,
    required: bool,
) -> ModelArtifact | None:
    artifact_key = required_spec_artifact(tier, role)
    if artifact_key is None:
        if required:
            raise SelectionError(f"spec matrix has no artifact for {tier}/{role}")
        return None
    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}
    artifact = artifacts.get(artifact_key)
    if artifact is None:
        if required:
            raise SelectionError(
                f"unavailable model artifact for selected spec: {tier}/{role}"
            )
        return None
    return artifact


def active_model_catalog(
    settings: Settings,
    catalog: ModelCatalog | None = None,
) -> ActiveModelCatalog:
    """Read explicit selection identity; never infer identity from a directory name."""

    resolved_catalog = catalog or load_catalog()
    if (
        settings.selection_schema_version != 2
        or settings.asr_artifact_key is None
        or settings.tts_artifact_key is None
    ):
        return ActiveModelCatalog(
            profile=None,
            asr=None,
            tts=None,
            tts_clone=None,
            aligner=settings.alignment_artifact_key,
            diarization=settings.diarization_coreml_model_path is not None,
        )
    artifacts = {artifact.key: artifact for artifact in resolved_catalog.artifacts}
    return ActiveModelCatalog(
        profile=(
            f"{settings.selection_asr_spec}/{settings.selection_tts_spec}"
            if settings.selection_asr_spec is not None
            and settings.selection_tts_spec is not None
            else None
        ),
        asr=artifacts.get(settings.asr_artifact_key),
        tts=artifacts.get(settings.tts_artifact_key),
        tts_clone=(
            artifacts.get(settings.tts_base_artifact_key)
            if settings.tts_base_artifact_key is not None
            else None
        ),
        aligner=settings.alignment_artifact_key,
        diarization=settings.diarization_coreml_model_path is not None,
        asr_spec=settings.selection_asr_spec,
        tts_spec=settings.selection_tts_spec,
        auto=settings.selection_auto,
        generation=settings.selection_generation,
        voice_design=(
            artifacts.get(settings.voice_design_artifact_key)
            if settings.voice_design_artifact_key is not None
            else None
        ),
    )


def _require_directory(path: Path, *, label: str) -> Path:
    resolved = path.resolve()
    if ".staging" in resolved.parts:
        raise SelectionError("staging models cannot be used as active selection")
    if not resolved.is_dir():
        raise SelectionError(f"{label} snapshot directory is missing: {resolved}")
    return resolved


def resolve_selection(
    settings: Settings,
    selection: Mapping[str, object] | None,
    catalog: ModelCatalog,
    app_home: Path,
    *,
    runtime_lock: RuntimeLock | None = None,
) -> Settings:
    """Overlay one v2 selection while preserving unrelated user configuration."""

    if selection is None:
        return settings
    if not isinstance(selection, Mapping):
        raise ValueError("selection must be a mapping or None")
    try:
        record = SelectionRecord.model_validate(selection)
    except Exception as exc:
        raise SelectionError(f"invalid selection record: {exc}") from exc

    if runtime_lock is None:
        runtime_lock = load_runtime_lock()
    elif not isinstance(runtime_lock, RuntimeLock):
        raise ValueError("runtime_lock must be a RuntimeLock")
    if record.runtime_lock_id != runtime_lock.id:
        raise SelectionError(
            f"selection runtime lock does not match published lock: {record.runtime_lock_id}"
        )
    if not isinstance(catalog, ModelCatalog):
        raise ValueError("catalog must be a ModelCatalog")

    asr = _artifact_for_spec(catalog, record.asr_spec, "asr", required=True)
    tts = _artifact_for_spec(
        catalog, record.tts_spec, "tts_custom_voice", required=True
    )
    tts_base = _artifact_for_spec(catalog, record.tts_spec, "tts_base", required=False)
    voice_design = _artifact_for_spec(
        catalog, record.tts_spec, "voice_design", required=False
    )
    assert asr is not None and tts is not None

    resolved_app_home = Path(app_home).resolve()
    if not resolved_app_home.is_absolute():
        raise ValueError("app_home must be an absolute path")
    models_dir = (resolved_app_home / "models").resolve()
    asr_dir = _require_directory(models_dir / asr.key, label="ASR model")
    tts_dir = _require_directory(models_dir / tts.key, label="TTS model")
    clone_dir = (
        _require_directory(models_dir / tts_base.key, label="TTS clone model")
        if tts_base is not None
        else None
    )
    vendor_current = resolved_app_home / "vendor" / "current"
    vendor_python = vendor_current / "bin" / "python"
    vendor_ffmpeg = vendor_current / "ffmpeg" / "bin" / "ffmpeg"

    updates: dict[str, object] = {
        "qwen3_model_dir": asr_dir,
        "qwen3_tts_model_dir": tts_dir,
        "qwen3_tts_clone_model_dir": clone_dir,
        "qwen3_python": vendor_python,
        "qwen3_tts_python": vendor_python,
        "ffmpeg_path": vendor_ffmpeg,
        "selection_schema_version": 2,
        "selection_asr_spec": record.asr_spec,
        "selection_tts_spec": record.tts_spec,
        "selection_auto": record.auto,
        "selection_generation": record.generation,
        "selection_runtime_lock_id": record.runtime_lock_id,
        "asr_artifact_key": asr.key,
        "tts_artifact_key": tts.key,
        "tts_base_artifact_key": tts_base.key if tts_base is not None else None,
        "voice_design_artifact_key": (
            voice_design.key if voice_design is not None else None
        ),
        "alignment_artifact_key": None,
    }
    return settings.model_copy(update=updates)


__all__ = [
    "ActiveModelCatalog",
    "SelectionError",
    "active_model_catalog",
    "resolve_selection",
]
