"""Tests for chunked ASR inference and bounded window transcription (A03)."""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from unittest.mock import MagicMock

import pytest

from speechrail.application.audio_stream import split_pcm
from speechrail.backends.qwen3_native import Qwen3BatchTranscriber, Qwen3Worker
from speechrail.runtime.asr_mode import AsrModeGate
from speechrail.runtime.worker_protocol import ProtocolError


def test_each_inference_window_is_bounded() -> None:
    blocks = split_pcm(
        b"\0\0" * 16000 * 61,
        window_samples=16000 * 30,
        overlap_samples=16000,
    )
    assert max(len(b.pcm) for b in blocks) <= 32000 * 30
    assert blocks[-1].core_end_sample == 16000 * 61


class _FakeSharedWorker:
    def __init__(self) -> None:
        self.mode_gate = AsrModeGate()
        self.requests: list[dict[str, object]] = []
        self.payloads: list[bytes | None] = []
        self.fail_on_request_id: str | None = None

    async def start(self) -> None:
        pass

    async def request(
        self, payload: dict[str, object], binary: bytes | None = None
    ) -> dict[str, object]:
        req_id = str(payload.get("request_id"))
        self.requests.append(payload)
        self.payloads.append(binary)
        if self.fail_on_request_id and req_id == self.fail_on_request_id:
            raise RuntimeError("simulated_window_failure")

        # Mock result for a window
        sample_count = len(binary or b"") // 2
        duration_ms = round(sample_count * 1000 / 16000)
        return {
            "type": "result",
            "request_id": req_id,
            "text": f"window text for {req_id}",
            "language": "zh",
            "segments": [
                {
                    "text": f"window text for {req_id}",
                    "start": 0.0,
                    "end": duration_ms / 1000.0,
                }
            ],
        }


class _TransportLossSharedWorker(_FakeSharedWorker):
    def __init__(self, fail_request_id: str, *, failures: int = 1) -> None:
        super().__init__()
        self._fail_request_id = fail_request_id
        self._failures = failures

    async def request(
        self, payload: dict[str, object], binary: bytes | None = None
    ) -> dict[str, object]:
        request_id = str(payload.get("request_id"))
        if request_id == self._fail_request_id and self._failures:
            self.requests.append(payload)
            self.payloads.append(binary)
            self._failures -= 1
            raise RuntimeError("worker_unavailable") from ProtocolError("truncated frame")
        return await super().request(payload, binary=binary)


class _FailureSharedWorker(_FakeSharedWorker):
    def __init__(self, fail_request_id: str, failure: BaseException) -> None:
        super().__init__()
        self._fail_request_id = fail_request_id
        self._failure = failure

    async def request(
        self, payload: dict[str, object], binary: bytes | None = None
    ) -> dict[str, object]:
        request_id = str(payload.get("request_id"))
        if request_id == self._fail_request_id:
            self.requests.append(payload)
            self.payloads.append(binary)
            raise self._failure
        return await super().request(payload, binary=binary)


async def _audio_chunks(total_samples: int, chunk_size: int = 16000) -> AsyncIterator[bytes]:
    sent = 0
    while sent < total_samples:
        current = min(chunk_size, total_samples - sent)
        yield b"\0\0" * current
        sent += current


def test_transcribe_stream_chunks_long_audio_and_merges_results() -> None:
    async def scenario() -> None:
        fake_shared = _FakeSharedWorker()
        worker = Qwen3Worker(MagicMock(), shared_owner=fake_shared)  # type: ignore[arg-type]
        transcriber = Qwen3BatchTranscriber(worker=worker, model_id="speechrail/qwen3-asr-1.7b")

        # 65 seconds of audio -> 30s window, 29s step -> 3 windows
        # Window 0: 0..30s (core 0..30s)
        # Window 1: 29..59s (core 30..59s)
        # Window 2: 58..65s (core 59..65s)
        stream = _audio_chunks(16000 * 65)

        result = await transcriber.transcribe_stream(
            request_id="test_req_long",
            audio=stream,
            language="zh",
            prompt="test prompt",
            include_timestamps=True,
        )

        assert result.request_id == "test_req_long"
        assert result.model_id == "speechrail/qwen3-asr-1.7b"
        assert result.duration_ms == 65000
        assert len(fake_shared.requests) == 3

        # Ensure each chunk payload was bounded to at most 30 seconds (960,000 bytes)
        for p in fake_shared.payloads:
            assert p is not None
            assert len(p) <= 32000 * 30

        # Verify mode gate token was fully released
        assert fake_shared.mode_gate.active_mode is None
        assert fake_shared.mode_gate.active_count == 0

    asyncio.run(scenario())


def test_first_window_failure_does_not_return_partial_result() -> None:
    async def scenario() -> None:
        fake_shared = _FakeSharedWorker()
        # Instruct fake to fail on second window
        fake_shared.fail_on_request_id = "test_req_fail_win_1"

        worker = Qwen3Worker(MagicMock(), shared_owner=fake_shared)  # type: ignore[arg-type]
        transcriber = Qwen3BatchTranscriber(worker=worker, model_id="speechrail/qwen3-asr-1.7b")

        stream = _audio_chunks(16000 * 65)

        with pytest.raises(RuntimeError, match="simulated_window_failure"):
            await transcriber.transcribe_stream(
                request_id="test_req_fail",
                audio=stream,
                language="zh",
                prompt="test prompt",
                include_timestamps=True,
            )

        # Ensure mode gate is released even on error
        assert fake_shared.mode_gate.active_mode is None
        assert fake_shared.mode_gate.active_count == 0

    asyncio.run(scenario())


def test_transcribe_stream_respects_include_timestamps_false() -> None:
    async def scenario() -> None:
        fake_shared = _FakeSharedWorker()
        worker = Qwen3Worker(MagicMock(), shared_owner=fake_shared)  # type: ignore[arg-type]
        transcriber = Qwen3BatchTranscriber(worker=worker, model_id="speechrail/qwen3-asr-1.7b")

        stream = _audio_chunks(16000 * 35)

        result = await transcriber.transcribe_stream(
            request_id="test_req_notimestamps",
            audio=stream,
            include_timestamps=False,
        )

        assert result.request_id == "test_req_notimestamps"
        for req in fake_shared.requests:
            assert req["include_timestamps"] is False

    asyncio.run(scenario())


def test_long_transcribe_retries_a_window_once_and_preserves_no_partial_success() -> None:
    async def scenario() -> None:
        fake_shared = _TransportLossSharedWorker("long_retry_win_0")
        worker = Qwen3Worker(MagicMock(), shared_owner=fake_shared)  # type: ignore[arg-type]

        result = await worker.transcribe(
            b"\0\0" * 16000 * 65,
            "zh",
            "prompt",
            include_timestamps=True,
            request_id="long_retry",
        )
        assert result.duration_ms == 65000
        assert [
            request["request_id"] for request in fake_shared.requests
        ] == [
            "long_retry_win_0",
            "long_retry_win_0",
            "long_retry_win_1",
            "long_retry_win_2",
        ]

        failed_shared = _TransportLossSharedWorker("long_fail_win_1", failures=2)
        failed_worker = Qwen3Worker(  # type: ignore[arg-type]
            MagicMock(), shared_owner=failed_shared
        )
        with pytest.raises(RuntimeError, match="worker_unavailable"):
            await failed_worker.transcribe(
                b"\0\0" * 16000 * 65,
                "zh",
                "prompt",
                request_id="long_fail",
            )
        assert [
            request["request_id"] for request in failed_shared.requests
        ] == [
            "long_fail_win_0",
            "long_fail_win_1",
            "long_fail_win_1",
        ]

    asyncio.run(scenario())


def test_transcribe_stream_reuses_bounded_transport_retry_per_window() -> None:
    async def scenario() -> None:
        fake_shared = _TransportLossSharedWorker("stream_retry_win_0")
        worker = Qwen3Worker(MagicMock(), shared_owner=fake_shared)  # type: ignore[arg-type]
        transcriber = Qwen3BatchTranscriber(
            worker=worker, model_id="speechrail/qwen3-asr-1.7b"
        )
        result = await transcriber.transcribe_stream(
            request_id="stream_retry",
            audio=_audio_chunks(16000 * 35),
            language="zh",
        )
        assert result.duration_ms == 35000
        assert [
            request["request_id"] for request in fake_shared.requests
        ] == [
            "stream_retry_win_0",
            "stream_retry_win_0",
            "stream_retry_win_1",
        ]

    asyncio.run(scenario())


@pytest.mark.parametrize(
    "failure",
    [TimeoutError("worker_request_timeout"), RuntimeError("worker_inference_error")],
    ids=["timeout", "semantic"],
)
def test_long_transcribe_does_not_retry_timeout_or_semantic_error(
    failure: BaseException,
) -> None:
    async def scenario() -> None:
        fake_shared = _FailureSharedWorker("long_failure_win_1", failure)
        worker = Qwen3Worker(MagicMock(), shared_owner=fake_shared)  # type: ignore[arg-type]

        with pytest.raises(type(failure), match=str(failure)):
            await worker.transcribe(
                b"\0\0" * 16000 * 65,
                "zh",
                "prompt",
                request_id="long_failure",
            )
        assert [
            request["request_id"] for request in fake_shared.requests
        ] == [
            "long_failure_win_0",
            "long_failure_win_1",
        ]

    asyncio.run(scenario())
