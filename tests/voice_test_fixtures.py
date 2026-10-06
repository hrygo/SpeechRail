"""Opt-in fakes for voice workflows; acoustic accuracy has its own tests."""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def fake_pitch_measurement(monkeypatch: pytest.MonkeyPatch) -> None:
    # Imported only by fake-backend workflow modules, never by acoustic tests.
    # F0 is a descriptive pre-screen measurement, not a quality gate input.
    monkeypatch.setattr(
        "speechrail.domain.voice_quality.f0_median_hz",
        lambda pcm, sample_rate: 220.0 if pcm and sample_rate > 0 else None,
    )
