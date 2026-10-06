from __future__ import annotations

import importlib.util
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "check_ci_efficiency", ROOT / "scripts/check_ci_efficiency.py"
)
assert SPEC is not None and SPEC.loader is not None
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

SHA = "a" * 40


def _run(seconds: float, *, optimized: bool = False) -> dict:
    names = [
        "Change Scope", "Quality Gates", "Test (macos-26 / Python 3.14.7)",
        "Package wheel artifact", "Gate Summary",
    ]
    names += (
        ["Swift Package Tests", "macOS App Build"]
        if optimized else ["macOS App Build & Tests"]
    )
    created = datetime(2026, 10, 6, tzinfo=UTC)
    completed = (created + timedelta(seconds=seconds)).isoformat()
    return {
        "databaseId": 2 if optimized else 1,
        "workflowName": "CI",
        "status": "completed",
        "conclusion": "success",
        "headSha": SHA,
        "createdAt": created.isoformat(),
        # Metadata may be updated later; it must not change execution duration.
        "updatedAt": (created + timedelta(days=1)).isoformat(),
        "jobs": [
            {"name": name, "status": "completed", "conclusion": "success",
             "startedAt": created.isoformat(), "completedAt": completed}
            for name in names
        ],
    }


def test_gate_counts_parallel_jobs_once_and_includes_queue() -> None:
    baseline = _run(525)
    candidate = _run(262, optimized=True)
    for job in candidate["jobs"]:
        job["startedAt"] = (
            datetime(2026, 10, 6, tzinfo=UTC) + timedelta(seconds=20)
        ).isoformat()
    result = checker.compare(baseline, candidate, SHA)
    assert result["baseline_seconds"] == 525
    assert result["candidate_seconds"] == 262
    assert result["reduction_percent"] > 50
    assert result["passed"] is True


@pytest.mark.parametrize("seconds", [262.5, 263, 525])
def test_gate_refuses_a_reduction_that_is_not_below_half(seconds: float) -> None:
    result = checker.compare(_run(525), _run(seconds, optimized=True), SHA)
    assert result["passed"] is False


@pytest.mark.parametrize("state", ["skipped", "failure", "cancelled", ""])
def test_gate_rejects_missing_or_non_successful_checks(state: str) -> None:
    candidate = _run(100, optimized=True)
    candidate["jobs"][0]["conclusion"] = state
    with pytest.raises(ValueError):
        checker.compare(_run(525), candidate, SHA)


def test_gate_rejects_partial_ci_or_the_wrong_commit() -> None:
    candidate = _run(100, optimized=True)
    candidate["jobs"] = candidate["jobs"][:-1]
    with pytest.raises(ValueError, match="missing"):
        checker.compare(_run(525), candidate, SHA)
    with pytest.raises(ValueError, match="commit"):
        checker.compare(_run(525), _run(100, optimized=True), "b" * 40)


@pytest.mark.parametrize("field", ["status", "workflowName", "conclusion"])
def test_gate_rejects_unfinished_failed_or_unrelated_runs(field: str) -> None:
    candidate = _run(100, optimized=True)
    candidate[field] = "unexpected"
    with pytest.raises(ValueError):
        checker.compare(_run(525), candidate, SHA)
