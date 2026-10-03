from __future__ import annotations

import json
import sys
from collections import Counter
from io import BytesIO
from pathlib import Path
from types import ModuleType, SimpleNamespace

import numpy as np
import pytest

import speechrail.backends.qwen3_tts_worker as worker_module
from speechrail.backends.model_identity import SnapshotIdentity
from speechrail.backends.qwen3_native import snapshot_is_quantized
from speechrail.backends.qwen3_tts_stream_host import ModelStepEvent
from speechrail.backends.qwen3_tts_worker import TtsWorkerIdentity, serve
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.domain.tts_stream import DEFAULT_TTS_STREAM_LIMITS
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, read_frame, write_frame


def test_float_overrange_is_observed_before_pcm16_clipping() -> None:
    engine = worker_module.MlxQwenTtsEngine.__new__(worker_module.MlxQwenTtsEngine)
    engine._sample_rate = 24_000
    engine._numpy = np
    engine._delivery_stats = Counter()

    result = SimpleNamespace(
        sample_rate=24_000,
        audio=np.array([0.25, 1.20, -1.40], dtype=np.float32),
        is_final_chunk=False,
    )

    pcm = engine._to_pcm(result)
    decoded = np.frombuffer(pcm, dtype="<i2")

    assert decoded.tolist() == [8191, 32767, -32768]
    assert engine.consume_delivery_stats() == {"float_overrange_chunks": 1}
    assert engine.consume_delivery_stats() == {}


def _snapshot_identity(
    *,
    bits: int | None = None,
    group_size: int | None = None,
    dtype: str | None = None,
) -> SnapshotIdentity:
    return SnapshotIdentity(
        family="qwen3_tts",
        variant="voice_design",
        quantization=QuantizationSpec(
            bits=bits,
            dtype=dtype,
            group_size=group_size,
            format="mlx" if bits is not None else "none",
        ),
        weight_fingerprint="shape:" + ("c" * 64),
    )


def test_expected_tts_dtype_uses_the_declared_bfloat16_snapshot(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    expected = _snapshot_identity(dtype="bf16")
    monkeypatch.setattr(worker_module, "inspect_model", lambda _: expected)

    assert worker_module._expected_tts_dtype(tmp_path, "mps") == "bfloat16"


class FakeEngine:
    identity = TtsWorkerIdentity(device="mps", dtype="float16", sample_rate=24_000)

    def synthesize(self, text: str, *, voice: str, speed: float, language: str):
        assert (text, voice, speed, language) == ("你好。", "default", 1.0, "auto")
        yield b"\x00\x00"
        yield b"\x01\x00"


def test_tts_snapshot_is_quantized_detects_config_quantization(tmp_path: Path) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    assert snapshot_is_quantized(model_dir) is False
    quantized = {"tts_model_type": "voice_design", "quantization": {"bits": 8, "group_size": 64}}
    (model_dir / "config.json").write_text(json.dumps(quantized), encoding="utf-8")
    assert snapshot_is_quantized(model_dir) is True
    (model_dir / "config.json").write_text(
        json.dumps({"quantization_config": {"bits": 8}}), encoding="utf-8"
    )
    assert snapshot_is_quantized(model_dir) is True


def test_serve_accepts_int8_identity_for_quantized_snapshot(tmp_path: Path) -> None:
    """A pre-quantized TTS snapshot reports int8 identity and must pass the gate."""
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    quantized = {"tts_model_type": "voice_design", "quantization": {"bits": 8, "group_size": 64}}
    (model_dir / "config.json").write_text(json.dumps(quantized), encoding="utf-8")
    source = BytesIO()
    target = BytesIO()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    source.seek(0)

    class Int8Engine(FakeEngine):
        identity = TtsWorkerIdentity(device="mps", dtype="int8", sample_rate=24_000)

    serve(source, target, model_dir=model_dir, device="mps", sample_rate=24_000,
          engine_factory=lambda _: Int8Engine())

    target.seek(0)
    ready = read_frame(target)
    assert ready["type"] == "ready"
    assert ready["dtype"] == "int8"
    assert ready["model_loaded"] is True


def test_serve_reports_tts_model_identity_and_preserves_four_bit_value(
    tmp_path: Path,
) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    source = BytesIO()
    target = BytesIO()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    source.seek(0)
    identity = TtsWorkerIdentity(
        device="mps",
        dtype="int8",
        sample_rate=24_000,
        family="qwen3_tts",
        model_variant="voice_design",
        quantization_bits=4,
        quantization_group_size=64,
        weight_fingerprint="shape:" + ("d" * 64),
    )

    class FourBitEngine(FakeEngine):
        pass

    FourBitEngine.identity = identity
    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: FourBitEngine(),
    )

    target.seek(0)
    ready = read_frame(target)
    assert ready == {
        "version": PROTOCOL_VERSION,
        "type": "ready",
        "backend": "mlx-qwen3-tts",
        "device": "mps",
        "dtype": "int8",
        "sample_rate": 24_000,
        "model_loaded": True,
        "profile_snapshot_version": 1,
        "family": "qwen3_tts",
        "model_variant": "voice_design",
        "quantization_bits": 4,
        "quantization_group_size": 64,
        "weight_fingerprint": "shape:" + ("d" * 64),
    }


def test_serve_rejects_tts_identity_metadata_mismatch(tmp_path: Path) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    source = BytesIO()
    target = BytesIO()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    source.seek(0)

    class WrongIdentityEngine(FakeEngine):
        identity = TtsWorkerIdentity(
            device="mps",
            dtype="float16",
            sample_rate=24_000,
            family="qwen3_asr",
            model_variant="asr",
        )

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: WrongIdentityEngine(),
    )

    target.seek(0)
    assert read_frame(target) == {
        "version": PROTOCOL_VERSION,
        "type": "error",
        "code": "backend_identity_mismatch",
    }


def test_tts_worker_emits_ordered_pcm_frames_without_vendor_runtime(tmp_path: Path) -> None:
    source = BytesIO()
    target = BytesIO()
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "synthesize",
            "request_id": "req-1",
            "text": "你好。",
            "voice": "default",
            "speed": 1.0,
        },
    )
    source.seek(0)

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: FakeEngine(),
    )

    target.seek(0)
    ready = read_frame(target)
    first = read_frame(target)
    second = read_frame(target)
    completed = read_frame(target)

    assert ready == {
        "version": PROTOCOL_VERSION,
        "type": "ready",
        "backend": "mlx-qwen3-tts",
        "device": "mps",
        "dtype": "float16",
        "sample_rate": 24_000,
        "model_loaded": True,
        "profile_snapshot_version": 1,
    }
    assert first.get("_binary") == b"\x00\x00"
    assert first["chunk_index"] == 0
    assert second["chunk_index"] == 1
    assert completed == {"version": PROTOCOL_VERSION, "type": "completed", "request_id": "req-1"}


def test_worker_completed_frame_carries_requested_chunk_timing(tmp_path: Path) -> None:
    class TimedEngine(FakeEngine):
        def consume_timing_sidecar(self) -> dict[str, object]:
            return {
                "schema_version": "tts_timing_v1",
                "timing_quality": "chunk",
                "coordinate_space": "normalized_spoken_unicode_codepoints",
                "planner_version": "tts_bounded_v1",
                "sample_rate": 24_000,
                "text_length": 3,
                "total_samples": 2,
                "chunks": [
                    {
                        "planner_chunk": 0,
                        "text_start": 0,
                        "text_end": 3,
                        "audio_start_sample": 0,
                        "audio_end_sample": 2,
                        "timing_quality": "chunk",
                    }
                ],
            }

    source = BytesIO()
    target = BytesIO()
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "synthesize",
            "request_id": "req-timed",
            "text": "你好。",
            "voice": "default",
            "speed": 1.0,
            "timing_mode": "chunk",
        },
    )
    source.seek(0)

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: TimedEngine(),
    )

    target.seek(0)
    read_frame(target)  # ready
    read_frame(target)  # first audio
    read_frame(target)  # second audio
    completed = read_frame(target)
    assert completed["type"] == "completed"
    timing = completed["timing_sidecar"]
    assert timing["timing_quality"] == "chunk"
    assert timing["total_samples"] == 2
    assert timing["chunks"][0]["audio_end_sample"] == 2


class SamplingEngine(FakeEngine):
    def synthesize(
        self,
        text: str,
        *,
        voice: str,
        speed: float,
        language: str,
        seed: int | None = None,
        **_: object,
    ):
        assert seed == 101
        yield b"\x00\x00"
        yield b"\x01\x00"

    def consume_sampling_observation(self) -> dict[str, object]:
        return {
            "seed_policy": "caller_fixed",
            "seed": 101,
            "temperature": 0.7,
            "top_p": 0.95,
            "repetition_penalty": 1.1,
        }


def test_worker_completed_frame_reports_the_sampler_it_used(tmp_path: Path) -> None:
    """The completed frame carries sampling facts, so the parent never guesses."""
    source = BytesIO()
    target = BytesIO()
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "synthesize",
            "request_id": "req-sampling",
            "text": "你好。",
            "voice": "default",
            "speed": 1.0,
            "seed": 101,
        },
    )
    source.seek(0)

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: SamplingEngine(),
    )

    target.seek(0)
    read_frame(target)  # ready
    read_frame(target)  # first audio
    read_frame(target)  # second audio
    completed = read_frame(target)

    assert completed["type"] == "completed"
    assert completed["sampling_observation"] == {
        "seed_policy": "caller_fixed",
        "seed": 101,
        "temperature": 0.7,
        "top_p": 0.95,
        "repetition_penalty": 1.1,
    }


def _sampling_engine(variant: str) -> worker_module.MlxQwenTtsEngine:
    engine = worker_module.MlxQwenTtsEngine.__new__(worker_module.MlxQwenTtsEngine)
    engine.identity = TtsWorkerIdentity(
        device="mps",
        dtype="float16",
        sample_rate=24_000,
        model_variant=variant,
    )
    engine._numpy = np
    engine._sample_rate = 24_000
    engine._delivery_stats = Counter()
    engine._last_sampling_observation = None
    engine._repetition_penalty = 1.05
    engine._temperature = 0.7
    engine._top_p = 0.95
    engine._chunk_ms = 200
    engine._audio_loader_fn = None
    engine._load_reference_audio = lambda _: "reference-array"
    engine._model = SimpleNamespace(
        generate=lambda **_: [
            SimpleNamespace(
                sample_rate=24_000,
                audio=np.zeros(2, dtype=np.float32),
            )
        ]
    )
    return engine


def _fake_mlx_runtime(monkeypatch: pytest.MonkeyPatch, seeded: list[int]) -> None:
    """Install a minimal importable `mlx.core` that only records seeding."""
    core = ModuleType("mlx.core")
    core.random = SimpleNamespace(seed=seeded.append)  # type: ignore[attr-defined]
    package = ModuleType("mlx")
    package.__path__ = []  # type: ignore[attr-defined]
    package.core = core  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx", package)
    monkeypatch.setitem(sys.modules, "mlx.core", core)


def _no_mlx_runtime(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make `import mlx.core` fail even where the real runtime is installed."""
    for name in ("mlx.core", "mlx"):
        monkeypatch.delitem(sys.modules, name, raising=False)
    # A None entry makes `import mlx.core` raise ImportError without touching
    # the real runtime on disk.
    monkeypatch.setitem(sys.modules, "mlx.core", None)


def test_caller_seed_is_reported_as_applied_only_when_the_runtime_took_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No vendor runtime means no fixed stream: the policy must say so."""
    _no_mlx_runtime(monkeypatch)
    engine = _sampling_engine("custom_voice")

    list(engine._generate("你好。", voice="default", speed=1.0, language="auto", seed=101))
    observation = engine.consume_sampling_observation()

    assert observation is not None
    assert observation["seed_policy"] == "unseeded_sampler"
    assert observation["seed"] is None
    assert engine.consume_sampling_observation() is None


def test_caller_seed_is_reported_as_fixed_when_the_runtime_seeds(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seeded: list[int] = []
    _fake_mlx_runtime(monkeypatch, seeded)
    engine = _sampling_engine("custom_voice")

    list(engine._generate("你好。", voice="default", speed=1.0, language="auto", seed=101))
    observation = engine.consume_sampling_observation()

    assert seeded == [101]
    assert observation is not None
    assert observation["seed_policy"] == "caller_fixed"
    assert observation["seed"] == 101
    assert observation["temperature"] == 0.7
    assert observation["top_p"] == 0.95
    assert observation["repetition_penalty"] == 1.05


def test_clone_path_reports_its_derived_seed_and_fixed_sampling(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seeded: list[int] = []
    _fake_mlx_runtime(monkeypatch, seeded)
    engine = _sampling_engine("base")
    engine._audio_loader_fn = lambda _: object()
    # The engine default is 0.95, which is exactly _CLONE_TOP_P. Leaving it
    # there would make the assertion below pass whether the clone path reports
    # its own constant or simply echoes the engine setting, so the two are
    # pulled apart deliberately.
    engine._top_p = 0.5

    list(
        engine._generate(
            "你好。",
            voice="narrator",
            speed=1.0,
            language="auto",
            ref_audio="/tmp/reference.wav",
            ref_text="参考文本。",
        )
    )
    observation = engine.consume_sampling_observation()

    assert observation is not None
    assert observation["seed_policy"] == "clone_reference_derived"
    assert observation["seed"] == seeded[0]
    assert observation["temperature"] == worker_module._CLONE_TEMPERATURE
    assert observation["top_p"] == worker_module._CLONE_TOP_P
    assert observation["repetition_penalty"] == 1.5


def test_clone_path_reports_no_fixed_sampler_when_the_runtime_cannot_seed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A derived seed that was never applied must not be reported as one.

    The audio is produced either way; what changes is whether the recipe may
    later claim this render is reproducible. Reporting `clone_reference_derived`
    for a stream that nothing seeded would hand a client a seed it can reuse
    and get different audio from.
    """
    _no_mlx_runtime(monkeypatch)
    engine = _sampling_engine("base")
    engine._audio_loader_fn = lambda _: object()

    list(
        engine._generate(
            "你好。",
            voice="narrator",
            speed=1.0,
            language="auto",
            ref_audio="/tmp/reference.wav",
            ref_text="参考文本。",
        )
    )
    observation = engine.consume_sampling_observation()

    assert observation is not None
    assert observation["seed_policy"] == "unseeded_sampler"
    assert observation["seed"] is None


def test_voice_design_profile_seed_is_reported_as_applied_only_when_the_runtime_took_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _no_mlx_runtime(monkeypatch)
    engine = _sampling_engine("voice_design")
    engine._temperature = 0.7

    list(
        engine._generate(
            "你好。",
            voice="v",
            speed=1.0,
            language="auto",
            profile=SimpleNamespace(
                id="v",
                mode="voice_design",
                instruction="沉稳",
                seed=202,
                temperature=0.4,
            ),
        )
    )
    observation = engine.consume_sampling_observation()

    assert observation is not None
    assert observation["seed_policy"] == "unseeded_sampler"
    assert observation["seed"] is None
    # The profile's own temperature still reached the sampler, so it is still
    # a fact worth reporting even though the seed was not applied.
    assert observation["temperature"] == 0.4


def test_voice_design_profile_seed_is_reported_as_profile_fixed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seeded: list[int] = []
    _fake_mlx_runtime(monkeypatch, seeded)
    engine = _sampling_engine("voice_design")
    engine._temperature = 0.7

    list(
        engine._generate(
            "你好。",
            voice="v",
            speed=1.0,
            language="auto",
            profile=SimpleNamespace(
                id="v",
                mode="voice_design",
                instruction="沉稳",
                seed=202,
                temperature=0.4,
            ),
        )
    )
    observation = engine.consume_sampling_observation()

    assert seeded == [202]
    assert observation is not None
    assert observation["seed_policy"] == "voice_profile_fixed"
    assert observation["seed"] == 202
    assert observation["temperature"] == 0.4


def test_voice_design_with_an_instruction_reports_the_callers_own_seed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A seed handed in with an instruction came from the caller, not the profile."""
    seeded: list[int] = []
    _fake_mlx_runtime(monkeypatch, seeded)
    engine = _sampling_engine("voice_design")

    list(
        engine._generate(
            "你好。",
            voice="v",
            speed=1.0,
            language="auto",
            instruction="沉稳",
            seed=303,
        )
    )
    observation = engine.consume_sampling_observation()

    assert seeded == [303]
    assert observation is not None
    assert observation["seed_policy"] == "caller_fixed"
    assert observation["seed"] == 303


def test_voice_design_with_an_instruction_and_no_seed_reports_no_fixed_sampler(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seeded: list[int] = []
    _fake_mlx_runtime(monkeypatch, seeded)
    engine = _sampling_engine("voice_design")

    list(
        engine._generate(
            "你好。",
            voice="v",
            speed=1.0,
            language="auto",
            instruction="沉稳",
        )
    )
    observation = engine.consume_sampling_observation()

    assert seeded == []
    assert observation is not None
    assert observation["seed_policy"] == "unseeded_sampler"
    assert observation["seed"] is None


def test_worker_main_passes_explicit_local_runtime_arguments_to_private_server(
    monkeypatch, tmp_path: Path
) -> None:
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    captured: dict[str, object] = {}

    def fake_serve(
        input_stream: object,
        output_stream: object,
        *,
        model_dir: Path,
        device: str,
        sample_rate: int,
        engine_factory: object,
    ) -> None:
        captured.update(
            {
                "input_stream": input_stream,
                "output_stream": output_stream,
                "model_dir": model_dir,
                "device": device,
                "sample_rate": sample_rate,
                "engine_factory": engine_factory,
            }
        )

    monkeypatch.setattr(worker_module, "serve", fake_serve)
    def engine_factory(_: Path) -> FakeEngine:
        return FakeEngine()

    worker_module.main(
        ["--model-dir", str(model_dir), "--device", "mps", "--sample-rate", "24000"],
        engine_factory=engine_factory,
    )

    assert captured["model_dir"] == model_dir.resolve()
    assert captured["device"] == "mps"
    assert captured["sample_rate"] == 24_000
    assert captured["engine_factory"] is engine_factory


def test_serve_reports_worker_load_error_with_traceback_on_stderr(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A failing model load emits worker_load_error AND the real traceback on stderr."""

    def failing_factory(_: Path) -> FakeEngine:
        raise RuntimeError("boom-model-load")

    source = BytesIO()
    target = BytesIO()
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    source.seek(0)

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=failing_factory,
    )

    target.seek(0)
    assert read_frame(target) == {
        "version": PROTOCOL_VERSION,
        "type": "error",
        "code": "worker_load_error",
    }
    assert "boom-model-load" in capsys.readouterr().err


class _FakeIncrementalSession:
    """One append-only session used to prove the full pipe wire end to end."""

    generation_identity = "gen-1"
    sample_rate = 24_000
    prefill_target_tokens = 1

    def __init__(self) -> None:
        self.steps = 0
        self.appended: list[str] = []
        self.finished = 0
        self.cancelled = 0
        self.closed = 0

    def append_text(self, text: str) -> tuple[int, ...]:
        self.appended.append(text)
        return (11, 12)

    def finish_input(self) -> None:
        self.finished += 1

    def step(self, *, max_steps: int) -> ModelStepEvent:
        assert max_steps > 0
        self.steps += 1
        if self.steps == 1:
            return ModelStepEvent(kind="pcm", pcm16=b"\x00\x00")
        return ModelStepEvent(kind="finished")

    def cancel(self) -> None:
        self.cancelled += 1

    def close(self) -> None:
        # The vendor driver's close is idempotent; the host releases on the
        # terminal and again from the per-utterance finally.
        if self.closed:
            return
        self.closed += 1


def test_serve_drives_one_incremental_utterance_over_the_pipe(tmp_path: Path) -> None:
    class IncrementalEngine(FakeEngine):
        def __init__(self) -> None:
            self.session = _FakeIncrementalSession()
            self.opened: dict[str, object] | None = None

        def open_incremental_session(self, **kwargs: object) -> _FakeIncrementalSession:
            self.opened = kwargs
            return self.session

    engine = IncrementalEngine()
    source = BytesIO()
    target = BytesIO()
    model_dir = tmp_path / "model"
    model_dir.mkdir()
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "start",
            "model_dir": str(model_dir),
            "device": "mps",
            "sample_rate": 24_000,
        },
    )
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "tts_stream_start",
            "request_id": "req-stream",
            "response_id": "resp-stream",
            "voice": "default",
            "speed": 1.0,
            "language": "auto",
            "limits": {
                field: getattr(DEFAULT_TTS_STREAM_LIMITS, field)
                for field in (
                    "max_append_codepoints",
                    "max_total_codepoints",
                    "max_pending_codepoints",
                    "max_pending_audio_bytes",
                    "input_wait_seconds",
                    "utterance_wall_clock_seconds",
                    "slow_consumer_seconds",
                )
            },
        },
    )
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "tts_stream_text",
            "request_id": "req-stream",
            "sequence": 0,
            "text": "你好",
        },
    )
    write_frame(
        source,
        {
            "version": PROTOCOL_VERSION,
            "type": "tts_stream_finish",
            "request_id": "req-stream",
            "last_sequence": 0,
        },
    )
    source.seek(0)

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: engine,
    )

    target.seek(0)
    ready = read_frame(target)
    started = read_frame(target)
    accepted = read_frame(target)
    audio = read_frame(target)
    fade = read_frame(target)
    done = read_frame(target)
    assert read_frame(target) is None

    assert ready["tts_stream_protocol"] == 1
    assert started["type"] == "tts_stream_started"
    assert started["request_id"] == "req-stream"
    assert started["response_id"] == "resp-stream"
    assert started["prefill_target_tokens"] == 1
    assert accepted["type"] == "tts_stream_text_accepted"
    assert accepted["accepted_tokens"] == 2
    assert audio["type"] == "tts_stream_audio"
    assert audio["_binary"] == b"\x00\x00"
    # The utterance ends on a fade-to-silence frame, so a completed stream
    # never leaves the speaker on a step. The fake's only sample is already
    # zero, so the ramp is the explicit quiet window.
    assert fade["type"] == "tts_stream_audio"
    assert fade["sample_offset"] == 1
    assert fade["_binary"] == b"\x00\x00" * 120
    assert done == {
        "version": PROTOCOL_VERSION,
        "type": "tts_stream_done",
        "request_id": "req-stream",
        "terminal": "completed",
        "event": "completed",
    }
    assert engine.session.appended == ["你好"]
    assert engine.session.finished == 1
    assert engine.session.closed == 1
