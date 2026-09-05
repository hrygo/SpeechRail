"""Tests for unified hardware memory budgeting and resource protection (R06)."""

from __future__ import annotations

import inspect

import pytest

from speechrail.runtime.model_budget import (
    ComponentFootprint,
    budget_for_hardware,
    can_overlap_heavy_compute,
)

GIB = 1024 ** 3


def test_low_memory_acceptance_is_not_a_global_cap() -> None:
    assert budget_for_hardware(8 * GIB) == 4 * GIB
    assert budget_for_hardware(16 * GIB) == 8 * GIB
    assert budget_for_hardware(128 * GIB) > 4 * GIB
    assert budget_for_hardware(128 * GIB) == 64 * GIB


def test_under_minimum_memory_raises_value_error() -> None:
    with pytest.raises(ValueError, match="minimum 8 GiB"):
        budget_for_hardware(7 * GIB)

    with pytest.raises(ValueError, match="minimum 8 GiB"):
        budget_for_hardware(0)


def test_budget_function_has_no_preset_id_parameter() -> None:
    sig = inspect.signature(budget_for_hardware)
    assert "preset_id" not in sig.parameters
    assert "preset" not in sig.parameters
    assert "total_bytes" in sig.parameters


def test_overlap_decision_requires_sufficient_budget() -> None:
    # 8 GiB hardware gives 4 GiB budget
    budget = budget_for_hardware(8 * GIB)
    footprint = ComponentFootprint(
        asr_bytes=int(2.5 * GIB),
        tts_bytes=int(2.5 * GIB),
        device="mps",
    )
    # Total required: 5 GiB > 4 GiB budget -> cannot overlap safely
    decision, reason = can_overlap_heavy_compute(budget, footprint)
    assert decision is False
    assert "exceeds" in reason.lower()

    # 32 GiB hardware gives 16 GiB budget -> can overlap
    large_budget = budget_for_hardware(32 * GIB)
    large_decision, large_reason = can_overlap_heavy_compute(large_budget, footprint)
    assert large_decision is True
    assert "within budget" in large_reason.lower()


def test_overlap_decision_accounts_for_diarization() -> None:
    budget = budget_for_hardware(16 * GIB)  # 8 GiB budget
    footprint_with_diarization = ComponentFootprint(
        asr_bytes=int(3.5 * GIB),
        tts_bytes=int(3.5 * GIB),
        diarization_bytes=int(1.5 * GIB),
        device="mps",
    )
    # Total required: 8.5 GiB > 8 GiB budget
    decision, _ = can_overlap_heavy_compute(budget, footprint_with_diarization)
    assert decision is False


def test_single_asr_still_must_fit_the_whole_service_budget() -> None:
    budget = budget_for_hardware(8 * GIB)
    footprint = ComponentFootprint(
        asr_bytes=5 * GIB,
        tts_bytes=0,
        diarization_bytes=1 * GIB,
    )

    decision, reason = can_overlap_heavy_compute(budget, footprint)

    assert decision is False
    assert "exceeds" in reason.lower()


def test_cpu_and_mps_identities_are_distinct() -> None:
    mps_fp = ComponentFootprint(asr_bytes=2 * GIB, device="mps")
    cpu_fp = ComponentFootprint(asr_bytes=2 * GIB, device="cpu")
    assert mps_fp.device != cpu_fp.device


def test_unknown_enabled_component_forces_conservative_serialization() -> None:
    footprint = ComponentFootprint(asr_bytes=None, tts_bytes=2 * GIB)

    decision, reason = can_overlap_heavy_compute(8 * GIB, footprint)

    assert decision is False
    assert "unknown" in reason.lower()


def test_component_footprint_rejects_negative_or_boolean_values() -> None:
    with pytest.raises(ValueError, match="footprint"):
        ComponentFootprint(asr_bytes=-1)
    with pytest.raises(ValueError, match="footprint"):
        ComponentFootprint(asr_bytes=True)  # type: ignore[arg-type]
