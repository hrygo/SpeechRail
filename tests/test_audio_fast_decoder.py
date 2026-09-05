"""Tests for in-memory fast audio decoding, resampling and 128MB decompression limits."""

from __future__ import annotations

import struct

import numpy as np
import pytest

import speechrail.http.routes.audio as audio_module
from speechrail.http.routes.audio import _decode_pcm, _try_fast_decode_wav


def _make_wav(
    *,
    sample_rate: int = 16_000,
    channels: int = 1,
    num_samples: int = 1600,
    frequency: float = 440.0,
) -> bytes:
    t = np.linspace(0, num_samples / sample_rate, num_samples, endpoint=False)
    raw = (8000.0 * np.sin(2 * np.pi * frequency * t)).astype("<i2")
    if channels == 2:
        stereo = np.column_stack((raw, raw)).flatten()
        data = stereo.tobytes()
    else:
        data = raw.tobytes()

    byte_rate = sample_rate * channels * 2
    block_align = channels * 2
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(data),
        b"WAVE",
        b"fmt ",
        16,
        1,  # PCM format
        channels,
        sample_rate,
        byte_rate,
        block_align,
        16,  # 16-bit
        b"data",
        len(data),
    )
    return header + data


def test_fast_decode_16k_mono_wav() -> None:
    wav_bytes = _make_wav(sample_rate=16_000, channels=1, num_samples=1600)
    pcm = _try_fast_decode_wav(wav_bytes)
    assert pcm is not None
    assert len(pcm) == 1600 * 2


def test_fast_decode_44k_stereo_wav_resampled() -> None:
    # 44.1kHz stereo WAV -> 16kHz mono resampled in-memory
    wav_bytes = _make_wav(sample_rate=44_100, channels=2, num_samples=4410)
    pcm = _try_fast_decode_wav(wav_bytes)
    assert pcm is not None
    # 0.1s audio at 16kHz mono = 1600 samples = 3200 bytes
    assert abs(len(pcm) - 3200) <= 4


def test_fast_decode_48k_mono_wav_resampled() -> None:
    # 48kHz mono WAV -> 16kHz mono resampled in-memory
    wav_bytes = _make_wav(sample_rate=48_000, channels=1, num_samples=4800)
    pcm = _try_fast_decode_wav(wav_bytes)
    assert pcm is not None
    # 0.1s audio at 16kHz mono = 1600 samples = 3200 bytes
    assert abs(len(pcm) - 3200) <= 4


def test_fast_decode_rejects_oversized_resample_before_numpy_allocation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A valid 1Hz WAV expands from 10 input frames to 160,000 output frames.
    wav_bytes = _make_wav(sample_rate=1, num_samples=10)

    def fail_numpy_allocation(*_: object, **__: object) -> None:
        raise AssertionError("NumPy allocation should not be reached")

    for name in ("frombuffer", "arange", "linspace", "interp", "clip"):
        monkeypatch.setattr(np, name, fail_numpy_allocation)

    with pytest.raises(OverflowError, match="audio_too_large"):
        _try_fast_decode_wav(wav_bytes, max_decompressed_bytes=1_000)


def test_fast_decode_allows_exact_output_byte_limit_and_rejects_one_byte_under() -> None:
    # 8kHz mono, 4 frames -> 8 output frames -> exactly 16 bytes.
    wav_bytes = _make_wav(sample_rate=8_000, num_samples=4)

    pcm = _try_fast_decode_wav(wav_bytes, max_decompressed_bytes=16)
    assert pcm is not None
    assert len(pcm) == 16

    with pytest.raises(OverflowError, match="audio_too_large"):
        _try_fast_decode_wav(wav_bytes, max_decompressed_bytes=15)


def test_fast_decode_stereo_limit_counts_mixed_mono_output() -> None:
    # 8kHz stereo, 4 interleaved frames -> 8 mono output frames -> 16 bytes.
    wav_bytes = _make_wav(sample_rate=8_000, channels=2, num_samples=4)

    pcm = _try_fast_decode_wav(wav_bytes, max_decompressed_bytes=16)
    assert pcm is not None
    assert len(pcm) == 16


def test_fast_decode_allows_exact_duration_limit_and_rejects_one_frame_over() -> None:
    exact = _make_wav(sample_rate=16_000, num_samples=16_000)
    pcm = _try_fast_decode_wav(exact, max_audio_seconds=1)
    assert pcm is not None
    assert len(pcm) == 32_000

    over = _make_wav(sample_rate=16_000, num_samples=16_001)
    with pytest.raises(ValueError, match="audio_too_long"):
        _try_fast_decode_wav(over, max_audio_seconds=1)


def test_fast_decode_zero_sample_rate_fails_closed() -> None:
    wav_bytes = bytearray(_make_wav(sample_rate=16_000, num_samples=100))
    struct.pack_into("<I", wav_bytes, 24, 0)

    assert _try_fast_decode_wav(bytes(wav_bytes)) is None


@pytest.mark.anyio
async def test_decode_pcm_passes_limits_before_numpy_allocation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    wav_bytes = _make_wav(sample_rate=1, num_samples=10)

    def fail_numpy_allocation(*_: object, **__: object) -> None:
        raise AssertionError("NumPy allocation should not be reached")

    def fail_ffmpeg() -> str:
        raise AssertionError("ffmpeg fallback should not be reached")

    for name in ("frombuffer", "arange", "linspace", "interp", "clip"):
        monkeypatch.setattr(np, name, fail_numpy_allocation)
    monkeypatch.setattr(audio_module, "_resolve_ffmpeg", fail_ffmpeg)

    with pytest.raises(OverflowError, match="audio_too_large"):
        await _decode_pcm(wav_bytes, max_decompressed_bytes=1_000)


@pytest.mark.anyio
async def test_decode_pcm_enforces_128mb_cutoff() -> None:
    # Create 16kHz mono WAV with 1000 samples
    wav_bytes = _make_wav(sample_rate=16_000, channels=1, num_samples=1000)
    # Set max_decompressed_bytes to smaller than 2000 bytes
    with pytest.raises(OverflowError):
        await _decode_pcm(wav_bytes, max_decompressed_bytes=1000)


def test_fast_decode_invalid_header_fails_closed() -> None:
    assert _try_fast_decode_wav(b"not-a-wav-file") is None
    assert _try_fast_decode_wav(b"RIFF\x00\x00\x00\x00WAVEfmt ") is None


@pytest.mark.anyio
async def test_decode_pcm_enforces_max_audio_seconds() -> None:
    # 2.0s audio @ 16kHz mono = 32000 samples = 64000 bytes
    wav_bytes = _make_wav(sample_rate=16_000, channels=1, num_samples=32000)
    # Allowed when limit is 3 seconds
    pcm = await _decode_pcm(wav_bytes, max_audio_seconds=3)
    assert len(pcm) == 64000
    # Rejected when limit is 1 second
    with pytest.raises(ValueError, match="audio_too_long"):
        await _decode_pcm(wav_bytes, max_audio_seconds=1)
