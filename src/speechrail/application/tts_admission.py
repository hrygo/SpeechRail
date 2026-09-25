"""Capability-aware TTS admission helpers."""

from __future__ import annotations

# The lanes a TTS router may hand to the governor.  ``tts`` is the conservative
# wildcard for an injected or design-only component; the plan roles keep the
# CustomVoice and Base weights in separate lanes.  A stale lane name (for
# example the retired ``voice_clone``) is rejected instead of silently
# serializing every request behind one key.
_ALLOWED_TTS_LANES = frozenset({"tts", "tts_custom_voice", "tts_base"})


def tts_resource_key(synthesizer: object | None, voice: str) -> str | None:
    """Return an optional stable worker lane for a TTS voice.

    The public ``SpeechSynthesizer`` port deliberately stays vendor-neutral.
    Concrete capability routers may expose this internal scheduling hint; an
    injected synthesizer without it keeps the governor's conservative wildcard
    TTS lane.
    """
    resolver = getattr(synthesizer, "resource_key_for_voice", None)
    if not callable(resolver):
        return None
    key = resolver(voice)
    if key is None:
        return None
    if not isinstance(key, str) or not key.strip():
        raise RuntimeError("invalid_tts_resource_key")
    normalized = key.strip()
    if normalized not in _ALLOWED_TTS_LANES:
        raise RuntimeError("invalid_tts_resource_key")
    return normalized


def supports_incremental_stream(synthesizer: object | None) -> bool:
    """Return whether a synthesizer exposes the negotiated incremental port.

    Capability is never inferred from a profile name, a resident model or the
    Python version: only an implementation that actually offers the append-only
    entry point can serve an incremental utterance.
    """
    return callable(getattr(synthesizer, "open_incremental_stream", None))


__all__ = ["supports_incremental_stream", "tts_resource_key"]
