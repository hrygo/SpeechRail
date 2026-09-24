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

import math
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Literal

from speechrail.runtime.busy import busy_retry_policy

_PROTOCOL_VERSION = "realtime=v1"
_DIARIZATION_EVENT_VERSION = 1
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

_SUPPORTED_TURN_DETECTION: frozenset[str | None] = frozenset({None, "manual", "server_vad"})
_SUPPORTED_PARTIAL_MODES: frozenset[str] = frozenset({"delta", "snapshot"})
_SUPPORTED_TRANSCRIPTION_CHUNKS_MS: frozenset[int] = frozenset({500, 1_000, 2_000})

_UNSUPPORTED_CLIENT_EVENTS: frozenset[str] = frozenset(
    {
        "session.update",
        "conversation.item.create",
        "conversation.item.delete",
        "conversation.item.truncate",
        "response.create",
        "response.cancel",
        "response.audio.delta",
        "response.audio.done",
        "response.audio_transcript.delta",
        "response.audio_transcript.done",
    }
)


class RealtimeAdapterError(ValueError):
    """Protocol-level rejection with a stable OpenAI-style error code."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        event_id: str | None = None,
        busy_reason: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.event_id = event_id
        self.busy_reason = busy_reason


EventKind = Literal[
    "transcription_session_update",
    "append",
    "commit",
    "clear",
    "diarization_finish",
    "tts_create",
    "tts_cancel",
]


@dataclass(frozen=True, slots=True)
class ParsedClientEvent:
    kind: EventKind


@dataclass(frozen=True, slots=True)
class TTSCreateRequest:
    request_id: str
    text: str
    voice: str | None
    speed: float
    expected_voice_revision: str | None


@dataclass(frozen=True, slots=True)
class TTSCancelRequest:
    request_id: str
    response_id: str | None


def parse_client_event(event: dict[str, Any]) -> ParsedClientEvent:
    """Classify the one current-only client event vocabulary.

    This is deliberately strict: a removed event is not translated into the
    new caller-owned TTS command and an unknown event is not silently ignored.
    """
    event_type = event.get("type")
    if not isinstance(event_type, str) or not event_type:
        raise RealtimeAdapterError("invalid_event", "event.type must be a non-empty string")
    kinds: dict[str, EventKind] = {
        "transcription_session.update": "transcription_session_update",
        "input_audio_buffer.append": "append",
        "input_audio_buffer.commit": "commit",
        "input_audio_buffer.clear": "clear",
        "speechrail.diarization.finish": "diarization_finish",
        "speechrail.tts.create": "tts_create",
        "speechrail.tts.cancel": "tts_cancel",
    }
    if event_type in kinds:
        return ParsedClientEvent(kinds[event_type])
    if event_type in _UNSUPPORTED_CLIENT_EVENTS or event_type.startswith(
        ("conversation.", "response.")
    ):
        raise RealtimeAdapterError(
            "unsupported_operation", f"{event_type} is not supported by SpeechRail"
        )
    raise RealtimeAdapterError(
        "unsupported_operation", f"unsupported event type: {event_type}"
    )


def _bounded_string(
    value: object,
    *,
    field: str,
    max_length: int,
    allow_blank: bool = False,
) -> str:
    if not isinstance(value, str):
        raise RealtimeAdapterError("tts_request_invalid", f"{field} must be a string")
    if not allow_blank and not value.strip():
        raise RealtimeAdapterError("tts_request_invalid", f"{field} must not be blank")
    if len(value) > max_length:
        raise RealtimeAdapterError(
            "tts_request_invalid", f"{field} exceeds {max_length} characters"
        )
    return value


def parse_tts_create(event: dict[str, Any]) -> TTSCreateRequest:
    """Validate a caller-owned, stateless TTS render request."""
    request_id = _bounded_string(
        event.get("request_id"), field="request_id", max_length=128
    )
    text = _bounded_string(event.get("text"), field="text", max_length=4096)
    voice_value = event.get("voice")
    voice = None if voice_value is None else _bounded_string(
        voice_value, field="voice", max_length=128
    )
    speed_value = event.get("speed", 1.0)
    if (
        isinstance(speed_value, bool)
        or not isinstance(speed_value, (int, float))
        or not math.isfinite(float(speed_value))
        or not 0.25 <= float(speed_value) <= 4.0
    ):
        raise RealtimeAdapterError(
            "tts_request_invalid", "speed must be between 0.25 and 4.0"
        )
    revision_value = event.get("expected_voice_revision")
    revision = None if revision_value is None else _bounded_string(
        revision_value, field="expected_voice_revision", max_length=128
    )
    return TTSCreateRequest(
        request_id=request_id,
        text=text,
        voice=voice,
        speed=float(speed_value),
        expected_voice_revision=revision,
    )


def parse_tts_cancel(event: dict[str, Any]) -> TTSCancelRequest:
    """Validate an explicit caller-owned TTS cancellation."""
    request_id = _bounded_string(
        event.get("request_id"), field="request_id", max_length=128
    )
    response_value = event.get("response_id")
    response_id = None if response_value is None else _bounded_string(
        response_value, field="response_id", max_length=128
    )
    return TTSCancelRequest(request_id=request_id, response_id=response_id)


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


def diarization_model_aliases() -> dict[str, str]:
    """OpenAI aliases whose contract requires a diarization profile."""
    return {"gpt-4o-transcribe-diarize": _ASR_MODEL_ALIASES["gpt-4o-transcribe-diarize"]}


def tts_model_aliases() -> dict[str, str]:
    """All OpenAI-standard TTS aliases mapped to their canonical profile."""
    return dict(_TTS_MODEL_ALIASES)


def session_created(
    *,
    session_id: str,
    model: str,
    tts_ready: bool,
    tts_loudness_profile: str | None = None,
) -> dict[str, object]:
    """The current transcription-session payload scoped to SpeechRail capabilities."""
    capabilities: list[str] = ["transcription"]
    if tts_ready:
        capabilities.append("speech")
    session: dict[str, object] = {
        "id": session_id,
        "model": model,
        "type": "transcription",
        "input_audio_format": "pcm16",
        "input_audio_transcription": {"model": model},
        "turn_detection": None,
        "capabilities": capabilities,
        "speechrail": {"tts": {"enabled": False}},
    }
    if tts_loudness_profile is not None:
        session["speech_capabilities"] = {
            "audio_loudness_profile": tts_loudness_profile,
        }
    return {"type": "session.created", "session": session}


def session_updated(
    *,
    session_id: str,
    model: str,
    turn_detection: dict[str, object] | None = None,
    speechrail_diarization: dict[str, object] | None = None,
    speechrail_transcription: dict[str, object] | None = None,
    speechrail_tts_enabled: bool = False,
    tts_loudness_profile: str | None = None,
) -> dict[str, object]:
    session: dict[str, object] = {
        "id": session_id,
        "model": model,
        "type": "transcription",
        "input_audio_format": "pcm16",
        "input_audio_transcription": {"model": model},
        "turn_detection": turn_detection,
        "speechrail": {"tts": {"enabled": speechrail_tts_enabled}},
    }
    if speechrail_diarization is not None:
        speechrail = session["speechrail"]
        assert isinstance(speechrail, dict)
        speechrail["diarization"] = speechrail_diarization
    if speechrail_transcription is not None:
        speechrail = session["speechrail"]
        assert isinstance(speechrail, dict)
        speechrail["transcription"] = speechrail_transcription
    if tts_loudness_profile is not None:
        session["speech_capabilities"] = {
            "audio_loudness_profile": tts_loudness_profile,
        }
    return {
        "type": "transcription_session.updated",
        "session": session,
    }


def input_audio_buffer_committed(
    *, session_id: str, item_id: str | None = None
) -> dict[str, object]:
    return {
        "type": "input_audio_buffer.committed",
        "previous_item_id": None,
        "item_id": item_id or f"item_{session_id}_input",
    }


def input_audio_buffer_cleared(*, session_id: str) -> dict[str, object]:
    return {
        "type": "input_audio_buffer.cleared",
    }


def conversation_item_created(
    *, session_id: str, transcript: str, item_id: str | None = None
) -> dict[str, object]:
    return {
        "type": "conversation.item.created",
        "previous_item_id": None,
        "item": {
            "id": item_id or f"item_{session_id}_input",
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


def transcription_delta(*, item_id: str, delta: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.delta",
        "item_id": item_id,
        "content_index": 0,
        "delta": delta,
    }


def transcription_snapshot(
    *, item_id: str, revision: int, text: str
) -> dict[str, object]:
    """Render the latest mutable transcript hypothesis for one input item."""
    return {
        "type": "speechrail.transcription.snapshot",
        "item_id": item_id,
        "content_index": 0,
        "revision": revision,
        "text": text,
    }


def transcription_completed(*, item_id: str, transcript: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.completed",
        "item_id": item_id,
        "content_index": 0,
        "transcript": transcript,
        "usage": {
            "type": "transcript_text_usage_tokens",
            "input_tokens": 0,
            "output_tokens": 0,
            "total_tokens": 0,
        },
    }


def transcription_completed_extension(
    *,
    item_id: str,
    transcript: str,
    audio_start_sample: int,
    audio_end_sample: int,
    attribution_units: list[dict[str, object]],
    diagnostics: dict[str, object] | None = None,
) -> dict[str, object]:
    """Opted-in diarization mode: source item bounds, units and diagnostics."""
    payload: dict[str, object] = {
        "type": "conversation.item.input_audio_transcription.completed",
        "event_version": _DIARIZATION_EVENT_VERSION,
        "item_id": item_id,
        "content_index": 0,
        "transcript": transcript,
        "audio_start_sample": audio_start_sample,
        "audio_end_sample": audio_end_sample,
        "attribution_units": attribution_units,
    }
    if diagnostics is not None:
        payload["diagnostics"] = diagnostics
    return payload


def diarization_update_item(
    *,
    segment_uid: str,
    revision: int,
    status: str,
    speaker: str | None,
    coverage_ratio: float,
    overlap_ratio: float,
    candidates: tuple[tuple[str, float], ...],
) -> dict[str, object]:
    """Render one speaker-attribution revision entry."""
    return {
        "segment_uid": segment_uid,
        "revision": revision,
        "status": status,
        "speaker": speaker,
        "coverage_ratio": coverage_ratio,
        "overlap_ratio": overlap_ratio,
        "candidates": [
            {"speaker": candidate_speaker, "support_ratio": support}
            for candidate_speaker, support in candidates
        ],
    }


def diarization_update_event(
    *,
    group_generation: str | None,
    stable_through_sample: int,
    updates: list[dict[str, object]],
    speaker_links: list[dict[str, object]],
) -> dict[str, object]:
    """Render a ``speechrail.diarization.updated`` event."""
    return {
        "type": "speechrail.diarization.updated",
        "event_version": _DIARIZATION_EVENT_VERSION,
        "group_generation": group_generation,
        "stable_through_sample": stable_through_sample,
        "updates": updates,
        "speaker_links": speaker_links,
    }


def diarization_status_event(
    *,
    reason: str,
    since_sample: int,
) -> dict[str, object]:
    """Render the one-shot ``speechrail.diarization.status`` degraded notice."""
    return {
        "type": "speechrail.diarization.status",
        "event_version": _DIARIZATION_EVENT_VERSION,
        "status": "degraded",
        "reason": reason,
        "since_sample": since_sample,
    }


def diarization_done_event(
    *,
    finalization_id: str,
    through_sample: int,
    stable_through_sample: int,
    status: str,
    reason: str | None,
    last_update_sequence: int,
) -> dict[str, object]:
    """Render the terminal ``speechrail.diarization.done`` barrier event."""
    return {
        "type": "speechrail.diarization.done",
        "event_version": _DIARIZATION_EVENT_VERSION,
        "finalization_id": finalization_id,
        "through_sample": through_sample,
        "stable_through_sample": stable_through_sample,
        "status": status,
        "reason": reason,
        "last_update_sequence": last_update_sequence,
    }


def parse_finish_request(event: dict[str, Any]) -> str:
    """Validate ``speechrail.diarization.finish`` and return its event id."""
    event_id = event.get("event_id")
    if not isinstance(event_id, str) or not 1 <= len(event_id) <= 128:
        raise RealtimeAdapterError(
            "invalid_argument", "event_id must be a 1-128 character string"
        )
    return event_id


def transcription_segment(
    *,
    session_id: str,
    item_id: str,
    segment_id: int,
    text: str,
    speaker: str | None,
    start_ms: int,
    end_ms: int,
) -> dict[str, object]:
    """Render one OpenAI-compatible immutable transcription segment."""
    return {
        "type": "conversation.item.input_audio_transcription.segment",
        "item_id": item_id,
        "content_index": 0,
        "id": segment_id,
        "text": text,
        "speaker": speaker,
        "start": start_ms / 1000,
        "end": end_ms / 1000,
    }


def transcription_failed(*, item_id: str, code: str, message: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.failed",
        "item_id": item_id,
        "content_index": 0,
        "error": {"type": "transcription_error", "code": code, "message": message},
    }


def input_audio_buffer_speech_started(
    *, session_id: str, audio_start_ms: int, item_id: str
) -> dict[str, object]:
    return {
        "type": "input_audio_buffer.speech_started",
        "audio_start_ms": audio_start_ms,
        "item_id": item_id,
    }


def input_audio_buffer_speech_stopped(
    *, session_id: str, audio_end_ms: int, item_id: str
) -> dict[str, object]:
    return {
        "type": "input_audio_buffer.speech_stopped",
        "audio_end_ms": audio_end_ms,
        "item_id": item_id,
    }


def response_created(*, session_id: str, response_id: str) -> dict[str, object]:
    return {
        "type": "response.created",
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
        "response_id": response_id,
        "output_index": 0,
        "item": {
            "id": item_id,
            "object": "realtime.item",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "audio", "transcript": None, "audio": None}],
        },
    }


def response_output_item_done(
    *, session_id: str, response_id: str, item_id: str, transcript: str
) -> dict[str, object]:
    return {
        "type": "response.output_item.done",
        "response_id": response_id,
        "output_index": 0,
        "item": {
            "id": item_id,
            "object": "realtime.item",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "audio", "transcript": transcript, "audio": None}],
        },
    }


def response_content_part_added(
    *, session_id: str, response_id: str, item_id: str
) -> dict[str, object]:
    return {
        "type": "response.content_part.added",
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
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "part": {"type": "audio", "transcript": transcript, "audio": None},
    }


def response_audio_delta(
    *,
    session_id: str,
    response_id: str,
    item_id: str,
    delta: str,
) -> dict[str, object]:
    return {
        "type": "response.output_audio.delta",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "delta": delta,
    }


def response_audio_done(
    *,
    session_id: str,
    response_id: str,
    item_id: str,
) -> dict[str, object]:
    return {
        "type": "response.output_audio.done",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
    }

def response_audio_transcript_delta(
    *, session_id: str, response_id: str, item_id: str, delta: str
) -> dict[str, object]:
    return {
        "type": "response.output_audio_transcript.delta",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "delta": delta,
    }


def response_audio_transcript_done(
    *, session_id: str, response_id: str, item_id: str, transcript: str
) -> dict[str, object]:
    return {
        "type": "response.output_audio_transcript.done",
        "response_id": response_id,
        "output_index": 0,
        "item_id": item_id,
        "content_index": 0,
        "transcript": transcript,
    }


def response_done(
    *,
    session_id: str,
    response_id: str,
    status: str = "completed",
    item_id: str | None = None,
    transcript: str | None = None,
    speechrail: dict[str, object] | None = None,
) -> dict[str, object]:
    output: list[dict[str, object]] = []
    if item_id is not None:
        output.append(
            {
                "id": item_id,
                "object": "realtime.item",
                "type": "message",
                "role": "assistant",
                "content": [
                    {
                        "type": "audio",
                        "transcript": transcript,
                        "audio": None,
                    }
                ],
            }
        )
    event: dict[str, object] = {
        "type": "response.done",
        "response": {
            "id": response_id,
            "object": "realtime.response",
            "status": status,
            "status_details": None,
            "output": output,
            "usage": None,
        },
    }
    if speechrail is not None:
        event["speechrail"] = speechrail
    return event


def error_event(
    *,
    code: str,
    message: str,
    client_event_id: str | None = None,
    request_id: str | None = None,
    busy_reason: str | None = None,
) -> dict[str, object]:
    error: dict[str, object] = {
        "type": "invalid_request_error",
        "code": code,
        "message": message,
    }
    if client_event_id:
        error["event_id"] = client_event_id
    if request_id:
        error["request_id"] = request_id
    event: dict[str, object] = {"type": "error", "error": error}
    if busy_reason is not None:
        policy = busy_retry_policy(busy_reason)
        event["speechrail"] = {
            "busy_reason": busy_reason,
            "retryable": policy.retryable,
            "retry_hint": policy.hint,
        }
    return event


def resolve_handshake_model(
    model: str,
    *,
    registered_asr: frozenset[str],
    diarization_ready: bool,
) -> str:
    """Resolve the ``?model=`` handshake value to an internal ASR profile id."""
    resolved = canonical_asr_model(model, registered=registered_asr)
    if resolved is None:
        raise RealtimeAdapterError("model_not_found", f"unknown model: {model[:200]}")
    if model == "gpt-4o-transcribe-diarize" and not diarization_ready:
        raise RealtimeAdapterError(
            "model_not_found",
            "gpt-4o-transcribe-diarize requires an available diarization profile",
        )
    return resolved


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
    registered_asr: frozenset[str],
    current_config: Mapping[str, Any] | None = None,
) -> tuple[dict[str, object], dict[str, Any]]:
    """Validate the current transcription session update and return its config.

    The returned config is a SpeechRail-internal dict consumed by the route.
    """
    if event.get("type") != "transcription_session.update":
        raise RealtimeAdapterError(
            "unsupported_operation",
            "only transcription_session.update is supported",
        )
    session = _require_object(event, "session")
    allowed_session_fields = {
        "type",
        "input_audio_format",
        "input_audio_transcription",
        "turn_detection",
        "speechrail",
    }
    if set(session) - allowed_session_fields:
        raise RealtimeAdapterError(
            "unsupported_operation",
            "unsupported transcription session field",
        )
    if "type" in session and session["type"] not in (None, "transcription"):
        raise RealtimeAdapterError("invalid_event", "session.type must be transcription")
    if "speechrail" in session:
        speechrail = session["speechrail"]
        if not isinstance(speechrail, dict):
            raise RealtimeAdapterError(
                "invalid_event", "session.speechrail must be an object"
            )
        if set(speechrail) - {
            "tts",
            "diarization",
            "render_receipts",
            "model_revision",
            "transcription",
        }:
            raise RealtimeAdapterError(
                "unsupported_operation", "unsupported session.speechrail field"
            )
    transcription = session.get("input_audio_transcription")
    transcription_obj: dict[str, Any] | None = None
    if transcription is not None:
        if not isinstance(transcription, dict):
            raise RealtimeAdapterError(
                "invalid_event", "input_audio_transcription must be an object"
            )
        transcription_obj = transcription
        allowed_transcription_fields = {
            "model",
            "language",
            "languages",
            "prompt",
            "keywords",
            "timestamp_granularities",
        }
        if set(transcription_obj) - allowed_transcription_fields:
            if "diarization" in transcription_obj:
                raise RealtimeAdapterError(
                    "invalid_diarization",
                    "use session.speechrail.diarization.enabled for realtime diarization",
                )
            raise RealtimeAdapterError(
                "unsupported_operation",
                "unsupported input_audio_transcription field: "
                + ", ".join(sorted(set(transcription_obj) - allowed_transcription_fields)),
            )
    if "diarization" in session or (
        transcription_obj is not None and "diarization" in transcription_obj
    ):
        raise RealtimeAdapterError(
            "invalid_diarization",
            "use session.speechrail.diarization.enabled for realtime diarization",
        )
    base_config = dict(current_config or {})
    model = str(
        (transcription_obj or {}).get("model")
        or base_config.get("model")
        or asr_model
    )
    resolved_asr = canonical_asr_model(model, registered=registered_asr)
    if resolved_asr is None:
        raise RealtimeAdapterError("model_not_found", f"unknown model: {model[:200]}")

    turn_detection = session.get("turn_detection")
    if isinstance(turn_detection, dict):
        mode = turn_detection.get("type")
        if mode not in _SUPPORTED_TURN_DETECTION:
            raise RealtimeAdapterError(
                "unsupported_turn_detection",
                f"unsupported turn_detection type: {mode}",
            )
        if mode == "server_vad":
            threshold = turn_detection.get("threshold")
            if threshold is not None and (
                not isinstance(threshold, (int, float)) or not (0.0 <= threshold <= 1.0)
            ):
                raise RealtimeAdapterError(
                    "invalid_turn_detection", "threshold must be a float between 0.0 and 1.0"
                )
            prefix_padding = turn_detection.get("prefix_padding_ms")
            if prefix_padding is not None and (
                not isinstance(prefix_padding, int) or prefix_padding < 0
            ):
                raise RealtimeAdapterError(
                    "invalid_turn_detection", "prefix_padding_ms must be a non-negative integer"
                )
            silence_duration = turn_detection.get("silence_duration_ms")
            if silence_duration is not None and (
                not isinstance(silence_duration, int) or silence_duration < 0
            ):
                raise RealtimeAdapterError(
                    "invalid_turn_detection", "silence_duration_ms must be a non-negative integer"
                )
    elif turn_detection not in _SUPPORTED_TURN_DETECTION:
        raise RealtimeAdapterError(
            "unsupported_turn_detection",
            "only manual or server_vad turn detection is supported",
        )

    input_format = session.get("input_audio_format")
    if input_format not in (None, "pcm16"):
        raise RealtimeAdapterError(
            "unsupported_audio_format", "only pcm16 audio input is supported"
        )

    language: str | None = None
    languages: list[str] | None = None
    keywords: list[str] | None = None
    prompt: str | None = None
    timestamp_granularities: list[str] | None = None
    if transcription_obj is not None:
        language = transcription_obj.get("language")
        if language is not None and not isinstance(language, str):
            raise RealtimeAdapterError("invalid_language", "language must be a string")
        prompt = transcription_obj.get("prompt")
        if prompt is not None and not isinstance(prompt, str):
            raise RealtimeAdapterError("invalid_prompt", "prompt must be a string")
        if prompt is not None and len(prompt) > 2000:
            raise RealtimeAdapterError("prompt_too_long", "prompt exceeds 2000 characters")
        languages = _string_list(transcription_obj, "languages")
        keywords = _string_list(transcription_obj, "keywords")
        timestamp_granularities = _string_list(transcription_obj, "timestamp_granularities")
        if timestamp_granularities is not None:
            if any(value not in {"word", "segment"} for value in timestamp_granularities):
                raise RealtimeAdapterError(
                    "invalid_timestamp_granularities",
                    "timestamp_granularities must contain only word or segment",
                )
            if "word" in timestamp_granularities:
                raise RealtimeAdapterError(
                    "unsupported_operation",
                    "word-level timestamp granularity is not supported by realtime ASR",
                )
        if language is None and languages:
            language = languages[0]
    # ``transcription_session.update`` is a patch: absence preserves the effective session,
    # while a present ``null`` clears the respective option.  Build the whole
    # candidate before returning it so callers can validate and commit atomically.
    config: dict[str, Any] = dict(base_config)
    config["model"] = resolved_asr or asr_model
    if transcription_obj is not None and "language" in transcription_obj:
        config["language"] = language
    elif "language" in session:
        config["language"] = session["language"]
    else:
        config.setdefault("language", None)
    if transcription_obj is not None and "prompt" in transcription_obj:
        config["prompt"] = prompt or ""
    else:
        config.setdefault("prompt", "")
    config.setdefault("voice", None)

    turn_detection_val = config.get("turn_detection")
    if "turn_detection" in session:
        turn_detection_val = turn_detection
        config["turn_detection"] = turn_detection_val

    speechrail = session.get("speechrail")
    if isinstance(speechrail, dict) and "transcription" in speechrail:
        transcription_options = speechrail["transcription"]
        if not isinstance(transcription_options, dict):
            raise RealtimeAdapterError(
                "invalid_event",
                "session.speechrail.transcription must be an object",
            )
        allowed_options = {"partial_mode", "chunk_duration_ms"}
        unknown_options = set(transcription_options) - allowed_options
        if unknown_options:
            raise RealtimeAdapterError(
                "unsupported_operation",
                "unsupported session.speechrail.transcription field",
            )
        if "partial_mode" in transcription_options:
            partial_mode = transcription_options["partial_mode"]
            if not isinstance(partial_mode, str) or partial_mode not in _SUPPORTED_PARTIAL_MODES:
                raise RealtimeAdapterError(
                    "invalid_event",
                    "partial_mode must be delta or snapshot",
                )
            config["transcription_partial_mode"] = partial_mode
        if "chunk_duration_ms" in transcription_options:
            chunk_duration_ms = transcription_options["chunk_duration_ms"]
            if (
                isinstance(chunk_duration_ms, bool)
                or not isinstance(chunk_duration_ms, int)
                or chunk_duration_ms not in _SUPPORTED_TRANSCRIPTION_CHUNKS_MS
            ):
                raise RealtimeAdapterError(
                    "invalid_event",
                    "chunk_duration_ms must be one of 500, 1000, or 2000",
                )
            config["transcription_chunk_duration_ms"] = chunk_duration_ms

    config.setdefault("transcription_partial_mode", "delta")
    config.setdefault("transcription_chunk_duration_ms", 2_000)

    for key, value in (
        ("languages", languages),
        ("keywords", keywords),
        ("timestamp_granularities", timestamp_granularities),
    ):
        if (transcription_obj is not None and key in transcription_obj) or value is not None:
            config[key] = value
    response = session_updated(
        session_id=session_id,
        model=resolved_asr,
        turn_detection=turn_detection_val,
        speechrail_tts_enabled=bool(base_config.get("tts_enabled", False)),
        speechrail_transcription={
            "partial_mode": config["transcription_partial_mode"],
            "chunk_duration_ms": config["transcription_chunk_duration_ms"],
        },
    )
    return response, config


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


def validate_append(
    event: dict[str, Any],
    *,
    max_frame_bytes: int | None = None,
    buffered_bytes: int = 0,
    max_buffer_bytes: int | None = None,
) -> bytes:
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
    if max_frame_bytes is not None and len(payload) > max_frame_bytes:
        raise RealtimeAdapterError("frame_too_large", "audio frame exceeds the configured limit")
    if max_buffer_bytes is not None and buffered_bytes + len(payload) > max_buffer_bytes:
        raise RealtimeAdapterError("buffer_too_large", "audio buffer exceeds the configured limit")
    return payload


def reject_unsupported(event_type: str) -> None:
    """Fail closed on client events outside the supported ASR/TTS subset."""
    raise RealtimeAdapterError(
        "unsupported_operation", f"{event_type or 'empty event'} is not supported by SpeechRail"
    )
