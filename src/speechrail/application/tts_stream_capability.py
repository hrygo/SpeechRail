"""Single incremental-TTS capability resolver for every public surface.

``/v1/models``, ``/v1/voices`` and the Realtime handshake must agree about what
this service can actually do, so they all read this module instead of
re-deriving support from a profile name, a resident model or a Python version.

Every axis is resolved separately and published next to the single verdict, so a
client can never read "the model supports streaming" as "every voice supports
streaming": variant support, artifact presence, active-profile enablement, the
per-voice reference precondition, the negotiated implementation and the current
resource budget stay distinguishable.  ``budget_available`` is deliberately
excluded from ``supported`` because it is transient.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Final

from speechrail.application.tts_admission import (
    supports_incremental_stream,
    tts_resource_key,
)
from speechrail.application.tts_stream import TtsStreamService
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.compatibility.openai_realtime import (
    TTS_STREAM_IMPLEMENTATION,
    TTS_STREAM_PROTOCOL_VERSION,
    tts_stream_limits_payload,
)
from speechrail.config.model_catalog import ModelArtifact
from speechrail.domain.tts_stream import DEFAULT_TTS_STREAM_LIMITS, TtsStreamLimits
from speechrail.runtime.resource_governor import WorkClass

# Only these variants have a verified append-only generation path.  A
# ``voice_design`` voice is a complete-text/instruction voice and must never be
# promoted into the stable-role incremental path.
_INCREMENTAL_VARIANTS: Final[frozenset[str]] = frozenset({"custom_voice", "base"})

_CLONE_HINT: Final[str] = (
    "register a stable clone of this voice and select it to use incremental TTS"
)
_REFERENCE_HINT: Final[str] = (
    "the incremental path needs a registered clone reference for this voice"
)
_IMPLEMENTATION_HINT: Final[str] = (
    "the active TTS backend did not negotiate the incremental stream protocol"
)


@dataclass(frozen=True, slots=True)
class TtsStreamCapability:
    """One voice-level incremental-TTS verdict with its separate axes."""

    voice_id: str
    voice_mode: str
    voice_variant: str | None
    supported: bool
    reason: str | None
    hint: str | None
    variant_supported: bool
    artifact_available: bool
    profile_enabled: bool
    reference_ready: bool
    implementation_supported: bool
    protocol_negotiated: bool | None
    ready: bool
    budget_available: bool | None
    limits: TtsStreamLimits | None = None


def _protocol_negotiated(synthesizer: object | None) -> bool | None:
    """Read the transport's own negotiation flag when it exposes one."""

    value = getattr(synthesizer, "supports_incremental_stream", None)
    if isinstance(value, bool):
        return value
    return None


def resolve_tts_stream_capability(
    *,
    voice_id: str,
    voice_mode: str,
    artifact: ModelArtifact | None,
    tts_ready: bool,
    voice_enabled: bool,
    synthesizer: object | None,
    stream_service: TtsStreamService | None,
) -> TtsStreamCapability:
    """Resolve the incremental capability of one voice on the current service."""

    artifact_available = artifact is not None
    variant = artifact.variant if artifact is not None else None
    variant_supported = variant in _INCREMENTAL_VARIANTS
    reference_ready = False
    if variant is not None and variant_supported:
        try:
            reference_ready = resolve_binding(variant, voice_id).supports_incremental_stream
        except ValueError:
            reference_ready = False
    negotiated = _protocol_negotiated(synthesizer)
    implementation_supported = supports_incremental_stream(synthesizer) and negotiated is not False
    ready = (
        tts_ready
        and voice_enabled
        and artifact_available
        and variant_supported
        and reference_ready
        and implementation_supported
    )
    budget_available: bool | None = None
    if stream_service is not None:
        budget_available = stream_service.governor.lane_available(
            WorkClass.REALTIME_TTS, tts_resource_key(synthesizer, voice_id)
        )

    reason: str | None = None
    hint: str | None = None
    if not voice_enabled:
        reason = "voice_disabled"
    elif not tts_ready:
        reason = "backend_not_ready"
    elif not artifact_available:
        reason = "artifact_unavailable"
    elif not variant_supported:
        reason = "variant_not_supported"
        hint = _CLONE_HINT
    elif not reference_ready:
        reason = "reference_not_ready"
        hint = _REFERENCE_HINT
    elif not implementation_supported:
        reason = "implementation_not_negotiated"
        hint = _IMPLEMENTATION_HINT
    if reason is not None:
        # A failing axis always wins over the transient budget signal: a voice
        # that cannot stream at all must never look merely "busy".
        return TtsStreamCapability(
            voice_id=voice_id,
            voice_mode=voice_mode,
            voice_variant=variant,
            supported=False,
            reason=reason,
            hint=hint,
            variant_supported=variant_supported,
            artifact_available=artifact_available,
            profile_enabled=voice_enabled,
            reference_ready=reference_ready,
            implementation_supported=implementation_supported,
            protocol_negotiated=negotiated,
            ready=False,
            budget_available=budget_available,
            limits=None,
        )
    return TtsStreamCapability(
        voice_id=voice_id,
        voice_mode=voice_mode,
        voice_variant=variant,
        supported=True,
        reason=None,
        hint=None,
        variant_supported=True,
        artifact_available=True,
        profile_enabled=True,
        reference_ready=True,
        implementation_supported=True,
        protocol_negotiated=negotiated,
        ready=ready,
        budget_available=budget_available,
        limits=DEFAULT_TTS_STREAM_LIMITS,
    )


def unresolved_tts_stream_capability(
    *, voice_id: str, voice_mode: str, reason: str, hint: str | None = None
) -> TtsStreamCapability:
    """Return a fail-closed verdict when the voice itself cannot be read."""

    return TtsStreamCapability(
        voice_id=voice_id,
        voice_mode=voice_mode,
        voice_variant=None,
        supported=False,
        reason=reason,
        hint=hint,
        variant_supported=False,
        artifact_available=False,
        profile_enabled=False,
        reference_ready=False,
        implementation_supported=False,
        protocol_negotiated=None,
        ready=False,
        budget_available=None,
    )


def tts_stream_capability_payload(capability: TtsStreamCapability) -> dict[str, object]:
    """Render one capability verdict for a JSON surface."""

    return {
        "supported": capability.supported,
        "reason": capability.reason,
        "hint": capability.hint,
        "protocol_version": (
            TTS_STREAM_PROTOCOL_VERSION if capability.implementation_supported else None
        ),
        "implementation_version": (
            TTS_STREAM_IMPLEMENTATION if capability.implementation_supported else None
        ),
        "voice_mode": capability.voice_mode,
        "voice_variant": capability.voice_variant,
        "limits": (
            tts_stream_limits_payload(capability.limits)
            if capability.limits is not None
            else None
        ),
        "axes": {
            "variant_supported": capability.variant_supported,
            "artifact_available": capability.artifact_available,
            "profile_enabled": capability.profile_enabled,
            "reference_ready": capability.reference_ready,
            "implementation_supported": capability.implementation_supported,
            "protocol_negotiated": capability.protocol_negotiated,
            "ready": capability.ready,
            "budget_available": capability.budget_available,
        },
    }


def tts_stream_model_payload(synthesizer: object | None) -> dict[str, object]:
    """Render the model-level view without claiming support for every voice.

    A model lists many voices, so the model scope reports only the
    voice-independent implementation axis and points at ``/v1/voices`` for the
    per-voice verdict.  It never ORs voice support into a model-wide claim.
    """

    negotiated = _protocol_negotiated(synthesizer)
    implementation_supported = supports_incremental_stream(synthesizer) and negotiated is not False
    return {
        "scope": "per_voice",
        "protocol_version": (
            TTS_STREAM_PROTOCOL_VERSION if implementation_supported else None
        ),
        "implementation_version": (
            TTS_STREAM_IMPLEMENTATION if implementation_supported else None
        ),
        "axes": {
            "implementation_supported": implementation_supported,
            "protocol_negotiated": negotiated,
        },
        "note": "streaming input is resolved per voice; read /v1/voices[].streaming",
    }


__all__ = [
    "TtsStreamCapability",
    "resolve_tts_stream_capability",
    "tts_stream_capability_payload",
    "tts_stream_model_payload",
    "unresolved_tts_stream_capability",
]
