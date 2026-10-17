from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "examples" / "perf"))

from calibrate_meeting_diarization import (
    _development_gate_passed,
    _execution_lock,
    _load_screen_summary,
    _rank_screen_candidates,
    _validate_locked_development_manifest,
    _validate_refinement_screen_summary,
    _write_screen_summary,
    _write_selected_candidate,
    clustering_grid,
    matching_embedding_space_grid,
    policy_grid,
    preprocessing_grid,
    refinement_candidate_grid,
    refinement_matching_embedding_space_candidate_grid,
    refinement_preprocessing_candidate_grid,
    screen_candidate_grid,
    screen_matching_embedding_space_candidate_grid,
    screen_preprocessing_candidate_grid,
)


def _write_manifest(tmp_path, fixture_ids: list[str]) -> bytes:
    manifest = tmp_path / "development.json"
    encoded = json.dumps({"fixtures": [{"id": item} for item in fixture_ids]}).encode()
    manifest.write_bytes(encoded)
    (tmp_path / "split-lock.json").write_text(
        json.dumps(
            {
                "dataset": "AISHELL-4",
                "split_rule": "R004 holdout, all other selected sessions development",
                "splits": {
                    "development": {
                        "manifest_sha256": hashlib.sha256(encoded).hexdigest(),
                        "sessions": len(fixture_ids),
                    },
                    "holdout": {"manifest_sha256": "1" * 64, "sessions": 4},
                }
            }
        )
    )
    return encoded


def test_calibration_accepts_only_the_locked_eight_session_development_split(tmp_path) -> None:
    manifest = tmp_path / "development.json"
    encoded = _write_manifest(tmp_path, [f"AISHELL-session-{index}" for index in range(8)])

    fixtures = _validate_locked_development_manifest(manifest, encoded)

    assert len(fixtures) == 8


@pytest.mark.parametrize(
    "fixture_ids",
    [
        [f"AISHELL-session-{index}" for index in range(7)],
        [
            *[f"AISHELL-session-{index}" for index in range(7)],
            "AISHELL-session-R004",
        ],
    ],
)
def test_calibration_rejects_holdout_or_incomplete_meeting_splits(tmp_path, fixture_ids) -> None:
    manifest = tmp_path / "development.json"
    encoded = _write_manifest(tmp_path, fixture_ids)

    with pytest.raises(ValueError, match="locked eight-session development split"):
        _validate_locked_development_manifest(manifest, encoded)


def test_calibration_rejects_duplicate_development_sessions(tmp_path) -> None:
    manifest = tmp_path / "development.json"
    fixture_ids = [*[f"AISHELL-session-{index}" for index in range(7)], "AISHELL-session-0"]
    encoded = _write_manifest(tmp_path, fixture_ids)

    with pytest.raises(ValueError, match="locked eight-session development split"):
        _validate_locked_development_manifest(manifest, encoded)


def test_calibration_rejects_non_string_session_ids_as_invalid_split(tmp_path) -> None:
    manifest = tmp_path / "development.json"
    fixture_ids = [*[f"AISHELL-session-{index}" for index in range(7)], ["not", "an", "id"]]
    encoded = _write_manifest(tmp_path, fixture_ids)

    with pytest.raises(ValueError, match="locked eight-session development split"):
        _validate_locked_development_manifest(manifest, encoded)


def test_calibration_rejects_a_manifest_that_differs_from_the_split_lock(tmp_path) -> None:
    manifest = tmp_path / "development.json"
    encoded = _write_manifest(tmp_path, [f"AISHELL-session-{index}" for index in range(8)])
    lock_path = tmp_path / "split-lock.json"
    lock = json.loads(lock_path.read_text())
    lock["splits"]["development"]["manifest_sha256"] = "0" * 64
    lock_path.write_text(json.dumps(lock))

    with pytest.raises(ValueError, match="locked eight-session development split"):
        _validate_locked_development_manifest(manifest, encoded)


def test_calibration_rejects_a_split_lock_without_four_locked_holdout_meetings(tmp_path) -> None:
    manifest = tmp_path / "development.json"
    encoded = _write_manifest(tmp_path, [f"AISHELL-session-{index}" for index in range(8)])
    lock_path = tmp_path / "split-lock.json"
    lock = json.loads(lock_path.read_text())
    lock["splits"]["holdout"]["sessions"] = 3
    lock_path.write_text(json.dumps(lock))

    with pytest.raises(ValueError, match="locked eight-session development split"):
        _validate_locked_development_manifest(manifest, encoded)


def test_selected_candidate_hash_freezes_matching_and_acoustic_settings(tmp_path) -> None:
    policy = {"version": "development-grid-1", "match_distance_max": 0.25}
    clustering = {"threshold": 0.6, "warm_start_fa": 0.07, "warm_start_fb": 0.8}
    preprocessing = {
        "segmentation_step_ratio": 0.1,
        "embedding_min_segment_duration_seconds": 0.0,
    }

    digest = _write_selected_candidate(
        tmp_path,
        policy,
        clustering,
        preprocessing,
        zero_vote_reembed=True,
    )

    selected = json.loads((tmp_path / "selected-candidate.json").read_text())
    assert selected == {
        "schema_version": 1,
        "matching_policy": policy,
        "matching_embedding_space": "embedding256_cosine",
        "clustering_policy": clustering,
        "preprocessing_policy": preprocessing,
        "zero_vote_reembed": True,
    }
    assert json.loads((tmp_path / "selected-policy.json").read_text()) == policy
    assert digest == hashlib.sha256(
        (tmp_path / "selected-candidate.json").read_bytes()
    ).hexdigest()


def test_execution_lock_records_fixed_worker_and_model_revisions() -> None:
    lock = _execution_lock(
        manifest_sha256="manifest",
        executable_sha256="worker",
        candidates_sha256="candidates",
        screen_summary_sha256="screen",
        stage="refine",
        experiment="preprocessing",
        zero_vote_reembed=True,
    )

    assert lock == {
        "manifest_sha256": "manifest",
        "executable_sha256": "worker",
        "candidates_sha256": "candidates",
        "screen_summary_sha256": "screen",
        "stage": "refine",
        "experiment": "preprocessing",
        "sdk_revision": "5c19d5e12320e22bbfb7a1877b089d2665a69add",
        "model_revision": "7eab74f3463c736418d0eb10296261ae581146c9",
        "zero_vote_reembed": True,
        "scope": "native_development_not_formal_acceptance",
    }


def test_development_selection_is_frozen_only_after_every_session_passes() -> None:
    passing_sessions = [
        {"candidates": [{"metrics": {"quality_gate": "pass"}}]}
        for _ in range(8)
    ]
    failing_sessions = [
        *passing_sessions[:-1],
        {"candidates": [{"metrics": {"quality_gate": "fail"}}]},
    ]

    assert _development_gate_passed(0, passing_sessions) is True
    assert _development_gate_passed(0, failing_sessions) is False
    assert _development_gate_passed(None, passing_sessions) is False


def test_acoustic_grid_and_stage_candidate_shapes_are_frozen() -> None:
    acoustic = clustering_grid()
    policies = policy_grid("a" * 64)

    assert acoustic == [
        {"threshold": 0.60, "warm_start_fa": 0.07, "warm_start_fb": 0.8},
        {"threshold": 0.45, "warm_start_fa": 0.07, "warm_start_fb": 0.8},
        {"threshold": 0.75, "warm_start_fa": 0.07, "warm_start_fb": 0.8},
        {"threshold": 0.60, "warm_start_fa": 0.05, "warm_start_fb": 0.8},
        {"threshold": 0.60, "warm_start_fa": 0.09, "warm_start_fb": 0.8},
        {"threshold": 0.60, "warm_start_fa": 0.07, "warm_start_fb": 0.5},
        {"threshold": 0.60, "warm_start_fa": 0.07, "warm_start_fb": 1.1},
    ]
    screen = screen_candidate_grid(policies)
    assert len(screen) == 7
    assert all(candidate["matching_policy"] == policies[11] for candidate in screen)
    assert [candidate["clustering_policy"] for candidate in screen] == acoustic
    refinement = refinement_candidate_grid(policies, acoustic[3])
    assert len(refinement) == 24
    assert all(candidate["clustering_policy"] == acoustic[3] for candidate in refinement)
    assert all(
        candidate["preprocessing_policy"] == preprocessing_grid()[0]
        for candidate in screen
    )
    assert [candidate["matching_policy"] for candidate in refinement] == policies


def test_preprocessing_profiles_hold_clustering_fixed_and_screen_short_turn_settings() -> None:
    policies = policy_grid("a" * 64)
    profiles = preprocessing_grid()
    screen = screen_preprocessing_candidate_grid(policies)

    assert profiles == [
        {"segmentation_step_ratio": 0.2, "embedding_min_segment_duration_seconds": 1.0},
        {"segmentation_step_ratio": 0.1, "embedding_min_segment_duration_seconds": 1.0},
        {"segmentation_step_ratio": 0.2, "embedding_min_segment_duration_seconds": 0.0},
        {"segmentation_step_ratio": 0.1, "embedding_min_segment_duration_seconds": 0.0},
    ]
    assert len(screen) == 4
    assert [candidate["preprocessing_policy"] for candidate in screen] == profiles
    assert all(candidate["matching_policy"] == policies[11] for candidate in screen)
    assert all(candidate["clustering_policy"] == clustering_grid()[0] for candidate in screen)

    refinement = refinement_preprocessing_candidate_grid(policies, profiles[3])
    assert len(refinement) == 24
    assert all(candidate["preprocessing_policy"] == profiles[3] for candidate in refinement)
    assert all(candidate["clustering_policy"] == clustering_grid()[0] for candidate in refinement)
    assert [candidate["matching_policy"] for candidate in refinement] == policies


def test_matching_embedding_space_screen_changes_only_the_centroid_representation() -> None:
    policies = policy_grid("a" * 64)
    spaces = matching_embedding_space_grid()
    candidates = screen_matching_embedding_space_candidate_grid(policies)

    assert spaces == [
        {"matching_embedding_space": "embedding256_cosine"},
        {"matching_embedding_space": "plda_rho128_cosine"},
    ]
    assert len(candidates) == 2
    assert [candidate["matching_embedding_space"] for candidate in candidates] == [
        item["matching_embedding_space"] for item in spaces
    ]
    assert all(candidate["matching_policy"] == policies[11] for candidate in candidates)
    assert all(candidate["clustering_policy"] == clustering_grid()[5] for candidate in candidates)
    assert all(
        candidate["preprocessing_policy"] == preprocessing_grid()[3]
        for candidate in candidates
    )


def test_matching_embedding_space_refinement_keeps_selected_space_and_acoustic_settings() -> None:
    policies = policy_grid("a" * 64)
    space = matching_embedding_space_grid()[1]
    candidates = refinement_matching_embedding_space_candidate_grid(policies, space)

    assert len(candidates) == 24
    assert all(
        candidate["matching_embedding_space"] == "plda_rho128_cosine"
        for candidate in candidates
    )
    assert [candidate["matching_policy"] for candidate in candidates] == policies
    assert all(candidate["clustering_policy"] == clustering_grid()[5] for candidate in candidates)
    assert all(
        candidate["preprocessing_policy"] == preprocessing_grid()[3]
        for candidate in candidates
    )


def test_preprocessing_refinement_uses_the_profile_grid_from_the_locked_screen() -> None:
    profiles = preprocessing_grid()
    candidates = screen_preprocessing_candidate_grid(policy_grid("a" * 64))
    candidate_digest = hashlib.sha256(
        json.dumps(candidates, indent=2, sort_keys=True).encode()
    ).hexdigest()
    screen_summary = {
        "manifest_sha256": "manifest",
        "experiment": "preprocessing",
        "sdk_revision": "5c19d5e12320e22bbfb7a1877b089d2665a69add",
        "model_revision": "7eab74f3463c736418d0eb10296261ae581146c9",
        "candidate_set_sha256": candidate_digest,
        "ranked_indices": [2, 0, 1, 3],
        "top_two_indices": [2, 0],
        "candidates": [
            {
                "candidate_index": index,
                "clustering_policy": candidate["clustering_policy"],
                "preprocessing_policy": candidate["preprocessing_policy"],
            }
            for index, candidate in enumerate(candidates)
        ],
    }

    selected = _validate_refinement_screen_summary(
        screen_summary,
        manifest_sha256="manifest",
        experiment="preprocessing",
        candidate_set_sha256=candidate_digest,
        refine_index=2,
    )

    assert selected == profiles[2]
    with pytest.raises(ValueError, match="locked refinement run"):
        _validate_refinement_screen_summary(
            screen_summary,
            manifest_sha256="manifest",
            experiment="preprocessing",
            candidate_set_sha256=candidate_digest,
            refine_index=1,
        )


def test_embedding_space_refinement_accepts_locked_screen_profile() -> None:
    profiles = matching_embedding_space_grid()
    candidates = screen_matching_embedding_space_candidate_grid(policy_grid("a" * 64))
    candidate_digest = hashlib.sha256(
        json.dumps(candidates, indent=2, sort_keys=True).encode()
    ).hexdigest()
    screen_summary = {
        "manifest_sha256": "manifest",
        "experiment": "embedding_space",
        "sdk_revision": "5c19d5e12320e22bbfb7a1877b089d2665a69add",
        "model_revision": "7eab74f3463c736418d0eb10296261ae581146c9",
        "candidate_set_sha256": candidate_digest,
        "ranked_indices": [1, 0],
        "top_two_indices": [1, 0],
        "candidates": [
            {
                "candidate_index": index,
                "matching_embedding_space": candidate["matching_embedding_space"],
            }
            for index, candidate in enumerate(candidates)
        ],
    }

    selected = _validate_refinement_screen_summary(
        screen_summary,
        manifest_sha256="manifest",
        experiment="embedding_space",
        candidate_set_sha256=candidate_digest,
        refine_index=1,
    )

    assert selected == profiles[1]


def test_screen_ranking_uses_worst_accuracy_then_mean_coverage_then_other_coverage() -> None:
    scores = [
        (0.95, 0.92, 0.80),
        (0.95, 0.92, 0.80),
        (0.95, 0.93, 0.70),
        (0.94, 0.99, 0.99),
        (0.96, 0.90, 0.70),
        (0.95, 0.91, 0.90),
        (0.95, 0.92, 0.81),
    ]
    sessions = [
        {
            "candidates": [
                {
                    "candidate_index": index,
                    "metrics": {
                        "known_accuracy": accuracy,
                        "known_coverage": coverage,
                        "other_min_known_coverage": other_coverage,
                    },
                }
                for index, (accuracy, coverage, other_coverage) in enumerate(scores)
            ]
        }
        for _ in range(8)
    ]

    assert _rank_screen_candidates(sessions) == [4, 2, 6, 0, 1, 5, 3]


def test_screen_summary_is_digest_locked_and_never_selects_a_candidate(tmp_path) -> None:
    payload = {
        "schema_version": 1,
        "stage": "screen",
        "ranked_indices": [0, 1],
        "top_two_indices": [0, 1],
    }
    digest = _write_screen_summary(tmp_path, payload)

    assert _load_screen_summary(tmp_path / "screen-summary.json") == (payload, digest)
    assert not (tmp_path / "selected-candidate.json").exists()
    (tmp_path / "screen-summary.json").write_text(json.dumps({**payload, "ranked_indices": [1, 0]}))
    with pytest.raises(ValueError, match="screen summary digest"):
        _load_screen_summary(tmp_path / "screen-summary.json")
