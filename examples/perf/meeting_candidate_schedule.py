"""Immutable common-prefix development scheduling; never issues certification."""

from __future__ import annotations

import json
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

_DECISIONS = {"pass", "point_failed", "insufficient_evidence", "not_observed"}
_SHA = re.compile(r"[0-9a-f]{64}\Z")


def _sha(value: object) -> str:
    if not isinstance(value, str) or not _SHA.fullmatch(value):
        raise ValueError("schedule identity must be a SHA-256 digest")
    return value


@dataclass(frozen=True, slots=True, init=False)
class CommonPrefixSchedule:
    speakers_count: int
    manifest_sha256: str
    scorer_policy_sha256: str
    _candidates: tuple[tuple[str, str], ...]
    _groups: tuple[str, ...]
    _rounds: tuple[str, ...]

    def __init__(
        self,
        speakers_count: int,
        candidate_ids: Mapping[str, str],
        source_groups: Sequence[str],
        *,
        manifest_sha256: str,
        scorer_policy_sha256: str,
    ) -> None:
        if type(speakers_count) is not int or not 1 <= speakers_count <= 8:
            raise ValueError("invalid speaker stratum")
        names = {"C0", "C1", "C2"} if speakers_count <= 4 else {"C1", "C2"}
        if set(candidate_ids) != names:
            raise ValueError("finite candidates differ from registered comparison")
        if len(source_groups) > 1024 or len(set(source_groups)) != len(source_groups):
            raise ValueError("source groups must be unique and bounded")
        object.__setattr__(self, "speakers_count", speakers_count)
        object.__setattr__(self, "manifest_sha256", _sha(manifest_sha256))
        object.__setattr__(self, "scorer_policy_sha256", _sha(scorer_policy_sha256))
        object.__setattr__(
            self, "_candidates", tuple(sorted((k, _sha(v)) for k, v in candidate_ids.items()))
        )
        object.__setattr__(self, "_groups", tuple(_sha(g) for g in source_groups))
        object.__setattr__(self, "_rounds", ())

    @property
    def candidate_ids(self) -> dict[str, str]:
        return dict(self._candidates)

    def request(self) -> dict[str, Any]:
        active, eliminated = {"C1", "C2"}, set()
        checkpoint, status = 6, "pending"
        eligible: list[str] = []
        if len(self._groups) < 6:
            status = "insufficient_sources"
        for encoded in self._rounds:
            results = json.loads(encoded)
            for name in sorted(active):
                values = (
                    results[name]["product_decision"],
                    results[name]["nondegradation_decision"],
                )
                if "point_failed" in values:
                    eliminated.add(name)
                    active.remove(name)
            if any(
                "not_observed" in (r["product_decision"], r["nondegradation_decision"])
                for r in results.values()
            ):
                status, eligible = "incomplete", []
                break
            eligible = sorted(
                name
                for name in active
                if results[name]["product_decision"] == "pass"
                and results[name]["nondegradation_decision"] in ("pass", None)
            )
            if not active:
                status = "no_candidate"
                break
            if len(eligible) == len(active):
                status = "passed"
                break
            if checkpoint == 24:
                status = "evidence_exhausted"
                break
            if checkpoint + 6 > len(self._groups):
                status = "insufficient_sources"
                break
            checkpoint += 6
            status, eligible = "pending", []
        names = sorted(active | ({"C0"} if self.speakers_count <= 4 else set()))
        return {
            "status": status,
            "checkpoint": checkpoint,
            "candidates": names,
            "source_group_ids": list(self._groups[:checkpoint]),
            "eliminated": sorted(eliminated),
            "eligible_candidates": eligible,
            "manifest_sha256": self.manifest_sha256,
            "scorer_policy_sha256": self.scorer_policy_sha256,
            "certified_max_speakers": None,
        }

    def record(self, results: Mapping[str, Any]) -> CommonPrefixSchedule:
        request = self.request()
        if request["status"] != "pending":
            raise ValueError("terminal comparison cannot accept another round")
        if set(results) != set(request["candidates"]):
            raise ValueError("round must include C0 and every surviving candidate")
        for name, row in results.items():
            if not isinstance(row, Mapping) or set(row) != {
                "candidate_sha256",
                "source_group_ids",
                "product_decision",
                "nondegradation_decision",
            }:
                raise ValueError("round evidence fields differ from schema")
            if row["candidate_sha256"] != self.candidate_ids[name]:
                raise ValueError("candidate identity differs from frozen schedule")
            if row["source_group_ids"] != request["source_group_ids"]:
                raise ValueError("round requires the same complete ordered source prefix")
            if row["product_decision"] not in _DECISIONS:
                raise ValueError("unknown product decision")
            requires_control = self.speakers_count <= 4 and name != "C0"
            if requires_control:
                if row["nondegradation_decision"] not in _DECISIONS:
                    raise ValueError("nondegradation evidence is required")
            elif row["nondegradation_decision"] is not None:
                raise ValueError("nondegradation is not applicable to this control or stratum")
        # JSON snapshots prevent later mutations of caller-owned result mappings.
        encoded = json.dumps(results, sort_keys=True, allow_nan=False)
        next_state = CommonPrefixSchedule(
            self.speakers_count,
            self.candidate_ids,
            self._groups,
            manifest_sha256=self.manifest_sha256,
            scorer_policy_sha256=self.scorer_policy_sha256,
        )
        object.__setattr__(next_state, "_rounds", (*self._rounds, encoded))
        return next_state

    def as_dict(self) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "speakers_count": self.speakers_count,
            "manifest_sha256": self.manifest_sha256,
            "scorer_policy_sha256": self.scorer_policy_sha256,
            "candidate_ids": self.candidate_ids,
            "source_groups": list(self._groups),
            "rounds": [json.loads(r) for r in self._rounds],
        }

    @classmethod
    def restore(
        cls,
        saved: Mapping[str, Any],
        *,
        expected: CommonPrefixSchedule,
    ) -> CommonPrefixSchedule:
        if expected._rounds:
            raise ValueError("restore requires the independently loaded initial source lock")
        if set(saved) != set(expected.as_dict()) or type(saved["schema_version"]) is not int:
            raise ValueError("invalid schedule schema")
        if any(saved[k] != v for k, v in expected.as_dict().items() if k != "rounds"):
            raise ValueError("schedule differs from independently loaded source/candidate lock")
        rounds = saved["rounds"]
        if not isinstance(rounds, list) or len(rounds) > 4:
            raise ValueError("round history exceeds finite checkpoints")
        state = expected
        for results in rounds:
            state = state.record(results)
        return state


def eligible_across_strata(
    schedules: Mapping[int, CommonPrefixSchedule],
    *,
    required_max: int,
) -> list[str]:
    """Intersect development eligibility; never certify or skip an unobserved stratum."""
    if (
        type(required_max) is not int
        or not 1 <= required_max <= 8
        or set(schedules) != set(range(1, required_max + 1))
    ):
        raise ValueError("selection requires every continuous speaker stratum")
    identities = set()
    eligible = {"C1", "C2"}
    for count, state in schedules.items():
        if state.speakers_count != count:
            raise ValueError("schedule belongs to another speaker stratum")
        identities.add(
            (
                state.manifest_sha256,
                state.scorer_policy_sha256,
                state.candidate_ids["C1"],
                state.candidate_ids["C2"],
            )
        )
        eligible.intersection_update(state.request()["eligible_candidates"])
    if len(identities) != 1:
        raise ValueError("selection mixes source, scorer or candidate identities")
    return sorted(eligible)
