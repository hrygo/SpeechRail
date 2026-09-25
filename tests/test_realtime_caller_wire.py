from __future__ import annotations

import json
from pathlib import Path

import jsonschema
import pytest

from realtime_wire import (
    DEFAULT_ASR_MODEL,
    session_update,
    tts_append_text,
    tts_cancel,
    tts_finish_text,
    tts_start,
)
from speechrail.compatibility.openai_realtime import (
    DEFAULT_TTS_STREAM_LIMITS,
    RealtimeAdapterError,
    parse_client_event,
    parse_tts_cancel,
    parse_tts_start,
    tts_audio_delta,
    tts_cancelled,
    tts_completed,
    tts_failed,
    tts_stream_started,
    tts_text_accepted,
)

_SCHEMA = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "contracts"
        / "realtime-events.schema.json"
    ).read_text(encoding="utf-8")
)
_VALIDATOR = jsonschema.Draft202012Validator(_SCHEMA)


def _envelope(payload: dict[str, object], *, sequence: int = 1) -> dict[str, object]:
    return {
        **payload,
        "event_id": f"evt-srv-{sequence}",
        "session_id": "sess-test",
        "sequence": sequence,
    }


def test_session_update_is_the_canonical_session_event() -> None:
    parsed = parse_client_event(
        session_update(
            model=DEFAULT_ASR_MODEL,
            task="caption",
            language="zh",
            keywords=["SpeechRail"],
            timestamp_granularities=["segment"],
        )
    )

    assert parsed.kind == "session_update"


@pytest.mark.parametrize(
    "event_type",
    [
        "transcription_session.update",
        "session.updated",
        "speechrail.tts.create",
        "conversation.item.create",
        "response.create",
        "response.cancel",
        "response.output_audio.delta",
    ],
)
def test_removed_events_are_rejected_without_compatibility_alias(
    event_type: str,
) -> None:
    with pytest.raises(RealtimeAdapterError) as exc_info:
        parse_client_event({"type": event_type})

    assert exc_info.value.code == "unsupported_operation"


def test_tts_start_requires_task_and_voice() -> None:
    request = parse_tts_start(
        tts_start(
            request_id="tts_req_001",
            task="conversation",
            voice="serena",
            voice_revision="vr_" + "a" * 40,
            speed=1.25,
        )
    )

    assert request.request_id == "tts_req_001"
    assert request.task == "conversation"
    assert request.voice == "serena"
    assert request.expected_voice_revision == "vr_" + "a" * 40
    assert request.speed == 1.25

    for missing in ("task", "voice"):
        event = tts_start(request_id="tts_req_002")
        event.pop(missing)
        with pytest.raises(RealtimeAdapterError):
            parse_tts_start(event)


@pytest.mark.parametrize("task", ["caption", "transcription", "voice_design"])
def test_tts_start_rejects_non_utterance_tasks(task: str) -> None:
    with pytest.raises(RealtimeAdapterError, match="conversation or render"):
        parse_tts_start(tts_start(request_id="tts_req_003", task=task))


def test_tts_sequence_helpers_match_the_current_namespace() -> None:
    append = parse_client_event(
        tts_append_text(request_id="tts_req_001", sequence=0, text="hello")
    )
    finish = parse_client_event(
        tts_finish_text(request_id="tts_req_001", last_sequence=0)
    )
    cancel = parse_client_event(tts_cancel(request_id="tts_req_001"))

    assert append.kind == "tts_append_text"
    assert finish.kind == "tts_finish_text"
    assert cancel.kind == "tts_cancel"


def test_tts_cancel_rejects_legacy_response_id() -> None:
    with pytest.raises(RealtimeAdapterError) as exc_info:
        parse_tts_cancel(
            {
                "type": "speechrail.tts.cancel",
                "request_id": "tts_req_001",
                "response_id": "resp_001",
            }
        )

    assert exc_info.value.code == "tts_request_invalid"


def test_server_tts_builders_match_the_shared_schema() -> None:
    events = [
        tts_stream_started(
            task_id="task-1",
            plan_id="plan-1",
            request_id="req-tts-1",
            voice_revision="vr_" + "a" * 40,
            limits=DEFAULT_TTS_STREAM_LIMITS,
        ),
        tts_text_accepted(
            task_id="task-1",
            request_id="req-tts-1",
            append_sequence=0,
            accepted_codepoints=7,
            total_codepoints=7,
        ),
        tts_audio_delta(
            task_id="task-1",
            request_id="req-tts-1",
            chunk_index=0,
            sample_offset=0,
            delta="AA==",
        ),
        tts_completed(
            task_id="task-1",
            request_id="req-tts-1",
            generated_samples=1,
        ),
        tts_cancelled(task_id="task-1", request_id="req-tts-1"),
        tts_failed(
            task_id="task-1",
            request_id="req-tts-1",
            code="tts_backend_failed",
            message="tts failed",
        ),
    ]

    for sequence, event in enumerate(events, start=12):
        _VALIDATOR.validate(_envelope(event, sequence=sequence))
