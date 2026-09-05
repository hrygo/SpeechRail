from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import numpy as np

from speechrail.backends.qwen3_tts_worker import MlxVoiceDesignEngine


class FakeGenerationResult:
    sample_rate = 24_000
    audio = np.array([0.25, 0.5, 0.0, 0.0], dtype=np.float32)
    is_final_chunk = True


class FakeMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    def generate(self, **kwargs: object):
        self.calls.append(kwargs)
        yield FakeGenerationResult()


def test_mlx_voice_design_engine_routes_preset_and_streaming_parameters(
    tmp_path: Path,
) -> None:
    model = FakeMlxModel()
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        sample_rate=24_000,
        chunk_ms=100,
        repetition_penalty=1.25,
        temperature=0.85,
        top_p=0.95,
        load_fn=lambda _: model,
        numpy_module=np,
        warmup=False,
    )

    chunks = list(engine.synthesize("你好", voice="warm", speed=1.25, language="zh"))

    assert engine.identity.backend == "mlx-qwen3-tts-voice-design"
    assert model.calls == [
        {
            "text": "你好。",
            "voice": None,
            "instruct": "温暖柔和的中文女声，语速略慢，语气舒缓，适合阅读与陪伴场景。",
            "speed": 1.25,
            "lang_code": "zh",
            "max_tokens": 39,
            "repetition_penalty": 1.25,
            "temperature": 0.1,
            "top_p": 0.95,
            "stream": True,
            "streaming_interval": 0.1,
        }
    ]
    assert len(chunks) == 1
    assert np.frombuffer(chunks[0], dtype="<i2").size == 4
    assert np.isfinite(np.frombuffer(chunks[0], dtype="<i2")).all()


class SequencedFakeMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def generate(self, **kwargs: object):
        del kwargs
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=False,
        )
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=True,
        )


def test_mlx_voice_design_engine_fades_only_logical_synthesis_boundaries(
    tmp_path: Path,
) -> None:
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: SequencedFakeMlxModel(),
        numpy_module=np,
        warmup=False,
    )

    chunks = list(engine.synthesize("边界测试", voice="default", speed=1.0, language="zh"))
    first = np.frombuffer(chunks[0], dtype="<i2")
    final = np.frombuffer(chunks[1], dtype="<i2")

    assert abs(int(first[0])) < 100
    assert abs(int(first[1_200]) - 16_383) < 100
    assert abs(int(first[-1]) - 16_383) < 100
    assert abs(int(final[0]) - 16_383) < 100
    assert abs(int(final[1_200]) - 16_383) < 100
    assert abs(int(final[-1])) < 100


class EmptyThenSequencedFakeMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def generate(self, **kwargs: object):
        del kwargs
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.array([], dtype=np.float32),
            is_final_chunk=False,
        )
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=False,
        )
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=True,
        )


class SingleFinalFakeMlxModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def generate(self, **kwargs: object):
        del kwargs
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.full(2_400, 0.5, dtype=np.float32),
            is_final_chunk=True,
        )


def test_mlx_voice_design_engine_ignores_empty_chunk_before_fade_in(tmp_path: Path) -> None:
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: EmptyThenSequencedFakeMlxModel(),
        numpy_module=np,
        warmup=False,
    )
    first = np.frombuffer(
        next(iter(engine.synthesize("空块测试", voice="default", speed=1.0, language="zh"))),
        dtype="<i2",
    )
    assert abs(int(first[0])) < 100


def test_mlx_voice_design_engine_fades_both_ends_of_single_final_chunk(
    tmp_path: Path,
) -> None:
    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: SingleFinalFakeMlxModel(),
        numpy_module=np,
        warmup=False,
    )
    samples = np.frombuffer(
        next(iter(engine.synthesize("单块测试", voice="default", speed=1.0, language="zh"))),
        dtype="<i2",
    )
    assert abs(int(samples[0])) < 100
    assert abs(int(samples[1_200]) - 16_383) < 100
    assert abs(int(samples[-1])) < 100
