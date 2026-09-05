"""Qwen3-TTS CustomVoice 的条件构造和共享生成测试。"""

from __future__ import annotations

from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

import speechrail.backends.qwen3_tts_worker as worker_module
from speechrail.backends.model_identity import SnapshotIdentity
from speechrail.backends.qwen3_tts_worker import (
    MlxQwenTtsEngine,
    MlxVoiceDesignEngine,
    TtsWorkerIdentity,
    generation_condition,
    serve,
)
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION, read_frame, write_frame


class FakeGenerationResult:
    sample_rate = 24_000
    audio = np.array([0.25, 0.5, 0.0, 0.0], dtype=np.float32)
    is_final_chunk = True


class FakeCustomVoiceModel:
    config = SimpleNamespace(tts_model_type="custom_voice")

    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    def generate(self, **kwargs: object):
        self.calls.append(kwargs)
        yield FakeGenerationResult()


class EmptyThenNonEmptyCustomVoiceModel:
    config = SimpleNamespace(tts_model_type="custom_voice")

    def generate(self, **kwargs: object):
        del kwargs
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.array([], dtype=np.float32),
            is_final_chunk=False,
        )
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(4, 0.5, dtype=np.float32),
            is_final_chunk=False,
        )


class SingleFinalCustomVoiceModel:
    config = SimpleNamespace(tts_model_type="custom_voice")

    def generate(self, **kwargs: object):
        del kwargs
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.array([0.25, 0.5, 0.75, 1.0], dtype=np.float32),
            is_final_chunk=True,
        )


def _snapshot_identity() -> SnapshotIdentity:
    return SnapshotIdentity(
        family="qwen3_tts",
        variant="custom_voice",
        quantization=QuantizationSpec(bits=4, group_size=64, format="mlx"),
        weight_fingerprint="shape:" + ("a" * 64),
    )


@pytest.mark.parametrize(
    ("voice", "speaker"),
    [
        ("default", "Serena"),
        ("warm", "Serena"),
        ("bright", "Vivian"),
        ("calm", "Uncle_Fu"),
    ],
)
def test_custom_voice_generation_condition_maps_public_voice(
    voice: str, speaker: str
) -> None:
    assert generation_condition("custom_voice", voice) == {"voice": speaker}


def test_voice_design_generation_condition_keeps_instruction() -> None:
    assert generation_condition("voice_design", "serena") == {
        "voice": None,
        "instruct": "温暖柔和的年轻中文女声，音色自然亲切，语气平和，语速适中。",
    }


def test_generation_condition_rejects_unknown_variant_or_voice() -> None:
    with pytest.raises(ValueError, match="variant"):
        generation_condition("base", "default")
    with pytest.raises(ValueError, match="voice"):
        generation_condition("custom_voice", "unknown")


def test_custom_voice_engine_uses_shared_streaming_generation_without_instruction(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    expected = _snapshot_identity()
    monkeypatch.setattr(worker_module, "inspect_model", lambda _: expected)
    model = FakeCustomVoiceModel()
    engine = MlxQwenTtsEngine(
        tmp_path,
        device="mps",
        chunk_ms=100,
        repetition_penalty=1.25,
        temperature=0.85,
        top_p=0.95,
        load_fn=lambda _: model,
        numpy_module=np,
        warmup=False,
    )

    chunks = list(engine.synthesize("你好", voice="warm", speed=1.25, language="zh"))

    assert engine.identity.model_variant == "custom_voice"
    assert engine.identity.quantization_bits == 4
    assert model.calls == [
        {
            "text": "你好。",
            "voice": "Serena",
            "speed": 1.25,
            "lang_code": "zh",
            "max_tokens": 39,
            "repetition_penalty": 1.25,
            "temperature": 0.85,
            "top_p": 0.95,
            "stream": True,
            "streaming_interval": 0.1,
        }
    ]
    assert len(chunks) == 1
    assert len(chunks[0]) % 2 == 0
    assert np.isfinite(np.frombuffer(chunks[0], dtype="<i2")).all()


def test_custom_voice_fades_first_non_empty_pcm_after_empty_model_result(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    expected = _snapshot_identity()
    monkeypatch.setattr(worker_module, "inspect_model", lambda _: expected)
    engine = MlxQwenTtsEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: EmptyThenNonEmptyCustomVoiceModel(),
        numpy_module=np,
        warmup=False,
    )

    chunks = list(engine.synthesize("你好", voice="warm", speed=1.0, language="zh"))

    assert len(chunks) == 1
    samples = np.frombuffer(chunks[0], dtype="<i2")
    assert abs(int(samples[0])) < 100
    assert abs(int(samples[-1]) - 16_383) < 100


def test_custom_voice_single_final_chunk_has_fade_in_and_fade_out(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    expected = _snapshot_identity()
    monkeypatch.setattr(worker_module, "inspect_model", lambda _: expected)
    engine = MlxQwenTtsEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: SingleFinalCustomVoiceModel(),
        numpy_module=np,
        warmup=False,
    )

    chunks = list(engine.synthesize("你好", voice="warm", speed=1.0, language="zh"))

    assert len(chunks) == 1
    samples = np.frombuffer(chunks[0], dtype="<i2")
    assert abs(int(samples[0])) < 100
    assert int(samples[1]) > 0
    assert int(samples[2]) > 0
    assert abs(int(samples[-1])) < 100


def test_voice_design_alias_is_preserved() -> None:
    assert MlxVoiceDesignEngine is MlxQwenTtsEngine


def test_serve_accepts_loaded_custom_voice_identity(tmp_path: Path) -> None:
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

    class CustomVoiceServeEngine:
        identity = TtsWorkerIdentity(
            device="mps",
            dtype="int8",
            sample_rate=24_000,
            family="qwen3_tts",
            model_variant="custom_voice",
            quantization_bits=4,
            quantization_group_size=64,
            weight_fingerprint="shape:" + ("a" * 64),
        )

        def synthesize(
            self, text: str, *, voice: str, speed: float, language: str
        ) -> object:
            del text, voice, speed, language
            yield b"\x00\x00"

    serve(
        source,
        target,
        model_dir=model_dir,
        device="mps",
        sample_rate=24_000,
        engine_factory=lambda _: CustomVoiceServeEngine(),
    )

    target.seek(0)
    ready = read_frame(target)
    assert ready["type"] == "ready"
    assert ready["model_variant"] == "custom_voice"
