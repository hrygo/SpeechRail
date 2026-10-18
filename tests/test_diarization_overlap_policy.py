"""Budget-driven overlap policy for the diarization heavy axis (ADR-0016 ext)."""

from __future__ import annotations

import pytest

import speechrail.application.services as services_module
from speechrail.config import Settings
from speechrail.runtime.model_budget import (
    ComponentFootprint,
    budget_for_hardware,
    can_overlap_heavy_compute,
    declared_heavy_axes,
)

GIB = 1024 ** 3


def test_can_overlap_certifies_asr_and_diarization_within_budget() -> None:
    budget = budget_for_hardware(16 * GIB)  # 8 GiB
    footprint = ComponentFootprint(asr_bytes=3 * GIB, tts_bytes=0, diarization_bytes=2 * GIB)

    decision, reason = can_overlap_heavy_compute(budget, footprint)

    assert decision is True
    assert "within budget" in reason.lower()
    assert "diarization" in reason.lower()
    assert declared_heavy_axes(footprint) == ("asr", "diarization")


def test_can_overlap_certifies_tts_and_diarization_within_budget() -> None:
    budget = budget_for_hardware(16 * GIB)  # 8 GiB
    footprint = ComponentFootprint(asr_bytes=0, tts_bytes=2 * GIB, diarization_bytes=2 * GIB)

    decision, reason = can_overlap_heavy_compute(budget, footprint)

    assert decision is True
    assert "within budget" in reason.lower()
    assert declared_heavy_axes(footprint) == ("tts", "diarization")


def test_overlap_boundary_total_equal_to_budget_is_admitted() -> None:
    budget = 4 * GIB
    footprint = ComponentFootprint(asr_bytes=2 * GIB, tts_bytes=0, diarization_bytes=2 * GIB)
    assert footprint.total_bytes == budget

    decision, _ = can_overlap_heavy_compute(budget, footprint)

    assert decision is True


def test_can_overlap_serializes_when_diarization_pushes_total_over_budget() -> None:
    budget = 4 * GIB
    footprint = ComponentFootprint(asr_bytes=2 * GIB, tts_bytes=0, diarization_bytes=2 * GIB + 1)

    decision, reason = can_overlap_heavy_compute(budget, footprint)

    assert decision is False
    assert "exceeds" in reason.lower()


def test_can_overlap_serializes_when_enabled_diarization_is_unknown() -> None:
    footprint = ComponentFootprint(asr_bytes=2 * GIB, tts_bytes=0, diarization_bytes=None)

    decision, reason = can_overlap_heavy_compute(8 * GIB, footprint)

    assert decision is False
    assert "unknown" in reason.lower()


def test_disabled_component_is_not_a_declared_axis() -> None:
    footprint = ComponentFootprint(asr_bytes=2 * GIB, tts_bytes=0, diarization_bytes=1 * GIB)

    assert declared_heavy_axes(footprint) == ("asr", "diarization")


def test_three_way_overlap_certified_only_while_total_fits_budget() -> None:
    within = ComponentFootprint(asr_bytes=1 * GIB, tts_bytes=1 * GIB, diarization_bytes=1 * GIB)

    decision, reason = can_overlap_heavy_compute(4 * GIB, within)

    assert decision is True
    assert declared_heavy_axes(within) == ("asr", "tts", "diarization")
    assert "diarization" in reason.lower()

    over = ComponentFootprint(asr_bytes=2 * GIB, tts_bytes=2 * GIB, diarization_bytes=2 * GIB)

    over_decision, over_reason = can_overlap_heavy_compute(4 * GIB, over)

    assert over_decision is False
    assert "exceeds" in over_reason.lower()


def _settings(**overrides: object) -> Settings:
    return Settings(_env_file=None, qwen3_model_dir=None, qwen3_python=None, **overrides)


@pytest.mark.parametrize("legacy,dynamic", [(0, GIB), (GIB, 0), (GIB, 2 * GIB)])
def test_enabled_alternatives_must_both_have_bounds_before_using_max(legacy, dynamic):
    from pathlib import Path

    settings = _settings(
        diarization_dynamic_enabled=True,
        diarization_coreml_model_path=Path("/nonexistent/test-model"),
        diarization_worker_path=Path("/nonexistent/test-worker"),
        diarization_resident_bytes=legacy,
        diarization_dynamic_resident_bytes=dynamic,
    )
    assert services_module._diarization_declared_bytes(settings) == (
        max(legacy, dynamic) if legacy and dynamic else 0
    )


def test_heavy_overlap_policy_certifies_diarization_axis_when_declared(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(services_module, "detect_system_memory_bytes", lambda: 128 * GIB)
    settings = _settings(asr_resident_bytes=2 * GIB, diarization_resident_bytes=1 * GIB)

    overlap, reason = services_module._heavy_overlap_policy(
        settings, asr_enabled=True, tts_enabled=False, diarization_enabled=True
    )

    assert overlap is True
    assert "within budget" in reason.lower()
    assert "diarization" in reason.lower()


def test_heavy_overlap_policy_serializes_when_diarization_axis_is_undeclared(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(services_module, "detect_system_memory_bytes", lambda: 128 * GIB)
    settings = _settings(asr_resident_bytes=2 * GIB)

    overlap, reason = services_module._heavy_overlap_policy(
        settings, asr_enabled=True, tts_enabled=False, diarization_enabled=True
    )

    assert overlap is False
    assert "unknown" in reason.lower()


def test_heavy_overlap_policy_serializes_when_total_exceeds_budget(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(services_module, "detect_system_memory_bytes", lambda: 8 * GIB)
    settings = _settings(asr_resident_bytes=3 * GIB, diarization_resident_bytes=3 * GIB)

    overlap, reason = services_module._heavy_overlap_policy(
        settings, asr_enabled=True, tts_enabled=False, diarization_enabled=True
    )

    assert overlap is False
    assert "exceeds" in reason.lower()


def test_heavy_overlap_policy_respects_explicit_disable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(services_module, "detect_system_memory_bytes", lambda: 128 * GIB)
    settings = _settings(
        allow_heavy_overlap="false",
        asr_resident_bytes=2 * GIB,
        diarization_resident_bytes=1 * GIB,
    )

    overlap, reason = services_module._heavy_overlap_policy(
        settings, asr_enabled=True, tts_enabled=False, diarization_enabled=True
    )

    assert overlap is False
    assert "disabled" in reason.lower()
