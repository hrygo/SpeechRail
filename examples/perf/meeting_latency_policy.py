"""Pre-registered latency sampling; no model, audio or certification operations."""

from __future__ import annotations

import math
from collections.abc import Sequence
from typing import Any


def latency_policy() -> dict[str, Any]:
    return {
        "input_rate": 1.0,
        "stable_label_p95_seconds": 15.0,
        "stable_label_hard_seconds": 30.0,
        "finish_p95_seconds": 5.0,
        "finish_hard_seconds": 15.0,
        "asr_relative_p95_max": 1.05,
        "diarization_relative_p95_max": 1.1,
        "primary_benefit": "serial_minus_overlap_joint_tail_to_final",
        "relative_sampling": {
            "population": "one_owned_lane_completion_per_execution",
            "origin": "last_source_sample_target",
            "asr_completion": "host_callback_return_including_owned_cleanup",
            "asr_baseline": "serial",
            "asr_candidate": "overlap",
            "dia_single_completion": "host_callback_and_report_validation_joined",
            "dia_joint_completion": "actual_dia_scope_closed_not_relay",
            "dia_baseline": "diarization-only",
            "dia_candidate": "overlap",
            "aggregation": "source_mode_max_then_equal_source_inverse_cdf_p95",
            "missing": "infinite_with_original_source_weight_and_no_go",
            "zero_baseline": "candidate_zero_pass_else_fail_ratio_null",
        },
        "sampling": {
            "version": "sealed_owned_span_duration_v1",
            "stable_population": "all_nonempty_sealed_asr_units",
            "stable_weight": "owned_span_samples",
            "stable_origin": "owned_span_last_sample_target",
            "stable_completion": "joined_watermarks_and_stable_marker_sink_ack",
            "stable_missing_or_unknown": "failure_with_infinite_delay_and_original_weight",
            "quantile": "inverse_empirical_cdf_at_95_over_100",
            "stable_aggregation": "per_meeting_and_worst_no_cross_meeting_pooling",
            "finish_population": "one_final_ack_and_scope_close_per_execution",
            "finish_aggregation": "source_meeting_max_then_equal_source_p95_and_slowest",
            "finish_missing": "failure_with_infinite_delay_and_original_source_weight",
            "finish_origin": "last_source_sample_target",
            "asr_deletions": "independent_asr_quality_gate_not_synthetic_latency_units",
        },
    }


def weighted_p95(rows: Sequence[tuple[int, float | None]]) -> float | None:
    """None denotes positive infinity, never a dropped observation."""
    if len(rows) > 4096 or any(
        type(weight) is not int or weight <= 0
        or (value is not None and (
            type(value) not in (int, float) or not math.isfinite(value) or value < 0
        )) for weight, value in rows
    ):
        raise ValueError("invalid bounded latency samples")
    total = sum(weight for weight, _ in rows)
    cumulative = 0
    for weight, value in sorted(rows, key=lambda row: math.inf if row[1] is None else row[1]):
        cumulative += weight
        if cumulative * 100 >= total * 95:
            return value
    return None
