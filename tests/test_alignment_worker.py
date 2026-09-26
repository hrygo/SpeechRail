from __future__ import annotations

import asyncio
import io
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

import speechrail.backends.qwen3_alignment_worker as alignment_worker_module
from speechrail.backends.model_identity import SnapshotIdentity
from speechrail.backends.qwen3_alignment import (
    AlignmentQueueFullError,
    Qwen3AlignmentConfig,
    Qwen3AlignmentWorker,
)
from speechrail.backends.qwen3_alignment_worker import (
    AlignmentIdentity,
    Qwen3AlignerEngine,
    serve,
)
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, encode_frame, read_frame


class _FakeEngine:
    def __init__(self, identity: AlignmentIdentity | None = None) -> None:
        self.identity = identity or AlignmentIdentity(
            device="cpu", dtype="float32", quantization_format="none"
        )
        self.seen: list[tuple[bytes, str, str]] = []

    def align_text(self, audio: bytes, *, text: str, language: str) -> list[dict[str, object]]:
        self.seen.append((audio, text, language))
        return [
            {"text": "你好", "start": 0.0, "end": 0.5},
            {"text": "世界", "start": 0.5, "end": 1.0},
        ]


def _start_frame(model_dir: Path, *, device: str = "cpu", dtype: str = "float32") -> bytes:
    return encode_frame(
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": device,
            "dtype": dtype,
        }
    )


def _align_frame(request_id: str = "r1") -> bytes:
    return encode_frame(
        {
            "version": PROTOCOL_VERSION,
            "type": "align_text",
            "request_id": request_id,
            "sample_rate": 16_000,
            "channels": 1,
            "sample_width_bytes": 2,
            "language": "zh",
            "text": "你好世界",
        },
        binary_payload=b"\x00\x00" * 1_600,
    )


def _run_serve(frames: bytes, engine: _FakeEngine, model_dir: Path) -> io.BytesIO:
    output = io.BytesIO()
    serve(
        io.BytesIO(frames),
        output,
        model_dir=model_dir,
        device="cpu",
        dtype="float32",
        engine_factory=lambda *_: engine,
    )
    output.seek(0)
    return output


def test_alignment_worker_serves_fixed_text_and_rejects_asr_frames(tmp_path: Path) -> None:
    model_dir = tmp_path / "aligner"
    engine = _FakeEngine()
    frames = (
        _start_frame(model_dir)
        + _align_frame()
        + encode_frame(
            {
                "version": PROTOCOL_VERSION,
                "type": "session.open",
                "session_id": "s1",
                "language": "zh",
            }
        )
        + encode_frame({"version": PROTOCOL_VERSION, "type": "shutdown"})
    )

    output = _run_serve(frames, engine, model_dir)

    ready = read_frame(output)
    result = read_frame(output)
    rejected = read_frame(output)
    assert ready is not None and ready["type"] == "ready"
    assert ready["backend"] == "mlx-qwen3-forced-aligner"
    assert result is not None and result["type"] == "align_result"
    assert result["request_id"] == "r1"
    assert [token["text"] for token in result["tokens"]] == ["你好", "世界"]
    assert rejected is not None and rejected["code"] == "worker_invalid_frame_type"
    assert engine.seen == [(b"\x00\x00" * 1_600, "你好世界", "zh")]
    assert read_frame(output) is None


def test_alignment_worker_rejects_a_mismatched_start(tmp_path: Path) -> None:
    output = _run_serve(_start_frame(tmp_path / "other"), _FakeEngine(), tmp_path / "aligner")

    frame = read_frame(output)
    assert frame is not None and frame["code"] == "worker_invalid_start"


def test_alignment_worker_rejects_a_malformed_request(tmp_path: Path) -> None:
    model_dir = tmp_path / "aligner"
    frames = (
        _start_frame(model_dir)
        + encode_frame(
            {
                "version": PROTOCOL_VERSION,
                "type": "align_text",
                "request_id": "r1",
                "sample_rate": 16_000,
                "channels": 1,
                "sample_width_bytes": 2,
                "language": "zh",
                "text": "",
            },
            binary_payload=b"\x00\x00" * 16,
        )
        + encode_frame({"version": PROTOCOL_VERSION, "type": "shutdown"})
    )

    output = _run_serve(frames, _FakeEngine(), model_dir)
    read_frame(output)

    frame = read_frame(output)
    assert frame is not None and frame["code"] == "worker_invalid_request"


def test_alignment_worker_refuses_to_report_a_different_identity(tmp_path: Path) -> None:
    engine = _FakeEngine(
        AlignmentIdentity(device="cpu", dtype="float16", quantization_format="none")
    )
    output = _run_serve(
        _start_frame(tmp_path / "aligner") + encode_frame({"version": PROTOCOL_VERSION}),
        engine,
        tmp_path / "aligner",
    )

    frame = read_frame(output)
    assert frame is not None and frame["code"] == "backend_identity_mismatch"


def _aligner_snapshot(
    *, bits: int | None = None, group_size: int | None = None
) -> SnapshotIdentity:
    return SnapshotIdentity(
        family="qwen3_aligner",
        variant="aligner",
        quantization=QuantizationSpec(
            bits=bits,
            group_size=group_size,
            format="mlx" if bits is not None else "none",
        ),
        weight_fingerprint="shape:" + ("b" * 64),
    )


def _install_fake_aligner_runtime(
    monkeypatch: pytest.MonkeyPatch,
    *,
    reported_dtype: object = None,
) -> list[dict[str, object]]:
    """Register fake ``mlx``/``mlx_qwen3_asr`` modules and record load calls."""

    calls: list[dict[str, object]] = []
    core = ModuleType("mlx.core")
    for name in ("float16", "float32", "bfloat16", "int8"):
        setattr(core, name, SimpleNamespace(name=name))
    package = ModuleType("mlx")
    package.core = core  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx", package)
    monkeypatch.setitem(sys.modules, "mlx.core", core)

    class FakeAligner:
        def __init__(self, *, model_path: str, dtype: object = None) -> None:
            calls.append({"model_path": model_path, "dtype": dtype})
            self.dtype = dtype if reported_dtype is None else reported_dtype

    runtime = ModuleType("mlx_qwen3_asr")
    runtime.ForcedAligner = FakeAligner  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx_qwen3_asr", runtime)
    return calls


def test_aligner_engine_loads_the_bfloat16_snapshot_at_its_own_precision(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The aligner must not silently fall back to the vendor float16 default."""

    calls = _install_fake_aligner_runtime(monkeypatch, reported_dtype="mlx.core.bfloat16")
    monkeypatch.setattr(alignment_worker_module, "inspect_model", lambda _: _aligner_snapshot())
    fake_mlx = sys.modules["mlx.core"]

    engine = Qwen3AlignerEngine(tmp_path, "mps", "bfloat16")

    assert [call["model_path"] for call in calls] == [str(tmp_path)]
    assert [call["dtype"] for call in calls] == [fake_mlx.bfloat16]
    assert engine.identity.dtype == "bfloat16"
    assert engine.identity.quantization_format == "none"


def test_aligner_engine_keeps_float16_compute_for_a_quantized_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A pre-quantized aligner keeps its int8 identity without int8 activations."""

    calls = _install_fake_aligner_runtime(monkeypatch)
    monkeypatch.setattr(
        alignment_worker_module,
        "inspect_model",
        lambda _: _aligner_snapshot(bits=8, group_size=64),
    )
    fake_mlx = sys.modules["mlx.core"]

    engine = Qwen3AlignerEngine(tmp_path, "mps", "int8")

    assert [call["dtype"] for call in calls] == [fake_mlx.float16]
    assert engine.identity.dtype == "int8"
    assert engine.identity.quantization_format == "mlx"


def test_aligner_engine_refuses_a_loader_dtype_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _install_fake_aligner_runtime(monkeypatch, reported_dtype="mlx.core.float16")
    monkeypatch.setattr(alignment_worker_module, "inspect_model", lambda _: _aligner_snapshot())

    with pytest.raises(RuntimeError, match="aligner reported"):
        Qwen3AlignerEngine(tmp_path, "mps", "bfloat16")


def test_aligner_engine_refuses_int8_on_a_non_quantized_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls = _install_fake_aligner_runtime(monkeypatch)
    monkeypatch.setattr(alignment_worker_module, "inspect_model", lambda _: _aligner_snapshot())

    with pytest.raises(RuntimeError, match="backend_quantization_unavailable"):
        Qwen3AlignerEngine(tmp_path, "mps", "int8")

    assert calls == []


def _config(tmp_path: Path) -> Qwen3AlignmentConfig:
    repository = tmp_path / "repo"
    repository.mkdir()
    model = tmp_path / "aligner-snapshot"
    model.mkdir()
    (model / "config.json").write_text("{}", encoding="utf-8")
    (model / "model.safetensors").touch()
    return Qwen3AlignmentConfig(
        repository_root=repository,
        python_executable=Path("/usr/bin/python3"),
        model_dir=model,
        device="cpu",
        dtype="float32",
    )


class _FakeProcess:
    def __init__(self, *, gate: asyncio.Event | None = None, crash: bool = False) -> None:
        self._gate = gate
        self._crash = crash
        self._alive = False
        self.aborted = 0
        self.closed = 0
        self.requests: list[str] = []

    @property
    def alive(self) -> bool:
        return self._alive

    async def start(self) -> None:
        self._alive = True

    async def exchange(
        self, payload, binary_payload=None, *, handshake: bool = False
    ) -> dict[str, object]:
        if payload.get("type") == "start":
            return {
                "type": "ready",
                "model_loaded": True,
                "device": "cpu",
                "dtype": "float32",
            }
        self.requests.append(str(payload.get("request_id")))
        if self._gate is not None:
            await self._gate.wait()
        if self._crash:
            raise RuntimeError("worker_transport_invalid")
        return {
            "type": "align_result",
            "request_id": payload.get("request_id"),
            "tokens": [{"text": "你", "start": 0.0, "end": 0.5}],
        }

    async def abort(self) -> None:
        self.aborted += 1
        self._alive = False

    async def close(self) -> None:
        self.closed += 1
        self._alive = False


def test_alignment_client_returns_validated_raw_tokens(tmp_path: Path) -> None:
    process = _FakeProcess()
    worker = Qwen3AlignmentWorker(_config(tmp_path), process=process)  # type: ignore[arg-type]

    tokens = asyncio.run(worker.align_text(b"\x00\x00" * 16, text="你好", language="zh"))

    assert tokens == (("你", 0.0, 0.5),)
    assert worker.ready is True
    assert len(process.requests) == 1


def test_alignment_client_fails_fast_when_the_queue_is_full(tmp_path: Path) -> None:
    gate = asyncio.Event()
    process = _FakeProcess(gate=gate)
    worker = Qwen3AlignmentWorker(  # type: ignore[arg-type]
        _config(tmp_path), max_pending_requests=1, process=process
    )

    async def scenario() -> None:
        first = asyncio.create_task(
            worker.align_text(b"\x00\x00" * 16, text="你好", language="zh")
        )
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        with pytest.raises(AlignmentQueueFullError):
            await worker.align_text(b"\x00\x00" * 16, text="你好", language="zh")
        gate.set()
        await first

    asyncio.run(scenario())
    assert worker.pending_requests == 0


def test_alignment_client_resets_a_crashed_transport(tmp_path: Path) -> None:
    process = _FakeProcess(crash=True)
    worker = Qwen3AlignmentWorker(_config(tmp_path), process=process)  # type: ignore[arg-type]

    with pytest.raises(RuntimeError):
        asyncio.run(worker.align_text(b"\x00\x00" * 16, text="你好", language="zh"))

    assert process.aborted == 1
    assert worker.ready is False
