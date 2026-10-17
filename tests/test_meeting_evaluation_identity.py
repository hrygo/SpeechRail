"""Evaluation identity and holdout claims must fail before any inference."""

from __future__ import annotations

import copy
import json
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path

import pytest
from meeting_evaluation_identity import (
    EvaluationLocks,
    MeetingCandidateSpec,
    candidate_digest,
    claim_holdout_attempt,
    development_receipt,
    validate_development_receipt,
    validate_execution_identity,
)


def candidate() -> MeetingCandidateSpec:
    return MeetingCandidateSpec(
        implementation_id="sortformer-v2.1",
        adapter_sha256="a" * 64,
        sdk_revision="5c19d5e12320e22bbfb7a1877b089d2665a69add",
        worker_sha256="b" * 64,
        model_revision="ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1",
        model_files_sha256={"model/weights.bin": "c" * 64},
        dtype="fp16",
        preset={"name": "balancedV2_1", "sample_rate": 16000},
        compute_units="all",
        decoder={"threshold": 0.25, "comparison": ">=", "consolidation": {"enabled": False}},
        attribution={"algorithm": "time-overlap-v1", "unknown": "retain"},
        scorer={"policy_version": 2, "overlap": True},
    )


def locks() -> EvaluationLocks:
    return EvaluationLocks("d" * 64, "e" * 64, "f" * 64, "0" * 64)


def receipt() -> dict[str, object]:
    return development_receipt(
        candidate(), locks(), all_required_strata_observed=True, quality_passed=True
    )


def test_consolidation_changes_digest() -> None:
    spec = candidate()
    decoder = spec.as_dict()["decoder"]
    decoder["consolidation"]["enabled"] = True
    assert candidate_digest(spec) != candidate_digest(replace(spec, decoder=decoder))


@pytest.mark.parametrize(
    "field,value",
    [
        ("decoder", {"threshold": 0.5, "comparison": ">", "consolidation": {"enabled": False}}),
        ("preset", {"name": "fast128", "sample_rate": 16000}),
        ("worker_sha256", "1" * 64),
        ("adapter_sha256", "2" * 64),
        ("scorer", {"policy_version": 3, "overlap": True}),
    ],
)
def test_threshold_and_preset_change_digest(field: str, value: object) -> None:
    spec = candidate()
    assert candidate_digest(spec) != candidate_digest(replace(spec, **{field: value}))


def test_dict_order_does_not_change_digest() -> None:
    spec = candidate()
    reordered = dict(reversed(list(spec.as_dict()["decoder"].items())))
    assert candidate_digest(spec) == candidate_digest(replace(spec, decoder=reordered))


def test_candidate_cannot_change_through_nested_mutation() -> None:
    raw = candidate().as_dict()
    spec = MeetingCandidateSpec(**raw)
    digest = candidate_digest(spec)
    raw["decoder"]["consolidation"]["enabled"] = True
    assert candidate_digest(spec) == digest
    with pytest.raises(TypeError):
        spec.decoder["consolidation"]["enabled"] = True


@pytest.mark.parametrize("value", [float("nan"), float("inf"), object(), {1: "non-json key"}])
def test_noncanonical_values_rejected(value: object) -> None:
    with pytest.raises(ValueError):
        replace(candidate(), decoder={"invalid": value})


def test_actual_worker_mismatch_fails_before_inference() -> None:
    observed = candidate().as_dict()
    observed["worker_sha256"] = "1" * 64
    with pytest.raises(ValueError, match="worker_sha256"):
        validate_execution_identity(candidate(), observed)


def test_execution_requires_every_observed_field() -> None:
    observed = candidate().as_dict()
    del observed["preset"]
    with pytest.raises(ValueError, match="preset"):
        validate_execution_identity(candidate(), observed)


def test_dev_receipt_cannot_unlock_other_decoder() -> None:
    changed = replace(candidate(), decoder={"threshold": 0.5})
    with pytest.raises(ValueError, match="candidate"):
        validate_development_receipt(receipt(), changed, locks())


@pytest.mark.parametrize("version", [None, 1, True])
def test_legacy_receipt_cannot_unlock_new_experiment(version: object) -> None:
    legacy = receipt()
    legacy["schema_version"] = version
    with pytest.raises(ValueError, match="schema_version"):
        validate_development_receipt(legacy, candidate(), locks())


def test_distinct_manifests_have_separate_acyclic_locks() -> None:
    result = receipt()
    assert result["development_manifest_sha256"] != result["holdout_manifest_sha256"]
    assert "receipt" not in json.dumps(candidate().as_dict())
    validate_development_receipt(result, candidate(), locks())
    with pytest.raises(ValueError, match="distinct"):
        EvaluationLocks("d" * 64, "d" * 64, "f" * 64, "0" * 64)


@pytest.mark.parametrize(
    "field",
    [
        "development_manifest_sha256",
        "holdout_manifest_sha256",
        "scorer_policy_sha256",
        "runtime_policy_sha256",
    ],
)
def test_all_receipt_locks_are_required(field: str) -> None:
    wrong = copy.deepcopy(receipt())
    wrong[field] = "9" * 64
    with pytest.raises(ValueError, match=field):
        validate_development_receipt(wrong, candidate(), locks())


@pytest.mark.parametrize("observed,quality", [(False, True), (True, False), (False, False)])
def test_incomplete_evidence_never_unlocks(observed: bool, quality: bool) -> None:
    result = development_receipt(
        candidate(), locks(), all_required_strata_observed=observed, quality_passed=quality
    )
    with pytest.raises(ValueError, match="not pass"):
        validate_development_receipt(result, candidate(), locks())


def test_holdout_claim_is_durable_before_inference_and_never_reused(tmp_path: Path) -> None:
    claim = claim_holdout_attempt(
        receipt(), candidate(), locks(), observed=candidate().as_dict(), attempts_directory=tmp_path
    )
    attempt = json.loads(claim.read_text())
    assert attempt["status"] == "claimed"
    assert attempt["candidate_sha256"] == candidate_digest(candidate())
    with pytest.raises(ValueError, match="already consumed"):
        claim_holdout_attempt(
            receipt(),
            candidate(),
            locks(),
            observed=candidate().as_dict(),
            attempts_directory=tmp_path,
        )


def test_two_executors_cannot_claim_same_holdout(tmp_path: Path) -> None:
    def claim() -> bool:
        try:
            claim_holdout_attempt(
                receipt(),
                candidate(),
                locks(),
                observed=candidate().as_dict(),
                attempts_directory=tmp_path,
            )
        except ValueError:
            return False
        return True

    with ThreadPoolExecutor(max_workers=2) as executor:
        assert sorted(executor.map(lambda _: claim(), range(2))) == [False, True]


def test_mismatched_worker_does_not_consume_attempt(tmp_path: Path) -> None:
    observed = candidate().as_dict()
    observed["worker_sha256"] = "9" * 64
    with pytest.raises(ValueError, match="worker_sha256"):
        claim_holdout_attempt(
            receipt(), candidate(), locks(), observed=observed, attempts_directory=tmp_path
        )
    assert list(tmp_path.iterdir()) == []


def test_changing_candidate_does_not_reset_same_holdout(tmp_path: Path) -> None:
    claim_holdout_attempt(
        receipt(), candidate(), locks(), observed=candidate().as_dict(), attempts_directory=tmp_path
    )
    changed = replace(candidate(), worker_sha256="8" * 64)
    new_receipt = development_receipt(
        changed, locks(), all_required_strata_observed=True, quality_passed=True
    )
    with pytest.raises(ValueError, match="already consumed"):
        claim_holdout_attempt(
            new_receipt, changed, locks(), observed=changed.as_dict(), attempts_directory=tmp_path
        )
