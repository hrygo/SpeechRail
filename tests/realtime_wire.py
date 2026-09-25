"""Shared builders for the single current-only Realtime wire.

The runtime has exactly one Realtime vocabulary: ``session.update`` with the
nested ``session.audio.input`` configuration and the namespaced
``speechrail.tts.*`` incremental utterance. These helpers keep every test on
that vocabulary instead of re-deriving the envelope in each file.
"""

from __future__ import annotations

from typing import Any

DEFAULT_ASR_MODEL = "speechrail/qwen3-asr-1.7b"
WIRE_FORMAT = {"type": "audio/pcm", "rate": 24_000}


def pcm_format() -> dict[str, object]:
    return dict(WIRE_FORMAT)


def session_update(
    *,
    model: str = DEFAULT_ASR_MODEL,
    task: str = "conversation",
    language: str | None = None,
    languages: list[str] | None = None,
    prompt: str | None = None,
    keywords: list[str] | None = None,
    timestamp_granularities: list[str] | None = None,
    turn_detection: object = None,
    endpointing: dict[str, object] | None = None,
    tts: dict[str, object] | None = None,
    alignment: dict[str, object] | None = None,
    diarization: dict[str, object] | None = None,
    expected_asr_revision: str | None = None,
    expected_tts_revision: str | None = None,
    extra_transcription: dict[str, object] | None = None,
    extra_session: dict[str, object] | None = None,
    event_id: str = "evt-session-1",
) -> dict[str, Any]:
    """Build one schema-valid ``session.update`` event."""

    transcription: dict[str, object] = {"model": model}
    if extra_transcription:
        transcription.update(extra_transcription)
    if language is not None:
        transcription["language"] = language
    if languages is not None:
        transcription["languages"] = languages
    if prompt is not None:
        transcription["prompt"] = prompt
    if keywords is not None:
        transcription["keywords"] = keywords
    if timestamp_granularities is not None:
        transcription["timestamp_granularities"] = timestamp_granularities
    speechrail: dict[str, object] = {"task": task}
    if tts is not None:
        speechrail["tts"] = tts
    if alignment is not None:
        speechrail["alignment"] = alignment
    if diarization is not None:
        speechrail["diarization"] = diarization
    if endpointing is not None:
        speechrail["endpointing"] = endpointing
    if expected_asr_revision is not None:
        speechrail["expected_asr_revision"] = expected_asr_revision
    if expected_tts_revision is not None:
        speechrail["expected_tts_revision"] = expected_tts_revision
    session: dict[str, object] = {
        "type": "transcription",
        "audio": {
            "input": {
                "format": pcm_format(),
                "transcription": transcription,
                "turn_detection": turn_detection,
            }
        },
        "speechrail": speechrail,
    }
    if extra_session:
        session.update(extra_session)
    return {
        "type": "session.update",
        "event_id": event_id,
        "session": session,
    }


def server_vad(
    *,
    threshold: float = 0.5,
    prefix_padding_ms: int = 300,
    silence_duration_ms: int = 400,
) -> dict[str, object]:
    return {
        "mode": "server_vad",
        "threshold": threshold,
        "prefix_padding_ms": prefix_padding_ms,
        "silence_duration_ms": silence_duration_ms,
    }


def tts_start(
    *,
    request_id: str,
    voice: str = "serena",
    task: str = "conversation",
    voice_revision: str | None = None,
    expected_model_revision: str | None = None,
    speed: float | None = None,
    limits: dict[str, object] | None = None,
    event_id: str = "evt-tts-1",
    **extra: object,
) -> dict[str, Any]:
    event: dict[str, Any] = {
        "type": "speechrail.tts.start",
        "event_id": event_id,
        "request_id": request_id,
        "task": task,
        "voice": voice,
    }
    if voice_revision is not None:
        event["voice_revision"] = voice_revision
    if expected_model_revision is not None:
        event["expected_model_revision"] = expected_model_revision
    if speed is not None:
        event["speed"] = speed
    if limits is not None:
        event["limits"] = limits
    event.update(extra)
    return event


def tts_append_text(
    *,
    request_id: str,
    sequence: int,
    text: str,
    event_id: str | None = None,
) -> dict[str, Any]:
    return {
        "type": "speechrail.tts.append_text",
        "event_id": event_id or f"evt-tts-append-{sequence}",
        "request_id": request_id,
        "sequence": sequence,
        "text": text,
    }


def tts_finish_text(
    *, request_id: str, last_sequence: int, event_id: str = "evt-tts-finish"
) -> dict[str, Any]:
    return {
        "type": "speechrail.tts.finish_text",
        "event_id": event_id,
        "request_id": request_id,
        "last_sequence": last_sequence,
    }


def tts_cancel(*, request_id: str, event_id: str = "evt-tts-cancel") -> dict[str, Any]:
    return {
        "type": "speechrail.tts.cancel",
        "event_id": event_id,
        "request_id": request_id,
    }
