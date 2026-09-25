"""Vendor-neutral prepared reference condition contract for clone TTS.

The pinned mlx-audio 0.4.8 Qwen3-TTS backend has a private in-model ICL cache,
but its public generation contract still accepts raw ref_audio + ref_text.
SpeechRail must not bind correctness to private cache fields or private helper
methods. This port is explicit and fail-closed until a pinned vendor version
exposes a reusable public prepared-condition contract that can be bounded,
invalidated, and identity-bound safely.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import asdict, dataclass
from typing import Final, Protocol

PREPARED_REFERENCE_SCHEMA = "prepared_reference_condition_v2"
_CONTENT_IDENTITY_RE: Final[re.Pattern[str]] = re.compile(r"[0-9a-f]{64}")
_REVISION_RE: Final[re.Pattern[str]] = re.compile(r"[0-9a-f]{40}")
_TOKEN_RE: Final[re.Pattern[str]] = re.compile(r"[A-Za-z0-9._-]{1,64}")


class PreparedReferenceIdentityError(RuntimeError):
    """Reference material does not match the identity recorded in its key."""


@dataclass(frozen=True, slots=True)
class PreparedReferenceKey:
    """Everything one reusable Base reference condition depends on.

    The key is the only cache namespace for prepared conditions. Because it
    binds the material identity, preprocessing, artifact/engine/quantization,
    text tokenizer, speech codec and implementation version together, two
    precisions (for example q8 and bf16) -- or two engines serving the same
    voice id -- can never share one cached tensor by accident.
    """

    content_identity: str
    preprocessing_version: str
    model_revision: str
    engine_revision: str
    quantization: str
    tokenizer_revision: str
    codec_revision: str
    implementation_version: str
    conditioning_mode: str = "icl"
    schema_version: str = PREPARED_REFERENCE_SCHEMA

    def __post_init__(self) -> None:
        if _CONTENT_IDENTITY_RE.fullmatch(self.content_identity) is None:
            raise ValueError("content identity must be a sha256 hex digest")
        for name in ("model_revision", "tokenizer_revision"):
            if _REVISION_RE.fullmatch(getattr(self, name)) is None:
                raise ValueError(f"{name} must be a 40-character hex revision")
        for name in (
            "preprocessing_version",
            "engine_revision",
            "codec_revision",
            "implementation_version",
            "conditioning_mode",
            "schema_version",
        ):
            value = getattr(self, name)
            if not isinstance(value, str) or _TOKEN_RE.fullmatch(value) is None:
                raise ValueError(f"{name} must be a short version token")
        if not isinstance(self.quantization, str) or _TOKEN_RE.fullmatch(self.quantization) is None:
            raise ValueError("quantization must be a short version token")

    @property
    def digest(self) -> str:
        """Stable cache key material for this prepared condition."""

        payload = json.dumps(asdict(self), sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def prepared_reference_content_identity(*, reference_audio: bytes, reference_text: str) -> str:
    """Hash canonical reference material without retaining it."""

    if not isinstance(reference_audio, bytes):
        raise ValueError("reference audio must be bytes")
    if not isinstance(reference_text, str):
        raise ValueError("reference text must be a string")
    digest = hashlib.sha256()
    digest.update(b"speechrail-prepared-reference-v1\x00")
    digest.update(len(reference_audio).to_bytes(8, "big"))
    digest.update(reference_audio)
    encoded_text = reference_text.encode("utf-8")
    digest.update(len(encoded_text).to_bytes(8, "big"))
    digest.update(encoded_text)
    return digest.hexdigest()


def verify_prepared_reference_material(
    key: PreparedReferenceKey, *, reference_audio: bytes, reference_text: str
) -> None:
    """Fail closed when material does not match the key that will name its tensor."""

    identity = prepared_reference_content_identity(
        reference_audio=reference_audio, reference_text=reference_text
    )
    if identity != key.content_identity:
        raise PreparedReferenceIdentityError("reference material does not match the key")


@dataclass(frozen=True, slots=True)
class PreparedReferenceCondition:
    """Opaque immutable reference to a provider-owned reusable condition."""

    schema_version: str
    provider: str
    identity: str
    voice_revision: str
    key: PreparedReferenceKey

    @property
    def model_revision(self) -> str:
        """Model revision frozen by the prepared key."""

        return self.key.model_revision


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
        key: PreparedReferenceKey,
        reference_audio: bytes,
        reference_text: str,
        voice_revision: str,
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
        key: PreparedReferenceKey,
        reference_audio: bytes,
        reference_text: str,
        voice_revision: str,
    ) -> PreparedReferenceCondition:
        del key, reference_audio, reference_text, voice_revision
        raise PreparedReferenceUnsupportedError(self.support.reason)


__all__ = [
    "MLX_AUDIO_0_4_8_QWEN3_TTS_SUPPORT",
    "PREPARED_REFERENCE_SCHEMA",
    "PreparedReferenceCondition",
    "PreparedReferenceIdentityError",
    "PreparedReferenceKey",
    "PreparedReferenceProvider",
    "PreparedReferenceSupport",
    "PreparedReferenceUnsupportedError",
    "UnsupportedPreparedReferenceProvider",
    "prepared_reference_content_identity",
    "verify_prepared_reference_material",
]
