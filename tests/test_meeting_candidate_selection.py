"""Development selection consumes only paired completed diagnostic checkpoints."""

from __future__ import annotations

import copy
import hashlib
import json

import pytest
from meeting_candidate_schedule import CommonPrefixSchedule
from meeting_candidate_selection import select_development_candidate
from meeting_evaluation_identity import canonical_digest

from test_meeting_quality_metrics import policy


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


def inputs(maximum=2, *, scenes=("near", "far"), shared_groups=False):
    scorer = policy()
    manifest = {"schema_version": 2, "split": "development", "fixtures": [], "group_order": {}}
    for count in range(1, maximum + 1):
        groups = [sha(f"{count}-{i}") for i in range(6)]
        if shared_groups and count > 1:
            groups = list(manifest["group_order"]["1"])
        manifest["group_order"][str(count)] = groups
        for index, group in enumerate(groups):
            for scene in scenes:
                manifest["fixtures"].append(
                    {
                        "id": f"F{count}-{index}-{scene}",
                        "source_group_id": group,
                        "speakers_count": count,
                        "scene": scene,
                        "channel": 0,
                        "sample_kind": "natural_single" if count == 1 else "natural_meeting",
                        "transform": {"kind": "identity"},
                        "reference_label_policy": {"kind": "anonymous"},
                        "artifacts": {
                            "asr_sidecar": {"sha256": sha(f"sidecar-{count}-{index}-{scene}")}
                        },
                    }
                )
    initial, checkpoints = {}, {}
    for count in range(1, maximum + 1):
        ids = {name: sha(name) for name in ("C0", "C1", "C2") if count <= 4 or name != "C0"}
        schedule = CommonPrefixSchedule(
            count,
            ids,
            manifest["group_order"][str(count)],
            manifest_sha256=canonical_digest(manifest),
            scorer_policy_sha256=canonical_digest(scorer),
        )
        initial[count] = schedule
        request = schedule.request()
        evidence = {
            name: {
                "candidate_sha256": value,
                "source_group_ids": request["source_group_ids"],
                "product_decision": "pass",
                "nondegradation_decision": "pass" if count <= 4 and name != "C0" else None,
            }
            for name, value in ids.items()
        }
        done = schedule.record(evidence)
        observations = {}
        for name, digest in ids.items():
            rows = []
            for fixture in manifest["fixtures"]:
                if fixture["speakers_count"] != count:
                    continue
                der = 0.1 if name == "C1" else 0.105
                rows.append(
                    {
                        "schema_version": 1,
                        "fixture_id": fixture["id"],
                        "status": "completed",
                        "candidate_sha256": digest,
                        "manifest_sha256": schedule.manifest_sha256,
                        "scorer_policy_sha256": schedule.scorer_policy_sha256,
                        "source_meeting_id": fixture["source_group_id"],
                        "speakers_count": count,
                        "scene": fixture["scene"],
                        "channel": fixture["channel"],
                        "sample_kind": fixture["sample_kind"],
                        "transform_sha256": canonical_digest(fixture["transform"]),
                        "reference_label_policy_sha256": canonical_digest(
                            fixture["reference_label_policy"]
                        ),
                        "sidecar": {"sha256": fixture["artifacts"]["asr_sidecar"]["sha256"]},
                        "quality": {
                            "schema_version": 3,
                            "policy_sha256": schedule.scorer_policy_sha256,
                            "standard_metrics": {
                                "diarization": {
                                    "availability": "observed",
                                    "scorer": "pyannote.metrics",
                                    "scorer_version": "4.1",
                                    "collar_seconds": 0,
                                    "skip_overlap": False,
                                    "der": der,
                                    "components": {
                                        "total": 100,
                                        "correct": 100 - der * 100,
                                        "missed detection": 0,
                                        "false alarm": 0,
                                        "confusion": der * 100,
                                    },
                                },
                                "cp_cer": {
                                    "availability": "observed",
                                    "error_rate": 0.2,
                                    "errors": 20,
                                    "reference_tokens": 100,
                                    "algorithm": "meeteval.cp",
                                    "scorer_version": "0.4.3",
                                    "tokenization": scorer["tokenization"]["character"],
                                },
                            },
                        },
                        "execution": {"stable_label_p95_seconds": None},
                        "certification_eligible": False,
                        "certified_max_speakers": None,
                    }
                )
            observations[name] = rows
        checkpoints[count] = {
            "schema_version": 1,
            "status": "completed",
            "speakers_count": count,
            "checkpoint": 6,
            "source_group_ids": request["source_group_ids"],
            "candidate_ids": ids,
            "manifest_sha256": schedule.manifest_sha256,
            "scorer_policy_sha256": schedule.scorer_policy_sha256,
            "schedule": done.as_dict(),
            "request": done.request(),
            "observations": observations,
            "comparisons": {
                name: {
                    "product": {"decision": "pass"},
                    "nondegradation": {"decision": "pass"} if count <= 4 and name != "C0" else None,
                }
                for name in ids
            },
            "verdict": "diagnostic",
            "certification_eligible": False,
            "runtime_identity_verified": False,
            "certified_max_speakers": None,
        }
    return initial, checkpoints, manifest, scorer


def select(value):
    initial, checkpoints, manifest, scorer = value
    return select_development_candidate(
        initial_schedules=initial,
        checkpoints=checkpoints,
        manifest=manifest,
        policy=scorer,
        required_max=len(initial),
    )


def change_der(row, value, total=100):
    metric = row["quality"]["standard_metrics"]["diarization"]
    metric["der"] = value
    metric["components"] = {
        "total": total,
        "correct": total * (1 - value),
        "missed detection": 0,
        "false alarm": 0,
        "confusion": total * value,
    }


def test_selects_unique_der_best_without_inventing_latency_or_certification():
    value = inputs()
    before = copy.deepcopy(value[1])
    result = select(value)
    assert result["selected_candidate"] == "C1"
    assert result["status"] == "selected" and result["verdict"] == "diagnostic"
    assert result["certification_eligible"] is False and result["certified_max_speakers"] is None
    assert result["latency"]["availability"] == "not_observed"
    assert result["footprint"]["availability"] == "not_observed"
    assert result["differences_from_der_best"]["C2"]["upper"] == pytest.approx(0.005)
    assert result["differences_from_der_best"]["C2"]["noninferior"] is True
    assert "latency_and_footprint_not_observed" in result["limitations"]
    assert value[1] == before
    assert "fixture_id" not in json.dumps(result)
    assert sha("1-0") not in json.dumps(result)


@pytest.mark.parametrize(
    "mutation",
    [
        "gap",
        "pending",
        "forged_schedule",
        "reordered_prefix",
        "missing_candidate",
        "wrong_candidate",
        "wrong_scorer",
        "missing_fixture",
        "duplicate_fixture",
        "wrong_scene",
        "wrong_sidecar",
    ],
)
def test_rejects_unpaired_or_unfrozen_checkpoint_evidence(mutation):
    value = inputs()
    initial, checkpoints, _, _ = value
    report = checkpoints[1]
    row = report["observations"]["C1"][0]
    if mutation == "gap":
        del checkpoints[1]
    elif mutation == "pending":
        report["schedule"] = initial[1].as_dict()
        report["request"] = initial[1].request()
    elif mutation == "forged_schedule":
        report["schedule"]["source_groups"].reverse()
    elif mutation == "reordered_prefix":
        report["source_group_ids"].reverse()
    elif mutation == "missing_candidate":
        del report["observations"]["C2"]
    elif mutation == "wrong_candidate":
        row["candidate_sha256"] = sha("wrong")
    elif mutation == "wrong_scorer":
        row["quality"]["policy_sha256"] = sha("wrong")
    elif mutation == "missing_fixture":
        for rows in report["observations"].values():
            rows.pop()
    elif mutation == "duplicate_fixture":
        report["observations"]["C1"].append(copy.deepcopy(row))
    elif mutation == "wrong_scene":
        row["scene"] = "far"
    else:
        row["sidecar"]["sha256"] = sha("wrong")
    with pytest.raises(ValueError):
        select(value)


def test_initial_schedule_must_be_independent_and_unadvanced():
    value = inputs(1)
    value[0][1] = CommonPrefixSchedule.restore(value[1][1]["schedule"], expected=value[0][1])
    with pytest.raises(ValueError, match="initial"):
        select(value)


def test_missing_scene_keeps_ranking_unavailable_instead_of_reweighting():
    result = select(inputs(1, scenes=("near",)))
    assert result["status"] == "ranking_unavailable"
    assert result["selected_candidate"] is None
    assert "required_scene_not_observed" in result["limitations"]


def test_source_meeting_and_scene_macro_does_not_weight_longer_meetings_more():
    value = inputs(1)
    for name, rows in value[1][1]["observations"].items():
        for row in rows:
            change_der(row, 0.2 if name == "C1" else 0.15, total=100000 if row is rows[0] else 100)
        if name == "C1":
            change_der(rows[0], 0, total=100000)
    result = select(value)
    assert result["selected_candidate"] == "C2"
    assert result["ranking"]["C1"]["der"] == pytest.approx((0.2 * 11) / 12)
    assert result["ranking"]["C1"]["source_groups"] == 6


def test_exact_der_ties_use_cpcer_then_explicit_deterministic_candidate_order():
    value = inputs(1)
    for row in value[1][1]["observations"]["C2"]:
        change_der(row, 0.1)
        row["quality"]["standard_metrics"]["cp_cer"].update(errors=10, error_rate=0.1)
    result = select(value)
    assert result["selected_candidate"] == "C2" and result["selection_reason"] == "cp_cer_tiebreak"
    for row in value[1][1]["observations"]["C2"]:
        row["quality"]["standard_metrics"]["cp_cer"].update(errors=20, error_rate=0.2)
    result = select(value)
    assert result["selected_candidate"] == "C1"
    assert result["selection_reason"] == "deterministic_candidate_order"
    assert result["ranking_uncertain"] is True


def test_missing_or_incompatible_scores_cannot_support_ranking():
    value = inputs(1)
    value[1][1]["observations"]["C1"][0]["quality"]["standard_metrics"]["diarization"]["der"] = None
    result = select(value)
    assert result["status"] == "ranking_unavailable" and result["selected_candidate"] is None
    value = inputs(1)
    value[1][1]["observations"]["C1"][0]["quality"]["standard_metrics"]["diarization"][
        "skip_overlap"
    ] = True
    with pytest.raises(ValueError):
        select(value)


def test_numeric_self_reported_latency_cannot_override_der_best():
    value = inputs(1)
    for name, rows in value[1][1]["observations"].items():
        for row in rows:
            row["execution"].update(
                stable_label_p95_seconds=1 if name == "C2" else 10,
                latency_verified=True,
                peak_footprint_bytes=10,
            )
    result = select(value)
    assert result["selected_candidate"] == "C1"
    assert result["latency"]["availability"] == "not_observed"


def test_changed_bootstrap_policy_is_rejected_before_ranking():
    value = inputs(1)
    value[3]["statistics"]["seed"] = 42
    with pytest.raises(ValueError):
        select(value)


def relock(value):
    initial, checkpoints, manifest, scorer = value
    digest = canonical_digest(manifest)
    for count in initial:
        old = initial[count]
        initial[count] = CommonPrefixSchedule(
            count,
            old.candidate_ids,
            manifest["group_order"][str(count)],
            manifest_sha256=digest,
            scorer_policy_sha256=canonical_digest(scorer),
        )
        report = checkpoints[count]
        report["manifest_sha256"] = digest
        report["schedule"]["manifest_sha256"] = digest
        report["request"]["manifest_sha256"] = digest
        for rows in report["observations"].values():
            for row in rows:
                row["manifest_sha256"] = digest


def test_same_source_fragments_merge_totals_before_meeting_macro():
    value = inputs(1)
    extra = copy.deepcopy(value[2]["fixtures"][0])
    extra["id"] = "extra-fragment"
    value[2]["fixtures"].append(extra)
    for name, rows in value[1][1]["observations"].items():
        row = copy.deepcopy(rows[0])
        row["fixture_id"] = extra["id"]
        change_der(row, 0.4 if name == "C1" else 0.105, total=300)
        rows.append(row)
    relock(value)
    result = select(value)
    # Source 0 near is (10+120)/(100+300)=0.325; the other eleven
    # source/scene cells remain 0.1. The extra fragment adds no source.
    assert result["ranking"]["C1"]["der"] == pytest.approx((0.325 + 1.1) / 12)
    assert result["ranking"]["C1"]["source_groups"] == 6


def test_candidate_eliminated_in_any_layer_cannot_return_for_ranking():
    value = inputs(2)
    for count, failed in ((1, "C1"), (2, "C2")):
        report = value[1][count]
        report["schedule"]["rounds"][0][failed]["product_decision"] = "point_failed"
        report["comparisons"][failed]["product"]["decision"] = "point_failed"
        restored = CommonPrefixSchedule.restore(report["schedule"], expected=value[0][count])
        report["request"] = restored.request()
    result = select(value)
    assert result["status"] == "no_candidate"
    assert result["eligible_candidates"] == [] and result["selected_candidate"] is None


def test_paired_bootstrap_resamples_source_meetings_with_both_scenes_together():
    import numpy as np

    value = inputs(1)
    groups = sorted(value[0][1].request()["source_group_ids"])
    deltas = {group: index / 100 for index, group in enumerate(groups)}
    for row in value[1][1]["observations"]["C2"]:
        change_der(row, 0.1 + deltas[row["source_meeting_id"]])
    result = select(value)
    indices = np.random.default_rng(1717).integers(0, 6, size=(10000, 6))
    expected = np.quantile(np.array(list(deltas.values()))[indices].mean(axis=1), [0.025, 0.975])
    difference = result["differences_from_der_best"]["C2"]
    assert difference["lower"] == pytest.approx(expected[0])
    assert difference["upper"] == pytest.approx(expected[1])
    assert difference["noninferior"] is False


def test_singleton_scene_block_does_not_manufacture_confidence_bounds():
    value = inputs(1)
    first = value[2]["fixtures"][0]["source_group_id"]
    value[2]["fixtures"] = [
        f for f in value[2]["fixtures"] if f["scene"] == "near" or f["source_group_id"] == first
    ]
    valid = {f["id"] for f in value[2]["fixtures"]}
    for name, rows in value[1][1]["observations"].items():
        value[1][1]["observations"][name] = [r for r in rows if r["fixture_id"] in valid]
    relock(value)
    result = select(value)
    assert result["selected_candidate"] == "C1"
    assert result["differences_from_der_best"]["C2"]["upper"] is None
    assert result["differences_from_der_best"]["C2"]["noninferior"] is False
    assert result["ranking_uncertain"] is True


def test_mismatched_der_denominator_is_rejected_even_when_cpcer_is_missing():
    value = inputs(1)
    row = value[1][1]["observations"]["C1"][0]
    row["quality"]["standard_metrics"]["cp_cer"].update(
        availability="not_observed", error_rate=None
    )
    change_der(row, 0.1, total=99)
    with pytest.raises(ValueError, match="denominator"):
        select(value)


def test_bounded_json_rejects_oversized_diagnostic_inputs(monkeypatch):
    import meeting_candidate_selection

    monkeypatch.setattr(meeting_candidate_selection, "_MAX_JSON_BYTES", 100)
    with pytest.raises(ValueError, match="budget"):
        select(inputs(1))


def test_c0_identity_cannot_change_between_lower_speaker_strata():
    value = inputs(2)
    initial, checkpoints, manifest, scorer = value
    ids = {**initial[2].candidate_ids, "C0": sha("other-control")}
    initial[2] = CommonPrefixSchedule(
        2,
        ids,
        manifest["group_order"]["2"],
        manifest_sha256=canonical_digest(manifest),
        scorer_policy_sha256=canonical_digest(scorer),
    )
    report = checkpoints[2]
    report["candidate_ids"] = ids
    report["schedule"]["candidate_ids"] = ids
    report["schedule"]["rounds"][0]["C0"]["candidate_sha256"] = ids["C0"]
    for row in report["observations"]["C0"]:
        row["candidate_sha256"] = ids["C0"]
    with pytest.raises(ValueError, match="C0"):
        select(value)


def test_eliminated_candidates_missing_der_does_not_block_survivor_ranking():
    value = inputs(1)
    report = value[1][1]
    report["schedule"]["rounds"][0]["C1"]["product_decision"] = "point_failed"
    report["comparisons"]["C1"]["product"]["decision"] = "point_failed"
    restored = CommonPrefixSchedule.restore(report["schedule"], expected=value[0][1])
    report["request"] = restored.request()
    for row in report["observations"]["C1"]:
        row["quality"]["standard_metrics"]["diarization"].update(
            availability="not_observed", der=None
        )
    result = select(value)
    assert result["selected_candidate"] == "C2"
    assert result["eligible_candidates"] == ["C2"]


def test_actual_fake_checkpoint_outputs_feed_selector_without_field_translation(tmp_path):
    import asyncio

    from meeting_development_fixture import evaluate_development_checkpoint

    from test_meeting_candidate_runner import Activity
    from test_meeting_development_fixture import checkpoint_inputs

    manifest, lock = checkpoint_inputs(tmp_path)
    for index, fixture in enumerate(manifest["fixtures"]):
        fixture["scene"] = "near" if index < 3 else "far"
    lock["development_manifest_sha256"] = canonical_digest(manifest)
    candidates = {"C0": "a" * 64, "C1": "b" * 64, "C2": "c" * 64}
    schedule = CommonPrefixSchedule(
        1,
        candidates,
        manifest["group_order"]["1"],
        manifest_sha256=canonical_digest(manifest),
        scorer_policy_sha256=canonical_digest(policy()),
    )
    checkpoint = asyncio.run(
        evaluate_development_checkpoint(
            manifest,
            lock,
            schedule=schedule,
            candidate_ids=candidates,
            activity_factories=dict.fromkeys(candidates, Activity),
            artifact_root=tmp_path,
            scorer_policy=policy(),
            output_directory=tmp_path / "checkpoint",
        )
    )
    result = select_development_candidate(
        initial_schedules={1: schedule},
        checkpoints={1: checkpoint},
        manifest=manifest,
        policy=policy(),
        required_max=1,
    )
    assert checkpoint["request"]["status"] == "passed"
    assert result["selected_candidate"] == "C1"
    assert result["selection_reason"] == "deterministic_candidate_order"
    assert result["certification_eligible"] is False


def test_cpcer_reference_pairing_survives_missing_control_cpcer():
    value = inputs(1)
    for row in value[1][1]["observations"]["C0"]:
        row["quality"]["standard_metrics"]["cp_cer"].update(
            availability="not_observed", error_rate=None
        )
    cp = value[1][1]["observations"]["C2"][0]["quality"]["standard_metrics"]["cp_cer"]
    cp.update(reference_tokens=200, error_rate=0.1)
    with pytest.raises(ValueError, match="denominator"):
        select(value)


def test_same_source_is_resampled_together_across_speaker_strata():
    value = inputs(2, shared_groups=True)
    groups = sorted(value[0][1].request()["source_group_ids"])
    for count in (1, 2):
        for row in value[1][count]["observations"]["C2"]:
            index = groups.index(row["source_meeting_id"])
            # Opposite within-source changes cancel when both strata are
            # sampled together; independent per-stratum draws widen the CI.
            delta = index * 0.02 if count == 1 else (5 - index) * 0.02
            change_der(row, 0.1 + delta)
    result = select(value)
    difference = result["differences_from_der_best"]["C2"]
    assert result["selected_candidate"] == "C1"
    assert result["ranking"]["C2"]["source_groups"] == 6
    assert difference["difference"] == pytest.approx(0.05)
    assert difference["lower"] == pytest.approx(0.05)
    assert difference["upper"] == pytest.approx(0.05)


def test_selection_identity_binds_implementation_policy_and_input_checkpoints():
    from pathlib import Path

    import meeting_candidate_selection

    value = inputs(1)
    result = select(value)
    identity = result["selection_identity"]
    assert (
        identity["implementation_sha256"]
        == hashlib.sha256(Path(meeting_candidate_selection.__file__).read_bytes()).hexdigest()
    )
    assert len(identity["policy_sha256"]) == 64
    assert result["checkpoint_sha256"] == {"1": canonical_digest(value[1][1])}
    value[1][1]["diagnostic_metadata"] = "changed"
    updated = select(value)
    assert updated["checkpoint_sha256"] != result["checkpoint_sha256"]
    assert updated["selection_identity"] == result["selection_identity"]
