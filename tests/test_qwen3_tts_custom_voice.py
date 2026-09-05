"""Qwen3-TTS CustomVoice 的条件构造和共享生成测试。"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

import speechrail.backends.qwen3_tts_worker as worker_module
from speechrail.backends.model_identity import SnapshotIdentity
from speechrail.backends.qwen3_tts_worker import (
    MlxQwenTtsEngine,
    MlxVoiceDesignEngine,
    generation_condition,
)
from speechrail.config.model_catalog import QuantizationSpec


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
    assert generation_condition("voice_design", "warm") == {
        "voice": None,
        "instruct": "温暖柔和的中文女声，语速略慢，语气舒缓，适合阅读与陪伴场景。",
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


def test_voice_design_alias_is_preserved() -> None:
    assert MlxVoiceDesignEngine is MlxQwenTtsEngine
