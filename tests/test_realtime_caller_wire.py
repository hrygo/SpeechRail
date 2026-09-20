from __future__ import annotations

import pytest

from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    parse_client_event,
    parse_tts_cancel,
    parse_tts_create,
    response_audio_delta,
    response_audio_transcript_delta,
)


def test_transcription_session_update_is_the_canonical_session_event() -> None:
    parsed = parse_client_event(
        {
            "type": "transcription_session.update",
            "session": {
                "input_audio_format": "pcm16",
                "input_audio_transcription": {
                    "model": "speechrail/qwen3-asr-1.7b",
                    "language": "zh",
                },
                "turn_detection": {"type": "server_vad"},
                "speechrail": {"tts": {"enabled": True}},
            },
        }
    )

    assert parsed.kind == "transcription_session_update"


@pytest.mark.parametrize(
    "event_type",
    [
        "session.update",
        "conversation.item.create",
        "response.create",
        "response.cancel",
        "response.audio.delta",
    ],
)
def test_removed_events_are_rejected_without_compatibility_alias(event_type: str) -> None:
    with pytest.raises(RealtimeAdapterError) as exc_info:
        parse_client_event({"type": event_type})

    assert exc_info.value.code == "unsupported_operation"


def test_tts_create_requires_caller_text_and_validates_bounds() -> None:
    request = parse_tts_create(
        {
            "type": "speechrail.tts.create",
            "request_id": "tts_req_001",
            "text": "你好",
            "voice": "serena",
            "speed": 1.25,
            "expected_voice_revision": "vr_" + "a" * 40,
        }
    )

    assert request.request_id == "tts_req_001"
    assert request.text == "你好"
    assert request.voice == "serena"
    assert request.speed == 1.25
    assert request.expected_voice_revision == "vr_" + "a" * 40


def test_tts_cancel_requires_request_id() -> None:
    request = parse_tts_cancel(
        {
            "type": "speechrail.tts.cancel",
            "request_id": "tts_req_001",
            "response_id": "resp_001",
        }
    )

    assert request.request_id == "tts_req_001"
    assert request.response_id == "resp_001"


def test_audio_events_are_current_only_and_transcript_is_output_audio_transcript() -> None:
    audio = response_audio_delta(
        session_id="sess_1",
        response_id="resp_1",
        item_id="item_1",
        delta="AA==",
    )
    transcript = response_audio_transcript_delta(
        session_id="sess_1",
        response_id="resp_1",
        item_id="item_1",
        delta="你好",
    )

    assert audio["type"] == "response.output_audio.delta"
    assert transcript["type"] == "response.output_audio_transcript.delta"
