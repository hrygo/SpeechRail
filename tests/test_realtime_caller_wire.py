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
    apply_session_update,
    parse_client_event,
    parse_tts_audio_ack,
    parse_tts_cancel,
    parse_tts_start,
    transcription_segment_closed,
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


def test_swift_assistant_handshake_fixture_has_only_asr_identity() -> None:
    fixture_root = (
        Path(__file__).resolve().parent / "fixtures" / "realtime-current"
    )
    event = json.loads(
        (fixture_root / "client" / "assistant-session-update.json").read_text()
    )
    _VALIDATOR.validate(event)
    _, config = apply_session_update(
        event,
        session_id="session-assistant",
        asr_model=DEFAULT_ASR_MODEL,
        registered_asr=frozenset({DEFAULT_ASR_MODEL}),
    )
    assert config["expected_asr_revision"] == "asr-catalog"
    assert config["tts_enabled"] is True
    assert "expected_model_revision" not in config
    assert "voice" not in config

    legacy = json.loads(
        (fixture_root / "invalid" / "legacy-session-tts-revision.json").read_text()
    )
    with pytest.raises(RealtimeAdapterError) as exc_info:
        apply_session_update(
            legacy,
            session_id="session-assistant",
            asr_model=DEFAULT_ASR_MODEL,
            registered_asr=frozenset({DEFAULT_ASR_MODEL}),
        )
    assert exc_info.value.code == "unsupported_operation"


@pytest.mark.parametrize("nested", [False, True])
def test_session_update_rejects_tts_revision_without_utterance_identity(
    nested: bool,
) -> None:
    """TTS pins belong to the start event that also identifies the voice."""
    event = session_update(tts={"enabled": True})
    extensions = {"expected_tts_revision": "a" * 40}
    if nested:
        event["session"]["audio"]["input"]["speechrail"] = extensions
    else:
        event["session"]["speechrail"].update(extensions)

    with pytest.raises(RealtimeAdapterError) as exc_info:
        apply_session_update(
            event,
            session_id="session-identity",
            asr_model=DEFAULT_ASR_MODEL,
            registered_asr=frozenset({DEFAULT_ASR_MODEL}),
        )

    assert exc_info.value.code == "unsupported_operation"
    assert "expected_tts_revision" in str(exc_info.value)


def test_schema_rejects_session_tts_revision_without_voice() -> None:
    event = session_update(tts={"enabled": True})
    event["session"]["speechrail"]["expected_tts_revision"] = "a" * 40
    assert list(_VALIDATOR.iter_errors(event))


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

    assert request.audio_window_bytes == 48_000
    for missing in ("task", "voice", "audio_window_bytes"):
        event = tts_start(request_id="tts_req_002")
        event.pop(missing)
        with pytest.raises(RealtimeAdapterError):
            parse_tts_start(event)


@pytest.mark.parametrize("task", ["caption", "transcription", "voice_design"])
def test_tts_start_rejects_non_utterance_tasks(task: str) -> None:
    with pytest.raises(RealtimeAdapterError, match="conversation or render"):
        parse_tts_start(tts_start(request_id="tts_req_003", task=task))

@pytest.mark.parametrize("window", [None, True, 0, -2, 3, 1_440_002, "48000", 4.0])
def test_invalid_consumption_window_is_rejected(window: object) -> None:
    with pytest.raises(RealtimeAdapterError) as failure:
        parse_tts_start(tts_start(request_id="invalid-window", audio_window_bytes=window))
    assert failure.value.code == "tts_request_invalid"


@pytest.mark.parametrize("window", [48_002, 1_440_000])
def test_prefetch_window_is_independent_of_worker_chunk_budget(window: int) -> None:
    request = parse_tts_start(tts_start(request_id="prefetch-window", audio_window_bytes=window))
    assert request.audio_window_bytes == window
    assert request.limits.max_pending_audio_bytes == 48_000


@pytest.mark.parametrize("offset", [True, -1, "1920", 1.5, 2**53])
def test_invalid_audio_consumption_watermark_is_rejected(offset: object) -> None:
    event = {
        "type": "speechrail.tts.audio_ack", "event_id": "ack-invalid-offset",
        "request_id": "invalid-ack", "sample_offset": offset,
    }
    with pytest.raises(RealtimeAdapterError) as failure:
        parse_tts_audio_ack(event)
    assert failure.value.code == "tts_audio_ack_invalid"


@pytest.mark.parametrize("event_id", [None, "", " " * 2, "x" * 129, True, 1])
def test_audio_consumption_ack_requires_valid_event_id(event_id: object) -> None:
    event = {
        "type": "speechrail.tts.audio_ack", "request_id": "ack-id", "sample_offset": 0
    }
    if event_id is not None:
        event["event_id"] = event_id
    with pytest.raises(RealtimeAdapterError, match="event_id"):
        parse_tts_audio_ack(event)


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
            audio_window_bytes=48_000,
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


def test_segment_closed_builder_matches_the_shared_schema() -> None:
    event = transcription_segment_closed(
        item_id="item_asr_1",
        sample_span=(0, 24_000),
        reason="client_commit",
        commit_event_id="evt_commit_1",
    )

    _VALIDATOR.validate(_envelope(event))

    without_commit_id = transcription_segment_closed(
        item_id="item_asr_2",
        sample_span=(24_000, 48_000),
        reason="budget_rollover",
    )
    _VALIDATOR.validate(_envelope(without_commit_id, sequence=2))
