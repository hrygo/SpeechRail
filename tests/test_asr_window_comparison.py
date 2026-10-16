"""Paired evidence resamples meetings, never repeated runs as new meetings."""

import sys
from copy import deepcopy
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf.compare_asr_windows import compare_results


def evidence(errors):
    return {
        "profile": "quality",
        "evidence_mode": "real",
        "measurement_completed": True,
        "warmup_completed": True,
        "model_identity": {"snapshot": "pinned"},
        "sessions": [
            {
                "id": f"meeting-{i}",
                "repeat": 1,
                "wire_pcm_sha256": str(i) * 64,
                "reference_text_sha256": "a" * 64,
                "quality_metrics": {
                    "normalized": {
                        "reference_characters": 100,
                        "character_errors": count,
                        "cer": count / 100,
                    }
                },
            }
            for i, count in enumerate(errors)
        ],
    }


def test_paired_cli_reports_micro_and_whole_session_interval():
    result = compare_results(evidence([20, 30, 40]), evidence([10, 20, 30]), draws=100)
    assert result["normalized_cer"]["baseline_micro"] == 0.3
    assert result["normalized_cer"]["candidate_micro"] == 0.2
    assert result["normalized_cer"]["paired"]["ci95"][1] < 0
    assert result["normalized_cer"]["paired"]["session_count"] == 3
    assert result["quality_enable_gate"] == "unset"


def test_repeats_do_not_inflate_independent_sessions_or_confidence():
    old, new = evidence([20]), evidence([10])
    for payload in (old, new):
        for repeat in (2, 3):
            row = deepcopy(payload["sessions"][0])
            row["repeat"] = repeat
            payload["sessions"].append(row)
    result = compare_results(old, new, draws=100)
    assert result["independent_sessions"] == 1 and result["paired_runs"] == 3
    assert result["normalized_cer"]["paired"] == "insufficient_independent_sessions"


@pytest.mark.parametrize(
    "change", ["wire", "reference", "profile", "incomplete", "missing", "duplicate"]
)
def test_nonpaired_or_incomplete_evidence_is_rejected(change):
    old, new = evidence([20, 30]), evidence([10, 20])
    if change == "wire":
        new["sessions"][0]["wire_pcm_sha256"] = "f" * 64
    if change == "reference":
        new["sessions"][0]["reference_text_sha256"] = "f" * 64
    if change == "profile":
        new["profile"] = "fast"
    if change == "incomplete":
        new["measurement_completed"] = False
    if change == "missing":
        new["sessions"].pop()
    if change == "duplicate":
        new["sessions"].append(deepcopy(new["sessions"][0]))
    with pytest.raises(ValueError):
        compare_results(old, new, draws=100)
