"""Vendor-neutral prepared reference condition contract for clone TTS.

The pinned mlx-audio 0.4.8 Qwen3-TTS backend has a private in-model ICL cache,
but its public generation contract still accepts raw ref_audio + ref_text.
SpeechRail must not bind correctness to private cache fields or private helper
methods. This port is explicit and fail-closed until a pinned vendor version
exposes a reusable public prepared-condition contract that can be bounded,
invalidated, and identity-bound safely.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol


PREPARED_REFERENCE_SCHEMA = "prepared_reference_condition_v1"


@dataclass(frozen=True, slots=True)
class PreparedReferenceCondition:
    """Opaque immutable reference to a provider-owned reusable condition."""

    schema_version: str
    provider: str
    identity: str
    voice_revision: str
    model_revision: str | None


@dataclass(frozen=True, slots=True)
class PreparedReferenceSupport:
    """Audited support state for one pinned vendor/runtime combination."""

    supported: bool
    provider: str
    vendor_package: str
    vendor_version: str
    public_contract: str
    private_cache_observed: bool
    reason: str


class PreparedReferenceUnsupportedError(RuntimeError):
    """The pinned backend has no supported public prepared-reference port."""


class PreparedReferenceProvider(Protocol):
    """Provider boundary used by future prepared-condition implementations."""

    @property
    def support(self) -> PreparedReferenceSupport: ...

    def prepare(
        self,
        *,
        reference_audio: bytes,
        reference_text: str,
        voice_revision: str,
        model_revision: str | None,
    ) -> PreparedReferenceCondition: ...


MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT = PreparedReferenceSupport(
    supported=False,
    provider="mlx_audio.qwen3_tts",
    vendor_package="mlx-audio",
    vendor_version="0.4.8",
    public_contract="generate(ref_audio, ref_text)",
    private_cache_observed=True,
    reason="public_api_has_no_reusable_prepared_reference_condition",
)


class UnsupportedPreparedReferenceProvider:
    """Fail-closed adapter for the currently pinned mlx-audio public API."""

    support = MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT

    def prepare(
        self,
        *,
        reference_audio: bytes,
        reference_text: str,
        voice_revision: str,
        model_revision: str | None,
    ) -> PreparedReferenceCondition:
        del reference_audio, reference_text, voice_revision, model_revision
        raise PreparedReferenceUnsupportedError(self.support.reason)


__all__ = [
    "MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT",
    "PREPARED_REFERENCE_SCHEMA",
    "PreparedReferenceCondition",
    "PreparedReferenceProvider",
    "PreparedReferenceSupport",
    "PreparedReferenceUnsupportedError",
    "UnsupportedPreparedReferenceProvider",
]
