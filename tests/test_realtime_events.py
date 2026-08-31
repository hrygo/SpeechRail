import base64

import pytest

from speechrail.realtime.events import RealtimeSession, SessionError


def test_realtime_session_requires_update_before_audio_and_commits_once() -> None:
    session = RealtimeSession(session_id="sess_1", max_frame_bytes=16, max_buffer_bytes=32)

    with pytest.raises(SessionError, match="session_not_configured"):
        session.append(base64.b64encode(b"\x00\x00").decode())

    created = session.update({"language": "zh", "model": "speechrail/qwen3-asr-1.7b"})
    assert created["type"] == "transcription_session.created"
    session.append(base64.b64encode(b"\x00\x00").decode())
    assert session.commit() == b"\x00\x00"
    with pytest.raises(SessionError, match="already_committed"):
        session.commit()


def test_realtime_session_rejects_invalid_base64_and_buffer_overflow() -> None:
    session = RealtimeSession(session_id="sess_1", max_frame_bytes=4, max_buffer_bytes=4)
    session.update({"model": "speechrail/qwen3-asr-1.7b"})
    with pytest.raises(SessionError, match="invalid_base64"):
        session.append("not base64")
    with pytest.raises(SessionError, match="audio_too_large"):
        session.append(base64.b64encode(b"\x00" * 6).decode())
