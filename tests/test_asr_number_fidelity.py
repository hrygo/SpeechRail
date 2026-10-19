"""Public transcription paths preserve ambiguous spoken quantities."""

from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from test_realtime_openai import (
    _FRAME,
    _pcm16,
    _receive_committed_item,
    session_update,
)
from test_realtime_openai import (
    _client as realtime_client,
)
from test_transcription_api import _client as batch_client

_RAW = "等七八天，五六个人，费用五十六元。"
_EXPECTED = "等七八天，五六个人，费用56元。"


def test_batch_transcript_preserves_approximate_quantities() -> None:
    async def transcribe(*args: object) -> TranscriptResult:
        return TranscriptResult(
            request_id="backend", model_id="speechrail/qwen3-asr-1.7b",
            text=_RAW, language="zh", duration_ms=1000,
            segments=(TranscriptSegment(id=0, start_ms=0, end_ms=1000, text=_RAW),),
        )

    with batch_client(transcribe=transcribe) as client:
        response = client.post(
            "/v1/audio/transcriptions",
            files={"file": ("clip.wav", b"1234", "audio/wav")},
            data={"response_format": "json"},
        )
    assert response.status_code == 200
    assert response.json()["text"] == _EXPECTED


def test_realtime_preview_and_final_preserve_approximate_quantities() -> None:
    client, _ = realtime_client(partials=(_RAW,), completed_text=_RAW)
    with client, client.websocket_connect("/v1/realtime") as socket:
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json(session_update())
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json({"type": "input_audio_buffer.commit", "event_id": "numbers"})
        _, final, events = _receive_committed_item(socket)
        assert final["transcript"] == _EXPECTED
        previews = [v for v in events if v["type"] == "speechrail.transcription.hypothesis"]
        assert len(previews) == 1 and previews[0]["text"] == _EXPECTED
