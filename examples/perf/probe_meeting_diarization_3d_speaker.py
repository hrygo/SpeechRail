"""Evaluate the pinned 3D-Speaker pipeline on the locked R003 split only."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, cast

from calibrate_meeting_diarization import (
    _file_digest,
    _validate_locked_development_manifest,
)
from diarization_quality import score_diarization
from probe_meeting_diarization_global_context import _validate_audio_fixture

JsonDict = dict[str, Any]
_RECORD_ID = re.compile(r"meeting-[0-9]{4}\Z")
_SPEAKER_ID = re.compile(r"[0-9]+\Z")
_CAMPLUS_MODEL_ID = "iic/speech_campplus_sv_zh_en_16k-common_advanced"
_CAMPLUS_MODEL_REVISION = "v1.0.0"
_FSMN_VAD_MODEL_ID = "iic/speech_fsmn_vad_zh-cn-16k-common-pytorch"
_FSMN_VAD_MODEL_REVISION = "v2.0.4"


class CandidateRunnerError(RuntimeError):
    def __init__(self, *, exit_code: int, runner_error: JsonDict | None) -> None:
        super().__init__("3D-Speaker candidate runner failed before completing R003")
        self.exit_code = exit_code
        self.runner_error = runner_error

    def as_record(self) -> JsonDict:
        record = {
            "error": "candidate_runner_failed",
            "runner_exit_code": self.exit_code,
            "runner_error_type": self.runner_error.get("error")
            if self.runner_error is not None
            else None,
        }
        if self.runner_error is not None and "missing_module" in self.runner_error:
            record["missing_module"] = self.runner_error["missing_module"]
        return record


def _require_external_path(path: Path, *, repository_root: Path) -> Path:
    resolved = path.expanduser().resolve()
    root = repository_root.resolve()
    if resolved == root or resolved.is_relative_to(root):
        raise ValueError("evaluation inputs and outputs must remain external")
    return resolved


def _require_external_executable_path(
    path: Path, *, repository_root: Path
) -> Path:
    executable = path.expanduser().absolute()
    target = executable.resolve()
    root = repository_root.resolve()
    is_internal = any(
        candidate == root or candidate.is_relative_to(root)
        for candidate in (executable, target)
    )
    if is_internal:
        raise ValueError("evaluation inputs and outputs must remain external")
    return executable


def _read_dependency_lock(
    path: Path, *, repository_root: Path
) -> tuple[Path, bytes, str]:
    resolved = _require_external_path(path, repository_root=repository_root)
    if not resolved.is_file():
        raise ValueError("dependency lock is unavailable")
    contents = resolved.read_bytes()
    if not contents:
        raise ValueError("dependency lock is empty")
    if b"--hash=sha256:" not in contents:
        raise ValueError("dependency lock must contain artifact hashes")
    return resolved, contents, hashlib.sha256(contents).hexdigest()


def _validate_runner_error(value: object) -> JsonDict:
    if (
        not isinstance(value, dict)
        or set(value) not in ({"error"}, {"error", "missing_module"})
        or not isinstance(value.get("error"), str)
        or re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,79}", value["error"]) is None
        or ("missing_module" in value and value.get("error") != "ModuleNotFoundError")
        or (
            "missing_module" in value
            and (
                not isinstance(value["missing_module"], str)
                or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]{0,159}", value["missing_module"])
                is None
            )
        )
    ):
        raise ValueError("candidate runner error record is invalid")
    return cast(JsonDict, value)


def _parse_rttm(
    path: Path,
    *,
    duration: float,
    expected_record_id: str,
    allow_noise_label: bool = False,
) -> tuple[list[JsonDict], int, int]:
    if (
        not math.isfinite(duration)
        or duration <= 0
        or _RECORD_ID.fullmatch(expected_record_id) is None
    ):
        raise ValueError("invalid candidate scoring bounds")

    speaker_labels: dict[str, str] = {}
    segments: list[JsonDict] = []
    clipped_count = 0
    unassigned_count = 0
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            fields = line.split()
            if (
                len(fields) != 10
                or fields[0] != "SPEAKER"
                or fields[1] != expected_record_id
                or fields[2] != "0"
                or (
                    _SPEAKER_ID.fullmatch(fields[7]) is None
                    and not (allow_noise_label and fields[7] == "-1")
                )
                or len(segments) + unassigned_count >= 100_000
            ):
                raise ValueError("invalid candidate RTTM row")
            try:
                start = float(fields[3])
                segment_duration = float(fields[4])
            except ValueError as exc:
                raise ValueError("invalid candidate RTTM times") from exc
            end = start + segment_duration
            if (
                not math.isfinite(start)
                or not math.isfinite(segment_duration)
                or not math.isfinite(end)
                or start < 0
                or segment_duration <= 0
                or end > duration + 1.0 + 1e-9
            ):
                raise ValueError("candidate RTTM exceeds the supported tail-padding bound")

            bounded_start = min(start, duration)
            bounded_end = min(end, duration)
            was_clipped = bounded_start != start or bounded_end != end
            if fields[7] == "-1":
                unassigned_count += 1
                clipped_count += was_clipped or bounded_end <= bounded_start
                continue
            if bounded_end <= bounded_start:
                clipped_count += 1
                continue
            speaker_id = fields[7]
            if speaker_id not in speaker_labels:
                speaker_labels[speaker_id] = f"S{len(speaker_labels) + 1}"
            segments.append(
                {
                    "start": bounded_start,
                    "end": bounded_end,
                    "speaker": speaker_labels[speaker_id],
                }
            )
            clipped_count += was_clipped

    return segments, clipped_count, unassigned_count


def _validate_source_checkout(source: Path, *, expected_commit: str) -> str:
    if re.fullmatch(r"[0-9a-f]{40}", expected_commit) is None or not source.is_dir():
        raise ValueError("candidate source checkout is invalid")
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=source,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    dirty = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=source,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if revision != expected_commit or dirty.strip():
        raise ValueError("candidate source checkout is not the pinned clean revision")
    return revision


def _validate_runner_metadata(value: object, *, source_commit: str) -> JsonDict:
    required = {
        "schema_version",
        "source_commit",
        "python_version",
        "torch_version",
        "modelscope_version",
        "embedding_device",
        "vad_device",
        "clustering_device",
        "model_stage_runtime_seconds",
        "model_load_runtime_seconds",
        "model_assets",
        "cluster_policy",
    }
    asset_keys = {
        f"{_CAMPLUS_MODEL_ID}@{_CAMPLUS_MODEL_REVISION}",
        f"{_FSMN_VAD_MODEL_ID}@{_FSMN_VAD_MODEL_REVISION}",
    }
    if (
        not isinstance(value, dict)
        or set(value) != required
        or value.get("schema_version") != 1
        or value.get("source_commit") != source_commit
        or value.get("embedding_device") not in {"cpu", "mps"}
        or value.get("vad_device") != "cpu"
        or value.get("clustering_device") != "cpu"
        or not all(
            isinstance(value.get(key), str)
            for key in required
            - {
                "schema_version",
                "model_stage_runtime_seconds",
                "model_load_runtime_seconds",
                "model_assets",
                "cluster_policy",
            }
        )
        or type(value.get("model_stage_runtime_seconds")) not in (int, float)
        or not math.isfinite(value["model_stage_runtime_seconds"])
        or value["model_stage_runtime_seconds"] < 0
        or type(value.get("model_load_runtime_seconds")) not in (int, float)
        or not math.isfinite(value["model_load_runtime_seconds"])
        or value["model_load_runtime_seconds"] < 0
        or not isinstance(value.get("model_assets"), dict)
        or set(value["model_assets"]) != asset_keys
        or not isinstance(value.get("cluster_policy"), dict)
    ):
        raise ValueError("candidate runner metadata is invalid")
    cluster_policy = value["cluster_policy"]
    common_policy = {
        "cluster_type",
        "cluster_line",
        "min_cluster_size",
        "mer_cos",
        "speaker_count_mode",
    }
    if cluster_policy.get("cluster_type") == "spectral":
        policy_valid = (
            set(cluster_policy)
            == common_policy
            | {"pval", "min_num_spks", "max_num_spks", "oracle_num"}
            and cluster_policy.get("cluster_line") == 40
            and cluster_policy.get("min_cluster_size") in {0, 4}
            and cluster_policy.get("mer_cos") in (None, 0.8)
            and cluster_policy.get("pval") in {0.003, 0.012}
            and cluster_policy.get("min_num_spks") in {1, 4}
            and cluster_policy.get("max_num_spks") == 15
            and cluster_policy.get("oracle_num") is None
        )
    elif cluster_policy.get("cluster_type") == "AHC":
        policy_valid = (
            set(cluster_policy) == common_policy | {"fix_cos_thr"}
            and cluster_policy.get("cluster_line") == 40
            and cluster_policy.get("min_cluster_size") == 4
            and cluster_policy.get("mer_cos") == 0.8
            and cluster_policy.get("fix_cos_thr") == 0.4
        )
    elif cluster_policy.get("cluster_type") == "umap_hdbscan":
        policy_valid = (
            set(cluster_policy)
            == common_policy
            | {"n_neighbors", "n_components", "min_samples", "metric", "random_state"}
            and cluster_policy.get("cluster_line") == 40
            and cluster_policy.get("min_cluster_size") == 4
            and cluster_policy.get("mer_cos") == 0.8
            and cluster_policy.get("n_neighbors") == 20
            and cluster_policy.get("n_components") == 60
            and cluster_policy.get("min_samples") == 20
            and cluster_policy.get("metric") == "euclidean"
            and type(cluster_policy.get("random_state")) is int
            and cluster_policy.get("random_state") == 0
        )
    else:
        policy_valid = False
    if not policy_valid or cluster_policy.get("speaker_count_mode") != "automatic":
        raise ValueError("candidate spectral cluster policy is invalid")
    for digest in value["model_assets"].values():
        if (
            not isinstance(digest, dict)
            or set(digest) != {"file_count", "snapshot_sha256"}
            or type(digest.get("file_count")) is not int
            or digest["file_count"] <= 0
            or not isinstance(digest.get("snapshot_sha256"), str)
            or re.fullmatch(r"[0-9a-f]{64}", digest["snapshot_sha256"]) is None
        ):
            raise ValueError("candidate model digest is invalid")
    return cast(JsonDict, value)


def _summarize(
    results: list[JsonDict], runtimes: list[float], clipped_counts: list[int]
) -> JsonDict:
    if not results or len(results) != len(runtimes) or len(results) != len(clipped_counts):
        raise ValueError("candidate result count is invalid")
    metrics = [cast(JsonDict, result["metrics"]) for result in results]

    def values(key: str) -> list[float]:
        return [float(metric[key]) for metric in metrics]

    gates = {
        "known_coverage": 0.9,
        "known_accuracy": 0.95,
        "top_four_min_known_coverage": 0.95,
        "other_min_known_coverage": 0.8,
    }
    gate_pass_counts = {
        key: sum(float(metric[key]) >= threshold for metric in metrics)
        for key, threshold in gates.items()
    }
    return {
        "session_count": len(results),
        "quality_gate_pass_sessions": sum(metric["quality_gate"] == "pass" for metric in metrics),
        "all_sessions_pass": all(metric["quality_gate"] == "pass" for metric in metrics),
        "gate_pass_sessions": gate_pass_counts,
        "mean_known_coverage": math.fsum(values("known_coverage")) / len(metrics),
        "mean_known_accuracy": math.fsum(values("known_accuracy")) / len(metrics),
        "minimum_known_accuracy": min(values("known_accuracy")),
        "mean_der": math.fsum(values("der")) / len(metrics),
        "maximum_der": max(values("der")),
        "mean_jer": math.fsum(values("jer")) / len(metrics),
        "maximum_jer": max(values("jer")),
        "minimum_top_four_known_coverage": min(values("top_four_min_known_coverage")),
        "minimum_other_speaker_known_coverage": min(values("other_min_known_coverage")),
        "overlap_reference_speaker_seconds": math.fsum(
            float(metric["overlap_reference_speaker_seconds"]) for metric in metrics
        ),
        "short_under_two_seconds": sum(
            int(metric["short_under_two_seconds"]) for metric in metrics
        ),
        "boundary_clipped_segment_count": sum(clipped_counts),
        "unassigned_prediction_segment_count": sum(
            int(result["unassigned_prediction_segment_count"]) for result in results
        ),
        "mean_session_runtime_seconds": math.fsum(runtimes) / len(runtimes),
        "maximum_session_runtime_seconds": max(runtimes),
    }


def run_probe(
    *,
    manifest: Path,
    output: Path,
    speakerlab_root: Path,
    speaker_python: Path,
    model_cache: Path,
    dependency_lock: Path,
    expected_commit: str,
    disable_cosine_merge: bool = False,
    min_cluster_size: int = 4,
    spectral_pval: float = 0.012,
    min_num_spks: int = 1,
    cluster_type: str = "spectral",
    fix_cos_thr: float = 0.4,
) -> JsonDict:
    repository = Path(__file__).resolve().parents[2]
    resolved_manifest = _require_external_path(manifest, repository_root=repository)
    resolved_output = _require_external_path(output, repository_root=repository)
    resolved_speakerlab = _require_external_path(speakerlab_root, repository_root=repository)
    resolved_python = _require_external_executable_path(
        speaker_python, repository_root=repository
    )
    resolved_cache = _require_external_path(model_cache, repository_root=repository)
    resolved_dependency_lock, dependency_lock_bytes, dependency_lock_sha256 = (
        _read_dependency_lock(dependency_lock, repository_root=repository)
    )
    if not resolved_manifest.is_file() or resolved_output.exists():
        raise ValueError("locked manifest must exist and output directory must be new")
    if not resolved_python.is_file() or not resolved_speakerlab.is_dir():
        raise ValueError("isolated candidate runtime or checkout is unavailable")
    if resolved_cache.exists() and not resolved_cache.is_dir():
        raise ValueError("candidate model cache is not a directory")

    source_commit = _validate_source_checkout(
        resolved_speakerlab, expected_commit=expected_commit
    )
    manifest_bytes = resolved_manifest.read_bytes()
    fixtures = _validate_locked_development_manifest(resolved_manifest, manifest_bytes)
    fixture_inputs: list[tuple[JsonDict, Path, Path, int]] = []
    for fixture in fixtures:
        audio = _require_external_path(Path(fixture["path"]), repository_root=repository)
        reference = _require_external_path(
            Path(fixture["reference_path"]), repository_root=repository
        )
        checked_fixture = {**fixture, "path": str(audio), "reference_path": str(reference)}
        audio, reference, frame_count = _validate_audio_fixture(checked_fixture)
        fixture_inputs.append((fixture, audio, reference, frame_count))

    resolved_cache.mkdir(parents=True, exist_ok=True)
    resolved_output.mkdir(parents=True, exist_ok=False)
    predictions_dir = resolved_output / "predictions"
    predictions_dir.mkdir()
    runner_input_path = resolved_output / "audio-list.json"
    records = [
        {"record_id": f"meeting-{index:04d}", "audio_path": str(audio)}
        for index, (_, audio, _, _) in enumerate(fixture_inputs, start=1)
    ]
    runner_input_path.write_text(json.dumps(records), encoding="utf-8")
    runner_script = repository / "examples" / "perf" / "diarization_3d_speaker_runner.py"
    if not runner_script.is_file():
        raise ValueError("candidate runner is unavailable")

    started = time.perf_counter()
    runner_metadata: JsonDict | None = None
    runner_error: JsonDict | None = None
    runtimes: list[float] = []
    process: subprocess.Popen[str] | None = None
    try:
        command = [
            str(resolved_python),
            str(runner_script),
            "--speakerlab-root",
            str(resolved_speakerlab),
            "--model-cache-dir",
            str(resolved_cache),
            "--input-list",
            str(runner_input_path),
            "--output-dir",
            str(predictions_dir),
            "--min-cluster-size",
            str(min_cluster_size),
            "--spectral-pval",
            str(spectral_pval),
            "--min-num-spks",
            str(min_num_spks),
            "--cluster-type",
            cluster_type,
            "--fix-cos-thr",
            str(fix_cos_thr),
        ]
        if disable_cosine_merge:
            command.append("--disable-cosine-merge")
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
        )
        assert process.stdout is not None
        for line in process.stdout:
            stripped = line.rstrip("\n")
            if stripped.startswith("MODEL_METADATA\t"):
                runner_metadata = _validate_runner_metadata(
                    json.loads(stripped.partition("\t")[2]), source_commit=source_commit
                )
            elif stripped.startswith("PROGRESS\t"):
                progress = json.loads(stripped.partition("\t")[2])
                completed = progress.get("completed_sessions")
                runtime = progress.get("runtime_seconds")
                if (
                    type(completed) is not int
                    or completed != len(runtimes) + 1
                    or type(runtime) not in (int, float)
                    or not math.isfinite(runtime)
                    or runtime < 0
                ):
                    raise ValueError("candidate progress record is invalid")
                runtimes.append(float(runtime))
                print(
                    json.dumps({"completed_sessions": completed, "session_count": 8}),
                    flush=True,
                )
            elif stripped.startswith("ERROR\t"):
                if runner_error is not None:
                    raise ValueError("candidate runner emitted more than one error record")
                runner_error = _validate_runner_error(
                    json.loads(stripped.partition("\t")[2])
                )
        return_code = process.wait()
    except BaseException:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        raise
    finally:
        runner_input_path.unlink(missing_ok=True)
    if runner_error is not None:
        raise CandidateRunnerError(
            exit_code=return_code, runner_error=runner_error
        )
    if return_code != 0 or runner_metadata is None or len(runtimes) != len(fixtures):
        raise CandidateRunnerError(
            exit_code=return_code,
            runner_error=None,
        )
    if resolved_manifest.read_bytes() != manifest_bytes:
        raise ValueError("development manifest changed while the candidate was running")
    if resolved_dependency_lock.read_bytes() != dependency_lock_bytes:
        raise ValueError("dependency lock changed while the candidate was running")

    results: list[JsonDict] = []
    clipped_counts: list[int] = []
    for index, ((fixture, audio, reference, frame_count), runtime) in enumerate(
        zip(fixture_inputs, runtimes, strict=True), start=1
    ):
        if (
            _file_digest(audio) != fixture["audio_sha256"]
            or _file_digest(reference) != fixture["reference_sha256"]
        ):
            raise ValueError("development fixture digest changed while candidate was running")
        record_id = f"meeting-{index:04d}"
        prediction_path = predictions_dir / f"{record_id}.rttm"
        if not prediction_path.is_file():
            raise ValueError("candidate prediction is missing")
        duration = frame_count / 16000
        hypothesis, clipped_count, unassigned_count = _parse_rttm(
            prediction_path,
            duration=duration,
            expected_record_id=record_id,
            allow_noise_label=runner_metadata["cluster_policy"]["cluster_type"]
            == "umap_hdbscan",
        )
        truth = json.loads(reference.read_text(encoding="utf-8"))["speaker_spans"]
        metrics = score_diarization(truth, hypothesis, duration=duration)
        metrics.pop("participants", None)
        results.append(
            {
                "session_index": index,
                "duration_seconds": duration,
                "runtime_seconds": runtime,
                "boundary_clipped_segment_count": clipped_count,
                "unassigned_prediction_segment_count": unassigned_count,
                "metrics": metrics,
            }
        )
        clipped_counts.append(clipped_count)

    summary = _summarize(results, runtimes, clipped_counts)
    summary["total_runtime_seconds"] = time.perf_counter() - started
    run_lock = {
        "schema_version": 1,
        "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "dependency_lock_sha256": dependency_lock_sha256,
        "speaker_python_sha256": _file_digest(resolved_python),
        "source_commit": source_commit,
        "speaker_model_id": _CAMPLUS_MODEL_ID,
        "speaker_model_revision": _CAMPLUS_MODEL_REVISION,
        "vad_model_id": _FSMN_VAD_MODEL_ID,
        "vad_model_revision": _FSMN_VAD_MODEL_REVISION,
        "scorer": "pyannote.metrics",
        "scorer_version": "4.1",
        "collar_seconds": 0,
        "skip_overlap": False,
        "overlap_model_enabled": False,
        "speaker_count_mode": "automatic",
        "cluster_policy": runner_metadata["cluster_policy"],
        "process_mode": "single_process_serial_sessions",
        "runner": runner_metadata,
    }
    (resolved_output / "execution-lock.json").write_text(
        json.dumps(run_lock, indent=2, sort_keys=True), encoding="utf-8"
    )
    (resolved_output / "results.json").write_text(
        json.dumps(results, indent=2, sort_keys=True), encoding="utf-8"
    )
    (resolved_output / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8"
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--speakerlab-root", type=Path, required=True)
    parser.add_argument("--speaker-python", type=Path, required=True)
    parser.add_argument("--model-cache", type=Path, required=True)
    parser.add_argument("--dependency-lock", type=Path, required=True)
    parser.add_argument("--disable-cosine-merge", action="store_true")
    parser.add_argument("--min-cluster-size", type=int, default=4, choices=(0, 4))
    parser.add_argument("--spectral-pval", type=float, default=0.012, choices=(0.003, 0.012))
    parser.add_argument("--min-num-spks", type=int, default=1, choices=(1, 4))
    parser.add_argument(
        "--cluster-type",
        choices=("spectral", "AHC", "umap_hdbscan"),
        default="spectral",
    )
    parser.add_argument("--fix-cos-thr", type=float, default=0.4, choices=(0.4,))
    parser.add_argument("--expected-commit", required=True)
    arguments = parser.parse_args()
    try:
        summary = run_probe(
            manifest=arguments.manifest,
            output=arguments.output,
            speakerlab_root=arguments.speakerlab_root,
            speaker_python=arguments.speaker_python,
            model_cache=arguments.model_cache,
            dependency_lock=arguments.dependency_lock,
            expected_commit=arguments.expected_commit,
            disable_cosine_merge=arguments.disable_cosine_merge,
            min_cluster_size=arguments.min_cluster_size,
            spectral_pval=arguments.spectral_pval,
            min_num_spks=arguments.min_num_spks,
            cluster_type=arguments.cluster_type,
            fix_cos_thr=arguments.fix_cos_thr,
        )
    except CandidateRunnerError as exc:
        print(json.dumps(exc.as_record(), sort_keys=True), file=sys.stderr)
        return 1
    except Exception as exc:
        print(json.dumps({"error": type(exc).__name__}), file=sys.stderr)
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
