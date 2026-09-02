from pathlib import Path
from sys import executable
from typing import Any

import pytest

from speechrail.backends.qwen3_native import (
    MODEL_FILES,
    Qwen3BackendConfig,
    Qwen3Worker,
    validate_snapshot,
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
    for filename in MODEL_FILES:
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
