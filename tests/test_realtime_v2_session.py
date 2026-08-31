from __future__ import annotations

import base64

import pytest

from speechrail.domain.realtime_v2 import RealtimeV2Error
from speechrail.realtime.v2_session import PCM16, SpeechSession, TranscriptionSession


def _pcm16(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def test_transcription_session_emits_monotonic_revisions_and_completes_item() -> None:
    session = TranscriptionSession(max_audio_bytes=16, request_id="req-test")

    created = session.configure({"type": "transcription", "audio_format": PCM16})
    first = session.transcription_delta(
        item_id="item-1", revision=1, text="你", start_ms=0, end_ms=100
    )
    second = session.transcription_delta(
        item_id="item-1", revision=2, text="你好", start_ms=0, end_ms=200
    )

    assert created["type"] == "session.created"
    assert created["request_id"] == "req-test"
    assert first["revision"] == 1
    assert second["revision"] == 2

    with pytest.raises(RealtimeV2Error, match="revision"):
        session.transcription_delta(
            item_id="item-1", revision=2, text="你好", start_ms=0, end_ms=200
        )

    completed = session.transcription_completed(
        item_id="item-1", text="你好", language="zh", segments=[]
    )
    assert completed["type"] == "transcription.completed"
    assert completed["item_id"] == "item-1"


def test_transcription_flush_preserves_session_and_commit_is_terminal() -> None:
    session = TranscriptionSession(max_audio_bytes=16)
    session.configure({"type": "transcription", "audio_format": PCM16})

    session.append_audio(_pcm16(b"\x00\x00\x01\x00"))
    flushed = session.flush_audio()
    session.append_audio(_pcm16(b"\x02\x00"))
    committed = session.commit_audio()

    assert flushed == b"\x00\x00\x01\x00"
    assert committed == b"\x02\x00"
    assert session.state == "committed"

    with pytest.raises(RealtimeV2Error, match="terminal"):
        session.append_audio(_pcm16(b"\x03\x00"))


def test_speech_session_enforces_one_active_response_and_chunk_order() -> None:
    session = SpeechSession(max_text_chars=16)
    session.configure({"type": "speech", "voice": "alloy", "audio_format": PCM16})
    session.append_text("你好")

    created = session.response_created(response_id="response-1")
    delta = session.audio_delta(response_id="response-1", chunk_index=0, audio=b"\x00\x00")

    assert created["type"] == "response.created"
    assert delta["audio"] == _pcm16(b"\x00\x00")

    with pytest.raises(RealtimeV2Error, match="chunk_index"):
        session.audio_delta(response_id="response-1", chunk_index=2, audio=b"\x00\x00")

    completed = session.response_completed(response_id="response-1")
    assert completed["type"] == "response.audio.completed"


def test_speech_response_cancel_is_idempotent_and_session_cancel_is_terminal() -> None:
    session = SpeechSession(max_text_chars=16)
    session.configure({"type": "speech", "voice": "alloy", "audio_format": PCM16})
    session.response_created(response_id="response-1")

    cancelled = session.response_cancel(response_id="response-1")
    repeated = session.response_cancel(response_id="response-1")
    terminal = session.cancel()

    assert cancelled["type"] == "response.audio.cancelled"
    assert repeated["type"] == "response.audio.cancelled"
    assert terminal["type"] == "session.cancelled"

    with pytest.raises(RealtimeV2Error, match="terminal"):
        session.append_text("再次输入")
