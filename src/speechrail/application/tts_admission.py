"""Capability-aware TTS admission helpers."""

from __future__ import annotations

from speechrail.domain.tts_execution import VoiceLaneResolver
from speechrail.domain.tts_stream import IncrementalSpeechSynthesizer

# The lanes a TTS router may hand to the governor.  ``tts`` is the conservative
# wildcard for an injected or design-only component; the plan roles keep the
# CustomVoice and Base weights in separate lanes.  A stale lane name (for
# example the retired ``voice_clone``) is rejected instead of silently
# serializing every request behind one key.
#
# ``voice_design`` is the tier-independent on-demand design lane. It owns its
# worker and must not serialize behind (or evict) the production lanes, so it
# gets its own key; dual residency with per-lane TTL is governed per key.
_ALLOWED_TTS_LANES = frozenset({"tts", "tts_custom_voice", "tts_base", "voice_design"})


def tts_resource_key(resolver: VoiceLaneResolver | None, voice: str) -> str | None:
    """Return an optional stable worker lane for a TTS voice.

    The public ``SpeechSynthesizer`` port deliberately stays vendor-neutral.
    A separately injected resolver supplies the scheduling hint. Without it,
    the governor keeps its conservative wildcard TTS lane.
    """
    if resolver is None:
        return None
    key = resolver.resource_key_for_voice(voice)
    if key is None:
        return None
    if not isinstance(key, str) or not key.strip():
        raise RuntimeError("invalid_tts_resource_key")
    normalized = key.strip()
    if normalized not in _ALLOWED_TTS_LANES:
        raise RuntimeError("invalid_tts_resource_key")
    return normalized


def supports_incremental_stream(factory: IncrementalSpeechSynthesizer | None) -> bool:
    """Return whether the composition supplied an incremental factory.

    Capability is never inferred from a profile name, a resident model or the
    Python version: only an implementation that actually offers the append-only
    entry point can serve an incremental utterance. Readiness and protocol
    negotiation are evaluated separately.
    """
    return factory is not None


__all__ = ["supports_incremental_stream", "tts_resource_key"]
