"""Compare complete GitHub CI runs against the strictly-below-half time target.

Read-only: fetches run metadata via gh; never starts or modifies a workflow.
Exit 0: verified timing target; exit 1: too slow; exit 2: invalid/incomplete evidence.
Coverage and test-count evidence still need the corresponding run logs.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime
from typing import Any

COMMON_CHECKS = {
    "Change Scope",
    "Quality Gates",
    "Test (macos-26 / Python 3.14.7)",
    "Package wheel artifact",
    "Gate Summary",
}


def elapsed(run: dict[str, Any], *, optimized: bool) -> float:
    if run.get("workflowName") != "CI":
        raise ValueError("run is not the CI workflow")
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise ValueError("run must be completed and successful")
    jobs = run.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        raise ValueError("missing job evidence")
    if any(not isinstance(job, dict) for job in jobs):
        raise ValueError("invalid job evidence")
    names = {job.get("name") for job in jobs}
    expected = COMMON_CHECKS | (
        {"Swift Package Tests", "macOS App Build"}
        if optimized else {"macOS App Build & Tests"}
    )
    missing = expected - names
    if missing:
        raise ValueError(f"missing required checks: {', '.join(sorted(missing))}")
    if any(
        job.get("status") != "completed" or job.get("conclusion") != "success"
        for job in jobs
    ):
        raise ValueError("every job must complete successfully; partial CI is not comparable")
    created = datetime.fromisoformat(run["createdAt"])
    if created.tzinfo is None:
        raise ValueError("run timestamp must include a timezone")
    completed = [datetime.fromisoformat(job["completedAt"]) for job in jobs]
    if any(end.tzinfo is None or end <= created for end in completed):
        raise ValueError("invalid job completion timestamps")
    # Includes queue/setup/post-actions once. updatedAt is mutable metadata, and
    # summing job durations would overcount the intentionally parallel work.
    return (max(completed) - created).total_seconds()


def compare(
    baseline: dict[str, Any], candidate: dict[str, Any], candidate_sha: str
) -> dict[str, Any]:
    if not re.fullmatch(r"[0-9a-f]{40}", candidate_sha):
        raise ValueError("candidate commit must be a complete SHA")
    if candidate.get("headSha") != candidate_sha:
        raise ValueError("candidate run does not match the requested commit")
    before = elapsed(baseline, optimized=False)
    after = elapsed(candidate, optimized=True)
    return {
        "baseline_run": baseline["databaseId"],
        "candidate_run": candidate["databaseId"],
        "candidate_sha": candidate_sha,
        "baseline_seconds": before,
        "candidate_seconds": after,
        "target_seconds_exclusive": before * 0.5,
        "reduction_percent": 100 * (1 - after / before),
        "passed": after < before * 0.5,
    }


def read_run(run_id: int) -> dict[str, Any]:
    output = subprocess.check_output(
        [
            "gh", "run", "view", str(run_id), "--json",
            "databaseId,workflowName,headSha,status,conclusion,createdAt,jobs",
        ],
        text=True,
        timeout=60,
    )
    run = json.loads(output)
    if not isinstance(run, dict):
        raise ValueError("invalid GitHub run metadata")
    return run


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-run", type=int, required=True)
    parser.add_argument("--candidate-run", type=int, required=True)
    parser.add_argument("--candidate-sha", required=True)
    args = parser.parse_args()
    try:
        result = compare(
            read_run(args.baseline_run), read_run(args.candidate_run), args.candidate_sha
        )
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        print(f"CI timing evidence rejected: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
