from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

import speechrail.backends.qwen3_tts_worker as worker_module
from speechrail.backends.model_identity import SnapshotIdentity
from speechrail.backends.qwen3_tts_worker import MlxQwenTtsEngine
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.domain.tts import (
    StreamingSentenceSplitter,
    apply_crossfade,
    bounded_sentences,
    create_breath_pause,
)


def test_streaming_sentence_splitter_basic() -> None:
    splitter = StreamingSentenceSplitter(min_sentence_chars=4, min_secondary_chars=8)
    # Feed partial
    assert splitter.feed("你好，") == []
    # Feed enough with comma
    assert splitter.feed("今天天气真的很好，") == ["你好，今天天气真的很好，"]
    # Feed period
    assert splitter.feed("我们一起去散步吧。") == ["我们一起去散步吧。"]
    # Remaining
    assert splitter.feed("这是最后一句") == []
    assert splitter.flush() == ["这是最后一句"]
    assert splitter.flush() == []


def test_streaming_sentence_splitter_abbreviation_and_decimal() -> None:
    splitter = StreamingSentenceSplitter(min_sentence_chars=4)
    # 3.14 should not split on period
    assert splitter.feed("圆周率是 3.14，") == []
    assert splitter.feed("计算非常精准。") == ["圆周率是 3.14，计算非常精准。"]

    # Dr. Smith should not split on Dr.
    splitter.clear()
    assert splitter.feed("Hello Dr. Smith ") == []
    assert splitter.feed("how are you doing today?") == ["Hello Dr. Smith how are you doing today?"]
    assert splitter.flush() == []


def test_streaming_sentence_splitter_book_and_quote_protection() -> None:
    splitter = StreamingSentenceSplitter(min_sentence_chars=4)
    # Inside book title 《...》 period or exclamation is not prematurely split if short
    assert splitter.feed("我正在读《活着！》这本书。") == ["我正在读《活着！》这本书。"]


def test_apply_crossfade_ramps_ends() -> None:
    # 24kHz, 100ms = 2400 samples
    sample_rate = 24_000
    num_samples = 2400
    constant_val = 10000
    raw_samples = np.full(num_samples, constant_val, dtype="<i2")
    pcm = raw_samples.tobytes()

    faded = apply_crossfade(pcm, sample_rate=sample_rate, fade_ms=5, fade_in=True, fade_out=True)
    faded_samples = np.frombuffer(faded, dtype="<i2")

    # Start should start near 0
    assert abs(faded_samples[0]) < 100
    # Middle should be close to constant_val
    assert abs(faded_samples[num_samples // 2] - constant_val) < 100
    # End should be near 0
    assert abs(faded_samples[-1]) < 100


def test_create_breath_pause() -> None:
    pause = create_breath_pause(sample_rate=24_000, pause_ms=100)
    # 100ms @ 24kHz = 2400 samples * 2 bytes = 4800 bytes
    assert len(pause) == 4800
    assert all(b == 0 for b in pause)


def test_long_text_is_not_silently_truncated() -> None:
    text = "今天下午三点开会。" * 100

    chunks = bounded_sentences(text, max_chars=240)

    assert "".join(chunks) == text
    assert max(map(len, chunks)) <= 240


def test_bounded_sentences_prefers_sentence_end_and_preserves_whitespace() -> None:
    text = "第一句完成。 第二句也完成！\n第三句还在继续，后面还有内容。"

    chunks = bounded_sentences(text, max_chars=12)

    assert "".join(chunks) == text
    assert all(0 < len(chunk) <= 12 for chunk in chunks)
    assert chunks[0] == "第一句完成。"
    assert any("！" in chunk for chunk in chunks)


def test_bounded_sentences_protects_decimal_url_abbreviation_and_quotes() -> None:
    text = 'Dr. Smith checked 3.14 at https://example.com/path?q=3.14. 然后他说：“继续。”最后结束。'

    chunks = bounded_sentences(text, max_chars=60)

    assert "".join(chunks) == text
    assert all(len(chunk) <= 60 for chunk in chunks)
    assert chunks[0] == "Dr. Smith checked 3.14 at https://example.com/path?q=3.14."
    assert any("：“继续。”" in chunk for chunk in chunks)
    assert all(not chunk.endswith("Dr.") for chunk in chunks)
    assert all(not chunk.endswith("3.") for chunk in chunks)


def test_bounded_sentences_splits_unpunctuated_text_at_safe_character_boundary() -> None:
    text = "没有标点的长文本" * 100

    chunks = bounded_sentences(text, max_chars=37)

    assert "".join(chunks) == text
    assert all(0 < len(chunk) <= 37 for chunk in chunks)


def test_bounded_sentences_requires_positive_limit() -> None:
    with pytest.raises(ValueError, match="max_chars"):
        bounded_sentences("文本", max_chars=0)


class _RecordingTtsModel:
    def __init__(self, variant: str) -> None:
        self.config = SimpleNamespace(tts_model_type=variant)
        self.calls: list[dict[str, object]] = []

    def generate(self, **kwargs: object):
        self.calls.append(kwargs)
        yield SimpleNamespace(
            sample_rate=24_000,
            audio=np.array([0.25, 0.5], dtype=np.float32),
            is_final_chunk=True,
        )


@pytest.mark.parametrize("variant", ["custom_voice", "voice_design"])
def test_tts_worker_uses_same_bounded_segments_for_both_variants(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    variant: str,
) -> None:
    model = _RecordingTtsModel(variant)
    monkeypatch.setattr(
        worker_module,
        "inspect_model",
        lambda _: SnapshotIdentity(
            family="qwen3_tts",
            variant=variant,
            quantization=QuantizationSpec(bits=4, group_size=64, format="mlx"),
            weight_fingerprint="shape:" + ("a" * 64),
        ),
    )
    engine = MlxQwenTtsEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: model,
        numpy_module=np,
        warmup=False,
    )
    text = "第一句。" * 60

    list(engine.synthesize(text, voice="default", speed=1.0, language="zh"))

    assert [call["text"] for call in model.calls] == list(
        bounded_sentences(text + "。" if not text.endswith("。") else text)
    )
    assert all(int(call["max_tokens"]) <= 1_200 for call in model.calls)


class _TwoSentenceTtsModel:
    config = SimpleNamespace(tts_model_type="voice_design")

    def generate(self, **kwargs: object):
        del kwargs
        samples = np.full(2_400, 0.5, dtype=np.float32)
        yield SimpleNamespace(sample_rate=24_000, audio=samples, is_final_chunk=False)
        yield SimpleNamespace(sample_rate=24_000, audio=samples, is_final_chunk=True)


def test_tts_worker_fades_only_first_logical_chunk_across_sentences(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        worker_module,
        "inspect_model",
        lambda _: SnapshotIdentity(
            family="qwen3_tts",
            variant="voice_design",
            quantization=QuantizationSpec(bits=4, group_size=64, format="mlx"),
            weight_fingerprint="shape:" + ("b" * 64),
        ),
    )
    engine = MlxQwenTtsEngine(
        tmp_path,
        device="mps",
        load_fn=lambda _: _TwoSentenceTtsModel(),
        numpy_module=np,
        warmup=False,
    )

    text = "第一句。第二句。" * 50
    chunks = list(engine.synthesize(text, voice="default", speed=1.0, language="zh"))
    segment_count = len(bounded_sentences(text))
    assert segment_count > 1
    assert len(chunks) == segment_count * 2
    first = np.frombuffer(chunks[0], dtype="<i2")
    second = np.frombuffer(chunks[1], dtype="<i2")
    third = np.frombuffer(chunks[2], dtype="<i2")
    fourth = np.frombuffer(chunks[3], dtype="<i2")

    assert abs(int(first[0])) < 100
    assert abs(int(second[0]) - 16_383) < 100
    assert abs(int(third[0]) - 16_383) < 100
    assert abs(int(fourth[0]) - 16_383) < 100
    assert abs(int(fourth[-1])) < 100
