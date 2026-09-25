"""OpenAI Realtime WebSocket wire adapter for SpeechRail's ASR/TTS only.

This module builds and validates the single current-only Realtime event
envelope described by ``contracts/realtime-openai.md`` and
``contracts/realtime-events.schema.json``.  It deliberately supports only the
ASR/TTS subset of the protocol: one ``session.update`` configuration event,
input audio buffering, transcription outcomes, and the namespaced
``speechrail.tts.*`` incremental utterance.  LLM conversation history, tools,
``response.*`` lifecycle, and non-audio modalities are rejected with a stable
``error`` instead of being silently accepted; there is no legacy alias.

The adapter owns no inference state; the route maps these events onto the
existing ``RealtimeAsrFactory``/``RealtimeAsrSession`` and TTS ports.
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Literal

from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    TtsStreamLimits,
)
from speechrail.runtime.busy import busy_retry_policy

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

# The single current wire boundary: 24 kHz mono PCM16 little-endian.  The ASR
# kernel runs at 16 kHz and is reached through a continuous resampler, so the
# two rates are deliberately not the same constant.
WIRE_SAMPLE_RATE: int = 24_000
ASR_KERNEL_SAMPLE_RATE: int = 16_000
_INPUT_WIRE_FORMAT: dict[str, object] = {"type": "audio/pcm", "rate": WIRE_SAMPLE_RATE}

_SUPPORTED_TASKS: frozenset[str] = frozenset(
    {"conversation", "caption", "transcription", "render", "voice_design"}
)
_SUPPORTED_TTS_TASKS: frozenset[str] = frozenset({"conversation", "render"})
_SUPPORTED_ALIGNMENT_GRANULARITIES: frozenset[str] = frozenset(
    {"segment", "word", "character"}
)
_SUPPORTED_ALIGNMENT_PRECISIONS: frozenset[str] = frozenset({"q8", "bf16"})

# The incremental TTS extension is negotiated on its own version axis so a
# vendor protocol change never silently reuses the shared realtime=v1 envelope.
TTS_STREAM_PROTOCOL_VERSION: int = 1
TTS_STREAM_IMPLEMENTATION: str = "qwen3-tts-incremental-v1"
_TTS_STREAM_EVENT_PREFIX = "speechrail.tts."
_MAX_STREAM_APPEND_CODEPOINTS: int = DEFAULT_TTS_STREAM_LIMITS.max_append_codepoints
_STREAM_LIMIT_FIELDS: tuple[str, ...] = (
    "max_append_codepoints",
    "max_total_codepoints",
    "max_pending_codepoints",
    "max_pending_audio_bytes",
    "input_wait_seconds",
    "utterance_wall_clock_seconds",
    "slow_consumer_seconds",
)
_TTS_START_FIELDS: frozenset[str] = frozenset(
    {
        "type",
        "event_id",
        "request_id",
        "task",
        "voice",
        "voice_revision",
        "speed",
        "expected_model_revision",
        "limits",
    }
)
_TTS_APPEND_TEXT_FIELDS: frozenset[str] = frozenset(
    {"type", "event_id", "request_id", "sequence", "text"}
)
_TTS_FINISH_TEXT_FIELDS: frozenset[str] = frozenset(
    {"type", "event_id", "request_id", "last_sequence"}
)
_TTS_CANCEL_FIELDS: frozenset[str] = frozenset(
    {"type", "event_id", "request_id"}
)

_UNSUPPORTED_CLIENT_EVENTS: frozenset[str] = frozenset(
    {
        "transcription_session.update",
        "conversation.item.create",
        "conversation.item.delete",
        "conversation.item.truncate",
        "response.create",
        "response.cancel",
        "response.audio.delta",
        "response.audio.done",
        "response.audio_transcript.delta",
        "response.audio_transcript.done",
        "session.updated",
        "speechrail.tts.create",
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
    "session_update",
    "append",
    "commit",
    "clear",
    "diarization_finish",
    "tts_start",
    "tts_append_text",
    "tts_finish_text",
    "tts_cancel",
]


@dataclass(frozen=True, slots=True)
class ParsedClientEvent:
    kind: EventKind


@dataclass(frozen=True, slots=True)
class TTSCancelRequest:
    request_id: str


@dataclass(frozen=True, slots=True)
class TTSStartRequest:
    """One incremental utterance request, including its tightened limits."""

    request_id: str
    task: str
    voice: str
    speed: float
    expected_voice_revision: str | None
    expected_model_revision: str | None
    limits: TtsStreamLimits


@dataclass(frozen=True, slots=True)
class TTSAppendTextRequest:
    request_id: str
    sequence: int
    text: str


@dataclass(frozen=True, slots=True)
class TTSFinishTextRequest:
    request_id: str
    last_sequence: int


def parse_client_event(event: dict[str, Any]) -> ParsedClientEvent:
    """Classify the one current-only client event vocabulary.

    This is deliberately strict: a removed event is not translated into the
    current caller-owned command and an unknown event is not silently ignored.
    """
    event_type = event.get("type")
    if not isinstance(event_type, str) or not event_type:
        raise RealtimeAdapterError("invalid_event", "event.type must be a non-empty string")
    kinds: dict[str, EventKind] = {
        "session.update": "session_update",
        "input_audio_buffer.append": "append",
        "input_audio_buffer.commit": "commit",
        "input_audio_buffer.clear": "clear",
        "speechrail.diarization.finish": "diarization_finish",
        "speechrail.tts.start": "tts_start",
        "speechrail.tts.append_text": "tts_append_text",
        "speechrail.tts.finish_text": "tts_finish_text",
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


def _tts_speed(value: object) -> float:
    """Validate the bounded playback speed shared by create and start."""

    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or not 0.25 <= float(value) <= 4.0
    ):
        raise RealtimeAdapterError(
            "tts_request_invalid", "speed must be between 0.25 and 4.0"
        )
    return float(value)


def parse_tts_cancel(event: dict[str, Any]) -> TTSCancelRequest:
    """Validate an explicit caller-owned TTS cancellation."""
    _reject_unknown_fields(
        event, _TTS_CANCEL_FIELDS, event_type="speechrail.tts.cancel"
    )
    request_id = _bounded_string(
        event.get("request_id"), field="request_id", max_length=128
    )
    return TTSCancelRequest(request_id=request_id)


def _reject_unknown_fields(
    event: Mapping[str, Any], allowed: frozenset[str], *, event_type: str
) -> None:
    """Reject a field the incremental extension does not define.

    Unknown-field rejection is what keeps this namespaced extension from growing
    accidental aliases: an unrecognised key fails closed instead of being
    silently ignored by a newer server or an older client.
    """

    unknown = sorted(set(event) - allowed)
    if unknown:
        raise RealtimeAdapterError(
            "tts_request_invalid", f"{event_type} does not accept field: {unknown[0]}"
        )


def _stream_sequence(value: object, *, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise RealtimeAdapterError(
            "tts_sequence_invalid", f"{field} must be a non-negative integer"
        )
    return value


def _stream_limits(value: object) -> TtsStreamLimits:
    """Accept only limits that tighten, never widen, the server safety budget."""

    if value is None:
        return DEFAULT_TTS_STREAM_LIMITS
    if not isinstance(value, dict):
        raise RealtimeAdapterError("tts_request_invalid", "limits must be an object")
    unknown = sorted(set(value) - set(_STREAM_LIMIT_FIELDS))
    if unknown:
        raise RealtimeAdapterError(
            "tts_request_invalid", f"limits does not accept field: {unknown[0]}"
        )
    overrides: dict[str, float] = {}
    for field in _STREAM_LIMIT_FIELDS:
        if field not in value:
            continue
        raw = value[field]
        if isinstance(raw, bool) or not isinstance(raw, (int, float)):
            raise RealtimeAdapterError("tts_request_invalid", f"limits.{field} must be a number")
        if float(raw) > float(getattr(DEFAULT_TTS_STREAM_LIMITS, field)):
            raise RealtimeAdapterError(
                "tts_stream_limit_exceeded",
                f"limits.{field} must not exceed the server limit",
            )
        overrides[field] = raw
    try:
        return TtsStreamLimits(**overrides)  # type: ignore[arg-type]
    except ValueError as exc:
        raise RealtimeAdapterError("tts_request_invalid", str(exc)) from exc


def parse_tts_start(event: dict[str, Any]) -> TTSStartRequest:
    """Validate one incremental utterance start.

    The start event carries the caller task, the voice identity pins and an
    optional limits object.  Only request identity, identity pins and budgets
    live here; text arrives through ``append_text`` so the two axes stay
    independent.
    """

    _reject_unknown_fields(event, _TTS_START_FIELDS, event_type="speechrail.tts.start")
    request_id = _bounded_string(event.get("request_id"), field="request_id", max_length=128)
    task_value = event.get("task")
    if task_value not in _SUPPORTED_TTS_TASKS:
        raise RealtimeAdapterError(
            "tts_request_invalid", "task must be conversation or render"
        )
    voice = _bounded_string(event.get("voice"), field="voice", max_length=128)
    revision_value = event.get("voice_revision")
    revision = (
        None
        if revision_value is None
        else _bounded_string(revision_value, field="voice_revision", max_length=128)
    )
    model_revision_value = event.get("expected_model_revision")
    model_revision = (
        None
        if model_revision_value is None
        else _bounded_string(
            model_revision_value, field="expected_model_revision", max_length=128
        )
    )
    return TTSStartRequest(
        request_id=request_id,
        task=str(task_value),
        voice=voice,
        speed=_tts_speed(event.get("speed", 1.0)),
        expected_voice_revision=revision,
        expected_model_revision=model_revision,
        limits=_stream_limits(event.get("limits")),
    )


def parse_tts_append_text(event: dict[str, Any]) -> TTSAppendTextRequest:
    """Validate one append of immutable text for an open utterance."""

    _reject_unknown_fields(
        event, _TTS_APPEND_TEXT_FIELDS, event_type="speechrail.tts.append_text"
    )
    request_id = _bounded_string(event.get("request_id"), field="request_id", max_length=128)
    text = event.get("text")
    if not isinstance(text, str) or not text:
        raise RealtimeAdapterError("tts_request_invalid", "text must be a non-empty string")
    if len(text) > _MAX_STREAM_APPEND_CODEPOINTS:
        raise RealtimeAdapterError(
            "tts_stream_limit_exceeded", "text exceeds the per-append codepoint limit"
        )
    return TTSAppendTextRequest(
        request_id=request_id,
        sequence=_stream_sequence(event.get("sequence"), field="sequence"),
        text=text,
    )


def parse_tts_finish_text(event: dict[str, Any]) -> TTSFinishTextRequest:
    """Validate the close of the text side of one open utterance."""

    _reject_unknown_fields(
        event, _TTS_FINISH_TEXT_FIELDS, event_type="speechrail.tts.finish_text"
    )
    request_id = _bounded_string(event.get("request_id"), field="request_id", max_length=128)
    return TTSFinishTextRequest(
        request_id=request_id,
        last_sequence=_stream_sequence(event.get("last_sequence"), field="last_sequence"),
    )


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


def session_payload(
    *,
    session_id: str,
    model: str,
    language: str | None = None,
    languages: list[str] | None = None,
    prompt: str = "",
    keywords: list[str] | None = None,
    timestamp_granularities: list[str] | None = None,
    turn_detection: str | None = None,
    task: str = "conversation",
    tts_enabled: bool = False,
    alignment_enabled: bool = False,
    diarization_enabled: bool = False,
    endpointing: dict[str, object] | None = None,
    expected_asr_revision: str | None = None,
    expected_tts_revision: str | None = None,
) -> dict[str, object]:
    """Render the single current ``session`` object shared by create/update.

    Every field is a member of ``contracts/realtime-events.schema.json``'s
    ``session`` definition; capability advertisement lives on the REST
    capability snapshot, not inside this object.
    """

    transcription: dict[str, object] = {"model": model}
    if language:
        transcription["language"] = language
    if languages:
        transcription["languages"] = list(languages)
    if prompt:
        transcription["prompt"] = prompt
    if keywords:
        transcription["keywords"] = list(keywords)
    if timestamp_granularities:
        transcription["timestamp_granularities"] = list(timestamp_granularities)
    speechrail: dict[str, object] = {
        "task": task,
        "tts": {"enabled": bool(tts_enabled)},
        "alignment": {"enabled": bool(alignment_enabled)},
        "diarization": {"enabled": bool(diarization_enabled)},
    }
    if endpointing is not None:
        speechrail["endpointing"] = dict(endpointing)
    if expected_asr_revision is not None:
        speechrail["expected_asr_revision"] = expected_asr_revision
    if expected_tts_revision is not None:
        speechrail["expected_tts_revision"] = expected_tts_revision
    return {
        "id": session_id,
        "type": "transcription",
        "audio": {
            "input": {
                "format": dict(_INPUT_WIRE_FORMAT),
                "transcription": transcription,
                "turn_detection": turn_detection,
            }
        },
        "speechrail": speechrail,
    }


def session_created(*, session_id: str, **session_fields: Any) -> dict[str, object]:
    """Render ``session.created`` from one current session object."""

    return {
        "type": "session.created",
        "session": session_payload(session_id=session_id, **session_fields),
    }


def session_updated(*, session_id: str, **session_fields: Any) -> dict[str, object]:
    """Render ``session.updated``; the server never emits the legacy event name."""

    return {
        "type": "session.updated",
        "session": session_payload(session_id=session_id, **session_fields),
    }


def transcription_delta(*, item_id: str, delta: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.delta",
        "item_id": item_id,
        "content_index": 0,
        "delta": delta,
    }


def transcription_hypothesis(
    *,
    task_id: str,
    epoch: int,
    utterance_id: str,
    revision: int,
    text: str,
    sample_span: tuple[int, int],
    stable_prefix_codepoints: int,
) -> dict[str, object]:
    """Render one explicitly mutable, revisioned Realtime transcript hypothesis."""
    return {
        "type": "speechrail.transcription.hypothesis",
        "task_id": task_id,
        "epoch": epoch,
        "utterance_id": utterance_id,
        "revision": revision,
        "text": text,
        "sample_span": {
            "start": max(0, sample_span[0]),
            "end": max(0, sample_span[1]),
        },
        "stable_prefix_codepoints": max(0, stable_prefix_codepoints),
    }


def transcription_completed(*, item_id: str, transcript: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.completed",
        "item_id": item_id,
        "content_index": 0,
        "transcript": transcript,
    }


def alignment_done(
    *,
    task_id: str,
    epoch: int,
    utterance_id: str,
    transcript_revision: int,
    metadata_revision: int,
    sample_span: tuple[int, int],
    codepoint_span: tuple[int, int],
    units: list[dict[str, object]],
) -> dict[str, object]:
    """Render an auxiliary fixed-text alignment result independent of the ASR final."""
    return {
        "type": "speechrail.alignment.done",
        "task_id": task_id,
        "epoch": epoch,
        "utterance_id": utterance_id,
        "transcript_revision": max(0, transcript_revision),
        "metadata_revision": max(0, metadata_revision),
        "sample_span": {
            "start": max(0, sample_span[0]),
            "end": max(0, sample_span[1]),
        },
        "codepoint_span": {
            "start": max(0, codepoint_span[0]),
            "end": max(0, codepoint_span[1]),
        },
        "units": units,
    }


def alignment_failed(
    *,
    task_id: str,
    epoch: int,
    utterance_id: str,
    transcript_revision: int,
    metadata_revision: int,
    code: str,
    message: str,
) -> dict[str, object]:
    """Render an auxiliary alignment failure without rewriting the ASR final."""
    return {
        "type": "speechrail.alignment.failed",
        "task_id": task_id,
        "epoch": epoch,
        "utterance_id": utterance_id,
        "transcript_revision": max(0, transcript_revision),
        "metadata_revision": max(0, metadata_revision),
        "error": {
            "type": "server_error",
            "code": code,
            "message": message,
        },
    }


def diarization_updated(
    *,
    task_id: str,
    epoch: int,
    utterance_id: str,
    transcript_revision: int,
    metadata_revision: int,
    units: list[dict[str, object]],
) -> dict[str, object]:
    """Render a ``speechrail.diarization.updated`` event."""
    return {
        "type": "speechrail.diarization.updated",
        "task_id": task_id,
        "epoch": max(0, int(epoch)),
        "utterance_id": utterance_id,
        "transcript_revision": max(0, int(transcript_revision)),
        "metadata_revision": max(0, int(metadata_revision)),
        "units": units,
    }


def diarization_done_event(
    *,
    task_id: str,
    epoch: int,
    utterance_id: str,
    transcript_revision: int,
    metadata_revision: int,
    units: list[dict[str, object]],
) -> dict[str, object]:
    """Render the terminal ``speechrail.diarization.done`` barrier event."""
    return {
        "type": "speechrail.diarization.done",
        "task_id": task_id,
        "epoch": max(0, int(epoch)),
        "utterance_id": utterance_id,
        "transcript_revision": max(0, int(transcript_revision)),
        "metadata_revision": max(0, int(metadata_revision)),
        "units": units,
    }


def diarization_failed(
    *,
    task_id: str,
    epoch: int,
    utterance_id: str,
    transcript_revision: int,
    metadata_revision: int,
    code: str,
    message: str,
) -> dict[str, object]:
    """Render an auxiliary diarization failure without rewriting the ASR final."""
    return {
        "type": "speechrail.diarization.failed",
        "task_id": task_id,
        "epoch": max(0, int(epoch)),
        "utterance_id": utterance_id,
        "transcript_revision": max(0, int(transcript_revision)),
        "metadata_revision": max(0, int(metadata_revision)),
        "error": {
            "type": "server_error",
            "code": code,
            "message": message,
        },
    }


def parse_finish_request(event: dict[str, Any]) -> str:
    """Validate ``speechrail.diarization.finish`` and return its event id."""
    event_id = event.get("event_id")
    if not isinstance(event_id, str) or not 1 <= len(event_id) <= 128:
        raise RealtimeAdapterError(
            "invalid_argument", "event_id must be a 1-128 character string"
        )
    return event_id


def transcription_failed(*, item_id: str, code: str, message: str) -> dict[str, object]:
    return {
        "type": "conversation.item.input_audio_transcription.failed",
        "item_id": item_id,
        "content_index": 0,
        "error": {"type": "server_error", "code": code, "message": message},
    }


def tts_stream_limits_payload(limits: TtsStreamLimits) -> dict[str, object]:
    """Render the effective incremental limits for one utterance."""

    return {field: getattr(limits, field) for field in _STREAM_LIMIT_FIELDS}


def tts_output_format() -> dict[str, object]:
    """The single negotiated incremental audio contract: 24 kHz mono PCM16."""

    return {"type": "audio/pcm", "sample_rate": WIRE_SAMPLE_RATE, "channels": 1}


def plan_fingerprint(
    *,
    task: str,
    asr_model: str,
    voice: str,
    voice_revision: str | None,
    catalog_revision: str | None,
) -> str:
    """Derive the stable plan identity echoed on every ``speechrail.tts.*`` event."""

    import hashlib

    payload = "|".join(
        [
            task,
            asr_model,
            voice,
            voice_revision or "",
            catalog_revision or "",
        ]
    )
    return f"plan_{hashlib.sha256(payload.encode('utf-8')).hexdigest()[:32]}"


def tts_stream_started(
    *,
    task_id: str,
    plan_id: str,
    request_id: str,
    voice_revision: str | None,
    limits: TtsStreamLimits,
    output_format: dict[str, object] | None = None,
) -> dict[str, object]:
    """Acknowledge ``speechrail.tts.start`` once the utterance is live."""

    event: dict[str, object] = {
        "type": "speechrail.tts.started",
        "task_id": task_id,
        "plan_id": plan_id,
        "request_id": request_id,
        "output_format": dict(output_format) if output_format else tts_output_format(),
        "limits": tts_stream_limits_payload(limits),
    }
    if voice_revision is not None:
        event["voice_revision"] = voice_revision
    return event


def tts_text_accepted(
    *,
    task_id: str,
    request_id: str,
    append_sequence: int,
    accepted_codepoints: int,
    total_codepoints: int,
) -> dict[str, object]:
    """Acknowledge one append that the model accepted into its queue.

    ``append_sequence`` is deliberately not named ``sequence``: the transport
    stamps every event with its own connection-scoped ``sequence``, so the
    caller's append index needs its own unambiguous field name.
    """

    return {
        "type": "speechrail.tts.text_accepted",
        "task_id": task_id,
        "request_id": request_id,
        "append_sequence": append_sequence,
        "accepted_codepoints": accepted_codepoints,
        "total_codepoints": total_codepoints,
    }


def tts_audio_delta(
    *,
    task_id: str,
    request_id: str,
    chunk_index: int,
    sample_offset: int,
    delta: str,
) -> dict[str, object]:
    """Render one byte-exact incremental PCM chunk with its sample position."""

    return {
        "type": "speechrail.tts.audio.delta",
        "task_id": task_id,
        "request_id": request_id,
        "chunk_index": max(0, int(chunk_index)),
        "sample_offset": max(0, int(sample_offset)),
        "delta": delta,
    }


def tts_completed(
    *, task_id: str, request_id: str, generated_samples: int
) -> dict[str, object]:
    """Render the one successful terminal for an incremental utterance."""

    return {
        "type": "speechrail.tts.completed",
        "task_id": task_id,
        "request_id": request_id,
        "generated_samples": max(0, int(generated_samples)),
    }


def tts_cancelled(*, task_id: str, request_id: str) -> dict[str, object]:
    """Render the one cancellation terminal for an incremental utterance."""

    return {
        "type": "speechrail.tts.cancelled",
        "task_id": task_id,
        "request_id": request_id,
    }


def tts_failed(
    *, task_id: str, request_id: str, code: str, message: str
) -> dict[str, object]:
    """Render the one failure terminal; the utterance never also sends ``error``."""

    return {
        "type": "speechrail.tts.failed",
        "task_id": task_id,
        "request_id": request_id,
        "error": {"type": "server_error", "code": code, "message": message},
    }


def error_event(
    *,
    code: str,
    message: str,
    client_event_id: str | None = None,
    request_id: str | None = None,
    busy_reason: str | None = None,
) -> dict[str, object]:
    """Render the stable error envelope.

    ``request_id`` is a top-level member of the envelope; the client event id
    stays inside ``error`` so a caller can correlate the rejected event.  The
    busy reason is folded into ``message`` because the current schema keeps the
    error object closed.
    """

    error: dict[str, object] = {
        "type": "invalid_request_error",
        "code": code,
        "message": message,
    }
    if client_event_id:
        error["event_id"] = client_event_id
    if busy_reason is not None:
        policy = busy_retry_policy(busy_reason)
        hint = policy.hint or "wait_before_retry"
        error["message"] = f"{message} (retryable={policy.retryable}, hint={hint})"
    event: dict[str, object] = {
        "type": "error",
        "request_id": request_id or client_event_id or "unknown_request",
        "error": error,
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


_SESSION_UPDATE_FIELDS: frozenset[str] = frozenset({"type", "audio", "speechrail"})
_SESSION_AUDIO_FIELDS: frozenset[str] = frozenset({"input"})
_SESSION_INPUT_FIELDS: frozenset[str] = frozenset(
    {"format", "transcription", "turn_detection", "speechrail"}
)
_SESSION_TRANSCRIPTION_FIELDS: frozenset[str] = frozenset(
    {
        "model",
        "language",
        "languages",
        "prompt",
        "keywords",
        "timestamp_granularities",
    }
)
_SESSION_SPEECHRAIL_FIELDS: frozenset[str] = frozenset(
    {
        "task",
        "tts",
        "alignment",
        "diarization",
        "endpointing",
        "expected_asr_revision",
        "expected_tts_revision",
    }
)
_ENDPOINTING_FIELDS: frozenset[str] = frozenset(
    {"mode", "threshold", "prefix_padding_ms", "silence_duration_ms"}
)
_ENDPOINTING_DEFAULTS: dict[str, object] = {
    "mode": "server_vad",
    "threshold": 0.5,
    "prefix_padding_ms": 300,
    "silence_duration_ms": 400,
}


def _reject_extra_fields(
    value: Mapping[str, Any], allowed: frozenset[str], *, label: str
) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise RealtimeAdapterError(
            "unsupported_operation", f"unsupported {label} field: {unknown[0]}"
        )


def _boolean_field(value: object, *, label: str) -> bool:
    if not isinstance(value, bool):
        raise RealtimeAdapterError("invalid_event", f"{label} must be a boolean")
    return value


def _revision_field(value: object, *, label: str) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= 128:
        raise RealtimeAdapterError(
            "invalid_event", f"{label} must be a 1-128 character revision"
        )
    return value


def _audio_format_is_current(value: object) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"type", "rate"}
        and value.get("type") == "audio/pcm"
        and value.get("rate") == WIRE_SAMPLE_RATE
    )


def _endpointing_config(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise RealtimeAdapterError("invalid_event", "speechrail.endpointing must be an object")
    _reject_extra_fields(value, _ENDPOINTING_FIELDS, label="speechrail.endpointing")
    if value.get("mode") != "server_vad":
        raise RealtimeAdapterError(
            "unsupported_operation", "endpointing.mode must be server_vad"
        )
    threshold = value.get("threshold", _ENDPOINTING_DEFAULTS["threshold"])
    if (
        isinstance(threshold, bool)
        or not isinstance(threshold, (int, float))
        or not 0.0 <= float(threshold) <= 1.0
    ):
        raise RealtimeAdapterError(
            "invalid_turn_detection", "threshold must be between 0.0 and 1.0"
        )
    prefix_padding = value.get("prefix_padding_ms", _ENDPOINTING_DEFAULTS["prefix_padding_ms"])
    if (
        isinstance(prefix_padding, bool)
        or not isinstance(prefix_padding, int)
        or not 0 <= prefix_padding <= 5_000
    ):
        raise RealtimeAdapterError(
            "invalid_turn_detection", "prefix_padding_ms must be a bounded integer"
        )
    silence = value.get("silence_duration_ms", _ENDPOINTING_DEFAULTS["silence_duration_ms"])
    if (
        isinstance(silence, bool)
        or not isinstance(silence, int)
        or not 100 <= silence <= 5_000
    ):
        raise RealtimeAdapterError(
            "invalid_turn_detection", "silence_duration_ms must be a bounded integer"
        )
    return {
        "mode": "server_vad",
        "threshold": float(threshold),
        "prefix_padding_ms": int(prefix_padding),
        "silence_duration_ms": int(silence),
    }


def apply_session_update(
    event: dict[str, Any],
    *,
    session_id: str,
    asr_model: str,
    registered_asr: frozenset[str],
    current_config: Mapping[str, Any] | None = None,
) -> tuple[dict[str, object], dict[str, Any]]:
    """Validate the single ``session.update`` event and return its config.

    ``session.update`` replaces the removed ``transcription_session.update``:
    audio options live under ``session.audio.input`` and the SpeechRail
    extension lives under ``session.speechrail``.  Unknown fields fail closed
    instead of being ignored.  The returned config is a SpeechRail-internal
    dict consumed by the route.
    """
    if event.get("type") != "session.update":
        raise RealtimeAdapterError(
            "unsupported_operation", "only session.update is supported"
        )
    session = _require_object(event, "session")
    _reject_extra_fields(session, _SESSION_UPDATE_FIELDS, label="session")
    if session.get("type") != "transcription":
        raise RealtimeAdapterError("invalid_event", "session.type must be transcription")
    audio = _require_object(session, "audio")
    _reject_extra_fields(audio, _SESSION_AUDIO_FIELDS, label="session.audio")
    audio_input = _require_object(audio, "input")
    _reject_extra_fields(audio_input, _SESSION_INPUT_FIELDS, label="session.audio.input")

    if not _audio_format_is_current(audio_input.get("format")):
        raise RealtimeAdapterError(
            "unsupported_audio_format",
            f"only audio/pcm at {WIRE_SAMPLE_RATE} Hz mono is accepted",
        )

    raw_turn_detection = audio_input.get("turn_detection")
    if raw_turn_detection not in (None, "manual"):
        raise RealtimeAdapterError(
            "unsupported_turn_detection",
            "audio.input.turn_detection accepts only null or manual",
        )

    transcription_obj = _require_object(audio_input, "transcription")
    _reject_extra_fields(
        transcription_obj, _SESSION_TRANSCRIPTION_FIELDS, label="audio.input.transcription"
    )
    model = transcription_obj.get("model")
    if not isinstance(model, str) or not model:
        raise RealtimeAdapterError("model_not_found", "audio.input.transcription.model is required")
    resolved_asr = canonical_asr_model(model, registered=registered_asr)
    if resolved_asr is None:
        raise RealtimeAdapterError("model_not_found", f"unknown model: {model[:200]}")

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
    if timestamp_granularities is not None and any(
        value not in _SUPPORTED_ALIGNMENT_GRANULARITIES for value in timestamp_granularities
    ):
        raise RealtimeAdapterError(
            "invalid_timestamp_granularities",
            "timestamp_granularities must contain only segment, word, or character",
        )
    if language is None and languages:
        language = languages[0]

    nested = audio_input.get("speechrail")
    top = session.get("speechrail")
    if nested is not None and not isinstance(nested, dict):
        raise RealtimeAdapterError("invalid_event", "audio.input.speechrail must be an object")
    speechrail_obj: dict[str, Any] = {}
    if isinstance(top, dict):
        _reject_extra_fields(top, _SESSION_SPEECHRAIL_FIELDS, label="session.speechrail")
        speechrail_obj.update(top)
    elif top is not None:
        raise RealtimeAdapterError("invalid_event", "session.speechrail must be an object")
    if isinstance(nested, dict):
        _reject_extra_fields(
            nested, _SESSION_SPEECHRAIL_FIELDS, label="audio.input.speechrail"
        )
        speechrail_obj.update(nested)
    task = speechrail_obj.get("task")
    if task not in _SUPPORTED_TASKS:
        raise RealtimeAdapterError(
            "invalid_event", "session.speechrail.task must be a supported task"
        )

    base_config = dict(current_config or {})
    config: dict[str, Any] = dict(base_config)
    config["model"] = resolved_asr or asr_model
    config["task"] = str(task)
    config["language"] = language
    config["prompt"] = prompt or ""
    config["languages"] = languages
    config["keywords"] = keywords
    config["timestamp_granularities"] = timestamp_granularities
    config.setdefault("voice", None)

    if "endpointing" in speechrail_obj:
        config["turn_detection"] = _endpointing_config(speechrail_obj["endpointing"])
    elif "turn_detection" in audio_input:
        config["turn_detection"] = raw_turn_detection

    tts_explicit = False
    if "tts" in speechrail_obj:
        raw_tts = speechrail_obj["tts"]
        if not isinstance(raw_tts, dict) or set(raw_tts) != {"enabled"}:
            raise RealtimeAdapterError(
                "invalid_event", "session.speechrail.tts requires boolean enabled only"
            )
        config["tts_enabled"] = _boolean_field(raw_tts["enabled"], label="speechrail.tts.enabled")
        tts_explicit = True
    config["tts_explicit"] = tts_explicit

    alignment_explicit = False
    if "alignment" in speechrail_obj:
        raw_alignment = speechrail_obj["alignment"]
        if not isinstance(raw_alignment, dict) or set(raw_alignment) - {
            "enabled",
            "granularity",
            "precision",
        }:
            raise RealtimeAdapterError(
                "invalid_event", "session.speechrail.alignment has an unsupported shape"
            )
        if "enabled" not in raw_alignment:
            raise RealtimeAdapterError(
                "invalid_event", "session.speechrail.alignment requires enabled"
            )
        enabled = _boolean_field(
            raw_alignment["enabled"], label="speechrail.alignment.enabled"
        )
        granularity = raw_alignment.get("granularity")
        if granularity is not None and granularity not in _SUPPORTED_ALIGNMENT_GRANULARITIES:
            raise RealtimeAdapterError(
                "unsupported_operation",
                "alignment.granularity must be segment, word, or character",
            )
        precision = raw_alignment.get("precision")
        if precision is not None and precision not in _SUPPORTED_ALIGNMENT_PRECISIONS:
            raise RealtimeAdapterError(
                "unsupported_operation", "alignment.precision must be q8 or bf16"
            )
        config["alignment_enabled"] = enabled
        config["alignment_granularity"] = granularity
        alignment_explicit = True
    config["alignment_explicit"] = alignment_explicit
    config.setdefault("alignment_enabled", False)

    diarization_explicit = False
    if "diarization" in speechrail_obj:
        raw_diarization = speechrail_obj["diarization"]
        if not isinstance(raw_diarization, dict) or set(raw_diarization) != {"enabled"}:
            raise RealtimeAdapterError(
                "invalid_event",
                "session.speechrail.diarization requires boolean enabled only",
            )
        config["diarization_enabled"] = _boolean_field(
            raw_diarization["enabled"], label="speechrail.diarization.enabled"
        )
        diarization_explicit = True
    config["diarization_explicit"] = diarization_explicit

    if "expected_asr_revision" in speechrail_obj:
        config["expected_asr_revision"] = _revision_field(
            speechrail_obj["expected_asr_revision"], label="expected_asr_revision"
        )
    if "expected_tts_revision" in speechrail_obj:
        config["expected_model_revision"] = _revision_field(
            speechrail_obj["expected_tts_revision"], label="expected_tts_revision"
        )

    endpointing = config.get("turn_detection")
    response = session_updated(
        session_id=session_id,
        model=resolved_asr or asr_model,
        language=config.get("language") if isinstance(config.get("language"), str) else None,
        languages=_list_or_none(config.get("languages")),
        prompt=str(config.get("prompt") or ""),
        keywords=_list_or_none(config.get("keywords")),
        timestamp_granularities=_list_or_none(config.get("timestamp_granularities")),
        turn_detection=_manual_or_none(endpointing),
        task=config["task"],
        tts_enabled=bool(config.get("tts_enabled", False)),
        alignment_enabled=bool(config.get("alignment_enabled", False)),
        diarization_enabled=bool(config.get("diarization_enabled", False)),
        endpointing=endpointing if isinstance(endpointing, dict) else None,
        expected_asr_revision=config.get("expected_asr_revision")
        if isinstance(config.get("expected_asr_revision"), str)
        else None,
        expected_tts_revision=config.get("expected_model_revision")
        if isinstance(config.get("expected_model_revision"), str)
        else None,
    )
    return response, config


def _list_or_none(value: object) -> list[str] | None:
    if value is None:
        return None
    if isinstance(value, (list, tuple)) and all(isinstance(item, str) for item in value):
        return list(value)
    return None


def _manual_or_none(value: object) -> str | None:
    return "manual" if value == "manual" else None


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
