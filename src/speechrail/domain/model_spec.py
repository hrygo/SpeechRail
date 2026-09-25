"""Immutable model specifications; this module never loads or downloads a model."""

from __future__ import annotations

import re
from collections.abc import Mapping
from enum import StrEnum
from types import MappingProxyType

from pydantic import BaseModel, ConfigDict, Field, field_validator

from speechrail.config.model_catalog import (
    REQUIRED_SPEC_BINDINGS,
    ModelArtifact,
    ModelCatalog,
    ModelRole,
    SpecTier,
)

_REVISION_RE = re.compile(r"[0-9a-fA-F]{40}")


class ModelCapability(StrEnum):
    """Capabilities a model spec can implement without claiming runtime readiness."""

    BATCH_ASR = "batch_asr"
    REALTIME_ASR = "realtime_asr"
    TTS_BUILTIN_VOICE = "tts_builtin_voice"
    TTS_FIXED_VOICE = "tts_fixed_voice"
    TTS_VOICE_DESIGN = "tts_voice_design"
    ALIGNMENT = "alignment"
    DIARIZATION = "diarization"


class ModelSpec(BaseModel):
    """One explicit tier/role binding to an immutable artifact and engine revision."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    spec_id: str = Field(min_length=1, max_length=128)
    role: ModelRole
    tier: SpecTier
    artifact_key: str = Field(min_length=1, max_length=128)
    artifact_revision: str = Field(min_length=40, max_length=40)
    weight_precision: str = Field(min_length=1, max_length=32)
    compute_config: str = Field(min_length=1, max_length=64)
    engine_revision: str = Field(min_length=1, max_length=128)
    dependency_ids: tuple[str, ...] = ()
    languages: frozenset[str] = Field(min_length=1)
    implemented_capabilities: frozenset[ModelCapability] = Field(min_length=1)

    @field_validator("artifact_revision")
    @classmethod
    def validate_revision(cls, value: str) -> str:
        if _REVISION_RE.fullmatch(value) is None:
            raise ValueError("artifact_revision must be a 40-character hexadecimal revision")
        return value.lower()


class ModelSpecRegistry:
    """Explicit lookup table for model specs; no path or name inference is permitted."""

    def __init__(self, specs: tuple[ModelSpec, ...]) -> None:
        by_key: dict[tuple[SpecTier, ModelRole], ModelSpec] = {}
        for spec in specs:
            key = (spec.tier, spec.role)
            if key in by_key:
                raise ValueError(f"duplicate model spec: {spec.tier}/{spec.role}")
            by_key[key] = spec
        self._specs = MappingProxyType(by_key)

    def get(self, tier: SpecTier, role: ModelRole) -> ModelSpec:
        try:
            return self._specs[(tier, role)]
        except KeyError as exc:
            raise KeyError(f"unavailable model spec: {tier}/{role}") from exc

    def available(self, tier: SpecTier, role: ModelRole) -> bool:
        return (tier, role) in self._specs

    @property
    def specs(self) -> tuple[ModelSpec, ...]:
        return tuple(self._specs.values())


_ASR_CAPABILITIES = frozenset(
    {ModelCapability.BATCH_ASR, ModelCapability.REALTIME_ASR}
)
_TTS_CAPABILITIES: Mapping[ModelRole, frozenset[ModelCapability]] = MappingProxyType(
    {
        "tts_base": frozenset({ModelCapability.TTS_FIXED_VOICE}),
        "tts_custom_voice": frozenset({ModelCapability.TTS_BUILTIN_VOICE}),
        "voice_design": frozenset({ModelCapability.TTS_VOICE_DESIGN}),
        "alignment": frozenset({ModelCapability.ALIGNMENT}),
        "diarization": frozenset({ModelCapability.DIARIZATION}),
    }
)


def _weight_precision(artifact: ModelArtifact) -> str:
    quantization = artifact.quantization
    if quantization.bits is not None:
        return f"int{quantization.bits}"
    if quantization.dtype is not None:
        return quantization.dtype
    raise ValueError("artifact precision is unavailable")


def registry_from_catalog(
    catalog: ModelCatalog,
    *,
    engine_revision: str,
) -> ModelSpecRegistry:
    """Build the explicit spec registry from shipped immutable artifact identity."""

    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}
    specs: list[ModelSpec] = []
    for (tier, role), artifact_key in REQUIRED_SPEC_BINDINGS.items():
        artifact = artifacts.get(artifact_key)
        if artifact is None:
            continue
        family_ok = (
            role == "asr"
            and artifact.family == "qwen3_asr"
            and artifact.variant == "asr"
        ) or (
            role in {"tts_base", "tts_custom_voice", "voice_design"}
            and artifact.family == "qwen3_tts"
        ) or (
            role == "alignment"
            and artifact.family == "qwen3_forced_aligner"
            and artifact.variant == "aligner"
        )
        if not family_ok:
            raise ValueError(f"model spec {tier}/{role} references an incompatible artifact")
        capabilities = (
            _ASR_CAPABILITIES if role == "asr" else _TTS_CAPABILITIES.get(role, frozenset())
        )
        if not capabilities:
            continue
        specs.append(
            ModelSpec(
                spec_id=f"{tier}.{role}",
                role=role,
                tier=tier,
                artifact_key=artifact.key,
                artifact_revision=artifact.revision,
                weight_precision=_weight_precision(artifact),
                compute_config="mps",
                engine_revision=engine_revision,
                languages=frozenset({"zh", "en"}),
                implemented_capabilities=capabilities,
            )
        )
    return ModelSpecRegistry(tuple(specs))




def required_spec_artifact(tier: SpecTier, role: ModelRole) -> str | None:
    """Return the explicitly required artifact key, or None when not in the target matrix."""

    return REQUIRED_SPEC_BINDINGS.get((tier, role))


def required_spec_bindings() -> tuple[tuple[SpecTier, ModelRole, str], ...]:
    """Return the complete target matrix in stable order."""

    return tuple(
        (tier, role, artifact_key)
        for (tier, role), artifact_key in REQUIRED_SPEC_BINDINGS.items()
    )


__all__ = [
    "ModelCapability",
    "ModelRole",
    "ModelSpec",
    "ModelSpecRegistry",
    "SpecTier",
    "registry_from_catalog",
    "required_spec_artifact",
    "required_spec_bindings",
]
