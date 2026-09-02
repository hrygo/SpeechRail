from __future__ import annotations

import asyncio
import base64
import contextlib
from collections.abc import AsyncIterator
from pathlib import Path
from sys import executable
from typing import Any

import pytest

from speechrail.backends.qwen3_tts import Qwen3TtsBackendConfig, Qwen3TtsWorker
from speechrail.backends.qwen3_tts_worker import TTS_BACKEND_ID
from speechrail.domain.ports import SpeechRequest


class _FakeTransport:
    """Record sent frames and replay canned responses with live request IDs."""

    alive = True

    def __init__(self, responses: list[dict[str, Any]] | None = None) -> None:
        self.responses: list[dict[str, Any]] = []
        self.sends: list[dict[str, Any]] = []
        self.abort_count = 0
        self._available = asyncio.Event()
        for response in responses or []:
            self.push(response)

    def push(self, response: dict[str, Any]) -> None:
        self.responses.append(response)
        self._available.set()

    async def start(self) -> None:
        return None

    async def send(self, payload: dict[str, Any]) -> None:
        self.sends.append(dict(payload))

    async def receive(self) -> dict[str, Any]:
        while not self.responses:
            self._available.clear()
            await self._available.wait()
        response = self.responses.pop(0)
        if response.get("request_id") == "pending" and self.sends:
            response["request_id"] = self.sends[-1]["request_id"]
        return response

    async def abort(self) -> None:
        self.abort_count += 1
        self.alive = False

    async def close(self) -> None:
        self.abort_count += 1
        self.alive = False


def _worker(
    tmp_path: Path, responses: list[dict[str, Any]] | None = None
) -> tuple[Qwen3TtsWorker, _FakeTransport]:
    snapshot = tmp_path.parent / "external-qwen3-tts"
    snapshot.mkdir(exist_ok=True)
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(responses)
    worker._transport = fake  # type: ignore[assignment]
    worker._started = True
    return worker, fake


def _chunk_frame(request_id: str, index: int, pcm: bytes) -> dict[str, Any]:
    return {
        "type": "audio",
        "request_id": request_id,
        "chunk_index": index,
        "pcm_b64": base64.b64encode(pcm).decode(),
    }


def test_tts_worker_config_requires_external_snapshot_and_builds_private_command(
    tmp_path: Path,
) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts"
    snapshot.mkdir(exist_ok=True)
    (snapshot / "config.json").write_text("{}")

    config = Qwen3TtsBackendConfig(
        repository_root=tmp_path,
        python_executable=Path(executable),
        model_dir=snapshot,
        device="mps",
        dtype="float16",
        sample_rate=24_000,
    )

    assert config.model_dir == snapshot.resolve()
    assert config.command() == [
        executable,
        "-m",
        "speechrail.backends.qwen3_tts_worker",
        "--model-dir",
        str(snapshot.resolve()),
        "--device",
        "mps",
        "--dtype",
        "float16",
        "--sample-rate",
        "24000",
        "--chunk-ms",
        "100",
        "--repetition-penalty",
        "1.25",
        "--temperature",
        "0.85",
        "--top-p",
        "0.95",
        "--cache-limit-mb",
        "256",
    ]


def test_tts_worker_config_rejects_snapshot_inside_repository(tmp_path: Path) -> None:
    snapshot = tmp_path / "model"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")

    with pytest.raises(ValueError, match="outside repository"):
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )


def test_tts_worker_normalizes_private_audio_frames_to_public_chunks(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [_chunk_frame("pending", 0, b"\x00\x00"), {"type": "completed", "request_id": "pending"}],
    )

    async def collect() -> list[Any]:
        return [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]

    chunks = asyncio.run(collect())

    request = fake.sends[0]
    response_id = str(request["request_id"])
    assert request["version"] == 1
    assert request["type"] == "synthesize"
    assert request["text"] == "你好"
    assert request["voice"] == "default"
    assert request["speed"] == 1.0
    assert request["language"] == "auto"
    assert chunks[0].response_id == response_id
    assert chunks[0].chunk_index == 0
    assert chunks[0].audio == b"\x00\x00"
    assert fake.abort_count == 0


def test_tts_worker_starts_offline_transport_and_checks_ready_identity(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-start"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    async def start_and_close() -> None:
        await worker.start()
        assert worker.ready is True
        assert fake.sends[0]["type"] == "start"
        assert fake.sends[0]["model_dir"].endswith("external-qwen3-tts-start")
        assert fake.sends[0]["device"] == "mps"
        assert fake.sends[0]["dtype"] == "float16"
        assert fake.sends[0]["sample_rate"] == 24_000
        await worker.close()
        assert worker.ready is False

    asyncio.run(start_and_close())


def test_start_failure_embeds_worker_stderr_tail(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-load-error"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "error",
                "code": "worker_load_error",
                "stderr_tail": "mlx.core: [Metal] failed to allocate model weights",
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    async def scenario() -> None:
        with pytest.raises(RuntimeError, match="worker_load_error") as exc_info:
            await worker.start()
        assert "failed to allocate" in str(exc_info.value)

    asyncio.run(scenario())


def test_ready_identity_mismatch_aborts_the_tts_worker(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-tts-mismatch"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    fake = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "cpu",
                "dtype": "float32",
                "sample_rate": 24_000,
            }
        ]
    )
    worker._transport = fake  # type: ignore[assignment]

    with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
        asyncio.run(worker.start())

    assert fake.abort_count == 1


def test_int8_config_builds_command_and_requires_int8_identity(tmp_path: Path) -> None:
    """SPEECHRAIL_DTYPE=int8 now strictly enforced on the TTS worker (was silent bf16)."""
    snapshot = tmp_path.parent / "external-qwen3-tts-int8"
    snapshot.mkdir()
    (snapshot / "config.json").write_text("{}")

    config = Qwen3TtsBackendConfig(
        repository_root=tmp_path,
        python_executable=Path(executable),
        model_dir=snapshot,
        device="mps",
        dtype="int8",
        sample_rate=24_000,
    )
    assert "--dtype" in config.command()
    assert config.command()[config.command().index("--dtype") + 1] == "int8"

    silent_bf16 = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "float16",
                "sample_rate": 24_000,
            }
        ]
    )
    worker = Qwen3TtsWorker(config)
    worker._transport = silent_bf16  # type: ignore[assignment]
    with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
        asyncio.run(worker.start())
    assert silent_bf16.abort_count == 1
    assert silent_bf16.sends[0]["dtype"] == "int8"

    int8_ready = _FakeTransport(
        [
            {
                "type": "ready",
                "model_loaded": True,
                "backend": TTS_BACKEND_ID,
                "device": "mps",
                "dtype": "int8",
                "sample_rate": 24_000,
            }
        ]
    )
    worker._transport = int8_ready  # type: ignore[assignment]
    asyncio.run(worker.start())
    assert worker.ready is True
    assert int8_ready.abort_count == 0


def test_each_synthesis_uses_an_independent_response_id(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [
            _chunk_frame("pending", 0, b"\x00\x00"),
            {"type": "completed", "request_id": "pending"},
            _chunk_frame("pending", 0, b"\x01\x00"),
            {"type": "completed", "request_id": "pending"},
        ],
    )

    async def collect_twice() -> tuple[list[Any], list[Any]]:
        first = [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]
        second = [
            chunk async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]
        return first, second

    first, second = asyncio.run(collect_twice())

    assert fake.sends[0]["request_id"] != fake.sends[1]["request_id"]
    assert first[0].response_id == fake.sends[0]["request_id"]
    assert second[0].response_id == fake.sends[1]["request_id"]


def test_cross_request_id_frame_aborts_the_stream(tmp_path: Path) -> None:
    worker, fake = _worker(tmp_path)

    async def scenario() -> None:
        stream = worker.synthesize(SpeechRequest(text="你好", voice="default"))
        agen = stream.__aiter__()
        task = asyncio.ensure_future(agen.__anext__())
        await asyncio.sleep(0.05)
        fake.push(
            {"type": "audio", "request_id": "other-response", "chunk_index": 0, "pcm_b64": "AAA="}
        )
        with pytest.raises(RuntimeError, match="worker_response_id_mismatch"):
            await task
        assert fake.abort_count == 1

    asyncio.run(scenario())


def test_invalid_base64_or_odd_pcm_aborts_the_stream(tmp_path: Path) -> None:
    for response in (
        {"type": "audio", "request_id": "pending", "chunk_index": 0, "pcm_b64": "not!!base64"},
        _chunk_frame("pending", 0, b"\x00"),  # odd byte count
    ):
        worker, fake = _worker(tmp_path, [response])

        async def consume(target: Qwen3TtsWorker) -> list[Any]:
            return [
                chunk
                async for chunk in target.synthesize(SpeechRequest(text="你好", voice="default"))
            ]

        with pytest.raises(RuntimeError, match="worker_audio_frame_invalid"):
            asyncio.run(consume(worker))

        assert fake.abort_count == 1


def test_gap_or_duplicate_chunk_index_aborts_the_stream(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path, [_chunk_frame("pending", 1, b"\x00\x00")]  # gap: first frame is index 1
    )

    async def consume() -> list[Any]:
        return [
            chunk
            async for chunk in worker.synthesize(SpeechRequest(text="你好", voice="default"))
        ]

    with pytest.raises(RuntimeError, match="worker_audio_frame_invalid"):
        asyncio.run(consume())

    assert fake.abort_count == 1


def test_tts_worker_aborts_private_generation_when_consumer_cancels(tmp_path: Path) -> None:
    worker, fake = _worker(tmp_path)
    started = asyncio.Event()
    release = asyncio.Event()

    async def blocked_receive() -> dict[str, Any]:
        started.set()
        await release.wait()
        return {"type": "completed", "request_id": fake.sends[0]["request_id"]}

    fake.receive = blocked_receive  # type: ignore[method-assign]

    async def consume() -> None:
        async for _chunk in worker.synthesize(SpeechRequest(text="取消", voice="default")):
            pass

    async def scenario() -> None:
        task = asyncio.create_task(consume())
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert fake.abort_count == 1

    asyncio.run(scenario())


def test_close_waits_for_lock_then_terminates_worker(tmp_path: Path) -> None:
    """close() acquires the lock, so it waits for any active stream to finish."""
    worker, fake = _worker(tmp_path)
    started = asyncio.Event()

    async def blocked_receive() -> dict[str, Any]:
        started.set()
        await asyncio.Event().wait()  # never released: stream holds the worker lock

    fake.receive = blocked_receive  # type: ignore[method-assign]

    async def scenario() -> None:
        stream = worker.synthesize(SpeechRequest(text="关闭", voice="default"))
        task = asyncio.ensure_future(stream.__anext__())
        await started.wait()

        # close() will block because stream holds the lock — cancel stream first
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        # stream finally aborted the worker (same epoch), releasing the lock
        assert fake.abort_count == 1

        # Now close() can acquire the lock and abort again (but epoch has advanced
        # from the finally block, so it sees a fresh transport)
        fake.alive = True
        worker._started = True
        await asyncio.wait_for(worker.close(), timeout=1.0)
        assert fake.abort_count == 2

    asyncio.run(scenario())


def test_close_acquires_lock_and_waits_for_active_stream(tmp_path: Path) -> None:
    """close() must acquire the lock, so it blocks while a stream is active."""
    worker, fake = _worker(tmp_path)
    stream_entered = asyncio.Event()
    close_started = asyncio.Event()

    original_receive = fake.receive

    call_count = 0

    async def gated_receive() -> dict[str, Any]:
        nonlocal call_count
        call_count += 1
        if call_count == 1:
            stream_entered.set()
            # Wait until close has been attempted (it should block on the lock)
            await close_started.wait()
            await asyncio.sleep(0.05)
        return await original_receive()

    fake.receive = gated_receive  # type: ignore[method-assign]
    fake.push(_chunk_frame("pending", 0, b"\x00\x00"))
    fake.push({"type": "completed", "request_id": "pending"})

    async def scenario() -> None:
        # Start streaming
        stream_task = asyncio.create_task(
            _collect(worker.synthesize(SpeechRequest(text="关闭", voice="default")))
        )
        await stream_entered.wait()

        # Try to close — should block on the lock
        close_task = asyncio.create_task(worker.close())
        close_started.set()

        # Stream should complete first
        chunks = await stream_task
        assert len(chunks) == 1

        # Then close finishes
        await asyncio.wait_for(close_task, timeout=2.0)
        assert fake.abort_count == 1  # only close()'s abort, not stream's (epoch advanced)

    asyncio.run(scenario())


def test_epoch_guard_prevents_stale_finally_from_aborting_new_worker(tmp_path: Path) -> None:
    """When worker epoch has advanced, a stale stream finally must skip abort."""
    worker, fake = _worker(tmp_path)
    stream_entered = asyncio.Event()

    async def blocked_receive() -> dict[str, Any]:
        stream_entered.set()
        await asyncio.Event().wait()  # block forever

    fake.receive = blocked_receive  # type: ignore[method-assign]

    async def scenario() -> None:
        stream = worker.synthesize(SpeechRequest(text="epoch", voice="default"))
        stream_task = asyncio.ensure_future(stream.__anext__())
        await stream_entered.wait()

        # Advance worker epoch (simulating recycling or epoch bump)
        worker._epoch += 10
        fake.abort_count = 0

        # Now cancel the stream — its finally block sees that self._epoch != captured_epoch
        stream_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await stream_task

        # Stale stream must NOT abort the worker because epoch has advanced
        assert fake.abort_count == 0

    asyncio.run(scenario())


async def _collect(source: AsyncIterator[Any]) -> list[Any]:
    return [item async for item in source]
