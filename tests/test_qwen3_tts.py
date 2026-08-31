from __future__ import annotations

import asyncio
import base64
from pathlib import Path
from sys import executable

import pytest

import speechrail.backends.qwen3_tts as tts_module
from speechrail.backends.qwen3_tts import Qwen3TtsBackendConfig, Qwen3TtsWorker
from speechrail.domain.ports import SpeechRequest


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
        "--sample-rate",
        "24000",
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

    written: list[dict[str, object]] = []
    frame_index = 0

    async def start() -> None:
        return None

    async def write(frame: dict[str, object]) -> None:
        written.append(frame)

    async def read() -> dict[str, object]:
        nonlocal frame_index
        request_id = written[0]["request_id"]
        frame_index += 1
        if frame_index == 1:
            return {
                "type": "audio",
                "request_id": request_id,
                "chunk_index": 0,
                "pcm_b64": base64.b64encode(b"\x00\x00").decode(),
            }
        return {"type": "completed", "request_id": request_id}

    worker.start = start  # type: ignore[method-assign]
    worker._write = write  # type: ignore[method-assign]
    worker._read = read  # type: ignore[method-assign]

    async def collect() -> list[object]:
        return [
            chunk
            async for chunk in worker.synthesize(
                SpeechRequest(text="你好", voice="default")
            )
        ]

    chunks = asyncio.run(collect())

    assert written[0] == {
        "version": 1,
        "type": "synthesize",
        "request_id": written[0]["request_id"],
        "text": "你好",
        "voice": "default",
        "speed": 1.0,
    }
    assert chunks[0].response_id == written[0]["request_id"]
    assert chunks[0].chunk_index == 0
    assert chunks[0].audio == b"\x00\x00"


def test_tts_worker_starts_offline_process_and_checks_ready_identity(
    monkeypatch, tmp_path: Path
) -> None:
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

    class FakeProcess:
        stdin = None
        stdout = None
        returncode: int | None = None

        def __init__(self) -> None:
            self.terminated = False

        def terminate(self) -> None:
            self.terminated = True
            self.returncode = 0

        async def wait(self) -> int:
            return 0

    process = FakeProcess()
    written: list[dict[str, object]] = []

    async def create_process(*args: object, **kwargs: object) -> FakeProcess:
        assert args == tuple(worker.config.command())
        environment = kwargs["env"]
        assert isinstance(environment, dict)
        assert environment["HF_HUB_OFFLINE"] == "1"
        assert environment["PYTORCH_ENABLE_MPS_FALLBACK"] == "0"
        return process

    async def write(frame: dict[str, object]) -> None:
        written.append(frame)

    async def read() -> dict[str, object]:
        return {
            "type": "ready",
            "model_loaded": True,
            "device": "mps",
            "dtype": "float16",
            "sample_rate": 24_000,
        }

    monkeypatch.setattr(tts_module.asyncio, "create_subprocess_exec", create_process)
    worker._write = write  # type: ignore[method-assign]
    worker._read = read  # type: ignore[method-assign]

    async def start_and_close() -> None:
        await worker.start()
        await worker.close()

    asyncio.run(start_and_close())

    assert written == [
        {
            "version": 1,
            "type": "start",
            "model_dir": str(snapshot.resolve()),
            "device": "mps",
            "sample_rate": 24_000,
        }
    ]
    assert process.terminated is True
