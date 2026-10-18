"""Frozen ABBA order and host-report ledger, never benchmark certification.

No workload is executed and no audio/model/reference is opened here. Conditions,
model identities and workload policy are declared controls, not attestations.
Host callback duration cannot substitute for joint tail-to-final latency.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, cast

from meeting_evaluation_identity import _freeze, _thaw, canonical_digest
from meeting_latency_policy import latency_policy

_CONTROLS = {
    "attempt_sha256",
    "source_pool_sha256",
    "asr_candidate_sha256",
    "diarization_candidate_sha256",
    "scorer_policy_sha256",
    "workload_policy_sha256",
}
_FEED = {"clock_source", "sample_rate", "chunk_samples", "queue_chunks", "max_lateness_seconds"}
_ORDER = ("asr-only", "diarization-only", "serial", "overlap", "overlap", "serial")
_LANES = {
    "asr-only": {"asr"},
    "diarization-only": {"diarization"},
    "serial": {"asr", "diarization"},
    "overlap": {"asr", "diarization"},
}


def _snapshot(value: Any, limit: int = 16 * 1024 * 1024) -> Any:
    raw = json.dumps(
        _thaw(_freeze(value)),
        sort_keys=True,
        allow_nan=False,
        ensure_ascii=False,
        separators=(",", ":"),
    )
    if len(raw.encode()) > limit:
        raise ValueError("ABBA metadata exceeds budget")
    return json.loads(raw)


def _sha(value: Any) -> str:
    if type(value) is not str or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError("ABBA identity must be SHA-256")
    return value


def _integer(value: Any, low: int, high: int) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValueError("invalid ABBA count")
    return value


def _number(value: Any) -> float:
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError("invalid ABBA time")
    return float(value)


def _sources() -> dict[str, str]:
    root = Path(__file__).parent
    return {
        name: hashlib.sha256((root / name).read_bytes()).hexdigest()
        for name in (
            "meeting_abba.py",
            "meeting_evaluation_identity.py",
            "meeting_latency_policy.py",
            "bench_asr_diarization_overlap.py",
            "meeting_pcm_feed.py",
        )
    }


class AbbaLedger:
    """Pre-register balanced blocks; keep failures and missing runs visible.

    One fixture per independent group; repeats never enlarge independent N.
    Separate baselines precede each ABBA block, in the registered condition.
    Cold/warm setup and actual model/production identity require later evidence.
    """

    def __init__(
        self,
        *,
        controls: Mapping[str, Any],
        sources: Sequence[Mapping[str, Any]],
        conditions: Sequence[str],
        blocks_per_source: int,
        feed_configuration: Mapping[str, Any],
    ) -> None:
        control, feed, source_rows = (
            _snapshot(controls),
            _snapshot(feed_configuration),
            _snapshot(sources),
        )
        if not isinstance(control, dict) or set(control) != _CONTROLS:
            raise ValueError("ABBA controls incomplete")
        for value in control.values():
            _sha(value)
        if not isinstance(feed, dict) or set(feed) != _FEED:
            raise ValueError("ABBA feed controls incomplete")
        if feed["clock_source"] not in {"injected", "monotonic"}:
            raise ValueError("ABBA clock missing")
        _integer(feed["sample_rate"], 16000, 16000)
        _integer(feed["chunk_samples"], 1, 16000)
        _integer(feed["queue_chunks"], 1, 64)
        if not 0 < _number(feed["max_lateness_seconds"]) <= 1:
            raise ValueError("invalid ABBA lateness")
        conditions = tuple(conditions)
        if (
            not 1 <= len(conditions) <= 2
            or len(set(conditions)) != len(conditions)
            or any(c not in {"cold", "warm"} for c in conditions)
        ):
            raise ValueError("ABBA conditions incomplete")
        _integer(blocks_per_source, 1, 8)
        if not isinstance(source_rows, list) or not 8 <= len(source_rows) <= 24:
            raise ValueError("ABBA requires 8 to 24 independent groups")
        groups, pcms, fixtures = set(), set(), set()
        for row in source_rows:
            if not isinstance(row, dict) or set(row) != {
                "source_group_sha256",
                "fixture_sha256",
                "pcm_sha256",
                "samples",
            }:
                raise ValueError("ABBA source controls incomplete")
            for key in ("source_group_sha256", "fixture_sha256", "pcm_sha256"):
                _sha(row[key])
            _integer(row["samples"], 1, 600 * 16000)
            if (
                row["source_group_sha256"] in groups
                or row["pcm_sha256"] in pcms
                or row["fixture_sha256"] in fixtures
            ):
                raise ValueError("ABBA independent source alias")
            groups.add(row["source_group_sha256"])
            pcms.add(row["pcm_sha256"])
            fixtures.add(row["fixture_sha256"])
        context = {
            "schema_version": 1,
            "controls": control,
            "feed_configuration": feed,
            "sources": source_rows,
            "conditions": list(conditions),
            "blocks_per_source": blocks_per_source,
            "source_digests": _sources(),
            "latency_policy": latency_policy(),
            "condition_scope": "declared_per_execution_not_inferred_from_first_run",
            "block_order": list(_ORDER),
            "source_weight": "one_independent_group",
            "split": "development",
        }
        context_sha = canonical_digest(context)
        runs: list[dict[str, Any]] = []
        for condition in conditions:
            for repeat in range(blocks_per_source):
                for source in source_rows:
                    block = canonical_digest(
                        {
                            "context": context_sha,
                            "condition": condition,
                            "repeat": repeat,
                            "source": source,
                        }
                    )
                    for position, mode in enumerate(_ORDER):
                        row = {
                            **source,
                            "condition": condition,
                            "repetition": repeat,
                            "block_sha256": block,
                            "position": position,
                            "mode": mode,
                            "ordinal": len(runs),
                        }
                        runs.append(
                            {
                                **row,
                                "run_sha256": canonical_digest(
                                    {"context": context_sha, "run": row}
                                ),
                            }
                        )
        seconds = sum(row["samples"] for row in runs) / 16000
        self._registration_json = json.dumps(
            {
                **context,
                "runs": runs,
                "blocks_per_condition": len(groups) * blocks_per_source,
                "minimum_pcm_feed_seconds": seconds,
                "minimum_joint_pcm_feed_seconds": seconds * 4 / 6,
                "budget_excludes": [
                    "load",
                    "cleanup",
                    "warmup",
                    "quality_review",
                    "production_revalidation",
                ],
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        self._plan_sha = canonical_digest(json.loads(self._registration_json))
        self._runs = tuple(cast(Mapping[str, Any], _freeze(r)) for r in runs)
        self._feed = cast(Mapping[str, Any], _freeze(feed))
        self._sources = _freeze(context["source_digests"])
        self._receipts: list[dict[str, Any]] = []
        self._reports: set[str] = set()
        self._last_source_end: float | None = None

    def _verify(self) -> None:
        if _sources() != self._sources:
            raise ValueError("ABBA sources changed")

    def registration(self) -> dict[str, Any]:
        return {**json.loads(self._registration_json), "plan_sha256": self._plan_sha}

    def _next(self, run_sha256: str) -> Mapping[str, Any]:
        self._verify()
        if (
            len(self._receipts) >= len(self._runs)
            or _sha(run_sha256) != self._runs[len(self._receipts)]["run_sha256"]
        ):
            raise ValueError("ABBA run differs from registered order")
        return self._runs[len(self._receipts)]

    def fail(self, run_sha256: str) -> None:
        """Record a failed attempt without an exception body, transcript or path."""
        row = self._next(run_sha256)
        self._receipts.append(
            {"run_sha256": row["run_sha256"], "status": "failed", "report_sha256": None}
        )

    def observe(self, run_sha256: str, *, condition: str, report: Mapping[str, Any]) -> None:
        row, value = self._next(run_sha256), _snapshot(report)
        if not isinstance(value, dict):
            raise ValueError("invalid ABBA report")
        if (
            condition != row["condition"]
            or value.get("mode") != row["mode"]
            or type(value.get("schema_version")) is not int
            or value["schema_version"] != 1
            or value.get("schedule_completed") is not True
            or value.get("clock_source") != self._feed["clock_source"]
            or any(
                value.get(k) is not False
                for k in (
                    "runtime_identity_verified",
                    "certification_eligible",
                    "joint_latency_observed",
                    "worker_reaping_verified",
                )
            )
        ):
            raise ValueError("ABBA diagnostic report differs from registration")
        feed, workloads = value.get("pcm_feed"), value.get("workloads")
        if not isinstance(feed, dict) or not isinstance(workloads, dict):
            raise ValueError("ABBA requires actual single/joint PCM reports")
        feed_policy = {
            **dict(self._feed),
            "source_pcm_sha256": row["pcm_sha256"],
            "source_samples": row["samples"],
        }
        if (
            any(type(feed.get(k)) is not type(v) or feed[k] != v for k, v in feed_policy.items())
            or feed.get("policy_sha256") != canonical_digest(feed_policy)
            or set(workloads) != _LANES[row["mode"]]
            or feed.get("delivered_samples") != dict.fromkeys(workloads, row["samples"])
            or any(type(v) is not int for v in feed["delivered_samples"].values())
        ):
            raise ValueError("ABBA PCM/feed/lanes differ")
        origin = _number(feed.get("source_origin_at"))
        target = _number(feed.get("source_end_target_at"))
        offered = _number(feed.get("source_end_offered_at"))
        if (
            not math.isclose(target - origin, row["samples"] / 16000, rel_tol=0, abs_tol=1e-6)
            or not target <= offered <= target + self._feed["max_lateness_seconds"]
            or (self._last_source_end is not None and origin < self._last_source_end)
        ):
            raise ValueError("ABBA source clock/order differs")
        for lane in workloads.values():
            if not isinstance(lane, dict):
                raise ValueError("invalid ABBA workload")
            start, end, elapsed = (
                _number(lane.get(k))
                for k in ("started_at_seconds", "ended_at_seconds", "elapsed_seconds")
            )
            _sha(lane.get("report_sha256"))
            if (
                start < 0
                or end < start
                or not math.isclose(end - start, elapsed, rel_tol=0, abs_tol=1e-6)
            ):
                raise ValueError("ABBA workload timing differs")
        digest = canonical_digest(value)
        if digest in self._reports:
            raise ValueError("ABBA report reused")
        self._verify()
        self._reports.add(digest)
        self._last_source_end = offered
        self._receipts.append(
            {"run_sha256": row["run_sha256"], "status": "completed", "report_sha256": digest}
        )

    def summary(self) -> dict[str, Any]:
        self._verify()
        plan = self.registration()
        receipts = {r["run_sha256"]: r for r in self._receipts}
        conditions = {}
        for condition in plan["conditions"]:
            blocks: dict[str, list[str]] = {}
            for row in self._runs:
                if row["condition"] == condition:
                    blocks.setdefault(row["block_sha256"], []).append(row["run_sha256"])
            complete = sum(
                all(receipts.get(key, {}).get("status") == "completed" for key in ids)
                for ids in blocks.values()
            )
            conditions[condition] = {
                "expected_blocks": len(blocks),
                "complete_blocks": complete,
                "declared_source_groups": len(plan["sources"]),
            }
        missing = len(self._runs) - len(receipts)
        failed = sum(r["status"] == "failed" for r in receipts.values())
        return {
            "schema_version": 1,
            "plan_sha256": self._plan_sha,
            "status": "invalid" if missing or failed else "complete_metadata",
            "expected_runs": len(self._runs),
            "observed_runs": len(receipts),
            "missing_runs": missing,
            "failed_runs": failed,
            "conditions": conditions,
            "receipts_sha256": canonical_digest({"receipts": self._receipts}),
            "provenance": "declared_controls_and_host_report_consistency",
            "condition_setup_verified": False,
            "runtime_identity_verified": False,
            "certification_eligible": False,
            "quality_gate": "not_observed",
            "footprint": "not_observed",
            "primary_benefit_interval_seconds": None,
            "primary_benefit": latency_policy()["primary_benefit"],
            "selected_schedule": None,
        }
