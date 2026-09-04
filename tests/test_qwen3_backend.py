from pathlib import Path
from sys import executable
from typing import Any

import pytest

from speechrail.backends.qwen3_native import (
    MODEL_FILES,
    Qwen3BackendConfig,
    Qwen3Worker,
    validate_snapshot,
    weight_files,
)


class _FakeTransport:
    def __init__(self, responses: list[dict[str, Any]]) -> None:
        self.responses = responses
        self.sends: list[dict[str, Any]] = []
        self.aborted = False

    alive = True

    async def start(self) -> None:
        return None

    async def send(self, payload: dict[str, Any], binary_payload: bytes | None = None) -> None:
        if binary_payload is not None:
            payload["_binary"] = binary_payload
        self.sends.append(payload)

    async def receive(self) -> dict[str, Any]:
        if not self.responses:
            raise AssertionError("fake transport ran out of canned responses")
        return self.responses.pop(0)

    async def exchange(
        self, payload: dict[str, Any], binary_payload: bytes | None = None
    ) -> dict[str, Any]:
        await self.send(payload, binary_payload=binary_payload)
        return await self.receive()

    async def abort(self) -> None:
        self.aborted = True

    async def close(self) -> None:
        self.aborted = True


def _worker(tmp_path: Path, responses: list[dict[str, Any]]) -> tuple[Qwen3Worker, _FakeTransport]:
    snapshot = tmp_path.parent / "external-qwen3-asr-profile"
    snapshot.mkdir(exist_ok=True)
    for filename in (*MODEL_FILES, "model.safetensors"):
        (snapshot / filename).touch()
    config = Qwen3BackendConfig(
        repository_root=Path(__file__).resolve().parents[1],
        python_executable=Path(executable),
        model_dir=snapshot,
        device="mps",
        dtype="float16",
    )
    worker = Qwen3Worker(config)
    fake = _FakeTransport(responses)
    worker._transport = fake  # type: ignore[assignment]
    return worker, fake


def test_snapshot_preflight_rejects_missing_or_repository_local_models(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="absolute"):
        validate_snapshot(Path("relative"), repository_root=tmp_path)

    inside_repository = tmp_path / "models" / "qwen"
    inside_repository.mkdir(parents=True)
    with pytest.raises(ValueError, match="outside"):
        validate_snapshot(inside_repository, repository_root=tmp_path)


def test_weight_files_accepts_both_layouts_and_rejects_missing(tmp_path: Path) -> None:
    single = tmp_path / "single-file"
    single.mkdir()
    (single / "model.safetensors").touch()
    assert weight_files(single) == ("model.safetensors",)

    sharded = tmp_path / "two-shard"
    sharded.mkdir()
    (sharded / "model-00001-of-00002.safetensors").touch()
    (sharded / "model-00002-of-00002.safetensors").touch()
    assert weight_files(sharded) == (
        "model-00001-of-00002.safetensors",
        "model-00002-of-00002.safetensors",
    )

    with pytest.raises(ValueError, match="weights are missing"):
        weight_files(tmp_path / "empty")


def test_validate_snapshot_accepts_single_file_quantized_layout(tmp_path: Path) -> None:
    snapshot = tmp_path.parent / "external-qwen3-asr-8bit"
    snapshot.mkdir(exist_ok=True)
    for filename in (*MODEL_FILES, "model.safetensors"):
        (snapshot / filename).touch()
    (snapshot / "config.json").write_text('{"quantization": {"bits": 8}}', encoding="utf-8")

    resolved = validate_snapshot(snapshot, repository_root=tmp_path)
    assert resolved.is_dir()
    assert resolved.name == "external-qwen3-asr-8bit"


def test_backend_config_rejects_cpu_fallback_for_mps_profile(tmp_path: Path) -> None:
    model_dir = tmp_path.parent / "external-model"
    model_dir.mkdir(exist_ok=True)
    python = Path("/usr/bin/python3")

    with pytest.raises(ValueError, match="float16"):
        Qwen3BackendConfig(
            repository_root=tmp_path,
            python_executable=python,
            model_dir=model_dir,
            device="mps",
            dtype="float32",
        )


def test_start_payload_declares_snapshot_and_device(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [{"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"}],
    )

    worker._transport = fake  # keep the fake after construction
    import asyncio

    asyncio.run(worker.start())

    assert fake.sends[0]["type"] == "start"
    assert fake.sends[0]["device"] == "mps"
    assert fake.sends[0]["model_dir"].endswith("external-qwen3-asr-profile")


def test_start_failure_embeds_worker_stderr_tail(tmp_path: Path) -> None:
    worker, _ = _worker(
        tmp_path,
        [
            {
                "type": "error",
                "code": "worker_load_error",
                "stderr_tail": "mlx.core: [Metal] failed to allocate model weights",
            }
        ],
    )
    import asyncio

    with pytest.raises(RuntimeError, match="worker_load_error") as exc_info:
        asyncio.run(worker.start())

    assert "failed to allocate" in str(exc_info.value)


def test_ready_identity_mismatch_aborts_the_worker(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [{"type": "ready", "model_loaded": True, "device": "cpu", "dtype": "float32"}],
    )
    import asyncio

    with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
        asyncio.run(worker.start())

    assert fake.aborted is True


def test_transcribe_request_is_single_pcm16_frame_with_stable_request_id(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [
            {"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"},
            {"type": "result", "request_id": "req_x", "text": "hello", "language": "Chinese"},
        ],
    )
    import asyncio

    result = asyncio.run(worker.transcribe(b"\x00\x00", "zh", "names", request_id="req_x"))

    request = fake.sends[1]
    assert request["type"] == "transcribe"
    assert request["request_id"] == "req_x"
    assert request["sample_rate"] == 16000
    assert request["channels"] == 1
    assert request["_binary"] == b"\x00\x00"
    assert result.request_id == "req_x"
    assert result.text == "hello"
    assert worker.last_active > 0


def test_transcribe_refreshes_last_active(tmp_path: Path) -> None:
    """Batch activity must keep the worker out of the idle evictor."""
    import asyncio
    import time

    worker, _ = _worker(
        tmp_path,
        [
            {"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"},
            {"type": "result", "request_id": "req_x", "text": "hi", "language": "zh"},
        ],
    )
    before = worker.last_active
    time.sleep(0.01)
    asyncio.run(worker.transcribe(b"\x00\x00", "zh", "names", request_id="req_x"))
    assert worker.last_active > before


def test_transcribe_rejects_non_result_or_mismatched_request_id(tmp_path: Path) -> None:
    for response in (
        {"type": "progress", "request_id": "req_x"},
        {"type": "result", "request_id": "req_other", "text": "hello", "language": "zh"},
    ):
        worker, _ = _worker(
            tmp_path,
            [
                {"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"},
                response,
            ],
        )
        import asyncio

        with pytest.raises(RuntimeError):
            asyncio.run(worker.transcribe(b"\x00\x00", None, ""))


def test_transcribe_rejects_invalid_text_or_language(tmp_path: Path) -> None:
    for response in (
        {"type": "result", "request_id": "req_x", "text": 123, "language": "zh"},
        {"type": "result", "request_id": "req_x", "text": "hello", "language": 456},
    ):
        worker, _ = _worker(
            tmp_path,
            [
                {"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"},
                response,
            ],
        )
        import asyncio

        with pytest.raises(RuntimeError, match="worker_result_invalid"):
            asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))


class _LossyTransport(_FakeTransport):
    """Transport that loses the pipe on a chosen exchange call, then recovers."""

    def __init__(self, responses: list[dict[str, Any]], lose_on: int) -> None:
        super().__init__(responses)
        self.starts = 0
        self.exchange_calls = 0
        self._lose_on = lose_on

    async def start(self) -> None:
        self.starts += 1

    async def exchange(
        self, payload: dict[str, Any], binary_payload: bytes | None = None
    ) -> dict[str, Any]:
        self.exchange_calls += 1
        if self._lose_on < 0 and payload.get("type") == "transcribe":
            raise BrokenPipeError("worker pipe closed")
        if self.exchange_calls == self._lose_on:
            raise BrokenPipeError("worker pipe closed")
        return await super().exchange(payload, binary_payload)


_READY = {"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"}


def _lossy_worker(tmp_path: Path, responses: list[dict[str, Any]], lose_on: int):
    worker, _ = _worker(tmp_path, responses)
    fake = _LossyTransport(responses, lose_on=lose_on)
    worker._transport = fake  # type: ignore[assignment]
    return worker, fake


def test_transcribe_rebuilds_worker_once_after_transport_loss(tmp_path: Path) -> None:
    """A dead worker pipe costs one in-request rebuild, not every later request."""
    import asyncio

    worker, fake = _lossy_worker(
        tmp_path,
        [_READY, _READY, {"type": "result", "request_id": "req_x", "text": "ok", "language": "zh"}],
        lose_on=2,
    )

    result = asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))

    assert result.text == "ok"
    assert fake.starts == 2
    assert fake.aborted is True
    assert worker._identity == ("mps", "float16")


def test_transcribe_rebuild_failure_propagates_without_infinite_retry(tmp_path: Path) -> None:
    import asyncio

    worker, fake = _lossy_worker(tmp_path, [_READY, _READY], lose_on=-1)

    with pytest.raises(OSError):
        asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))

    assert fake.starts == 2


def test_transcribe_semantic_error_does_not_rebuild_worker(tmp_path: Path) -> None:
    import asyncio

    worker, fake = _lossy_worker(
        tmp_path,
        [
            _READY,
            {"type": "error", "code": "backend_error"},
        ],
        lose_on=99,
    )

    with pytest.raises(RuntimeError, match="backend_error"):
        asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))

    assert fake.starts == 1
    assert fake.aborted is False


def test_transcribe_timeout_kills_worker_without_retry(tmp_path: Path) -> None:
    """A hung worker is killed (frame desync) but the timeout is not retried."""
    import asyncio

    class _HangingTransport(_FakeTransport):
        def __init__(self, responses: list[dict[str, Any]]) -> None:
            super().__init__(responses)
            self.starts = 0

        async def start(self) -> None:
            self.starts += 1

        async def exchange(
            self, payload: dict[str, Any], binary_payload: bytes | None = None
        ) -> dict[str, Any]:
            del payload, binary_payload
            if not self.responses:
                raise TimeoutError()
            return self.responses.pop(0)

    worker, _ = _worker(tmp_path, [])
    fake = _HangingTransport([_READY])
    worker._transport = fake  # type: ignore[assignment]

    with pytest.raises(TimeoutError):
        asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))

    assert fake.aborted is True
    assert worker._identity is None
    assert fake.starts == 1
