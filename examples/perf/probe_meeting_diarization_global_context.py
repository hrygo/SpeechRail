"""Compare session-wide offline VBx output against rolling-window meeting output."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
import wave
from pathlib import Path
from typing import Any, cast

from speechrail.runtime.diarization_worker import (
    MEETING_DYNAMIC_MODEL_REVISION,
    MEETING_DYNAMIC_SDK_REVISION,
)

try:
    from .calibrate_meeting_diarization import (  # type: ignore[import-not-found]
        _file_digest,
        _validate_locked_development_manifest,
        clustering_grid,
        preprocessing_grid,
    )
    from .diarization_quality import score_diarization  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover - direct CLI
    from calibrate_meeting_diarization import (  # type: ignore[no-redef]
        _file_digest,
        _validate_locked_development_manifest,
        clustering_grid,
        preprocessing_grid,
    )
    from diarization_quality import score_diarization  # type: ignore[no-redef]

JsonDict = dict[str, Any]
_ANONYMOUS_SPEAKER = re.compile(r"S[1-9][0-9]*\Z")
_PREPROCESSING_POLICIES = preprocessing_grid()
_CLUSTERING_POLICIES = clustering_grid()


def _validate_probe_payload(
    payload: object,
    *,
    expected_count: int,
    expected_preprocessing_count: int,
    expected_candidate_count: int,
) -> list[JsonDict]:
    if (
        not isinstance(payload, dict)
        or set(payload) != {"schema_version", "results"}
        or payload.get("schema_version") != 1
        or not isinstance(payload.get("results"), list)
        or len(payload["results"]) != expected_count
    ):
        raise ValueError("global probe result shape differs from the locked session list")

    results: list[JsonDict] = []
    for result in payload["results"]:
        if (
            not isinstance(result, dict)
            or set(result) != {"audio_loading_runtime_seconds", "preprocessing_profiles"}
            or type(result.get("audio_loading_runtime_seconds")) not in (int, float)
            or not math.isfinite(result["audio_loading_runtime_seconds"])
            or result["audio_loading_runtime_seconds"] < 0
            or not isinstance(result.get("preprocessing_profiles"), list)
            or len(result["preprocessing_profiles"]) != expected_preprocessing_count
        ):
            raise ValueError("global probe session result is invalid")
        for preprocessing_index, profile in enumerate(result["preprocessing_profiles"]):
            if (
                not isinstance(profile, dict)
                or set(profile)
                != {
                    "preprocessing_index",
                    "preparation_runtime_seconds",
                    "candidates",
                }
                or type(profile.get("preprocessing_index")) is not int
                or profile["preprocessing_index"] != preprocessing_index
                or type(profile.get("preparation_runtime_seconds")) not in (int, float)
                or not math.isfinite(profile["preparation_runtime_seconds"])
                or profile["preparation_runtime_seconds"] <= 0
                or not isinstance(profile.get("candidates"), list)
                or len(profile["candidates"]) != expected_candidate_count
            ):
                raise ValueError("global probe preprocessing result is invalid")
            for candidate_index, candidate in enumerate(profile["candidates"]):
                if (
                    not isinstance(candidate, dict)
                    or set(candidate)
                    != {"candidate_index", "runtime_seconds", "segments"}
                    or type(candidate.get("candidate_index")) is not int
                    or candidate["candidate_index"] != candidate_index
                    or type(candidate.get("runtime_seconds")) not in (int, float)
                    or not math.isfinite(candidate["runtime_seconds"])
                    or candidate["runtime_seconds"] <= 0
                    or not isinstance(candidate.get("segments"), list)
                ):
                    raise ValueError("global probe candidate result is invalid")
                for segment in candidate["segments"]:
                    if (
                        not isinstance(segment, dict)
                        or set(segment) != {"start", "end", "speaker"}
                        or type(segment.get("start")) not in (int, float)
                        or type(segment.get("end")) not in (int, float)
                        or not math.isfinite(segment["start"])
                        or not math.isfinite(segment["end"])
                        or segment["start"] < 0
                        or segment["end"] <= segment["start"]
                        or not isinstance(segment.get("speaker"), str)
                        or _ANONYMOUS_SPEAKER.fullmatch(segment["speaker"]) is None
                    ):
                        raise ValueError("global probe segment is invalid or not anonymous")
        results.append(cast(JsonDict, result))
    return results


def _clip_segments_to_duration(
    segments: list[JsonDict], *, duration: float
) -> tuple[list[JsonDict], int]:
    clipped: list[JsonDict] = []
    clipped_count = 0
    for segment in segments:
        start = float(segment["start"])
        end = float(segment["end"])
        if end > duration + 1.0 + 1e-9:
            raise ValueError("SDK segment exceeds the supported SDK tail-padding bound")
        bounded_start = min(start, duration)
        bounded_end = min(end, duration)
        if bounded_end <= bounded_start:
            clipped_count += 1
            continue
        if bounded_start != start or bounded_end != end:
            clipped_count += 1
        clipped.append(
            {"start": bounded_start, "end": bounded_end, "speaker": segment["speaker"]}
        )
    return clipped, clipped_count


def _run_probe(executable: Path, models: Path, fixtures: list[JsonDict]) -> list[JsonDict]:
    command = [str(executable), "--model-dir", str(models)]
    command.extend(
        (
            "--clustering-policies-json",
            json.dumps(_CLUSTERING_POLICIES, separators=(",", ":"), sort_keys=True),
            "--preprocessing-policies-json",
            json.dumps(_PREPROCESSING_POLICIES, separators=(",", ":"), sort_keys=True),
        )
    )
    for fixture in fixtures:
        command.extend(("--audio", str(Path(fixture["path"]))))

    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
    )
    payload: object | None = None
    assert process.stdout is not None
    for line in process.stdout:
        stripped = line.rstrip("\n")
        if stripped.startswith("PROGRESS "):
            parts = stripped.split()
            if len(parts) == 3 and parts[1].isdigit() and parts[2].isdigit():
                print(
                    json.dumps(
                        {"completed_sessions": int(parts[1]), "session_count": int(parts[2])}
                    ),
                    flush=True,
                )
        elif stripped.startswith("GLOBAL_PROBE_JSON\t"):
            payload = json.loads(stripped.partition("\t")[2])

    return_code = process.wait()
    if return_code != 0 or payload is None:
        raise RuntimeError("native global-context probe did not complete")
    return _validate_probe_payload(
        payload,
        expected_count=len(fixtures),
        expected_preprocessing_count=len(_PREPROCESSING_POLICIES),
        expected_candidate_count=len(_CLUSTERING_POLICIES),
    )


def _validate_audio_fixture(fixture: JsonDict) -> tuple[Path, Path, int]:
    audio = Path(fixture["path"])
    reference = Path(fixture["reference_path"])
    if _file_digest(audio) != fixture["audio_sha256"]:
        raise ValueError("development audio digest differs from the lock")
    if _file_digest(reference) != fixture["reference_sha256"]:
        raise ValueError("development reference digest differs from the lock")
    with wave.open(str(audio), "rb") as source:
        if (source.getnchannels(), source.getframerate(), source.getsampwidth()) != (1, 16000, 2):
            raise ValueError("global-context probe requires 16 kHz mono PCM16 audio")
        frame_count = source.getnframes()
    if frame_count <= 0:
        raise ValueError("development audio is empty")
    return audio, reference, frame_count


def _summary_metrics(
    session_metrics: list[JsonDict], runtimes: list[float], clipped_counts: list[int]
) -> JsonDict:
    count = len(session_metrics)
    values = {
        key: [float(item[key]) for item in session_metrics]
        for key in (
            "known_accuracy",
            "known_coverage",
            "top_four_min_known_coverage",
            "other_min_known_coverage",
            "der",
        )
    }
    return {
        "session_count": count,
        "quality_gate_pass_sessions": sum(
            item["quality_gate"] == "pass" for item in session_metrics
        ),
        "mean_known_accuracy": sum(values["known_accuracy"]) / count,
        "minimum_known_accuracy": min(values["known_accuracy"]),
        "mean_known_coverage": sum(values["known_coverage"]) / count,
        "minimum_top_four_known_coverage": min(values["top_four_min_known_coverage"]),
        "minimum_other_speaker_known_coverage": min(values["other_min_known_coverage"]),
        "mean_der": sum(values["der"]) / count,
        "mean_runtime_seconds": sum(runtimes) / len(runtimes),
        "boundary_clipped_segment_count": sum(clipped_counts),
        "boundary_clipped_sessions": sum(value > 0 for value in clipped_counts),
    }


def run_global_context_probe(
    *, manifest: Path, output: Path, executable: Path, models: Path
) -> None:
    repository = Path(__file__).resolve().parents[2]
    resolved_manifest = manifest.resolve()
    resolved_output = output.resolve()
    resolved_models = models.resolve()
    resolved_executable = executable.resolve()
    if (
        resolved_manifest.is_relative_to(repository)
        or resolved_output.is_relative_to(repository)
        or resolved_models.is_relative_to(repository)
        or output.exists()
    ):
        raise ValueError("manifest, model, and new result directory must remain external")
    if not resolved_executable.is_file() or not resolved_models.is_dir():
        raise ValueError("probe executable or local model directory is unavailable")
    if resolved_models.name != f"meeting-dynamic-{MEETING_DYNAMIC_MODEL_REVISION}":
        raise ValueError("local model directory revision differs from the locked revision")
    for name in ("Segmentation", "FBank", "Embedding", "PldaRho"):
        if not (resolved_models / f"{name}.mlmodelc").is_dir():
            raise ValueError("required precompiled local model is unavailable")
    if not (resolved_models / "plda-parameters.json").is_file():
        raise ValueError("local PLDA parameters are unavailable")

    manifest_bytes = resolved_manifest.read_bytes()
    fixtures = _validate_locked_development_manifest(resolved_manifest, manifest_bytes)
    fixture_files = [_validate_audio_fixture(fixture) for fixture in fixtures]
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    executable_digest = _file_digest(resolved_executable)
    output.mkdir(parents=True)
    execution_lock = {
        "manifest_sha256": manifest_digest,
        "executable_sha256": executable_digest,
        "sdk_revision": MEETING_DYNAMIC_SDK_REVISION,
        "model_revision": MEETING_DYNAMIC_MODEL_REVISION,
        "preprocessing_policies": _PREPROCESSING_POLICIES,
        "clustering_policies": _CLUSTERING_POLICIES,
        "zero_vote_reembed": False,
        "prediction_boundary_normalization": "clip_to_audio_duration; reject_overrun_gt_1s",
        "scope": "r003_development_global_context_diagnostic_only",
    }
    (output / "execution-lock.json").write_text(json.dumps(execution_lock, indent=2))

    results = _run_probe(resolved_executable, resolved_models, fixtures)
    if resolved_manifest.read_bytes() != manifest_bytes:
        raise ValueError("development manifest changed while the probe was running")

    candidate_count = len(_PREPROCESSING_POLICIES) * len(_CLUSTERING_POLICIES)
    session_metrics: list[list[JsonDict]] = [[] for _ in range(candidate_count)]
    runtimes: list[list[float]] = [[] for _ in range(candidate_count)]
    clipped_counts: list[list[int]] = [[] for _ in range(candidate_count)]
    session_summaries: list[JsonDict] = []
    activities: list[JsonDict] = []
    for index, (fixture, file_info, result) in enumerate(
        zip(fixtures, fixture_files, results, strict=True), start=1
    ):
        audio, reference, frame_count = file_info
        if (
            _file_digest(audio) != fixture["audio_sha256"]
            or _file_digest(reference) != fixture["reference_sha256"]
        ):
            raise ValueError("development fixture digest changed while the probe was running")
        duration = frame_count / 16000
        truth = json.loads(reference.read_text())["speaker_spans"]
        profile_summaries: list[JsonDict] = []
        profile_activities: list[JsonDict] = []
        for preprocessing_index, profile_result in enumerate(
            result["preprocessing_profiles"]
        ):
            candidate_session_rows: list[JsonDict] = []
            candidate_activities: list[JsonDict] = []
            for clustering_index, candidate in enumerate(profile_result["candidates"]):
                candidate_index = (
                    preprocessing_index * len(_CLUSTERING_POLICIES) + clustering_index
                )
                normalized_segments, clipped_count = _clip_segments_to_duration(
                    candidate["segments"], duration=duration
                )
                metrics = score_diarization(truth, normalized_segments, duration=duration)
                metrics.pop("participants", None)
                candidate_runtime = (
                    float(result["audio_loading_runtime_seconds"])
                    + float(profile_result["preparation_runtime_seconds"])
                    + float(candidate["runtime_seconds"])
                )
                session_metrics[candidate_index].append(metrics)
                runtimes[candidate_index].append(candidate_runtime)
                clipped_counts[candidate_index].append(clipped_count)
                candidate_session_rows.append(
                    {
                        "candidate_index": candidate_index,
                        "clustering_index": clustering_index,
                        "runtime_seconds": candidate_runtime,
                        "boundary_clipped_segment_count": clipped_count,
                        "metrics": metrics,
                    }
                )
                candidate_activities.append(
                    {
                        "candidate_index": candidate_index,
                        "segments": normalized_segments,
                    }
                )
            profile_summaries.append(
                {
                    "preprocessing_index": preprocessing_index,
                    "preparation_runtime_seconds": profile_result[
                        "preparation_runtime_seconds"
                    ],
                    "candidates": candidate_session_rows,
                }
            )
            profile_activities.append(
                {
                    "preprocessing_index": preprocessing_index,
                    "candidates": candidate_activities,
                }
            )
        session_summaries.append(
            {
                "session_index": index,
                "duration_seconds": duration,
                "audio_loading_runtime_seconds": result[
                    "audio_loading_runtime_seconds"
                ],
                "preprocessing_profiles": profile_summaries,
            }
        )
        activities.append(
            {"session_index": index, "preprocessing_profiles": profile_activities}
        )

    candidate_summaries = [
        {
            "candidate_index": preprocessing_index * len(_CLUSTERING_POLICIES)
            + clustering_index,
            "preprocessing_index": preprocessing_index,
            "clustering_index": clustering_index,
            "preprocessing_policy": preprocessing_policy,
            "clustering_policy": clustering_policy,
            "aggregate": _summary_metrics(
                session_metrics[
                    preprocessing_index * len(_CLUSTERING_POLICIES) + clustering_index
                ],
                runtimes[
                    preprocessing_index * len(_CLUSTERING_POLICIES) + clustering_index
                ],
                clipped_counts[
                    preprocessing_index * len(_CLUSTERING_POLICIES) + clustering_index
                ],
            ),
        }
        for preprocessing_index, preprocessing_policy in enumerate(_PREPROCESSING_POLICIES)
        for clustering_index, clustering_policy in enumerate(_CLUSTERING_POLICIES)
    ]
    ranked_indices = sorted(
        range(len(candidate_summaries)),
        key=lambda index: (
            -candidate_summaries[index]["aggregate"]["quality_gate_pass_sessions"],
            -candidate_summaries[index]["aggregate"]["minimum_known_accuracy"],
            -candidate_summaries[index]["aggregate"]["mean_known_coverage"],
            candidate_summaries[index]["aggregate"]["mean_der"],
            index,
        ),
    )
    best_observed_index = ranked_indices[0]
    winner_index = (
        best_observed_index
        if candidate_summaries[best_observed_index]["aggregate"][
            "quality_gate_pass_sessions"
        ]
        == len(fixtures)
        else None
    )
    summary = {
        **execution_lock,
        "candidate_count": len(candidate_summaries),
        "candidates": candidate_summaries,
        "ranked_indices": ranked_indices,
        "best_observed_index": best_observed_index,
        "winner_index": winner_index,
        "quality_gate": "pass" if winner_index is not None else "fail",
        "production_certified": False,
        "formal_public_api_acceptance": False,
        "sessions": session_summaries,
    }
    (output / "anonymous-activities.json").write_text(
        json.dumps({"schema_version": 1, "sessions": activities})
    )
    (output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps({"completed_sessions": len(results), "result": "complete"}), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--models", type=Path, required=True)
    args = parser.parse_args()
    try:
        run_global_context_probe(
            manifest=args.manifest,
            output=args.output,
            executable=args.executable,
            models=args.models,
        )
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"global-context diagnostic stopped: {type(exc).__name__}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
