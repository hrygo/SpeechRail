"""Repetition cleanup reaches callers, and can be turned off without a copy.

The unit behaviour lives in ``test_transcript_cleanup.py``; this file pins what
only an integration test can prove: that every ASR caller sees the same
cleaned transcript, that the realtime terminal reports the collapse, and that
the off switch leaves the original text alone.
"""

from __future__ import annotations

import asyncio
import base64
from collections.abc import AsyncIterator

from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.backends.qwen3_native import Qwen3BatchTranscriber
from speechrail.config import Settings
from speechrail.domain.contracts import (
    TranscriptResult,
    TranscriptSegment,
    TranscriptWord,
)
from speechrail.domain.ports import TranscriptionRequest
from test_realtime_admission_commits import _build
from test_realtime_multiscene_asr import _policy_update

_LOOP_TEXT = "预算" * 7


class _FakeWorker:
    """Stand in for the isolated worker: returns one canned result."""

    def __init__(self, result: TranscriptResult) -> None:
        self._result = result
        self.calls = 0

    async def transcribe(
        self,
        pcm: bytes,
        language: str | None,
        prompt: str,
        include_timestamps: bool = False,
        *,
        request_id: str | None = None,
    ) -> TranscriptResult:
        self.calls += 1
        return self._result.model_copy(update={"request_id": request_id or "req"})

    async def transcribe_stream(
        self,
        audio: AsyncIterator[bytes],
        language: str | None,
        prompt: str,
        include_timestamps: bool = True,
        *,
        request_id: str | None = None,
    ) -> TranscriptResult:
        chunks = [chunk async for chunk in audio]
        return await self.transcribe(
            b"".join(chunks), language, prompt, include_timestamps, request_id=request_id
        )


def _looped_result() -> TranscriptResult:
    return TranscriptResult(
        request_id="req-1",
        model_id="speechrail/qwen3-asr-1.7b",
        text=_LOOP_TEXT,
        duration_ms=4_000,
        segments=(TranscriptSegment(id=0, start_ms=0, end_ms=400, text=_LOOP_TEXT, partial=False),),
        words=tuple(
            TranscriptWord(word="预算", start_ms=index * 10, end_ms=index * 10 + 9)
            for index in range(7)
        ),
    )


def _request(request_id: str) -> TranscriptionRequest:
    return TranscriptionRequest(
        request_id=request_id, audio=b"\x00\x00" * 3200, language="zh", prompt=""
    )


def test_every_asr_caller_sees_the_same_cleaned_transcript() -> None:
    worker = _FakeWorker(_looped_result())
    transcriber = Qwen3BatchTranscriber(worker=worker, model_id="speechrail/qwen3-asr-1.7b")

    result = asyncio.run(transcriber.transcribe(_request("req-http")))

    assert result.text == "预算"
    assert result.segments[0].text == "预算"
    assert len(result.words) == 1
    assert result.repetition_collapsed == 1
    # The port still owns request identity and model identity.
    assert result.request_id == "req-http"
    assert result.model_id == "speechrail/qwen3-asr-1.7b"
    assert worker.calls == 1


def test_the_streaming_path_is_cleaned_too() -> None:
    worker = _FakeWorker(_looped_result())
    transcriber = Qwen3BatchTranscriber(worker=worker, model_id="m")

    async def chunks() -> AsyncIterator[bytes]:
        yield b"\x00\x00" * 3200

    result = asyncio.run(transcriber.transcribe_stream("req-stream", chunks()))

    assert result.text == "预算"
    assert result.repetition_collapsed == 1
    assert result.request_id == "req-stream"


def test_the_off_switch_and_the_threshold_are_honored() -> None:
    worker = _FakeWorker(_looped_result())
    request = _request("req-off")

    off = Qwen3BatchTranscriber(worker=worker, model_id="m", repetition_collapse_enabled=False)
    assert asyncio.run(off.transcribe(request)).text == _LOOP_TEXT

    strict = Qwen3BatchTranscriber(worker=worker, model_id="m", repetition_collapse_min_run=99)
    assert asyncio.run(strict.transcribe(request)).text == _LOOP_TEXT


def test_the_settings_defaults_expose_the_switch_and_the_threshold() -> None:
    settings = Settings()
    assert settings.asr_repetition_collapse_enabled is True
    assert settings.asr_repetition_collapse_min_run == 6

    assert Settings(asr_repetition_collapse_enabled=False).asr_repetition_collapse_enabled is False


async def _stream_and_collect(*, completed_text: str) -> list[dict]:
    """Run one realtime turn far enough for the completed event to be sent.

    The canned text is set on the factory the container already owns: passing a
    factory into ``_build`` would be swallowed by its ``**settings_overrides``
    and silently ignored.
    """

    services, factory = _build()
    factory.completed_text = completed_text
    sent: list[dict] = []

    async def send(event: dict):
        sent.append(event)
        return len(sent)

    session = OpenAIRealtimeSession(services, session_id="s", send=send)
    await session._update_session(_policy_update())
    frame = bytes(3200)
    for _ in range(12):
        await session._asr_owner.append(
            {"type": "input_audio_buffer.append", "audio": base64.b64encode(frame).decode()}
        )
    await session._asr_owner.commit("client")
    await asyncio.sleep(0)
    await session.close()
    return sent


def _terminals(sent: list[dict]) -> list[dict]:
    return [
        event
        for event in sent
        if event["type"] == "conversation.item.input_audio_transcription.completed"
    ]


def test_the_realtime_terminal_reports_the_collapse() -> None:
    sent = asyncio.run(_stream_and_collect(completed_text=_LOOP_TEXT))

    completed = _terminals(sent)
    assert len(completed) == 1
    assert completed[0]["transcript"] == "预算"
    assert completed[0]["repetition_collapsed"] == 1


def test_the_realtime_terminal_is_clean_when_nothing_loops() -> None:
    sent = asyncio.run(_stream_and_collect(completed_text="我们今天讨论预算"))

    completed = _terminals(sent)
    assert completed[0]["transcript"] == "我们今天讨论预算"
    assert "repetition_collapsed" not in completed[0]
