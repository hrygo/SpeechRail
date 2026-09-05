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
from speechrail.backends.qwen3_shared import Qwen3SharedWorker
from speechrail.runtime.asr_mode import AsrModeBusy, AsrModeGate


class _FakeSharedOwner:
    def __init__(
        self,
        responses: list[dict[str, Any] | BaseException],
        *,
        timeout_seconds: float = 120.0,
        expected_identity: tuple[str, str] = ("mps", "float16"),
    ) -> None:
        self.responses = list(responses)
        self.requests: list[tuple[dict[str, Any], bytes | None]] = []
        self.sends: list[dict[str, Any]] = []
        self.starts = 0
        self.close_calls = 0
        self.aborted = False
        self.alive = False
        self.ready = False
        self.identity: tuple[str, str] | None = None
        self.timeout_seconds = timeout_seconds
        self.mode_gate = AsrModeGate()
        self.last_active = 0.0
        self.expected_identity = expected_identity

    async def start(self) -> None:
        if self.ready and self.alive:
            return
        self.starts += 1
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            self._mark_dead()
            raise response
        self.sends.append({"type": "start"})
        if response.get("type") != "ready" or response.get("model_loaded") is not True:
            self._mark_dead()
            code = str(response.get("code") or "worker_start_failed")
            tail = response.get("stderr_tail")
            if isinstance(tail, str) and tail:
                code = f"{code}; worker stderr tail:\n{tail}"
            raise RuntimeError(code)
        device, dtype = response.get("device"), response.get("dtype")
        if (device, dtype) != self.expected_identity:
            self._mark_dead()
            raise RuntimeError("backend_identity_mismatch")
        self.alive = True
        self.ready = True
        self.identity = (device, dtype)
        self.last_active += 1

    async def request(
        self,
        payload: dict[str, Any],
        binary: bytes | None = None,
    ) -> dict[str, Any]:
        self.requests.append((dict(payload), binary))
        self.last_active += 1
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            if isinstance(response, (OSError, TimeoutError)):
                self._mark_dead()
            raise response
        return response

    async def send(
        self, payload: dict[str, Any], binary_payload: bytes | None = None
    ) -> None:
        if binary_payload is not None:
            payload["_binary"] = binary_payload
        self.sends.append(payload)
        self.last_active += 1

    async def trim_memory(self) -> None:
        self.last_active += 1

    async def close(self) -> None:
        self.close_calls += 1
        self._mark_dead()

    def _mark_dead(self) -> None:
        self.alive = False
        self.ready = False
        self.identity = None
        self.aborted = True


def _worker(
    tmp_path: Path,
    responses: list[dict[str, Any] | BaseException],
    *,
    timeout_seconds: float = 120.0,
) -> tuple[Qwen3Worker, _FakeSharedOwner]:
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
    fake = _FakeSharedOwner(
        responses,
        timeout_seconds=timeout_seconds,
        expected_identity=(config.device, config.dtype),
    )
    worker = Qwen3Worker(config, shared_owner=fake)  # type: ignore[arg-type]
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


def test_batch_facade_delegates_start_and_identity_to_shared_owner(tmp_path: Path) -> None:
    worker, fake = _worker(
        tmp_path,
        [{"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"}],
    )

    import asyncio

    asyncio.run(worker.start())

    assert worker.shared_owner is fake
    assert fake.starts == 1
    assert worker.ready is True
    assert worker.identity == ("mps", "float16")


def test_batch_facade_accepts_an_injected_shared_owner(tmp_path: Path) -> None:
    worker, _ = _worker(tmp_path, [])
    owner = object()

    facade = Qwen3Worker(worker.config, shared_owner=owner)  # type: ignore[arg-type]

    assert facade.shared_owner is owner


def test_batch_facade_default_owner_is_shared_worker(tmp_path: Path) -> None:
    worker, _ = _worker(tmp_path, [])

    facade = Qwen3Worker(worker.config)

    assert isinstance(facade.shared_owner, Qwen3SharedWorker)


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

    request, binary = fake.requests[0]
    assert request["type"] == "transcribe"
    assert request["request_id"] == "req_x"
    assert request["sample_rate"] == 16000
    assert request["channels"] == 1
    assert binary == b"\x00\x00"
    assert result.request_id == "req_x"
    assert result.text == "hello"
    assert worker.last_active > 0
    assert fake.mode_gate.active_count == 0


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


_READY = {"type": "ready", "model_loaded": True, "device": "mps", "dtype": "float16"}


def test_transcribe_rebuilds_worker_once_after_transport_loss(tmp_path: Path) -> None:
    """A dead worker pipe costs one in-request rebuild, not every later request."""
    import asyncio

    worker, fake = _worker(
        tmp_path,
        [
            _READY,
            BrokenPipeError("worker pipe closed"),
            _READY,
            {"type": "result", "request_id": "req_x", "text": "ok", "language": "zh"},
        ],
    )

    result = asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))

    assert result.text == "ok"
    assert fake.starts == 2
    assert fake.aborted is True
    assert fake.close_calls == 0
    assert worker.identity == ("mps", "float16")
    assert fake.mode_gate.active_count == 0


def test_transcribe_rebuild_failure_propagates_without_infinite_retry(tmp_path: Path) -> None:
    import asyncio

    worker, fake = _worker(
        tmp_path,
        [
            _READY,
            BrokenPipeError("worker pipe closed"),
            _READY,
            BrokenPipeError("worker pipe closed"),
        ],
    )

    with pytest.raises(OSError):
        asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))

    assert fake.starts == 2


def test_transcribe_semantic_error_does_not_rebuild_worker(tmp_path: Path) -> None:
    import asyncio

    worker, fake = _worker(
        tmp_path,
        [
            _READY,
            {"type": "error", "code": "backend_error"},
        ],
    )

    with pytest.raises(RuntimeError, match="backend_error"):
        asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))

    assert fake.starts == 1
    assert fake.aborted is False


def test_transcribe_timeout_kills_worker_without_retry(tmp_path: Path) -> None:
    """A hung worker is killed (frame desync) but the timeout is not retried."""
    import asyncio

    worker, fake = _worker(tmp_path, [_READY, TimeoutError()])

    with pytest.raises(TimeoutError):
        asyncio.run(worker.transcribe(b"\x00\x00", None, "", request_id="req_x"))

    assert fake.aborted is True
    assert worker.identity is None
    assert fake.starts == 1
    assert fake.mode_gate.active_count == 0


def test_batch_lease_rejects_streaming_mode_and_releases_on_error(tmp_path: Path) -> None:
    worker, fake = _worker(tmp_path, [_READY, {"type": "error", "code": "backend_error"}])
    streaming_lease = fake.mode_gate.acquire("streaming")

    import asyncio

    with pytest.raises(AsrModeBusy):
        asyncio.run(worker.transcribe(b"\x00\x00", None, ""))
    assert fake.mode_gate.active_count == 1
    fake.mode_gate.release(streaming_lease)

    with pytest.raises(RuntimeError, match="backend_error"):
        asyncio.run(worker.transcribe(b"\x00\x00", None, ""))
    assert fake.mode_gate.active_count == 0


def test_batch_config_command_self_describes_worker_role(tmp_path: Path) -> None:
    """batch worker must carry --worker-role batch so tooling can attribute it."""
    snapshot = tmp_path / "external-qwen3-asr-snapshot"
    snapshot.mkdir()
    for filename in (*MODEL_FILES, "model.safetensors"):
        (snapshot / filename).touch()
    config = Qwen3BackendConfig(
        repository_root=Path(__file__).resolve().parents[1],
        python_executable=Path(executable),
        model_dir=snapshot,
        device="mps",
        dtype="int8",
    )
    cmd = config.command()
    assert "--worker-role" in cmd and cmd[cmd.index("--worker-role") + 1] == "batch"
