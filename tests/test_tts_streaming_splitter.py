from __future__ import annotations

import numpy as np

from speechrail.domain.tts import (
    StreamingSentenceSplitter,
    apply_crossfade,
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
