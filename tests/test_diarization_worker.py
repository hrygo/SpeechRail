from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import pytest

from speechrail.backends.diarization.coreml import (
    MODEL_BUNDLE_NAME,
    CoreMLActivitySession,
    CoreMLSortformerEngine,
)
from speechrail.config import Settings, bundled_diarization_worker_path
from speechrail.domain.diarization import DiarizationError
from speechrail.runtime import diarization_worker
from speechrail.runtime.diarization_worker import (
    _STDERR_TAIL_BYTES,
    MAX_IPC_PAYLOAD_BYTES,
    CoreMLWorkerProcess,
    decode_message,
    encode_message,
)

_SWIFT_WORKER = (
    Path(__file__).resolve().parents[1]
    / "native"
    / "diarization"
    / ".build"
    / "debug"
    / "SpeechRailDiarizationWorker"
)


def test_diarization_ipc_round_trips_binary_pcm_without_json_encoding_audio() -> None:
    packet = encode_message(
        {
            "protocol_version": 1,
            "request_id": "r1",
            "epoch": "e1",
            "operation": "append",
            "audio_start": 0,
            "audio_samples": 2,
        },
        b"\x01\x00\x02\x00",
    )

    header, audio = decode_message(packet)

    assert header["operation"] == "append"
    assert audio == b"\x01\x00\x02\x00"


def test_default_diarization_worker_path_targets_the_installed_native_binary() -> None:
    assert Settings().diarization_worker_path == bundled_diarization_worker_path()


def test_diarization_ipc_rejects_a_declared_payload_larger_than_the_cap() -> None:
    with pytest.raises(ValueError, match="payload"):
        encode_message({"operation": "append"}, b"x" * (MAX_IPC_PAYLOAD_BYTES + 1))


def test_coreml_activity_session_rejects_a_response_for_another_epoch_or_operation() -> None:
    async def scenario() -> None:
        session = CoreMLActivitySession(worker=object(), epoch="expected-epoch")  # type: ignore[arg-type]
        response: dict[str, object] = {
            "protocol_version": 1,
            "ok": True,
            "epoch": "stale-epoch",
            "operation": "append",
            "processed_through": 0,
            "stable_through": 0,
            "frames": [],
        }

        with pytest.raises(DiarizationError, match="does not match"):
            await session._publish(response, operation="append")

        response["epoch"] = "expected-epoch"
        response["operation"] = "finish"
        with pytest.raises(DiarizationError, match="does not match"):
            await session._publish(response, operation="append")

    asyncio.run(scenario())


def test_coreml_activity_session_closes_its_exact_worker_after_final_snapshot() -> None:
    class Worker:
        def __init__(self) -> None:
            self.operations: list[str] = []
            self.closed = False

        async def start(self) -> None:
            return None

        async def request(self, header: dict[str, object], audio: bytes = b""):
            self.operations.append(str(header["operation"]))
            operation = str(header["operation"])
            through = len(audio) // 2 if operation == "append" else int(header["through_sample"])
            return (
                {
                    "ok": True,
                    "epoch": "epoch",
                    "operation": operation,
                    "processed_through": through,
                    "stable_through": through,
                    "frames": [],
                },
                b"",
            )

        async def close(self) -> None:
            self.closed = True

    async def scenario() -> None:
        worker = Worker()
        session = CoreMLActivitySession(worker=worker, epoch="epoch")  # type: ignore[arg-type]
        await session.append(start_sample=0, pcm16=b"\x00\x00" * 160)
        await session.finish(through_sample=160)
        assert worker.operations == ["append", "finish"]
        assert worker.closed is True

    asyncio.run(scenario())


def test_worker_request_rejects_an_ipc_protocol_mismatch(monkeypatch) -> None:
    class Writer:
        def write(self, packet: bytes) -> None:
            del packet

        async def drain(self) -> None:
            return None

    async def mismatched_response(reader):
        del reader
        return {"protocol_version": 2, "ok": True}, b""

    worker = CoreMLWorkerProcess(executable=Path("worker"), model_path=Path("model"))
    worker._writer = Writer()  # type: ignore[assignment]
    worker._reader = object()  # type: ignore[assignment]
    worker._lock = asyncio.Lock()
    monkeypatch.setattr(diarization_worker, "_read_packet", mismatched_response)

    async def scenario() -> None:
        with pytest.raises(RuntimeError, match="protocol mismatch"):
            await worker.request({"operation": "preflight"})

    asyncio.run(scenario())


def test_coreml_worker_stderr_tail_is_bounded_and_never_exposed_verbatim() -> None:
    async def scenario() -> None:
        reader = asyncio.StreamReader()
        reader.feed_data(b"x" * (_STDERR_TAIL_BYTES + 1_024))
        reader.feed_eof()
        worker = CoreMLWorkerProcess(executable=Path("worker"), model_path=Path("model"))

        await worker._drain_stderr(reader)

        assert len(worker._stderr_tail) == _STDERR_TAIL_BYTES
        assert worker._failure_summary() == (
            "CoreML diarization worker transport failed (exit_code=unknown, stderr_bytes=8192)"
        )

    asyncio.run(scenario())


def test_coreml_activity_session_maps_worker_transport_failure_to_stable_error() -> None:
    class Worker:
        async def start(self) -> None:
            return None

        async def request(self, header: dict[str, object], audio: bytes = b""):
            del header, audio
            raise RuntimeError("private child diagnostics")

        async def close(self) -> None:
            return None

    async def scenario() -> None:
        session = CoreMLActivitySession(worker=Worker(), epoch="epoch")  # type: ignore[arg-type]
        with pytest.raises(DiarizationError) as error:
            await session.append(start_sample=0, pcm16=b"\x00\x00")
        assert error.value.code == "diarization_invalid_output"
        assert "private child diagnostics" not in str(error.value)

    asyncio.run(scenario())


@pytest.mark.skipif(
    sys.platform != "darwin" or not _SWIFT_WORKER.is_file(),
    reason="requires a locally built macOS Swift diarization worker",
)
def test_real_swift_worker_returns_a_private_error_packet_for_an_invalid_bundle(tmp_path) -> None:
    """The actual executable fails its preflight without leaving a child behind."""

    invalid_bundle = tmp_path / MODEL_BUNDLE_NAME
    invalid_bundle.mkdir()
    worker = CoreMLWorkerProcess(executable=_SWIFT_WORKER, model_path=invalid_bundle)

    with pytest.raises(RuntimeError, match="preflight failed"):
        asyncio.run(worker.start())

    assert worker.process is None


def test_worker_close_targets_one_pid_cancel_then_terminate_then_kill(monkeypatch) -> None:
    calls: list[str] = []

    class Writer:
        def write(self, packet: bytes) -> None:
            header, _ = decode_message(packet)
            calls.append(f"write:{header['operation']}")

        async def drain(self) -> None:
            calls.append("drain")

        def close(self) -> None:
            calls.append("writer.close")

        async def wait_closed(self) -> None:
            calls.append("writer.wait_closed")

    class Process:
        returncode: int | None = None

        async def wait(self) -> int:
            calls.append("wait")
            self.returncode = 0
            return 0

        def terminate(self) -> None:
            calls.append("terminate")

        def kill(self) -> None:
            calls.append("kill")

    async def timed_out(awaitable, *, timeout: float):  # noqa: ASYNC109
        assert timeout == 2
        calls.append("wait_for")
        awaitable.close()
        raise TimeoutError

    monkeypatch.setattr(diarization_worker.asyncio, "wait_for", timed_out)
    worker = CoreMLWorkerProcess(executable=Path("worker"), model_path=Path("model"))
    worker.process = Process()  # type: ignore[assignment]
    worker._writer = Writer()  # type: ignore[assignment]

    asyncio.run(worker.close())

    assert calls == [
        "write:cancel",
        "drain",
        "writer.close",
        "wait_for",
        "terminate",
        "wait_for",
        "kill",
        "wait",
        "writer.wait_closed",
    ]
    assert worker.process is None
    assert worker._writer is None


def test_only_the_pinned_compiled_coreml_bundle_can_be_ready(tmp_path) -> None:
    worker = tmp_path / "SpeechRailDiarizationWorker"
    worker.write_text("worker")
    model = tmp_path / MODEL_BUNDLE_NAME
    model.mkdir()

    engine = CoreMLSortformerEngine(
        model_path=model,
        executable=worker,
        required_hashes={},
        required_signatures={},
    )

    assert engine.readiness.ready is True
    assert engine.supports_stream is True

    wrong = CoreMLSortformerEngine(
        model_path=tmp_path / "other.mlmodelc", executable=worker
    )
    assert wrong.readiness.ready is False


def test_coreml_bundle_with_a_missing_or_changed_pinned_file_is_not_ready(tmp_path) -> None:
    worker = tmp_path / "SpeechRailDiarizationWorker"
    worker.write_text("worker")
    model = tmp_path / MODEL_BUNDLE_NAME
    model.mkdir()
    artifact = model / "model0" / "model.mil"
    artifact.parent.mkdir()
    artifact.write_bytes(b"not-the-pinned-artifact")

    engine = CoreMLSortformerEngine(
        model_path=model,
        executable=worker,
        required_hashes={"model0/model.mil": "0" * 64},
        required_signatures={},
    )

    assert engine.readiness.ready is False
    assert engine.readiness.code == "diarization_not_available"


def test_coreml_bundle_with_an_unexpected_model_signature_is_not_ready(tmp_path) -> None:
    worker = tmp_path / "SpeechRailDiarizationWorker"
    worker.write_text("worker")
    model = tmp_path / MODEL_BUNDLE_NAME
    model.mkdir()
    artifact = model / "model0" / "model.mil"
    artifact.parent.mkdir()
    artifact.write_text("different static shape")

    engine = CoreMLSortformerEngine(
        model_path=model,
        executable=worker,
        required_hashes={},
        required_signatures={"model0/model.mil": ("[1, 112, 128]",)},
    )

    assert engine.readiness.ready is False
