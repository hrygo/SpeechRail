from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

from speechrail.backends.qwen3_native import Qwen3BatchTranscriber
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import (
    AudioChunk,
    BatchTranscriber,
    SpeechRequest,
    SpeechSynthesizer,
    StreamingTranscriber,
    TranscriptionRequest,
)


class FakeQwenWorker:
    async def transcribe(
        self, pcm: bytes, language: str | None, prompt: str, *, request_id: str | None = None
    ) -> TranscriptResult:
        assert pcm == b"\x00\x00"
        assert language == "zh"
        assert prompt == "会议"
        return TranscriptResult(
            request_id=request_id or "unexpected",
            model_id="vendor/model",
            text="转写完成",
            language="zh",
            duration_ms=10,
        )


class FakeStreamingTranscriber:
    async def stream(self, audio: AsyncIterator[bytes]) -> AsyncIterator[TranscriptResult]:
        async for _ in audio:
            yield TranscriptResult(
                request_id="req-stream",
                model_id="fake/asr",
                text="部分结果",
                language="zh",
                duration_ms=10,
            )


class FakeSpeechSynthesizer:
    async def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        assert request.text == "你好"
        yield AudioChunk(response_id="resp-1", chunk_index=0, audio=b"\x00\x00")


def test_qwen_adapter_normalizes_request_and_model_identity() -> None:
    async def scenario() -> None:
        adapter: BatchTranscriber = Qwen3BatchTranscriber(
            worker=FakeQwenWorker(), model_id="speechrail/qwen3-asr-1.7b"
        )
        result = await adapter.transcribe(
            TranscriptionRequest(
                request_id="req-1", audio=b"\x00\x00", language="zh", prompt="会议"
            )
        )

        assert result.request_id == "req-1"
        assert result.model_id == "speechrail/qwen3-asr-1.7b"
        assert result.text == "转写完成"

    asyncio.run(scenario())


def test_streaming_and_tts_ports_can_be_backed_by_deterministic_fakes() -> None:
    async def source() -> AsyncIterator[bytes]:
        yield b"\x00\x00"

    async def scenario() -> None:
        transcriber: StreamingTranscriber = FakeStreamingTranscriber()
        synthesizer: SpeechSynthesizer = FakeSpeechSynthesizer()

        results = [result async for result in transcriber.stream(source())]
        request = SpeechRequest(text="你好", voice="alloy")
        chunks = [
            chunk async for chunk in synthesizer.synthesize(request)
        ]

        assert results[0].text == "部分结果"
        assert chunks[0].audio == b"\x00\x00"

    asyncio.run(scenario())
