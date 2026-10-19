"""Public transcription paths preserve ambiguous spoken quantities."""

import pytest

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
_CASES = (
    (_RAW, _EXPECTED),
    ("万一人家不同意，价格五百一个。", "万一人家不同意，价格五百一个。"),
    ("预算三千五元，比例百分之一百五。", "预算三千五元，比例百分之一百五。"),
    ("一点一点地积累，五点六点再说，保持三点一线。",
     "一点一点地积累，五点六点再说，保持三点一线。"),
    ("百分之一点一点，实际增长百分之三点五。", "百分之一点一点，实际增长3.5%。"),
)


@pytest.mark.parametrize(("raw", "expected"), _CASES)
def test_batch_transcript_preserves_approximate_quantities(raw: str, expected: str) -> None:
    async def transcribe(*args: object) -> TranscriptResult:
        return TranscriptResult(
            request_id="backend", model_id="speechrail/qwen3-asr-1.7b",
            text=raw, language="zh", duration_ms=1000,
            segments=(TranscriptSegment(id=0, start_ms=0, end_ms=1000, text=raw),),
        )

    with batch_client(transcribe=transcribe) as client:
        response = client.post(
            "/v1/audio/transcriptions",
            files={"file": ("clip.wav", b"1234", "audio/wav")},
            data={"response_format": "json"},
        )
    assert response.status_code == 200
    assert response.json()["text"] == expected


@pytest.mark.parametrize(("raw", "expected"), _CASES)
def test_realtime_preview_and_final_preserve_approximate_quantities(
    raw: str, expected: str,
) -> None:
    client, _ = realtime_client(partials=(raw,), completed_text=raw)
    with client, client.websocket_connect("/v1/realtime") as socket:
        assert socket.receive_json()["type"] == "session.created"
        socket.send_json(session_update())
        assert socket.receive_json()["type"] == "session.updated"
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(_FRAME)})
        socket.send_json({"type": "input_audio_buffer.commit", "event_id": "numbers"})
        _, final, events = _receive_committed_item(socket)
        assert final["transcript"] == expected
        previews = [v for v in events if v["type"] == "speechrail.transcription.hypothesis"]
        assert len(previews) == 1 and previews[0]["text"] == expected
