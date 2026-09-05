"""Resolve managed model selection into runtime settings while preserving user configuration."""

from __future__ import annotations

from collections.abc import Mapping
from pathlib import Path
from typing import TYPE_CHECKING

from speechrail.config import Settings
from speechrail.service.profile_store import SelectionRecord

if TYPE_CHECKING:
    from speechrail.config.model_catalog import ModelArtifact, ModelCatalog


def resolve_selection(
    settings: Settings,
    selection: Mapping[str, object] | None,
    catalog: Mapping[str, ModelArtifact] | ModelCatalog,
    app_home: Path,
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

    resolved_app_home = Path(app_home).resolve()
    if not resolved_app_home.is_absolute():
        raise ValueError("app_home must be an absolute path")

    if hasattr(catalog, "artifacts"):
        artifacts_map: Mapping[str, ModelArtifact] = {a.key: a for a in catalog.artifacts}
    elif isinstance(catalog, Mapping):
        artifacts_map = catalog
    else:
        raise ValueError("catalog must be a ModelCatalog or a Mapping of artifacts")

    asr_key = record.asr
    tts_key = record.tts

    if asr_key not in artifacts_map:
        raise ValueError(f"unknown ASR artifact key: {asr_key}")
    if tts_key not in artifacts_map:
        raise ValueError(f"unknown TTS artifact key: {tts_key}")

    asr_artifact = artifacts_map[asr_key]
    tts_artifact = artifacts_map[tts_key]

    models_dir = (resolved_app_home / "models").resolve()
    asr_dir = (models_dir / asr_key).resolve()
    tts_dir = (models_dir / tts_key).resolve()

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
    final_tts_model_id: str = settings.tts_model_id
    if tts_configured:
        if not tts_dir.is_dir():
            raise ValueError(f"TTS model snapshot directory is missing: {tts_dir}")
        final_tts_dir = tts_dir
        final_tts_model_id = tts_artifact.model_id

    updates: dict[str, object] = {
        "qwen3_model_dir": asr_dir,
        "model_id": asr_artifact.model_id,
    }
    if asr_artifact.quantization.bits == 8:
        updates["dtype"] = "int8"

    if tts_configured:
        updates["qwen3_tts_model_dir"] = final_tts_dir
        updates["tts_model_id"] = final_tts_model_id

    return settings.model_copy(update=updates)


__all__ = ["resolve_selection"]
