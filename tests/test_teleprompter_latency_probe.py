from __future__ import annotations

import sys
import wave
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.probe_teleprompter_latency import (
    ProbeInputError,
    load_wave_fixture,
    percentile,
    timing_summary,
)


def test_percentile_and_timing_summary_are_deterministic() -> None:
    assert percentile([3.0, 1.0, 2.0], 0.50) == 2.0
    assert timing_summary([3.0, 1.0, 2.0]) == {
        "count": 3,
        "p50_ms": 2.0,
        "p95_ms": 3.0,
        "max_ms": 3.0,
    }
    assert timing_summary([])["p95_ms"] is None


def test_load_wave_fixture_requires_24khz_mono_pcm16(tmp_path: Path) -> None:
    path = tmp_path / "fixture.wav"
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24_000)
        output.writeframes(b"\x00\x00" * 2_400)

    fixture = load_wave_fixture(path)
    assert fixture.duration_seconds == 0.1
    assert len(fixture.pcm) == 4_800


def test_load_wave_fixture_rejects_wrong_format(tmp_path: Path) -> None:
    path = tmp_path / "wrong.wav"
    with wave.open(str(path), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(48_000)
        output.writeframes(b"\x00\x00" * 100)

    with pytest.raises(ProbeInputError):
        load_wave_fixture(path)
