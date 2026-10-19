"""Offline cross-stratum development selection, never a certification receipt.

The initial schedules and manifest must be loaded from independent frozen
controls, not reconstructed from checkpoint claims. Only the last completed
common prefix is ranked. Current checkpoint execution has no measured stable
label distribution or complete peak footprint provenance, so these dimensions
remain unavailable even if a result contains self-reported numeric fields.
"""

from __future__ import annotations

import hashlib
import json
import math
from collections import defaultdict
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from meeting_candidate_schedule import CommonPrefixSchedule, eligible_across_strata
from meeting_evaluation_identity import canonical_digest
from meeting_quality_metrics import _validate_policy, standard_metric_totals

_MAX_JSON_BYTES = 32 * 1024 * 1024
_SCENES = ("near", "far")
# One fixture execution per candidate is the current checkpoint schema. Duplicate
# rows are not repeat measurements: no independently frozen repeat IDs exist.
_AGGREGATION = "single_execution_fixture_totals_then_source_scene_ratios_v1"
_IMPLEMENTATION_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
_SELECTION_POLICY = {
    "aggregation": _AGGREGATION,
    "scenes": list(_SCENES),
    "weights": "equal_speaker_strata_then_equal_scenes_then_equal_source_meetings",
    "bootstrap": "global_paired_source_clusters_with_complete_cell_incidence_blocks",
    "seed": 1717,
    "draws": 10000,
    "interval": [0.025, 0.975],
    "noninferiority_margin": 0.01,
    "ties": ["cp_cer", "measured_label_p95", "measured_peak_footprint", "candidate_name"],
    "latency_and_footprint": "not_observed_in_checkpoint_schema_no_numeric_substitution",
    "missing_scenes_or_der": "ranking_unavailable",
    "singleton_bootstrap_block": "difference_interval_not_observed",
    "executions_per_fixture": 1,
}
Cell = tuple[int, str]
Scores = dict[Cell, dict[str, tuple[float, float | None]]]


def _snapshot(value: Mapping[str, Any]) -> dict[str, Any]:
    chunks, size = [], 0
    for chunk in json.JSONEncoder(allow_nan=False).iterencode(value):
        size += len(chunk.encode("utf-8"))
        if size > _MAX_JSON_BYTES:
            raise ValueError("selection JSON exceeds bounded input budget")
        chunks.append(chunk)
    result = json.loads("".join(chunks))
    if not isinstance(result, dict):
        raise ValueError("selection input must be an object")
    return result


def _restore(
    initial: CommonPrefixSchedule,
    report: dict[str, Any],
    manifest: dict[str, Any],
    policy: dict[str, Any],
) -> CommonPrefixSchedule:
    saved = report["schedule"]
    # JSON equality alone admits true == 1; canonical identities reject that
    # substitution at this external boundary before replaying the finite rules.
    expected = initial.as_dict()
    if expected["rounds"]:
        raise ValueError("selection requires independent initial schedules")
    if canonical_digest({k: v for k, v in saved.items() if k != "rounds"}) != canonical_digest(
        {k: v for k, v in expected.items() if k != "rounds"}
    ):
        raise ValueError("selection schedule differs from independent initial lock")
    state = CommonPrefixSchedule.restore(saved, expected=initial)
    request = state.request()
    identities = {
        "schema_version": 1,
        "speakers_count": state.speakers_count,
        "manifest_sha256": canonical_digest(manifest),
        "scorer_policy_sha256": canonical_digest(policy),
        "candidate_ids": initial.candidate_ids,
        "checkpoint": request["checkpoint"],
        "source_group_ids": request["source_group_ids"],
        "request": request,
    }
    if (
        report["status"] != "completed"
        or request["status"] not in {"passed", "evidence_exhausted"}
        or not request["eligible_candidates"]
        or any(
            canonical_digest({"v": report[k]}) != canonical_digest({"v": v})
            for k, v in identities.items()
        )
        or initial.manifest_sha256 != identities["manifest_sha256"]
        or initial.scorer_policy_sha256 != identities["scorer_policy_sha256"]
        or initial.as_dict()["source_groups"] != manifest["group_order"][str(state.speakers_count)]
    ):
        raise ValueError(
            "selection requires completed eligible common prefixes and frozen identities"
        )
    last = saved["rounds"][-1]
    if set(report["observations"]) != set(last) or set(report["comparisons"]) != set(last):
        raise ValueError("selection observation candidates differ from last common round")
    for name, evidence in last.items():
        comparison = report["comparisons"][name]
        control = comparison["nondegradation"]
        if (
            comparison["product"]["decision"] != evidence["product_decision"]
            or (control["decision"] if control is not None else None)
            != evidence["nondegradation_decision"]
        ):
            raise ValueError("selection comparisons disagree with recorded schedule evidence")
    return state


def _collect(
    report: dict[str, Any],
    state: CommonPrefixSchedule,
    manifest: dict[str, Any],
    policy: dict[str, Any],
) -> tuple[dict[str, Scores], set[str]]:
    count, request = state.speakers_count, state.request()
    fixtures = {
        f["id"]: f
        for f in manifest["fixtures"]
        if f["speakers_count"] == count and f["source_group_id"] in request["source_group_ids"]
    }
    if (
        not fixtures
        or len(fixtures) > 4096
        or {f["source_group_id"] for f in fixtures.values()} != set(request["source_group_ids"])
    ):
        raise ValueError("selection manifest does not cover exact source prefix")
    result: dict[str, Scores] = {}
    denominators: dict[str, tuple[float, float | None]] = {}
    missing_der: set[str] = set()
    for name, rows in report["observations"].items():
        if (
            not isinstance(rows, list)
            or len(rows) != len(fixtures)
            or len({r["fixture_id"] for r in rows}) != len(rows)
            or {r["fixture_id"] for r in rows} != set(fixtures)
        ):
            raise ValueError("selection requires each paired fixture once in the complete prefix")
        grouped: dict[tuple[str, str], list[tuple[float, float, float | None, float | None]]] = (
            defaultdict(list)
        )
        for row in rows:
            fixture = fixtures[row["fixture_id"]]
            required = {
                "schema_version": 1,
                "status": "completed",
                "candidate_sha256": state.candidate_ids[name],
                "manifest_sha256": state.manifest_sha256,
                "scorer_policy_sha256": state.scorer_policy_sha256,
                "source_meeting_id": fixture["source_group_id"],
                "speakers_count": count,
                "scene": fixture["scene"],
                "sample_kind": fixture["sample_kind"],
                "channel": fixture["channel"],
                "transform_sha256": canonical_digest(fixture["transform"]),
                "reference_label_policy_sha256": canonical_digest(
                    fixture["reference_label_policy"]
                ),
            }
            if (
                fixture["scene"] not in _SCENES
                or any(
                    canonical_digest({"v": row[k]}) != canonical_digest({"v": v})
                    for k, v in required.items()
                )
                or any(
                    row["sidecar"].get(k) != v
                    for k, v in fixture["artifacts"]["asr_sidecar"].items()
                    if k != "path"
                )
            ):
                raise ValueError("selection fixture identities differ from frozen manifest")
            totals = standard_metric_totals(row, policy)
            if totals[1] == 0:
                missing_der.add(name)
            denominator = totals[1], totals[3]
            # Missing evidence cannot become an unequal paired denominator.
            observed = denominators.setdefault(row["fixture_id"], denominator)
            if any(
                a is not None and b is not None and a > 0 and b > 0 and a != b
                for a, b in zip(observed, denominator, strict=True)
            ):
                raise ValueError("selection candidates have different reference denominators")
            denominators[row["fixture_id"]] = (
                observed[0] if observed[0] > 0 else denominator[0],
                observed[1] if observed[1] is not None else denominator[1],
            )
            grouped[(fixture["scene"], fixture["source_group_id"])].append(totals)
        scores: Scores = {}
        for (scene, group), totals_list in grouped.items():
            numerator = math.fsum(t[0] for t in totals_list)
            denominator_sum = math.fsum(t[1] for t in totals_list)
            cp = None
            if all(t[2] is not None and t[3] is not None for t in totals_list):
                cp = math.fsum(t[2] or 0 for t in totals_list) / math.fsum(
                    t[3] or 0 for t in totals_list
                )
            scores.setdefault((count, scene), {})[group] = (
                numerator / denominator_sum if denominator_sum else 0,
                cp,
            )
        result[name] = scores
    return result, missing_der


def _macro(scores: Scores, metric: int) -> float | None:
    if any(values[metric] is None for groups in scores.values() for values in groups.values()):
        return None
    return math.fsum(
        math.fsum(v[metric] or 0 for v in groups.values()) / len(groups)
        for groups in scores.values()
    ) / len(scores)


def _differences(scores: dict[str, Scores], best: str, maximum: int) -> dict[str, Any]:
    """Pair global source clusters within their full speaker/scene incidence.

    Every source is drawn once per replicate and contributes to all cells in
    which it occurs. Incidence blocks preserve each cell's source count, so
    no absent-cell draw is discarded or silently reweighted.
    """
    import numpy as np

    rng = np.random.default_rng(1717)
    replicates = {name: np.zeros(10000) for name in scores}
    base = scores[best]
    groups = sorted(set().union(*base.values()))
    blocks: dict[tuple[Cell, ...], list[str]] = defaultdict(list)
    for group in groups:
        incidence = tuple(cell for cell in sorted(base) if group in base[cell])
        blocks[incidence].append(group)
    enough_groups = all(len(block) >= 2 for block in blocks.values())
    for incidence, block in sorted(blocks.items()):
        indices = rng.integers(0, len(block), size=(10000, len(block)))
        for name, cells in scores.items():
            for cell in incidence:
                differences = np.array([cells[cell][g][0] - base[cell][g][0] for g in block])
                replicates[name] += differences[indices].sum(axis=1) / (
                    maximum * len(_SCENES) * len(base[cell])
                )
    result = {}
    for name, values in replicates.items():
        low, high = np.quantile(values, [0.025, 0.975])
        result[name] = {
            "difference": (_macro(scores[name], 0) or 0) - (_macro(scores[best], 0) or 0),
            "lower": float(low) if enough_groups or name == best else None,
            "upper": float(high) if enough_groups or name == best else None,
            "noninferior": bool((enough_groups or name == best) and high <= 0.01),
        }
    return result


def select_development_candidate(
    *,
    initial_schedules: Mapping[int, CommonPrefixSchedule],
    checkpoints: Mapping[int, Mapping[str, Any]],
    manifest: Mapping[str, Any],
    policy: Mapping[str, Any],
    required_max: int,
) -> dict[str, Any]:
    """Select one development candidate without adding samples or certifying.

    Current checkpoints support exactly one observation per frozen fixture;
    repeated rows cannot be promoted to independent sources. More general
    repeated-run ranking needs independently locked repeat identities first.
    No file, worker, model, service, or holdout is opened by this function.
    """
    if (
        type(required_max) is not int
        or not 1 <= required_max <= 8
        or set(initial_schedules) != set(range(1, required_max + 1))
        or set(checkpoints) != set(initial_schedules)
        or any(type(k) is not int for k in (*initial_schedules, *checkpoints))
    ):
        raise ValueError("selection requires every continuous speaker stratum")
    try:
        frozen = _snapshot(
            {
                "manifest": manifest,
                "policy": policy,
                "checkpoints": {str(k): v for k, v in checkpoints.items()},
            }
        )
        frozen_manifest: dict[str, Any] = frozen["manifest"]
        frozen_policy: dict[str, Any] = frozen["policy"]
        _validate_policy(frozen_policy)
        stats = frozen_policy["statistics"]
        if any(
            stats.get(k) != v
            for k, v in {
                "unit": "source_meeting_id",
                "seed": 1717,
                "bootstrap_draws": 10000,
                "percentile_interval": [0.025, 0.975],
                "selection_der_noninferiority_margin": 0.01,
            }.items()
        ):
            raise ValueError("selection bootstrap differs from frozen policy")
        if frozen_manifest["schema_version"] != 2 or frozen_manifest["split"] != "development":
            raise ValueError("selection requires a development manifest")
        if len(frozen_manifest["fixtures"]) > 32768 or len(
            {f["id"] for f in frozen_manifest["fixtures"]}
        ) != len(frozen_manifest["fixtures"]):
            raise ValueError("selection manifest fixtures must be unique and bounded")
        states: dict[int, CommonPrefixSchedule] = {}
        all_scores: dict[str, Scores] = {}
        missing: set[str] = set()
        for count in range(1, required_max + 1):
            report = frozen["checkpoints"][str(count)]
            state = _restore(initial_schedules[count], report, frozen_manifest, frozen_policy)
            states[count] = state
            stratum_scores, unavailable = _collect(report, state, frozen_manifest, frozen_policy)
            missing.update(unavailable)
            for name, cells in stratum_scores.items():
                all_scores.setdefault(name, {}).update(cells)
        eligible = eligible_across_strata(states, required_max=required_max)
        if len({state.candidate_ids["C0"] for count, state in states.items() if count <= 4}) > 1:
            raise ValueError("selection mixes C0 control identities across speaker strata")
        result: dict[str, Any] = {
            "schema_version": 1,
            "selection_identity": {
                "implementation_sha256": _IMPLEMENTATION_SHA256,
                "policy_sha256": canonical_digest(_SELECTION_POLICY),
            },
            "checkpoint_sha256": {
                str(k): canonical_digest(frozen["checkpoints"][str(k)]) for k in states
            },
            "status": "no_candidate",
            "selected_candidate": None,
            "eligible_candidates": eligible,
            "manifest_sha256": canonical_digest(frozen_manifest),
            "scorer_policy_sha256": canonical_digest(frozen_policy),
            "candidate_ids": {name: states[1].candidate_ids[name] for name in eligible},
            "checkpoints": {str(k): state.request()["checkpoint"] for k, state in states.items()},
            "aggregation": _AGGREGATION,
            "executions_per_fixture": 1,
            "statistics": {
                "unit": "source_meeting_id",
                "seed": 1717,
                "draws": 10000,
                "interval": "two_sided_percentile_95",
                "design": "global_source_complete_speaker_scene_cell_incidence_blocks",
            },
            "latency": {"availability": "not_observed"},
            "footprint": {"availability": "not_observed"},
            "ranking": {},
            "differences_from_der_best": {},
            "ranking_uncertain": True,
            "selection_reason": None,
            "limitations": [
                "latency_and_footprint_not_observed",
                "development_diagnostic_only",
                "single_execution_per_fixture_no_locked_repeat_ids",
            ],
            "verdict": "diagnostic",
            "runtime_identity_verified": False,
            "certification_eligible": False,
            "certified_max_speakers": None,
        }
        if not eligible:
            return result
        scores = {name: all_scores[name] for name in eligible}
        expected_cells = {(k, scene) for k in states for scene in _SCENES}
        if any(set(cells) != expected_cells for cells in scores.values()):
            result["status"] = "ranking_unavailable"
            result["limitations"].append("required_scene_not_observed")
            return result
        if missing.intersection(eligible):
            result["status"] = "ranking_unavailable"
            result["limitations"].append("der_not_observed")
            return result
        for name, cells in scores.items():
            result["ranking"][name] = {
                "der": _macro(cells, 0),
                "cp_cer": _macro(cells, 1),
                "source_groups": len(set().union(*(groups for groups in cells.values()))),
            }
        ranking = result["ranking"]
        best_value = min(ranking[name]["der"] for name in eligible)
        tied = [name for name in eligible if ranking[name]["der"] == best_value]
        best, reason = tied[0], "lowest_der"
        if len(tied) > 1:
            if all(ranking[name]["cp_cer"] is not None for name in tied):
                cp_value = min(ranking[name]["cp_cer"] for name in tied)
                cp_tied = [name for name in tied if ranking[name]["cp_cer"] == cp_value]
                best = cp_tied[0]
                reason = "cp_cer_tiebreak" if len(cp_tied) == 1 else "deterministic_candidate_order"
            else:
                reason = "deterministic_candidate_order"
                result["limitations"].append("cp_cer_tiebreak_not_observed")
        differences = _differences(scores, best, required_max)
        result.update(
            status="selected",
            selected_candidate=best,
            selection_reason=reason,
            differences_from_der_best=differences,
        )
        result["der_order_uncertain"] = len(tied) > 1 or any(
            differences[n]["lower"] is None or differences[n]["lower"] <= 0
            for n in eligible
            if n != best
        )
        # Missing measured latency/footprint precludes a complete selection
        # comparison even when the DER ordering itself is well supported.
        result["ranking_uncertain"] = len(eligible) > 1
        if any(differences[n]["upper"] is None for n in eligible):
            result["limitations"].append("bootstrap_block_has_fewer_than_two_source_groups")
        return result
    except KeyError, TypeError, IndexError, AttributeError, ZeroDivisionError, OverflowError:
        raise ValueError("selection evidence schema invalid") from None
