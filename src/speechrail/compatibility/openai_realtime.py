"""OpenAI Realtime WebSocket wire adapter for SpeechRail's ASR/TTS only.

This module builds and validates the OpenAI Realtime event envelope.  It
deliberately supports only the ASR/TTS subset of the protocol: session
configuration, input audio buffering, transcription outcomes, and one TTS
response.  LLM conversation history, tools, and non-audio modalities are
rejected with a stable ``error`` instead of being silently accepted.

The adapter owns no inference state; the route maps these events onto the
existing ``RealtimeAsrFactory``/``RealtimeAsrSession`` and TTS ports.
"""

from __future__ import annotations

from typing import Any, Literal

from speechrail.domain.diarization import DiarizationConfig

_PROTOCOL_VERSION = "realtime=v1"
_ASR_MODEL_ALIASES = {
    "whisper-1": "speechrail/qwen3-asr-1.7b",
    "gpt-4o-transcribe": "speechrail/qwen3-asr-1.7b",
    "gpt-4o-mini-transcribe": "speechrail/qwen3-asr-1.7b",
    "gpt-transcribe": "speechrail/qwen3-asr-1.7b",
    "gpt-live-transcribe": "speechrail/qwen3-asr-1.7b",
    "gpt-4o-transcribe-diarize": "speechrail/qwen3-asr-1.7b",
}
_TTS_MODEL_ALIASES = {
    "tts-1": "speechrail/qwen3-tts",
    "tts-1-hd": "speechrail/qwen3-tts",
    "gpt-4o-mini-tts": "speechrail/qwen3-tts",
}

_PCM16_FORMAT: dict[str, object] = {
    "type": "pcm16",
    "sample_rate": 16_000,
    "channels": 1,
    "bits_per_sample": 16,
}

_SUPPORTED_TURN_DETECTION: frozenset[str | None] = frozenset({None, "manual"})
_SUPPORTED_MODALITIES: frozenset[str] = frozenset({"text", "audio"})

_UNSUPPORTED_CLIENT_EVENTS: frozenset[str] = frozenset(
    {"conversation.item.delete", "conversation.item.truncate"}
)


class RealtimeAdapterError(ValueError):
    """Protocol-level rejection with a stable OpenAI-style error code."""

    def __init__(self, code: str, message: str, *, event_id: str | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.event_id = event_id


def canonical_asr_model(model: str, *, registered: frozenset[str]) -> str | None:
    """Map an accepted ASR model id or alias to the canonical profile."""
    if model in registered:
        return model
    return _ASR_MODEL_ALIASES.get(model)


def canonical_tts_model(model: str, *, registered: frozenset[str]) -> str | None:
    """Map an accepted TTS model id or alias to the canonical profile."""
    if model in registered:
        return model
    return _TTS_MODEL_ALIASES.get(model)


def asr_model_aliases() -> dict[str, str]:
    """All OpenAI-standard ASR aliases mapped to their canonical profile."""
    return dict(_ASR_MODEL_ALIASES)


def tts_model_aliases() -> dict[str, str]:
    """All OpenAI-standard TTS aliases mapped to their canonical profile."""
    return dict(_TTS_MODEL_ALIASES)


def session_created(*, session_id: str, model: str, tts_ready: bool) -> dict[str, object]:
    """The OpenAI ``session.created`` payload scoped to SpeechRail capabilities."""
    capabilities: list[str] = ["transcription"]
    if tts_ready:
        capabilities.append("speech")
    return {
        "type": "session.created",
        "event_id": f"event_{session_id}_created",
        "session": {
            "id": session_id,
            "model": model,
            "modalities": ["text", "audio"],
            "instructions": "",
            "voice": "default" if tts_ready else None,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "turn_detection": None,
            "tools": [],
            "tool_choice": "none",
            "temperature": 0.8,
            "max_response_output_tokens": "inf",
            "capabilities": capabilities,
        },
    }


def session_updated(*, session_id: str, model: str) -> dict[str, object]:
    return {
        "type": "session.updated",
        "event_id": f"event_{session_id}_updated",
        "session": {
            "id": session_id,
            "model": model,
            "modalities": ["text", "audio"],
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "turn_detection": None,
            "tools": [],
            "tool_choice": "none",
        },
    }


def conversation_created(*, session_id: str) -> dict[str, object]:
    return {
        "type": "conversation.created",
        "event_id": f"event_{session_id}_conversation",
        "conversation": {"id": f"conv_{session_id}"},
    }


def input_audio_buffer_committed(*, session_id: str) -> dict[str, object]:
    return {
        "type": "input_audio_buffer.committed",
        "event_id": f"event_{session_id}_committed",
        "previous_item_id": None,
        "item_id": f"item_{session_id}_input",
    }


def input_audio_buffer_cleared(*, session_id: str) -> dict[str, object]:
    return {
        "type": "input_audio_buffer.cleared",
        "event_id": f"event_{session_id}_cleared",
    }


def conversation_item_created(*, session_id: str, transcript: str) -> dict[str, object]:
    return {
        "type": "conversation.item.created",
        "event_id": f"event_{session_id}_item",
        "previous_item_id": None,
        "item": {
            "id": f"item_{session_id}_input",
            "object": "realtime.item",
            "type": "message",
            "role": "user",
            "content": [
                {
                    "type": "input_audio",
                    "transcript": transcript,
                    "audio": None,
                }
            ],
        },
    }


def conversation_text_item_created(
    *, session_id: str, item_id: str, text: str
) -> dict[str, object]:
    return {
        "type": "conversation.item.created",
        "event_id": f"event_{session_id}_text_item",
        "previous_item_id": None,
        "item": {
            "id": item_id,
            "object": "realtime.item",
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": text}],
        },
    }


def transcription_delta(*, session_id: str, delta: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.delta",
        "event_id": f"event_{session_id}_transcription_delta",
        "item_id": f"item_{session_id}_input",
        "content_index": 0,
        "delta": delta,
    }


def transcription_completed(*, session_id: str, transcript: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.completed",
        "event_id": f"event_{session_id}_transcription",
        "item_id": f"item_{session_id}_input",
        "content_index": 0,
        "transcript": transcript,
        "usage": {
            "type": "transcript_text_usage_tokens",
            "input_tokens": 0,
            "output_tokens": 0,
            "total_tokens": 0,
        },
    }


def transcription_segment(
    *,
    session_id: str,
    item_id: str,
    segment_id: str,
    text: str,
    speaker: str | None,
    start_ms: int,
    end_ms: int,
) -> dict[str, object]:
    """Render one OpenAI-compatible immutable transcription segment."""
    return {
        "type": "conversation.item.input_audio_transcription.segment",
        "event_id": f"event_{session_id}_segment_{segment_id}",
        "item_id": item_id,
        "content_index": 0,
        "id": segment_id,
        "text": text,
        "speaker": speaker,
        "start": start_ms / 1000,
        "end": end_ms / 1000,
    }


def transcription_failed(*, session_id: str, code: str, message: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.failed",
        "event_id": f"event_{session_id}_transcription_failed",
        "item_id": f"item_{session_id}_input",
        "content_index": 0,
        "error": {"type": "transcription_error", "code": code, "message": message},
    }


def response_created(*, session_id: str, response_id: str) -> dict[str, object]:
    return {
        "type": "response.created",
        "event_id": f"event_{session_id}_response_created",
        "response": {
            "id": response_id,
            "object": "realtime.response",
            "status": "in_progress",
            "status_details": None,
            "output": [],
            "usage": None,
        },
    }


def response_output_item_added(
    *, session_id: str, response_id: str, item_id: str
) -> dict[str, object]:
    return {
        "type": "response.output_item.added",
        "event_id": f"event_{session_id}_output_item",
        "response_id": response_id,
        "output_index": 0,
        "item": {
            "id": item_id,
            "object": "realtime.item",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_audio", "transcript": None, "audio": None}],
        },
    }


def response_output_item_done(
    *, session_id: str, response_id: str, item_id: str, transcript: str
) -> dict[str, object]:
    return {
        "type": "response.output_item.done",
        "event_id": f"event_{session_id}_output_item_done",
        "response_id": response_id,
        "output_index": 0,
        "item": {
            "id": item_id,
            "object": "realtime.item",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_audio", "transcript": transcript, "audio": None}],
        },
    }


def response_content_part_added(
    *, session_id: str, response_id: str, item_id: str
) -> dict[str, object]:
    return {
        "type": "response.content_part.added",
        "event_id": f"event_{session_id}_part_added",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "part": {"type": "audio", "transcript": None, "audio": None},
    }


def response_content_part_done(
    *, session_id: str, response_id: str, item_id: str, transcript: str
) -> dict[str, object]:
    return {
        "type": "response.content_part.done",
        "event_id": f"event_{session_id}_part_done",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "part": {"type": "audio", "transcript": transcript, "audio": None},
    }


def response_output_audio_delta(
    *, session_id: str, response_id: str, item_id: str, delta: str
) -> dict[str, object]:
    return {
        "type": "response.output_audio.delta",
        "event_id": f"event_{session_id}_audio_delta",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "delta": delta,
    }


def response_output_audio_done(
    *, session_id: str, response_id: str, item_id: str
) -> dict[str, object]:
    return {
        "type": "response.output_audio.done",
        "event_id": f"event_{session_id}_audio_done",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
    }


def response_output_audio_transcript_delta(
    *, session_id: str, response_id: str, item_id: str, delta: str
) -> dict[str, object]:
    return {
        "type": "response.output_audio_transcript.delta",
        "event_id": f"event_{session_id}_transcript_delta",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "delta": delta,
    }


def response_output_audio_transcript_done(
    *, session_id: str, response_id: str, item_id: str, transcript: str
) -> dict[str, object]:
    return {
        "type": "response.output_audio_transcript.done",
        "event_id": f"event_{session_id}_transcript_done",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "transcript": transcript,
    }


def response_done(
    *, session_id: str, response_id: str, status: str = "completed"
) -> dict[str, object]:
    return {
        "type": "response.done",
        "event_id": f"event_{session_id}_response_done",
        "response": {
            "id": response_id,
            "object": "realtime.response",
            "status": status,
            "status_details": None,
            "output": [],
            "usage": None,
        },
    }


def error_event(*, code: str, message: str, event_id: str | None = None) -> dict[str, object]:
    return {
        "type": "error",
        "event_id": f"event_{event_id or 'unknown'}_error",
        "error": {"type": "invalid_request_error", "code": code, "message": message},
    }


def _require_object(event: dict[str, Any], field: str) -> dict[str, Any]:
    value = event.get(field)
    if not isinstance(value, dict):
        raise RealtimeAdapterError("invalid_event", f"{field} must be an object")
    return value


def apply_session_update(
    event: dict[str, Any],
    *,
    session_id: str,
    asr_model: str,
    tts_model: str | None,
    tts_ready: bool,
    registered_asr: frozenset[str],
    registered_tts: frozenset[str],
) -> tuple[dict[str, object], dict[str, Any]]:
    """Validate an OpenAI ``session.update`` and return (session.updated, config).

    The returned config is a SpeechRail-internal dict consumed by the route.
    """
    session = _require_object(event, "session")
    transcription = session.get("input_audio_transcription")
    transcription_obj: dict[str, Any] | None = None
    if transcription is not None:
        transcription_obj = _require_object(session, "input_audio_transcription")
    model = str(
        session.get("model")
        or (transcription_obj or {}).get("model")
        or asr_model
    )
    resolved_asr = canonical_asr_model(model, registered=registered_asr)
    if resolved_asr is None and canonical_tts_model(model, registered=registered_tts) is None:
        raise RealtimeAdapterError("model_not_found", f"unknown model: {model}")

    modalities = session.get("modalities")
    if modalities is not None and (
        not isinstance(modalities, list)
        or any(m not in _SUPPORTED_MODALITIES for m in modalities)
    ):
        raise RealtimeAdapterError(
            "unsupported_modalities", "only text/audio modalities are supported"
        )

    turn_detection = session.get("turn_detection")
    mode = (
        turn_detection.get("type")
        if isinstance(turn_detection, dict)
        else turn_detection
    )
    if mode not in _SUPPORTED_TURN_DETECTION:
        raise RealtimeAdapterError(
            "unsupported_turn_detection",
            "only manual turn detection is supported; send input_audio_buffer.commit",
        )

    tools = session.get("tools")
    if tools:
        raise RealtimeAdapterError("unsupported_tools", "tools are not supported")

    # Accept both OpenAI-standard audio format fields and the legacy nested
    # "audio" object; anything else fails closed.
    input_format = session.get("input_audio_format")
    if input_format not in (None, "pcm16"):
        raise RealtimeAdapterError(
            "unsupported_audio_format", "only pcm16 audio input is supported"
        )
    output_format = session.get("output_audio_format")
    if output_format not in (None, "pcm16"):
        raise RealtimeAdapterError(
            "unsupported_audio_format", "only pcm16 audio output is supported"
        )
    if "audio" in session:
        audio = _require_object(session, "audio")
        if "input" in audio:
            audio_input = _require_object(audio, "input")
            if audio_input.get("format") not in (None, "pcm16"):
                raise RealtimeAdapterError(
                    "unsupported_audio_format", "only pcm16 audio input is supported"
                )

    language: str | None = None
    languages: list[str] | None = None
    keywords: list[str] | None = None
    timestamp_granularities: list[str] | None = None
    diarization: dict[str, Any] | None = None
    known_speaker_names: list[str] | None = None
    known_speaker_references: list[str] | None = None
    if transcription_obj is not None:
        language = transcription_obj.get("language")
        if language is not None and not isinstance(language, str):
            raise RealtimeAdapterError("invalid_language", "language must be a string")
        languages = _string_list(transcription_obj, "languages")
        keywords = _string_list(transcription_obj, "keywords")
        known_speaker_names = _string_list(transcription_obj, "known_speaker_names")
        known_speaker_references = _string_list(transcription_obj, "known_speaker_references")
        timestamp_granularities = _string_list(transcription_obj, "timestamp_granularities")
        if timestamp_granularities is not None and any(
            value not in {"word", "segment"} for value in timestamp_granularities
        ):
            raise RealtimeAdapterError(
                "invalid_timestamp_granularities",
                "timestamp_granularities must contain only word or segment",
            )
        raw_diarization = transcription_obj.get("diarization", session.get("diarization"))
        if raw_diarization is not None:
            if not isinstance(raw_diarization, dict):
                raise RealtimeAdapterError("invalid_diarization", "diarization must be an object")
            try:
                diarization = DiarizationConfig.model_validate(raw_diarization).model_dump(
                    mode="json"
                )
            except ValueError as exc:
                raise RealtimeAdapterError("invalid_diarization", str(exc)) from exc
        if language is None and languages:
            language = languages[0]

    voice = session.get("voice")
    if voice is not None and not isinstance(voice, str):
        raise RealtimeAdapterError("invalid_voice", "voice must be a string")

    config: dict[str, Any] = {
        "model": resolved_asr or asr_model,
        "language": language or session.get("language"),
        "voice": voice,
    }
    for key, value in (
        ("languages", languages),
        ("keywords", keywords),
        ("timestamp_granularities", timestamp_granularities),
        ("diarization", diarization),
        ("known_speaker_names", known_speaker_names),
        ("known_speaker_references", known_speaker_references),
    ):
        if value is not None:
            config[key] = value
    return session_updated(session_id=session_id, model=model), config


def _string_list(session: dict[str, Any], field: str) -> list[str] | None:
    value = session.get(field)
    if value is None:
        return None
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise RealtimeAdapterError("invalid_session", f"{field} must be a string array")
    if any(not item.strip() for item in value):
        raise RealtimeAdapterError("invalid_session", f"{field} must not contain blank values")
    if len(value) > 128 or any(len(item) > 1_000 for item in value):
        raise RealtimeAdapterError("invalid_session", f"{field} exceeds its size limit")
    return list(value)


def parse_text_item(event: dict[str, Any]) -> str:
    """Extract a single short user text item used as TTS input."""
    item = _require_object(event, "item")
    if item.get("type") not in (None, "message"):
        raise RealtimeAdapterError("unsupported_item", "only message items are supported")
    role = item.get("role")
    if role not in (None, "user"):
        raise RealtimeAdapterError("invalid_item_role", "only user items are supported")
    content = item.get("content")
    if not isinstance(content, list) or len(content) != 1:
        raise RealtimeAdapterError("invalid_item_content", "exactly one content part is required")
    part = content[0]
    if not isinstance(part, dict) or part.get("type") != "input_text":
        raise RealtimeAdapterError("invalid_item_content", "only input_text content is supported")
    text = str(part.get("text") or "")
    if not text.strip():
        raise RealtimeAdapterError("invalid_item_content", "text must not be blank")
    if len(text) > 100_000:
        raise RealtimeAdapterError("text_too_long", "text exceeds the 100k character limit")
    return text


def validate_append(event: dict[str, Any]) -> bytes:
    """Return the decoded PCM16 bytes from an input_audio_buffer.append."""
    audio = event.get("audio")
    if not isinstance(audio, str) or not audio:
        raise RealtimeAdapterError("invalid_audio", "audio must be a base64 string")
    import base64

    try:
        payload = base64.b64decode(audio, validate=True)
    except (ValueError, TypeError) as exc:
        raise RealtimeAdapterError("invalid_audio", "audio is not valid base64") from exc
    if not payload or len(payload) % 2:
        raise RealtimeAdapterError("invalid_audio", "audio must be non-empty even-length PCM16")
    return payload


def reject_unsupported(event_type: str) -> None:
    """Fail closed on client events outside the supported ASR/TTS subset."""
    if event_type in _UNSUPPORTED_CLIENT_EVENTS:
        raise RealtimeAdapterError(
            "unsupported_operation", f"{event_type} is not supported by SpeechRail"
        )


EventKind = Literal["session", "append", "commit", "clear", "text_item", "tts", "cancel"]
