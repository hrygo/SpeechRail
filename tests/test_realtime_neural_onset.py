from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from realtime_wire import server_vad, session_update
from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.backends.neural_vad import SileroVadDetector
from speechrail.backends.vad import VoiceActivityDetector
from test_realtime_admission_commits import _b64, _build


@pytest.mark.parametrize("engine", ["auto", "silero", "legacy"])
@pytest.mark.parametrize("peak_frames,probability", [(1, 0.55), (2, 0.55), (3, 0.55), (3, 0.49)])
def test_neural_onset_preserves_brief_confirmed_speech(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    engine: str,
    peak_frames: int,
    probability: float,
) -> None:
    """Neural speech confirmation should reach ASR; weak energy spikes still debounce."""
    model = tmp_path / "stub.onnx"
    model.write_bytes(b"stub; inference replaced")
    scores = iter([0.0] * 5 + [probability] * peak_frames + [0.0] * 40)
    monkeypatch.setattr(
        SileroVadDetector, "check_readiness", classmethod(lambda cls, path: (True, None))
    )
    monkeypatch.setattr(SileroVadDetector, "score_frame", lambda self, frame: next(scores, 0.0))
    monkeypatch.setattr(VoiceActivityDetector, "score_frame", lambda self, frame: next(scores, 0.0))
    services, _ = _build(
        realtime_vad_engine=engine,
        realtime_vad_model_path=model,
        realtime_speech_admission_enabled=True,
    )
    sent: list[dict] = []

    async def send(event: dict) -> int:
        sent.append(event)
        return len(sent)

    async def run() -> None:
        session = OpenAIRealtimeSession(services, session_id="onset", send=send)
        try:
            await session._update_session(session_update(endpointing=server_vad(threshold=0.5)))
            for _ in range(48):
                await session._asr_owner.append(
                    {"type": "input_audio_buffer.append", "audio": _b64(bytes(1536))}
                )
            await session._asr_owner.commit("client")
        finally:
            await session.close()

    asyncio.run(run())
    completed = [
        event
        for event in sent
        if event["type"] == "conversation.item.input_audio_transcription.completed"
        and event["transcript"]
    ]
    expected = probability >= 0.5 and (engine != "legacy" or peak_frames >= 3)
    assert len(completed) == int(expected)
    assert all(event["type"] != "error" for event in sent)
