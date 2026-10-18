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
from importlib.metadata import version
from pathlib import Path
from typing import Any, cast

from meeting_evaluation_identity import _freeze, _thaw, canonical_digest
from meeting_latency_cohort import finish_configuration, validate_finish_report
from meeting_latency_policy import latency_policy, weighted_p95

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


def joint_comparison_configuration(
    pipeline_policy: Mapping[str, Any],
    feed_policy: Mapping[str, Any],
) -> dict[str, Any]:
    """Only scheduling mode/permission may differ between paired workloads."""
    value = finish_configuration(pipeline_policy, feed_policy)
    return {k: v for k, v in value.items() if k not in {"mode", "overlap_enabled"}}


def _sources() -> dict[str, str]:
    root = Path(__file__).parent
    return {
        "numpy_version_sha256": hashlib.sha256(version("numpy").encode()).hexdigest(),
        **{
            name: hashlib.sha256((root / name).read_bytes()).hexdigest()
            for name in (
                "meeting_abba.py",
                "meeting_evaluation_identity.py",
                "meeting_latency_policy.py",
                "bench_asr_diarization_overlap.py",
                "meeting_pcm_feed.py",
                "meeting_latency_cohort.py",
                "meeting_quality_metrics.py",
            )
        },
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
        joint_policies: Mapping[str, Any] | None = None,
        joint_comparison_sha256: str | None = None,
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
        joint = _snapshot(joint_policies) if joint_policies is not None else None
        if joint is None and joint_comparison_sha256 is not None:
            raise ValueError("joint comparison requires complete policies")
        if joint is not None:
            _sha(joint_comparison_sha256)
            if not isinstance(joint, dict) or set(joint) != groups:
                raise ValueError("joint policies must cover all ABBA sources")
            common: dict[str, str] = {}
            for modes in joint.values():
                if not isinstance(modes, dict) or set(modes) != {"serial", "overlap"}:
                    raise ValueError("joint policies must include both modes")
                for mode, binding in modes.items():
                    if not isinstance(binding, dict) or set(binding) != {
                        "pipeline_policy_sha256",
                        "pipeline_configuration_sha256",
                    }:
                        raise ValueError("joint policy binding incomplete")
                    for value in binding.values():
                        _sha(value)
                    digest = binding["pipeline_configuration_sha256"]
                    if common.setdefault(mode, digest) != digest:
                        raise ValueError("joint common configuration differs between sources")
        context = {
            "schema_version": 2,
            "controls": control,
            "feed_configuration": feed,
            "sources": source_rows,
            "conditions": list(conditions),
            "blocks_per_source": blocks_per_source,
            "source_digests": _sources(),
            "latency_policy": latency_policy(),
            "joint_policies": joint,
            "joint_comparison_sha256": joint_comparison_sha256,
            "statistics": {
                "unit": "source_meeting_group",
                "within_source": "mode_max_all_repeats",
                "point": "equal_source_inverse_cdf_p95_serial_minus_overlap",
                "resampling": "paired_same_indices_for_both_modes",
                "numpy_version": version("numpy"),
                "rng": "PCG64",
                "seed": 1717,
                "draws": 10000,
                "interval": "two_sided_percentile_95_linear_2.5_97.5",
                "conditions": "separate_no_pooling",
            },
            "condition_scope": "declared_per_execution_not_inferred_from_first_run",
            "block_order": list(_ORDER),
            "run_scope_order": "next_source_after_previous_validation_and_joint_final_ack",
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
        self._joint = cast(Mapping[str, Any] | None, _freeze(joint))
        self._joint_comparison_sha = joint_comparison_sha256
        self._receipts: list[dict[str, Any]] = []
        self._reports: set[str] = set()
        self._last_run_end: float | None = None

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
            or value["schema_version"] != 2
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
            or (self._last_run_end is not None and origin < self._last_run_end)
        ):
            raise ValueError("ABBA source clock/order differs")
        schedule_origin = _number(value.get("schedule_origin_at"))
        callback_ends: dict[str, float] = {}
        validation_ends: dict[str, float] = {}
        for name, lane in workloads.items():
            if not isinstance(lane, dict):
                raise ValueError("invalid ABBA workload")
            start, end, elapsed = (
                _number(lane.get(k))
                for k in ("started_at_seconds", "ended_at_seconds", "elapsed_seconds")
            )
            validated = _number(lane.get("validated_at_seconds"))
            _sha(lane.get("report_sha256"))
            if (
                start < 0
                or end < start
                or validated < end
                or schedule_origin + end + 1e-6 < target
                or not math.isclose(end - start, elapsed, rel_tol=0, abs_tol=1e-6)
            ):
                raise ValueError("ABBA workload timing differs")
            callback_ends[name] = max(0.0, schedule_origin + end - target)
            validation_ends[name] = max(0.0, schedule_origin + validated - target)
        joint_observation = None
        if self._joint is not None and row["mode"] in {"serial", "overlap"}:
            if (
                canonical_digest(
                    joint_comparison_configuration(
                        value.get("pipeline_policy", {}),
                        value["pcm_feed"],
                    )
                )
                != self._joint_comparison_sha
            ):
                raise ValueError("ABBA joint comparison configuration differs")
            binding = self._joint[row["source_group_sha256"]][row["mode"]]
            joint_observation = validate_finish_report(
                report=value,
                mode=row["mode"],
                pcm_sha256=row["pcm_sha256"],
                expected_samples=row["samples"],
                **dict(binding),
            )
        if joint_observation is not None:
            marks = value["timing_observations"]["milestones_at"]
            if (
                _number(marks["asr_callback_complete"]) - target > callback_ends["asr"] + 1e-6
                or _number(marks["dia_scope_closed"]) - target
                > validation_ends["diarization"] + 1e-6
            ):
                raise ValueError("ABBA owned scope exceeds outer callback validation")
        relative_tail = {"asr": callback_ends.get("asr"), "diarization": None}
        if row["mode"] == "diarization-only":
            relative_tail["diarization"] = validation_ends["diarization"]
        elif joint_observation is not None and joint_observation["status"] == "completed":
            relative_tail["diarization"] = max(
                0.0,
                _number(value["timing_observations"]["milestones_at"]["dia_scope_closed"]) - target,
            )
        digest = canonical_digest(value)
        if digest in self._reports:
            raise ValueError("ABBA report reused")
        self._verify()
        self._reports.add(digest)
        final_ack = (
            target + joint_observation["finish_seconds"]
            if joint_observation is not None and joint_observation["finish_seconds"] is not None
            else offered
        )
        self._last_run_end = max(offered, target + max(validation_ends.values()), final_ack)
        self._receipts.append(
            {
                "run_sha256": row["run_sha256"],
                "status": "failed"
                if joint_observation is not None and joint_observation["status"] != "completed"
                else "completed",
                "report_sha256": digest,
                "joint_finish": joint_observation,
                "relative_tail": relative_tail,
            }
        )

    def _joint_summary(self, condition: str, receipts: Mapping[str, Any]) -> dict[str, Any]:
        groups = [row["source_group_sha256"] for row in self.registration()["sources"]]
        if self._joint is None:
            return {
                "status": "not_observed",
                "source_groups": len(groups),
                "paired_interval_seconds": None,
                "benefit_supported": False,
            }
        outcomes = []
        for group in groups:
            runs = [
                r
                for r in self._runs
                if r["condition"] == condition and r["source_group_sha256"] == group
            ]
            complete = all(
                receipts.get(r["run_sha256"], {}).get("status") == "completed" for r in runs
            )
            values = {}
            for mode in ("serial", "overlap"):
                times = [
                    receipts.get(r["run_sha256"], {}).get("joint_finish", {})
                    for r in runs
                    if r["mode"] == mode
                ]
                values[mode] = max(t["finish_seconds"] for t in times) if complete else None
            outcomes.append({"source_group_sha256": group, **values})
        failed = sum(r["serial"] is None or r["overlap"] is None for r in outcomes)
        p95 = {
            mode: weighted_p95([(1, r[mode]) for r in outcomes]) for mode in ("serial", "overlap")
        }
        worst = {
            mode: None if failed else max(r[mode] for r in outcomes)
            for mode in ("serial", "overlap")
        }
        gates = {
            mode: "diagnostic_pass"
            if not failed
            and p95[mode] is not None
            and p95[mode] <= latency_policy()["finish_p95_seconds"]
            and worst[mode] <= latency_policy()["finish_hard_seconds"]
            else "no-go"
            for mode in ("serial", "overlap")
        }
        interval, difference = None, None
        if not failed:
            import numpy as np

            # The same sampled source indices preserve pairing and independent N.
            serial = np.array([r["serial"] for r in outcomes], dtype=float)
            overlap = np.array([r["overlap"] for r in outcomes], dtype=float)
            indices = np.random.Generator(np.random.PCG64(1717)).integers(
                0, len(groups), size=(10000, len(groups))
            )
            rank = (95 * len(groups) + 99) // 100 - 1
            draws = (
                np.sort(serial[indices], axis=1)[:, rank]
                - np.sort(overlap[indices], axis=1)[:, rank]
            )
            interval = [float(v) for v in np.quantile(draws, [0.025, 0.975], method="linear")]
            serial_p95, overlap_p95 = p95["serial"], p95["overlap"]
            assert serial_p95 is not None and overlap_p95 is not None
            difference = serial_p95 - overlap_p95
        return {
            "status": "no-go" if failed else "diagnostic_not_certified",
            "source_groups": len(groups),
            "failed_source_groups": failed,
            "source_outcomes": outcomes,
            "serial_p95_seconds": p95["serial"],
            "overlap_p95_seconds": p95["overlap"],
            "serial_worst_seconds": worst["serial"],
            "overlap_worst_seconds": worst["overlap"],
            "absolute_finish_gate": gates,
            "primary_difference_seconds": difference,
            "paired_interval_seconds": interval,
            "benefit_supported": interval is not None and interval[0] > 0,
        }

    def _relative_summary(self, condition: str, receipts: Mapping[str, Any]) -> dict[str, Any]:
        groups = [r["source_group_sha256"] for r in self.registration()["sources"]]
        if self._joint is None:
            return {
                "status": "not_observed",
                "source_groups": len(groups),
                "asr": {"gate": "not_observed"},
                "diarization": {"gate": "not_observed"},
            }
        outcomes = []
        for group in groups:
            runs = [
                r
                for r in self._runs
                if r["condition"] == condition and r["source_group_sha256"] == group
            ]
            complete = all(
                receipts.get(r["run_sha256"], {}).get("status") == "completed" for r in runs
            )
            outcome: dict[str, Any] = {"source_group_sha256": group}
            for mode, lane, key in (
                ("serial", "asr", "asr_serial"),
                ("overlap", "asr", "asr_overlap"),
                ("diarization-only", "diarization", "dia_only"),
                ("overlap", "diarization", "dia_overlap"),
            ):
                values = [
                    receipts.get(r["run_sha256"], {}).get("relative_tail", {}).get(lane)
                    for r in runs
                    if r["mode"] == mode
                ]
                outcome[key] = (
                    max(values) if complete and all(v is not None for v in values) else None
                )
            outcomes.append(outcome)
        failed = sum(
            any(r[k] is None for k in ("asr_serial", "asr_overlap", "dia_only", "dia_overlap"))
            for r in outcomes
        )
        result: dict[str, Any] = {
            "status": "no-go" if failed else "diagnostic_not_certified",
            "source_groups": len(groups),
            "failed_source_groups": failed,
            "source_outcomes": outcomes,
        }
        for lane, baseline_key, candidate_key, baseline_mode, limit in (
            (
                "asr",
                "asr_serial",
                "asr_overlap",
                "serial",
                latency_policy()["asr_relative_p95_max"],
            ),
            (
                "diarization",
                "dia_only",
                "dia_overlap",
                "diarization-only",
                latency_policy()["diarization_relative_p95_max"],
            ),
        ):
            baseline = weighted_p95([(1, r[baseline_key]) for r in outcomes])
            candidate = weighted_p95([(1, r[candidate_key]) for r in outcomes])
            passed = (
                not failed
                and baseline is not None
                and candidate is not None
                and candidate <= baseline * limit
            )
            result[lane] = {
                "baseline_mode": baseline_mode,
                "candidate_mode": "overlap",
                "max_ratio": limit,
                "baseline_p95_seconds": baseline,
                "candidate_p95_seconds": candidate,
                "ratio": candidate / baseline if baseline and candidate is not None else None,
                "gate": "diagnostic_pass" if passed else "no-go",
            }
        return result

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
                "joint_finish": self._joint_summary(condition, receipts),
                "relative_lane_tail": self._relative_summary(condition, receipts),
            }
        missing = len(self._runs) - len(receipts)
        failed = sum(r["status"] == "failed" for r in receipts.values())
        return {
            "schema_version": 2,
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
