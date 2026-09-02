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
    assert engine.identity.dtype == "float16"
    assert model.calls == [
        {
            "text": "你好。",
            "voice": None,
            "instruct": "温暖柔和的中文女声，语速略慢，语气舒缓，适合阅读与陪伴场景。",
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
    assert np.frombuffer(chunks[0], dtype="<i2").size == 4
    assert np.isfinite(np.frombuffer(chunks[0], dtype="<i2")).all()


def test_mlx_voice_design_engine_quantizes_in_memory_on_int8(tmp_path: Path) -> None:
    model = FakeMlxModel()
    quantized = FakeMlxModel()
    calls: list[tuple[object, Path]] = []

    def fake_quantize(model_arg: object, model_dir_arg: Path):
        calls.append((model_arg, model_dir_arg))
        return quantized

    engine = MlxVoiceDesignEngine(
        tmp_path,
        device="mps",
        dtype="int8",
        sample_rate=24_000,
        load_fn=lambda _: model,
        quantize_fn=fake_quantize,
        numpy_module=np,
        warmup=False,
    )

    assert engine.identity.dtype == "int8"
    assert len(calls) == 1
    assert calls[0][0] is model
    assert calls[0][1] == tmp_path
    list(engine.synthesize("你好", voice="default", speed=1.0, language="zh"))
    assert quantized.calls, "generation must use the quantized model instance"
