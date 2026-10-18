"""Frozen development finish cohorts; host consistency, never certification.

No audio, references, model or holdout is opened. JSON digests do not attest
loaded production bytes, faithful decoding, real capture or independent runs.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

from meeting_evaluation_identity import _freeze, _thaw, canonical_digest
from meeting_latency_policy import latency_policy, weighted_p95
from meeting_quality_metrics import _validate_policy

_SHA = re.compile(r"[0-9a-f]{64}\Z")
_ROW = {"fixture_id", "repetition", "pcm_sha256", "expected_samples", "pipeline_policy_sha256"}
_OBS = {
    "schema_version",
    "cohort_sha256",
    "execution_sha256",
    "report_sha256",
    "clock_source",
    "status",
    "finish_seconds",
    "runtime_identity_verified",
    "certification_eligible",
}
_FIELDS = [
    "kind",
    "start_sample",
    "end_sample",
    "sequence",
    "known",
    "text_sha256",
    "entered_at",
    "completed_at",
]


def _sha(value: Any) -> str:
    if type(value) is not str or not _SHA.fullmatch(value):
        raise ValueError("finish identity must be SHA-256")
    return value


def _obj(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("finish control must be an object")
    return value


def _int(value: Any, low: int, high: int) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValueError("invalid finish integer")
    return value


def _number(value: Any) -> float:
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError("invalid finish time")
    return float(value)


def _snapshot(value: Mapping[str, Any], limit: int = 16 * 1024 * 1024) -> dict[str, Any]:
    encoded = json.dumps(
        _thaw(_freeze(value)),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )
    if len(encoded.encode()) > limit:
        raise ValueError("finish evidence exceeds budget")
    return _obj(json.loads(encoded))


def finish_configuration(
    pipeline_policy: Mapping[str, Any],
    feed_policy: Mapping[str, Any],
) -> dict[str, Any]:
    """Remove only source bytes/length; retain input pacing and queue settings."""
    policy = _snapshot(pipeline_policy)
    return {
        **{k: v for k, v in policy.items() if k != "pcm_feed_policy_sha256"},
        "pcm_feed_configuration": {
            k: feed_policy.get(k)
            for k in (
                "clock_source",
                "sample_rate",
                "chunk_samples",
                "queue_chunks",
                "max_lateness_seconds",
            )
        },
    }


def _sources() -> dict[str, str]:
    root = Path(__file__).parent
    return {
        name: hashlib.sha256((root / name).read_bytes()).hexdigest()
        for name in (
            "meeting_latency_cohort.py",
            "meeting_latency_policy.py",
            "meeting_evaluation_identity.py",
            "meeting_quality_metrics.py",
        )
    }


@dataclass(frozen=True, slots=True, init=False)
class FinishCohort:
    _plan_json: str
    _cohort_sha256: str
    _context: Mapping[str, Any]
    _entries: Mapping[str, Any]
    _groups: tuple[str, ...]
    _source_digests: Mapping[str, str]

    def __init__(
        self,
        *,
        manifest: Mapping[str, Any],
        split_lock: Mapping[str, Any],
        scorer_policy: Mapping[str, Any],
        speakers_count: int,
        checkpoint: int,
        repetitions: int,
        asr_candidate_sha256: str,
        diarization_candidate_sha256: str,
        mode: str,
        executions: Sequence[Mapping[str, Any]],
        pipeline_configuration_sha256: str,
    ) -> None:
        _int(speakers_count, 1, 8)
        if type(checkpoint) is not int or checkpoint not in {6, 12, 18, 24}:
            raise ValueError("invalid finish development checkpoint")
        _int(repetitions, 1, 8)
        if mode not in {"serial", "overlap"} or not 1 <= len(executions) <= 4096:
            raise ValueError("invalid finish execution scope")
        policy = _snapshot(scorer_policy)
        _validate_policy(policy)
        manifest, lock = _snapshot(manifest), _snapshot(split_lock)
        _sha(manifest.get("source_catalog_sha256"))
        if (
            type(manifest.get("schema_version")) is not int
            or manifest["schema_version"] != 2
            or type(lock.get("schema_version")) is not int
            or lock["schema_version"] != 2
            or manifest.get("split") != "development"
            or canonical_digest(manifest) != lock.get("development_manifest_sha256")
            or canonical_digest(policy) != lock.get("scorer_policy_sha256")
            or manifest.get("scorer_policy_sha256") != lock.get("scorer_policy_sha256")
            or manifest.get("source_catalog_sha256") != lock.get("source_catalog_sha256")
        ):
            raise ValueError("finish development locks differ")
        groups = _obj(manifest.get("group_order")).get(str(speakers_count))
        if (
            not isinstance(groups, list)
            or not checkpoint <= len(groups) <= 1024
            or len({_sha(g) for g in groups}) != len(groups)
        ):
            raise ValueError("finish source prefix is incomplete")
        groups = groups[:checkpoint]
        fixtures = manifest.get("fixtures")
        if not isinstance(fixtures, list) or not 1 <= len(fixtures) <= 4096:
            raise ValueError("finish manifest fixtures exceed budget")
        selected, all_ids = {}, set()
        for item in fixtures:
            item = _obj(item)
            identifier = item.get("id")
            if (
                type(identifier) is not str
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", identifier)
                or identifier in all_ids
                or item.get("split") != "development"
            ):
                raise ValueError("finish fixture identity invalid")
            all_ids.add(identifier)
            count = _int(item.get("speakers_count"), 1, 8)
            group = _sha(item.get("source_group_id"))
            if count == speakers_count and group in groups:
                selected[identifier] = item
        if {r["source_group_id"] for r in selected.values()} != set(groups):
            raise ValueError("finish source prefix lacks fixtures")
        context = {
            "manifest_sha256": canonical_digest(manifest),
            "split_lock_sha256": canonical_digest(lock),
            "scorer_policy_sha256": canonical_digest(policy),
            "asr_candidate_sha256": _sha(asr_candidate_sha256),
            "diarization_candidate_sha256": _sha(diarization_candidate_sha256),
            "mode": mode,
            "speakers_count": speakers_count,
            "checkpoint": checkpoint,
            "repetitions": repetitions,
            "pipeline_configuration_sha256": _sha(pipeline_configuration_sha256),
        }
        rows: list[dict[str, Any]] = []
        seen: set[tuple[str, int]] = set()
        pcm_groups: dict[str, str] = {}
        configs: dict[str, tuple[str, int, str]] = {}
        for value in executions:
            row = _snapshot(value, 2048)
            if set(row) != _ROW or row["fixture_id"] not in selected:
                raise ValueError("finish execution differs from selected fixtures")
            fixture = selected[row["fixture_id"]]
            repetition = _int(row["repetition"], 0, repetitions - 1)
            key = row["fixture_id"], repetition
            if key in seen:
                raise ValueError("duplicate finish registration")
            seen.add(key)
            pcm, samples = _sha(row["pcm_sha256"]), _int(row["expected_samples"], 1, 600 * 16000)
            pipeline = _sha(row["pipeline_policy_sha256"])
            group = fixture["source_group_id"]
            if pcm_groups.setdefault(pcm, group) != group:
                raise ValueError("one PCM cannot be independent source groups")
            config = pcm, samples, pipeline
            if configs.setdefault(row["fixture_id"], config) != config:
                raise ValueError("fixture repetitions require identical source and policy")
            row.update(source_group_sha256=group, fixture_sha256=canonical_digest(fixture))
            rows.append(
                {
                    "execution_sha256": canonical_digest({"context": context, "execution": row}),
                    **row,
                }
            )
        expected = {(identifier, r) for identifier in selected for r in range(repetitions)}
        if seen != expected:
            raise ValueError("finish registration must include every fixture repetition")
        sources = _sources()
        rows.sort(
            key=lambda r: (groups.index(r["source_group_sha256"]), r["fixture_id"], r["repetition"])
        )
        plan = {
            "schema_version": 1,
            "context": context,
            "source_group_ids": groups,
            "source_digests": sources,
            "executions": rows,
        }
        object.__setattr__(self, "_plan_json", json.dumps(plan, sort_keys=True, allow_nan=False))
        object.__setattr__(self, "_cohort_sha256", canonical_digest(plan))
        object.__setattr__(self, "_context", cast(Mapping[str, Any], _freeze(context)))
        object.__setattr__(
            self,
            "_entries",
            cast(Mapping[str, Any], _freeze({row["execution_sha256"]: row for row in rows})),
        )
        object.__setattr__(self, "_groups", tuple(groups))
        object.__setattr__(self, "_source_digests", cast(Mapping[str, str], _freeze(sources)))

    def registration(self) -> dict[str, Any]:
        return _obj(json.loads(self._plan_json))

    def _verify_sources(self) -> None:
        if _sources() != self._source_digests:
            raise ValueError("finish aggregation sources changed")

    def observe(self, execution_sha256: str, report: Mapping[str, Any]) -> dict[str, Any]:
        self._verify_sources()
        execution = self._entries.get(_sha(execution_sha256))
        if execution is None:
            raise ValueError("unregistered finish execution")
        value = _snapshot(report)
        policy, feed = _obj(value.get("pipeline_policy")), _obj(value.get("pcm_feed"))
        timing = _obj(value.get("timing_observations"))
        diagnostics = _obj(timing.get("latency_diagnostics"))
        if (
            value.get("mode") != self._context["mode"]
            or policy.get("mode") != self._context["mode"]
            or canonical_digest(policy) != execution["pipeline_policy_sha256"]
            or value.get("pipeline_policy_sha256") != execution["pipeline_policy_sha256"]
            or canonical_digest(_obj(policy.get("latency"))) != canonical_digest(latency_policy())
            or feed.get("source_pcm_sha256") != execution["pcm_sha256"]
            or type(feed.get("source_samples")) is not int
            or feed["source_samples"] != execution["expected_samples"]
            or any(
                value.get(k) is not False
                for k in (
                    "runtime_identity_verified",
                    "certification_eligible",
                    "joint_latency_observed",
                    "worker_reaping_verified",
                )
            )
            or timing.get("clock_source") not in {"injected", "monotonic"}
            or timing["clock_source"] != feed.get("clock_source")
            or type(timing.get("schema_version")) is not int
            or timing["schema_version"] != 2
        ):
            raise ValueError("finish report differs from diagnostic registration")
        configuration = finish_configuration(policy, feed)
        expected_configuration = self._context["pipeline_configuration_sha256"]
        if canonical_digest(configuration) != expected_configuration:
            raise ValueError("finish pipeline configuration differs")
        if _int(feed.get("sample_rate"), 16000, 16000) != 16000:
            raise ValueError("finish input must be 16 kHz")
        _int(feed.get("chunk_samples"), 1, 16000)
        _int(feed.get("queue_chunks"), 1, 64)
        if not 0 < _number(feed.get("max_lateness_seconds")) <= 1:
            raise ValueError("finish source lateness budget differs")
        feed_policy = {
            k: feed.get(k)
            for k in (
                "clock_source",
                "sample_rate",
                "chunk_samples",
                "queue_chunks",
                "max_lateness_seconds",
                "source_pcm_sha256",
                "source_samples",
            )
        }
        if (
            canonical_digest(feed_policy) != feed.get("policy_sha256")
            or policy.get("pcm_feed_policy_sha256") != feed["policy_sha256"]
        ):
            raise ValueError("finish source policy differs")
        origin = _number(timing.get("source_origin_at"))
        samples = execution["expected_samples"]
        if (
            not math.isclose(origin, _number(feed.get("source_origin_at")), rel_tol=0, abs_tol=1e-6)
            or not math.isclose(
                origin + samples / 16000,
                _number(feed.get("source_end_target_at")),
                rel_tol=0,
                abs_tol=1e-6,
            )
            or timing.get("record_fields") != _FIELDS
        ):
            raise ValueError("finish common source origin differs")
        records = timing.get("records")
        if not isinstance(records, list) or len(records) > 98304:
            raise ValueError("finish timing records exceed budget")
        acks, stable_sequences, unknown = [], set(), False
        texts: dict[int, tuple[int, int, bool, str, float]] = {}
        asr_through = dia_through = 0
        asr_ack = dia_ack = origin
        trace_complete = True
        stable_delays: list[tuple[int, float | None]] = []
        for row in records:
            if not isinstance(row, list) or len(row) != 8:
                raise ValueError("invalid finish timing record")
            if row[0] not in {
                "asr_sealed",
                "activity_watermark",
                "text",
                "stable_text",
                "asr_body_snapshot",
            }:
                raise ValueError("unknown finish timing record")
            if row[7] is None:
                trace_complete = False
                continue
            start, end = _int(row[1], 0, samples), _int(row[2], 0, samples)
            entered, finished = _number(row[6]), _number(row[7])
            if start > end or finished < entered or finished + 1e-6 < origin + end / 16000:
                raise ValueError("invalid final sink acknowledgement")
            if row[0] in {"asr_sealed", "activity_watermark"}:
                if _int(row[3], -1, -1) != -1 or row[4] is not None or row[5] is not None:
                    raise ValueError("invalid finish coverage record")
                if row[0] == "asr_sealed":
                    trace_complete &= start == asr_through and start < end and entered == finished
                    asr_through, asr_ack = end, finished
                else:
                    trace_complete &= start == dia_through
                    dia_through, dia_ack = end, finished
                continue
            if start == end:
                raise ValueError("empty finish publication")
            if row[0] == "text":
                sequence, text_hash = _int(row[3], 0, 4095), _sha(row[5])
                if type(row[4]) is not bool:
                    raise ValueError("invalid finish text disposition")
                trace_complete &= sequence not in texts
                texts[sequence] = (start, end, row[4], text_hash, finished)
                continue
            if row[0] == "stable_text":
                sequence = _int(row[3], 0, 4095)
                _sha(row[5])
                if type(row[4]) is not bool or sequence in stable_sequences:
                    raise ValueError("invalid or duplicate stable finish marker")
                stable_sequences.add(sequence)
                unknown = unknown or not row[4]
                text = texts.get(sequence)
                trace_complete &= (
                    text is not None
                    and text[:4] == (start, end, row[4], row[5])
                    and entered >= max(text[4], asr_ack, dia_ack)
                    and end <= min(asr_through, dia_through)
                )
                stable_delays.append((end - start, max(0.0, finished - origin - end / 16000)))
            else:
                # A replacement snapshot means attribution was withdrawn, even
                # if contradictory summary booleans still claim success.
                trace_complete = False
            acks.append(finished)
        marks = _obj(timing.get("milestones_at"))
        if set(marks) != {"asr_callback_complete", "dia_input_eof", "dia_scope_closed"}:
            raise ValueError("finish report lacks joined scopes")
        mark_times = {k: _number(v) for k, v in marks.items()}
        finish = diagnostics.get("finish_seconds")
        if finish is not None:
            finish = _number(finish)
            actual = max([origin, *acks, *mark_times.values()]) - origin - samples / 16000
            if finish < 0 or not math.isclose(finish, actual, rel_tol=0, abs_tol=1e-6):
                raise ValueError("finish summary differs from acknowledgement trace")
        expected_units = _int(timing.get("expected_text_units"), 0, 4096)
        stable_p95 = weighted_p95(stable_delays)
        completed = (
            trace_complete
            and asr_through == dia_through == samples
            and mark_times["asr_callback_complete"] >= max(asr_ack, origin + samples / 16000)
            and mark_times["dia_input_eof"] >= origin + samples / 16000
            and mark_times["dia_scope_closed"] >= max(dia_ack, mark_times["dia_input_eof"])
            and set(texts) == stable_sequences
            and stable_p95 is not None
            and stable_p95 <= latency_policy()["stable_label_p95_seconds"]
            and all(
                delay is not None and delay <= latency_policy()["stable_label_hard_seconds"]
                for _, delay in stable_delays
            )
            and not unknown
            and expected_units > 0
            and stable_sequences == set(range(expected_units))
            and finish is not None
            and diagnostics.get("finish_unresolved") is False
            and value.get("schedule_completed") is True
            and value.get("asr_complete") is True
            and value.get("live_attribution_complete") is True
            and value.get("asr_preserved_as_unknown") is False
            and value.get("diarization_failure") is None
            and value.get("joint_verdict") == "diagnostic_not_certified"
            and _obj(value.get("deadline_enforcement")).get("status") == "not_expired"
            and diagnostics.get("stable_gate") == "diagnostic_pass"
            and timing.get("text_delivery_verified") is True
            and timing.get("stable_delivery_verified") is True
            and type(timing.get("open_sink_deliveries")) is int
            and timing["open_sink_deliveries"] == 0
            and timing.get("failed_sink_deliveries") == {}
            and all(
                type(timing.get(k)) is int and timing[k] == samples
                for k in (
                    "source_samples_observed",
                    "asr_sealed_through",
                    "dia_stable_through",
                )
            )
        )
        observation = {
            "schema_version": 1,
            "cohort_sha256": self._cohort_sha256,
            "execution_sha256": execution_sha256,
            "report_sha256": canonical_digest(value),
            "clock_source": timing["clock_source"],
            "status": "completed" if completed else "failed",
            "finish_seconds": finish,
            "runtime_identity_verified": False,
            "certification_eligible": False,
        }
        self._verify_sources()
        return {**observation, "observation_sha256": canonical_digest(observation)}

    def aggregate(self, observations: Sequence[Mapping[str, Any]]) -> dict[str, Any]:
        self._verify_sources()
        if len(observations) > len(self._entries):
            raise ValueError("too many finish observations")
        seen, reports = {}, set()
        for item in observations:
            row = _snapshot(item, 4096)
            if set(row) != _OBS | {"observation_sha256"}:
                raise ValueError("finish observation fields differ")
            digest = _sha(row.pop("observation_sha256"))
            if (
                digest != canonical_digest(row)
                or row["cohort_sha256"] != self._cohort_sha256
                or type(row["schema_version"]) is not int
                or row["schema_version"] != 1
                or row["runtime_identity_verified"] is not False
                or row["certification_eligible"] is not False
                or row["status"] not in {"completed", "failed"}
                or row["clock_source"] not in {"injected", "monotonic"}
            ):
                raise ValueError("finish observation identity differs")
            execution, report_hash = _sha(row["execution_sha256"]), _sha(row["report_sha256"])
            if execution not in self._entries or execution in seen:
                raise ValueError("finish execution is unknown or duplicated")
            if report_hash in reports:
                raise ValueError("finish report reused across executions")
            if row["finish_seconds"] is not None:
                if _number(row["finish_seconds"]) < 0:
                    raise ValueError("negative finish observation")
            elif row["status"] == "completed":
                raise ValueError("completed finish observation needs time")
            reports.add(report_hash)
            seen[execution] = row
        outcomes = []
        for group in self._groups:
            ids = [key for key, row in self._entries.items() if row["source_group_sha256"] == group]
            rows = [seen[key] for key in ids if key in seen]
            missing = len(ids) - len(rows)
            failed = sum(row["status"] != "completed" for row in rows)
            outcomes.append(
                {
                    "source_group_sha256": group,
                    "expected_executions": len(ids),
                    "observed_executions": len(rows),
                    "missing_executions": missing,
                    "failed_executions": failed,
                    "finish_seconds": None
                    if missing or failed
                    else max(row["finish_seconds"] for row in rows),
                }
            )
        values = [row["finish_seconds"] for row in outcomes]
        p95 = weighted_p95([(1, value) for value in values])
        failed_groups = sum(value is None for value in values)
        worst = None if failed_groups else max(values)
        hard_failures = sum(
            value is None or value > latency_policy()["finish_hard_seconds"] for value in values
        )
        gate = (
            "diagnostic_pass"
            if (
                not hard_failures
                and p95 is not None
                and p95 <= latency_policy()["finish_p95_seconds"]
            )
            else "no-go"
        )
        self._verify_sources()
        return {
            "schema_version": 1,
            "cohort_sha256": self._cohort_sha256,
            "context": dict(self._context),
            "source_groups": len(self._groups),
            "expected_executions": len(self._entries),
            "observed_executions": len(seen),
            "missing_executions": len(self._entries) - len(seen),
            "failed_source_groups": failed_groups,
            "hard_failed_source_groups": hard_failures,
            "finish_p95_seconds": p95,
            "worst_finish_seconds": worst,
            "finish_gate": gate,
            "source_outcomes": outcomes,
            "observations_sha256": canonical_digest(
                {"observations": [seen[k] for k in sorted(seen)]}
            ),
            "injected_executions": sum(row["clock_source"] == "injected" for row in seen.values()),
            "provenance": "declared_controls_and_host_report_consistency",
            "runtime_identity_verified": False,
            "certification_eligible": False,
            "certified_max_speakers": None,
        }
