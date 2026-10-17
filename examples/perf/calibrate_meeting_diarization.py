"""Development calibration via one native worker; not public-API acceptance.

The native worker compares candidate matchers in RAM using the same acoustic
inference. Only anonymous activity intervals cross IPC; vectors never do.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import time
import wave
from pathlib import Path
from typing import Any, cast

from speechrail.runtime.diarization_worker import (
    MEETING_DYNAMIC_MODEL_REVISION,
    MEETING_DYNAMIC_SDK_REVISION,
    CoreMLWorkerProcess,
)

try:
    from .diarization_quality import score_diarization  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover - direct CLI
    from diarization_quality import score_diarization  # type: ignore[no-redef]

JsonDict = dict[str, Any]
CalibrationCandidate = dict[str, Any]
ClusteringPolicy = dict[str, float]


def _file_digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def _execution_lock(
    *,
    manifest_sha256: str,
    executable_sha256: str,
    candidates_sha256: str,
    screen_summary_sha256: str | None,
    stage: str,
    zero_vote_reembed: bool,
    experiment: str = "clustering",
) -> dict[str, object]:
    return {
        "manifest_sha256": manifest_sha256,
        "executable_sha256": executable_sha256,
        "candidates_sha256": candidates_sha256,
        "screen_summary_sha256": screen_summary_sha256,
        "stage": stage,
        "experiment": experiment,
        "sdk_revision": MEETING_DYNAMIC_SDK_REVISION,
        "model_revision": MEETING_DYNAMIC_MODEL_REVISION,
        "zero_vote_reembed": zero_vote_reembed,
        "scope": "native_development_not_formal_acceptance",
    }


def clustering_grid() -> list[dict[str, float]]:
    return [
        {"threshold": 0.60, "warm_start_fa": 0.07, "warm_start_fb": 0.8},
        {"threshold": 0.45, "warm_start_fa": 0.07, "warm_start_fb": 0.8},
        {"threshold": 0.75, "warm_start_fa": 0.07, "warm_start_fb": 0.8},
        {"threshold": 0.60, "warm_start_fa": 0.05, "warm_start_fb": 0.8},
        {"threshold": 0.60, "warm_start_fa": 0.09, "warm_start_fb": 0.8},
        {"threshold": 0.60, "warm_start_fa": 0.07, "warm_start_fb": 0.5},
        {"threshold": 0.60, "warm_start_fa": 0.07, "warm_start_fb": 1.1},
    ]


def preprocessing_grid() -> list[dict[str, float]]:
    """Declared segmentation/embedding ablations for meeting short turns."""
    return [
        {"segmentation_step_ratio": 0.2, "embedding_min_segment_duration_seconds": 1.0},
        {"segmentation_step_ratio": 0.1, "embedding_min_segment_duration_seconds": 1.0},
        {"segmentation_step_ratio": 0.2, "embedding_min_segment_duration_seconds": 0.0},
        {"segmentation_step_ratio": 0.1, "embedding_min_segment_duration_seconds": 0.0},
    ]


def matching_embedding_space_grid() -> list[JsonDict]:
    return [
        {"matching_embedding_space": "embedding256_cosine"},
        {"matching_embedding_space": "plda_rho128_cosine"},
    ]


def _candidate(
    matching_policy: JsonDict,
    clustering_policy: ClusteringPolicy,
    preprocessing_policy: JsonDict,
    matching_embedding_space: str = "embedding256_cosine",
) -> CalibrationCandidate:
    return {
        "matching_policy": matching_policy,
        "matching_embedding_space": matching_embedding_space,
        "clustering_policy": clustering_policy,
        "preprocessing_policy": preprocessing_policy,
    }


def screen_candidate_grid(policies: list[JsonDict]) -> list[CalibrationCandidate]:
    if len(policies) <= 11:
        raise ValueError("screen requires the locked matcher policy at index 11")
    baseline_preprocessing = preprocessing_grid()[0]
    return [
        _candidate(policies[11], clustering, baseline_preprocessing)
        for clustering in clustering_grid()
    ]


def screen_preprocessing_candidate_grid(
    policies: list[JsonDict],
) -> list[CalibrationCandidate]:
    if len(policies) <= 11:
        raise ValueError("screen requires the locked matcher policy at index 11")
    baseline_clustering = clustering_grid()[0]
    return [
        _candidate(policies[11], baseline_clustering, preprocessing)
        for preprocessing in preprocessing_grid()
    ]


def screen_matching_embedding_space_candidate_grid(
    policies: list[JsonDict],
) -> list[CalibrationCandidate]:
    if len(policies) <= 11:
        raise ValueError("screen requires the locked matcher policy at index 11")
    clustering = clustering_grid()[5]
    preprocessing = preprocessing_grid()[3]
    return [
        _candidate(
            policies[11],
            clustering,
            preprocessing,
            profile["matching_embedding_space"],
        )
        for profile in matching_embedding_space_grid()
    ]


def refinement_candidate_grid(
    policies: list[JsonDict], clustering: ClusteringPolicy
) -> list[CalibrationCandidate]:
    baseline_preprocessing = preprocessing_grid()[0]
    return [
        _candidate(policy, clustering, baseline_preprocessing) for policy in policies
    ]


def refinement_preprocessing_candidate_grid(
    policies: list[JsonDict], preprocessing: JsonDict
) -> list[CalibrationCandidate]:
    baseline_clustering = clustering_grid()[0]
    return [
        _candidate(policy, baseline_clustering, preprocessing) for policy in policies
    ]


def refinement_matching_embedding_space_candidate_grid(
    policies: list[JsonDict], embedding_space: JsonDict
) -> list[CalibrationCandidate]:
    clustering = clustering_grid()[5]
    preprocessing = preprocessing_grid()[3]
    return [
        _candidate(
            policy,
            clustering,
            preprocessing,
            embedding_space["matching_embedding_space"],
        )
        for policy in policies
    ]


def _screen_candidates(experiment: str, policies: list[JsonDict]) -> list[CalibrationCandidate]:
    if experiment == "clustering":
        return screen_candidate_grid(policies)
    if experiment == "preprocessing":
        return screen_preprocessing_candidate_grid(policies)
    if experiment == "embedding_space":
        return screen_matching_embedding_space_candidate_grid(policies)
    raise ValueError("unsupported calibration experiment")


def _experiment_profiles(experiment: str) -> list[JsonDict]:
    if experiment == "clustering":
        return cast(list[JsonDict], clustering_grid())
    if experiment == "preprocessing":
        return cast(list[JsonDict], preprocessing_grid())
    if experiment == "embedding_space":
        return matching_embedding_space_grid()
    raise ValueError("unsupported calibration experiment")


def _validate_refinement_screen_summary(
    screen_summary: JsonDict,
    *,
    manifest_sha256: str,
    experiment: str,
    candidate_set_sha256: str,
    refine_index: int,
) -> JsonDict:
    profiles = _experiment_profiles(experiment)
    ranked_indices = screen_summary.get("ranked_indices")
    top_two = screen_summary.get("top_two_indices")
    screen_candidates = screen_summary.get("candidates")
    profile_field = {
        "clustering": "clustering_policy",
        "preprocessing": "preprocessing_policy",
        "embedding_space": "matching_embedding_space",
    }[experiment]
    expected_profile: object = (
        profiles[refine_index]
        if type(refine_index) is int and 0 <= refine_index < len(profiles)
        else None
    )
    if experiment == "embedding_space" and isinstance(expected_profile, dict):
        expected_profile = expected_profile.get(profile_field)
    if (
        screen_summary.get("manifest_sha256") != manifest_sha256
        or screen_summary.get("experiment") != experiment
        or screen_summary.get("sdk_revision") != MEETING_DYNAMIC_SDK_REVISION
        or screen_summary.get("model_revision") != MEETING_DYNAMIC_MODEL_REVISION
        or screen_summary.get("candidate_set_sha256") != candidate_set_sha256
        or type(refine_index) is not int
        or not isinstance(top_two, list)
        or refine_index not in top_two
        or not 0 <= refine_index < len(profiles)
        or not isinstance(ranked_indices, list)
        or len(ranked_indices) != len(profiles)
        or sorted(ranked_indices) != list(range(len(profiles)))
        or top_two != ranked_indices[:2]
        or not isinstance(screen_candidates, list)
        or len(screen_candidates) != len(profiles)
        or any(not isinstance(candidate, dict) for candidate in screen_candidates)
        or screen_candidates[refine_index].get("candidate_index") != refine_index
        or screen_candidates[refine_index].get(profile_field) != expected_profile
    ):
        raise ValueError("screen summary does not match this locked refinement run")
    return profiles[refine_index]


def _refinement_candidates(
    experiment: str, policies: list[JsonDict], profile: JsonDict
) -> list[CalibrationCandidate]:
    if experiment == "clustering":
        return refinement_candidate_grid(policies, cast(ClusteringPolicy, profile))
    if experiment == "preprocessing":
        return refinement_preprocessing_candidate_grid(policies, profile)
    if experiment == "embedding_space":
        return refinement_matching_embedding_space_candidate_grid(policies, profile)
    raise ValueError("unsupported calibration experiment")


def _rank_screen_candidates(sessions: list[JsonDict]) -> list[int]:
    if len(sessions) != 8:
        raise ValueError("screen ranking requires all eight development sessions")
    candidate_count = len(sessions[0].get("candidates", []))
    if candidate_count not in {
        len(clustering_grid()),
        len(preprocessing_grid()),
        len(matching_embedding_space_grid()),
    }:
        raise ValueError("screen ranking requires a declared acoustic candidate grid")
    metrics: list[list[JsonDict]] = [[] for _ in range(candidate_count)]
    for session in sessions:
        candidates = session.get("candidates")
        if not isinstance(candidates, list) or len(candidates) != candidate_count:
            raise ValueError("screen results have inconsistent candidate counts")
        for index, candidate in enumerate(candidates):
            if candidate.get("candidate_index") != index:
                raise ValueError("screen candidate order changed")
            metrics[index].append(candidate["metrics"])

    def rank_key(index: int) -> tuple[float, float, float, int]:
        values = metrics[index]
        accuracy = [float(item["known_accuracy"]) for item in values]
        coverage = [float(item["known_coverage"]) for item in values]
        other = [float(item["other_min_known_coverage"]) for item in values]
        if any(not math.isfinite(value) for value in (*accuracy, *coverage, *other)):
            raise ValueError("screen ranking contains a non-finite metric")
        return (
            -min(accuracy),
            -sum(coverage) / len(coverage),
            -min(other),
            index,
        )

    return sorted(range(candidate_count), key=rank_key)


def _write_screen_summary(output: Path, payload: dict[str, object]) -> str:
    if payload.get("schema_version") != 1 or payload.get("stage") != "screen":
        raise ValueError("invalid screen summary")
    path = output / "screen-summary.json"
    encoded = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
    digest = hashlib.sha256(encoded).hexdigest()
    path.write_bytes(encoded)
    path.with_name(path.name + ".sha256").write_text(digest + "\n")
    return digest


def _load_screen_summary(path: Path) -> tuple[JsonDict, str]:
    try:
        encoded = path.read_bytes()
        expected = path.with_name(path.name + ".sha256").read_text().strip()
    except OSError as exc:
        raise ValueError("screen summary digest is unavailable") from exc
    actual = hashlib.sha256(encoded).hexdigest()
    if expected != actual:
        raise ValueError("screen summary digest does not match")
    try:
        payload = json.loads(encoded)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("screen summary is invalid") from exc
    ranked = payload.get("ranked_indices") if isinstance(payload, dict) else None
    top_two = payload.get("top_two_indices") if isinstance(payload, dict) else None
    if (
        not isinstance(payload, dict)
        or payload.get("schema_version") != 1
        or payload.get("stage") != "screen"
        or not isinstance(ranked, list)
        or not isinstance(top_two, list)
        or len(top_two) != 2
        or any(type(item) is not int for item in ranked)
        or any(type(item) is not int or item not in ranked for item in top_two)
    ):
        raise ValueError("screen summary is invalid")
    return cast(JsonDict, payload), actual


def policy_grid(calibration_digest: str) -> list[JsonDict]:
    return [
        {
            "version": f"development-grid-{index}",
            "prototype_policy": "anchor_farthest_v1",
            "match_distance_max": match,
            "match_margin_min": margin,
            "update_distance_max": match * ratio,
            "minimum_new_voice_ms": 1500,
            "minimum_update_voice_ms": 2000,
            "candidate_retention_ms": 60000,
            "model_snapshot": MEETING_DYNAMIC_MODEL_REVISION,
            "calibration_digest": calibration_digest,
        }
        for index, (match, margin, ratio) in enumerate(
            (m, g, u)
            for m in (0.15, 0.25, 0.35, 0.45)
            for g in (0.03, 0.06, 0.10)
            for u in (0.5, 0.7)
        )
    ]


def replace_mutable(
    old: list[JsonDict], incoming: list[JsonDict], previous_stable: int, end: int
) -> list[JsonDict]:
    """Auditor keeps the stable prefix and replaces exactly the mutable interval."""
    cursor = previous_stable
    for frame in incoming:
        if (
            type(frame.get("start")) is not int
            or type(frame.get("end")) is not int
            or (frame["start"] != cursor or not cursor < frame["end"] <= end)
        ):
            raise ValueError("calibration activity has a gap or overlap")
        if any(type(slot) is not int or not 0 <= slot < 32 for slot in frame["active_slots"]):
            raise ValueError("invalid calibration speaker slot")
        cursor = frame["end"]
    if cursor != end:
        raise ValueError("calibration activity omits accepted samples")
    prefix = [
        {**frame, "end": min(frame["end"], previous_stable)}
        for frame in old
        if frame["start"] < previous_stable
    ]
    return prefix + incoming


def speaker_spans(frames: list[JsonDict]) -> list[JsonDict]:
    return [
        {
            "start": frame["start"] / 16000,
            "end": frame["end"] / 16000,
            "speaker": "S" + str(slot + 1),
        }
        for frame in frames
        for slot in frame["active_slots"]
    ]


def _validate_locked_development_manifest(
    manifest_path: Path, manifest_bytes: bytes
) -> list[JsonDict]:
    try:
        manifest = json.loads(manifest_bytes)
        split_lock = json.loads(manifest_path.with_name("split-lock.json").read_bytes())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("calibration requires the locked eight-session development split") from exc
    fixtures = manifest.get("fixtures") if isinstance(manifest, dict) else None
    splits = split_lock.get("splits") if isinstance(split_lock, dict) else None
    development = splits.get("development") if isinstance(splits, dict) else None
    holdout = splits.get("holdout") if isinstance(splits, dict) else None
    dataset = split_lock.get("dataset") if isinstance(split_lock, dict) else None
    split_rule = split_lock.get("split_rule") if isinstance(split_lock, dict) else None
    fixture_ids = [
        fixture.get("id") for fixture in fixtures if isinstance(fixture, dict)
    ] if isinstance(fixtures, list) else []
    valid_fixture_ids = [identifier for identifier in fixture_ids if isinstance(identifier, str)]
    digest = hashlib.sha256(manifest_bytes).hexdigest()
    holdout_digest = holdout.get("manifest_sha256") if isinstance(holdout, dict) else None
    if (
        len(valid_fixture_ids) != 8
        or len(set(valid_fixture_ids)) != 8
        or any("R004" in identifier for identifier in valid_fixture_ids)
        or dataset != "AISHELL-4"
        or split_rule != "R004 holdout, all other selected sessions development"
        or not isinstance(development, dict)
        or development.get("sessions") != 8
        or development.get("manifest_sha256") != digest
        or not isinstance(holdout, dict)
        or holdout.get("sessions") != 4
        or not isinstance(holdout_digest, str)
        or len(holdout_digest) != 64
        or any(character not in "0123456789abcdef" for character in holdout_digest)
    ):
        raise ValueError("calibration requires the locked eight-session development split")
    return cast(list[JsonDict], fixtures)


def _write_selected_candidate(
    output: Path,
    matching_policy: JsonDict,
    clustering_policy: ClusteringPolicy,
    preprocessing_policy: JsonDict,
    *,
    matching_embedding_space: str = "embedding256_cosine",
    zero_vote_reembed: bool,
) -> str:
    (output / "selected-policy.json").write_text(json.dumps(matching_policy, indent=2))
    candidate = {
        "schema_version": 1,
        "matching_policy": matching_policy,
        "matching_embedding_space": matching_embedding_space,
        "clustering_policy": clustering_policy,
        "preprocessing_policy": preprocessing_policy,
        "zero_vote_reembed": zero_vote_reembed,
    }
    candidate_bytes = json.dumps(candidate, indent=2).encode("utf-8")
    candidate_path = output / "selected-candidate.json"
    candidate_path.write_bytes(candidate_bytes)
    return hashlib.sha256(candidate_bytes).hexdigest()


def _development_gate_passed(winner: int | None, sessions: list[JsonDict]) -> bool:
    return winner is not None and all(
        session["candidates"][winner]["metrics"]["quality_gate"] == "pass"
        for session in sessions
    )


async def calibrate(
    manifest: Path,
    output: Path,
    executable: Path,
    models: Path,
    *,
    stage: str,
    experiment: str = "clustering",
    screen_summary_path: Path | None = None,
    refine_index: int | None = None,
) -> None:
    repository = (await asyncio.to_thread(Path(__file__).resolve)).parents[2]
    resolved_output = await asyncio.to_thread(output.resolve)
    resolved_manifest = await asyncio.to_thread(manifest.resolve)
    if (
        resolved_output.is_relative_to(repository)
        or resolved_manifest.is_relative_to(repository)
        or await asyncio.to_thread(output.exists)
    ):
        raise ValueError("use a locked external manifest and new external output directory")
    if stage not in {"screen", "refine"}:
        raise ValueError("calibration stage must be screen or refine")
    if experiment not in {"clustering", "preprocessing", "embedding_space"}:
        raise ValueError("calibration experiment must be clustering or preprocessing")
    if stage == "screen" and (screen_summary_path is not None or refine_index is not None):
        raise ValueError("screen stage does not accept refinement inputs")
    if stage == "refine" and (screen_summary_path is None or refine_index is None):
        raise ValueError("refinement requires a screen summary and one acoustic candidate index")

    original = await asyncio.to_thread(manifest.read_bytes)
    fixtures = _validate_locked_development_manifest(resolved_manifest, original)
    digest = hashlib.sha256(original).hexdigest()
    policies = policy_grid(digest)
    screen_summary_digest: str | None = None
    if stage == "screen":
        candidates = _screen_candidates(experiment, policies)
    else:
        assert screen_summary_path is not None and refine_index is not None
        resolved_screen_summary = await asyncio.to_thread(screen_summary_path.resolve)
        if resolved_screen_summary.is_relative_to(repository):
            raise ValueError("screen summary must remain outside the repository")
        screen_summary, screen_summary_digest = await asyncio.to_thread(
            _load_screen_summary, resolved_screen_summary
        )
        expected_screen_bytes = json.dumps(
            _screen_candidates(experiment, policies), indent=2, sort_keys=True
        ).encode("utf-8")
        expected_screen_candidate_digest = hashlib.sha256(expected_screen_bytes).hexdigest()
        selected_profile = _validate_refinement_screen_summary(
            screen_summary,
            manifest_sha256=digest,
            experiment=experiment,
            candidate_set_sha256=expected_screen_candidate_digest,
            refine_index=refine_index,
        )
        candidates = _refinement_candidates(experiment, policies, selected_profile)

    await asyncio.to_thread(output.mkdir, parents=True)
    candidate_file = output / "calibration-candidates.json"
    candidate_file.write_text(json.dumps(candidates, indent=2, sort_keys=True))
    primary = output / "primary-policy.json"
    primary.write_text(json.dumps(candidates[0]["matching_policy"]))
    executable_digest = await asyncio.to_thread(_file_digest, executable)
    candidate_digest = await asyncio.to_thread(_file_digest, candidate_file)
    execution_lock = _execution_lock(
        manifest_sha256=digest,
        executable_sha256=executable_digest,
        candidates_sha256=candidate_digest,
        screen_summary_sha256=screen_summary_digest,
        stage=stage,
        zero_vote_reembed=False,
        experiment=experiment,
    )
    (output / "execution-lock.json").write_text(json.dumps(execution_lock, indent=2))
    all_results: list[JsonDict] = []
    for fixture in fixtures:
        if await asyncio.to_thread(manifest.read_bytes) != original:
            raise ValueError("calibration manifest changed")
        audio = Path(fixture["path"])
        if await asyncio.to_thread(_file_digest, audio) != fixture["audio_sha256"]:
            raise ValueError("calibration audio digest differs from lock")
        reference = Path(fixture["reference_path"])
        if await asyncio.to_thread(_file_digest, reference) != fixture["reference_sha256"]:
            raise ValueError("calibration reference digest differs from lock")
        truth = json.loads(await asyncio.to_thread(reference.read_text))["speaker_spans"]
        worker = CoreMLWorkerProcess(
            executable=executable,
            model_path=models,
            protocol_version=2,
            backend="meeting_dynamic",
            policy_path=primary,
            calibration_candidates_path=candidate_file,
        )
        frames: list[list[JsonDict]] = [[] for _ in candidates]
        timings: list[float] = []
        peaks: list[dict[str, int]] = [
            {"identities": 0, "prototypes": 0, "candidates": 0} for _ in candidates
        ]
        previous_stable = 0
        try:
            async with asyncio.timeout(120):
                await worker.start()
            with wave.open(str(audio)) as wav:
                if (wav.getnchannels(), wav.getframerate(), wav.getsampwidth()) != (1, 16000, 2):
                    raise ValueError("calibration requires 16 kHz mono PCM16")
                count = wav.getnframes()
                for end in [*range(160000, count, 160000), count]:
                    start = max(0, end - 480000)
                    wav.setpos(start)
                    pcm = wav.readframes(end - start)
                    started = time.monotonic()
                    async with asyncio.timeout(120):
                        response, payload = await worker.request(
                            {
                                "operation": "infer",
                                "epoch": fixture["id"],
                                "audio_start": start,
                                "audio_samples": end - start,
                                "previous_stable": previous_stable,
                                "final": end == count,
                            },
                            pcm,
                        )
                    if response.get("ok") is not True or response.get("epoch") != fixture["id"]:
                        raise RuntimeError("native calibration inference failed")
                    timings.append(time.monotonic() - started)
                    variants = json.loads(payload)
                    if len(variants) != len(candidates) or [
                        v["candidate_index"] for v in variants
                    ] != list(range(len(candidates))):
                        raise ValueError("calibration candidate identity changed")
                    for index, variant in enumerate(variants):
                        frames[index] = replace_mutable(
                            frames[index], variant["frames"], previous_stable, end
                        )
                        for field, key in (
                            ("identities", "identity_count"),
                            ("prototypes", "prototype_count"),
                            ("candidates", "candidate_count"),
                        ):
                            peaks[index][field] = max(peaks[index][field], variant[key])
                    stable = response["stable_through"]
                    if (
                        type(stable) is not int
                        or not previous_stable <= stable <= end
                        or (end == count and stable != end)
                    ):
                        raise ValueError("calibration watermark is invalid")
                    previous_stable = stable
                    (output / "progress.json").write_text(
                        json.dumps(
                            {
                                "fixture_id": fixture["id"],
                                "processed_seconds": end / 16000,
                                "total_seconds": count / 16000,
                                "completed_sessions": len(all_results),
                                "inference_count": len(timings),
                            }
                        )
                    )
        finally:
            await worker.close()
        (output / (fixture["id"] + ".activity.json")).write_text(
            json.dumps(
                {
                    "frames": frames,
                    "retained_state_peaks": peaks,
                    "duration_seconds": count / 16000,
                    "infer_seconds": timings,
                    "executable_sha256": executable_digest,
                    "manifest_sha256": digest,
                    "candidate_set_sha256": candidate_digest,
                    "stage": stage,
                }
            )
        )
        results = [
            {
                "candidate_index": index,
                "metrics": score_diarization(
                    truth, speaker_spans(activity), duration=count / 16000
                ),
                "retained_state_peaks": peaks[index],
            }
            for index, activity in enumerate(frames)
        ]
        result = {
            "fixture_id": fixture["id"],
            "duration_seconds": count / 16000,
            "infer_seconds": timings,
            "candidates": results,
        }
        (output / (fixture["id"] + ".json")).write_text(json.dumps(result, indent=2))
        all_results.append(result)
        print(
            json.dumps(
                {
                    "completed_fixture": fixture["id"],
                    "sessions": len(all_results),
                    "passing_candidates": sum(
                        r["metrics"]["quality_gate"] == "pass" for r in results
                    ),
                }
            ),
            flush=True,
        )
    def refinement_rank(index: int) -> tuple[float, float, int]:
        scores = [s["candidates"][index]["metrics"] for s in all_results]
        return (
            sum(s["known_coverage"] for s in scores) / len(scores),
            min(s["other_min_known_coverage"] for s in scores),
            -index,
        )

    winner: int | None = None
    best_observed: int | None = None
    selected_candidate_sha256: str | None = None
    feasible: list[int] = []
    if stage == "screen":
        ranked = _rank_screen_candidates(all_results)
        screen_summary_payload: JsonDict = {
            "schema_version": 1,
            "stage": "screen",
            "experiment": experiment,
            "manifest_sha256": digest,
            "sdk_revision": MEETING_DYNAMIC_SDK_REVISION,
            "model_revision": MEETING_DYNAMIC_MODEL_REVISION,
            "candidate_set_sha256": candidate_digest,
            "candidates": [
                {
                    "candidate_index": index,
                    "matching_embedding_space": candidates[index][
                        "matching_embedding_space"
                    ],
                    "clustering_policy": candidates[index]["clustering_policy"],
                    "preprocessing_policy": candidates[index]["preprocessing_policy"],
                    "minimum_known_accuracy": min(
                        session["candidates"][index]["metrics"]["known_accuracy"]
                        for session in all_results
                    ),
                    "mean_known_coverage": sum(
                        session["candidates"][index]["metrics"]["known_coverage"]
                        for session in all_results
                    ) / len(all_results),
                    "minimum_other_speaker_coverage": min(
                        session["candidates"][index]["metrics"]["other_min_known_coverage"]
                        for session in all_results
                    ),
                }
                for index in range(len(candidates))
            ],
            "ranked_indices": ranked,
            "top_two_indices": ranked[:2],
        }
        screen_summary_digest = await asyncio.to_thread(
            _write_screen_summary, output, screen_summary_payload
        )
        best_observed = ranked[0]
        development_gate_passed = False
    else:
        feasible = [
            index
            for index in range(len(candidates))
            if _development_gate_passed(index, all_results)
        ]
        best_observed = max(
            range(len(candidates)),
            key=lambda index: (
                min(
                    session["candidates"][index]["metrics"]["known_accuracy"]
                    for session in all_results
                ),
                *refinement_rank(index),
            ),
        )
        winner = max(feasible, key=refinement_rank) if feasible else None
        development_gate_passed = _development_gate_passed(winner, all_results)
        if development_gate_passed:
            assert winner is not None and refine_index is not None
            selected_candidate_sha256 = _write_selected_candidate(
                output,
                candidates[winner]["matching_policy"],
                candidates[winner]["clustering_policy"],
                candidates[winner]["preprocessing_policy"],
                matching_embedding_space=candidates[winner][
                    "matching_embedding_space"
                ],
                zero_vote_reembed=False,
            )

    summary: JsonDict = {
        "schema_version": 1,
        "tool": "speechrail-diarization-development-calibration",
        "evidence_mode": "native_development",
        "formal_public_api_acceptance": False,
        "manifest_sha256": digest,
        "sdk_revision": MEETING_DYNAMIC_SDK_REVISION,
        "model_revision": MEETING_DYNAMIC_MODEL_REVISION,
        "zero_vote_reembed": False,
        "stage": stage,
        "experiment": experiment,
        "sessions": len(all_results),
        "candidates": len(candidates),
        "feasible_candidates": feasible if stage == "refine" else [],
        "winner_index": winner,
        "best_observed_index": best_observed,
        "selected_candidate_sha256": selected_candidate_sha256,
        "quality_gate": (
            "diagnostic_only"
            if stage == "screen"
            else "pass" if development_gate_passed else "fail"
        ),
        "production_certified": False,
    }
    if stage == "screen":
        summary["ranked_indices"] = screen_summary_payload["ranked_indices"]
        summary["top_two_indices"] = screen_summary_payload["top_two_indices"]
        summary["screen_summary_sha256"] = screen_summary_digest
    else:
        assert refine_index is not None
        summary["screen_summary_sha256"] = screen_summary_digest
        summary["clustering_policy"] = candidates[0]["clustering_policy"]
        summary["preprocessing_policy"] = candidates[0]["preprocessing_policy"]
        summary["matching_embedding_space"] = candidates[0][
            "matching_embedding_space"
        ]
    (output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("manifest", "output", "executable", "models"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--stage", choices=("screen", "refine"), required=True)
    parser.add_argument(
        "--experiment",
        choices=("clustering", "preprocessing", "embedding_space"),
        default="clustering",
    )
    parser.add_argument("--screen-summary", type=Path)
    parser.add_argument("--refine-index", type=int)
    args = parser.parse_args()
    asyncio.run(
        calibrate(
            args.manifest,
            args.output,
            args.executable,
            args.models,
            stage=args.stage,
            experiment=args.experiment,
            screen_summary_path=args.screen_summary,
            refine_index=args.refine_index,
        )
    )
