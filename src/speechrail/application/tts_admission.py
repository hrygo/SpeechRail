"""Capability-aware TTS admission helpers."""

from __future__ import annotations


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
    return key.strip()


__all__ = ["tts_resource_key"]
