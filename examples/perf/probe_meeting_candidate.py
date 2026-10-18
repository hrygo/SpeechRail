"""Artifact preflight and serial development execution for C0/C1/C2.

Preflight reads files only. evaluate-development launches a supervised native
worker using caller-prepared local artifacts. No downloads or holdout execution.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import re
import struct
from pathlib import Path

from meeting_candidate_evidence import attribution_configuration
from meeting_candidate_protocol import SDK_REVISION
from meeting_evaluation_identity import (
    MeetingCandidateSpec,
    candidate_digest,
    canonical_digest,
    file_digest,
    model_file_digests,
    validate_execution_identity,
)

ROOT = Path(__file__).resolve().parents[2]
POLICY = Path(__file__).with_name("meeting-evaluation-policy.json")


def preset_configuration(name: str) -> dict[str, object]:
    """All SDK configuration fields, pinned to the approved monolithic FP16 presets."""
    if name not in {"fast32", "fast128"}:
        raise ValueError("only frozen fast32/fast128 FP16 candidates are allowed")
    return {
        "name": name, "num_speakers": 8, "pre_encoder_dims": 512,
        "subsampling_factor": 8, "mel_features": 128, "sample_rate": 16000,
        "upsample_factor": 8, "chunk_len": 32 if name == "fast32" else 128,
        "chunk_left_context": 0, "chunk_right_context": 4, "fifo_len": 40,
        "spkcache_len": 264, "spkcache_update_period": 40,
        "silence_threshold": 0.2, "pred_score_threshold": 0.25,
        "scores_boost_latest": 0.05, "strong_boost_rate": 0.75,
        "weak_boost_rate": 1.5, "min_pos_scores_rate": 0.5,
        "spkcache_sil_frames_per_spk": 1, "max_index": 99999,
        "debug_mode": False, "split_graph": False,
        "model_file_name": f"Nemotron3Diarizer_{name}.mlmodelc",
    }


def _source_digest(paths: tuple[str, ...]) -> str:
    return canonical_digest({name: file_digest(ROOT / name) for name in paths})


def static_candidate_spec(
    *, worker: Path, model_directory: Path, preset: str,
    model_revision: str, compute_units: str,
) -> MeetingCandidateSpec:
    """Bind observed files and frozen configuration, without claiming runtime provenance."""
    configuration = preset_configuration(preset)
    if re.fullmatch(r"[0-9a-f]{40}", model_revision) is None:
        raise ValueError("explicit model snapshot revision is required")
    if compute_units not in {"all", "cpuAndNeuralEngine", "cpuAndGPU", "cpuOnly"}:
        raise ValueError("explicit CoreML compute units are required")
    if worker.is_symlink() or not worker.is_file():
        raise ValueError("an exact candidate worker file is required")
    model_root = model_directory.resolve(strict=True)
    if model_root.is_relative_to(ROOT):
        raise ValueError("candidate models must remain outside the repository")
    bundle = model_root / str(configuration["model_file_name"])
    if (
        bundle.is_symlink() or not bundle.is_dir()
        or (bundle / "coremldata.bin").is_symlink()
        or not (bundle / "coremldata.bin").is_file()
    ):
        raise ValueError("the matching precompiled preset bundle is required; no implicit compile")
    embedding_path = model_root / "learnable_sil_emb.bin"
    if embedding_path.is_symlink() or embedding_path.stat().st_size != 512 * 4:
        raise ValueError("the local silence embedding must have exactly 2048 bytes")
    embedding = embedding_path.read_bytes()
    if len(embedding) != 512 * 4 or any(
        not math.isfinite(value[0]) for value in struct.iter_unpack("<f", embedding)
    ):
        raise ValueError("the local silence embedding must contain 512 finite Float32 values")
    policy = json.loads(POLICY.read_text(encoding="utf-8"))
    return MeetingCandidateSpec(
        implementation_id="nemotron3-streaming-candidate-v1",
        adapter_sha256=_source_digest((
            "examples/perf/probe_meeting_candidate.py",
            "examples/perf/meeting_candidate_protocol.py",
            "examples/perf/meeting_candidate_session.py",
            "examples/perf/meeting_candidate_execution.py",
            "src/speechrail/runtime/server_lock.py",
            "examples/perf/meeting_candidate_evidence.py",
            "examples/perf/meeting_candidate_runner.py",
            "examples/perf/meeting_asr_sidecar.py",
            "examples/perf/meeting_development_fixture.py",
            "examples/perf/meeting_candidate_schedule.py",
            "examples/perf/prepare_meeting_evaluation_manifest.py",
            "native/diarization-candidate/Package.swift",
            "native/diarization-candidate/Sources/CandidateFrames/CandidateFrames.swift",
            "native/diarization-candidate/Package.resolved",
            "native/diarization-candidate/Sources/MeetingDiarizationCandidate/main.swift",
            "native/diarization/Sources/SpeechRailDiarizationProtocol/PacketCodec.swift",
            "examples/perf/meeting_evaluation_identity.py",
            "src/speechrail/backends/diarization/coreml.py",
            "src/speechrail/runtime/diarization_owner.py",
            "src/speechrail/runtime/phase_trace.py",
            "src/speechrail/runtime/diarization_worker.py",
            "src/speechrail/runtime/resource_governor.py",
            "src/speechrail/runtime/cleanup.py",
            "src/speechrail/domain/diarization/types.py",
            "src/speechrail/domain/diarization/attribution.py",
            "src/speechrail/domain/audio_timeline.py",
        )),
        sdk_revision=SDK_REVISION, worker_sha256=file_digest(worker),
        model_revision=model_revision, model_files_sha256=model_file_digests(model_root),
        dtype="fp16", preset=configuration, compute_units=compute_units,
        decoder={"threshold": 0.5, "comparison": ">", "frame_samples": 160,
                 "minimum_turn_seconds": 0, "bridge_seconds": 0,
                 "ghost_merge": False, "consolidation": False, "vad_gate": False,
                 "tail": "clip_to_accepted_samples"},
        attribution=attribution_configuration(),
        scorer={"policy_sha256": canonical_digest(policy),
                "source_sha256": _source_digest((
                    "examples/perf/meeting_quality_metrics.py",
                    "examples/perf/diarization_quality.py",
                )), "versions": policy["scorer_versions"]},
    )


def artifact_preflight(
    spec: MeetingCandidateSpec, *, worker: Path, model_directory: Path,
) -> dict[str, object]:
    from meeting_c0 import C0_IMPLEMENTATION, static_c0_spec

    if spec.implementation_id == C0_IMPLEMENTATION:
        observed = static_c0_spec(worker=worker, model_directory=model_directory)
    elif spec.implementation_id == "nemotron3-streaming-candidate-v1":
        observed = static_candidate_spec(
            worker=worker, model_directory=model_directory,
            preset=str(spec.preset.get("name")), model_revision=spec.model_revision,
            compute_units=spec.compute_units,
        )
    else:
        raise ValueError("unknown frozen candidate implementation")
    validate_execution_identity(spec, observed.as_dict())
    return {
        "schema_version": 2, "mode": "artifact_preflight",
        "candidate_sha256": candidate_digest(observed),
        "artifact_spec_matches": True, "runtime_identity_verified": False,
        "model_shape_verified": False, "model_revision_provenance_verified": False,
        "model_slots": 4 if spec.implementation_id == C0_IMPLEMENTATION else 8,
        "certified_max_speakers": None,
        "verdict": "not_evaluated",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    preflight = commands.add_parser(
        "preflight", help="read files only; no worker or model execution"
    )
    preflight.add_argument("--candidate-spec", required=True, type=Path)
    preflight.add_argument("--worker", required=True, type=Path)
    preflight.add_argument("--model-directory", required=True, type=Path)
    development = commands.add_parser(
        "evaluate-development",
        help="execute one locked development fixture; requires model-run authorization"
    )
    for name in ("candidate-spec", "worker", "model-directory", "manifest", "split-lock",
                 "scorer-policy", "artifact-root", "output-directory"):
        development.add_argument(f"--{name}", required=True, type=Path)
    development.add_argument("--fixture-id", required=True)
    development.add_argument("--service-port", required=True, type=int)
    development.add_argument(
        "--input-mode", choices=("throughput", "realtime"), default="throughput"
    )
    development.add_argument("--timeout-seconds", type=float, default=1800)
    args = parser.parse_args(argv)
    try:
        from meeting_candidate_execution import evaluate_candidate_development, read_control_json

        spec = MeetingCandidateSpec(**read_control_json(args.candidate_spec))
        if args.command == "preflight":
            report = artifact_preflight(
                spec, worker=args.worker, model_directory=args.model_directory
            )
        else:
            report = asyncio.run(evaluate_candidate_development(
                spec=spec, worker=args.worker, model_directory=args.model_directory,
                manifest=read_control_json(args.manifest),
                split_lock=read_control_json(args.split_lock),
                scorer_policy=read_control_json(args.scorer_policy),
                artifact_root=args.artifact_root,
                output_directory=args.output_directory, fixture_id=args.fixture_id,
                service_port=args.service_port, input_mode=args.input_mode,
                timeout_seconds=args.timeout_seconds,
            ))
    except OSError:
        parser.error("required local artifact is unavailable")
    except (ValueError, TypeError, KeyError):
        parser.error("candidate spec or local artifacts do not match the frozen configuration")
    except RuntimeError as exc:
        if str(exc) == "evaluation_port_busy":
            parser.error("configured service port is busy; evaluation did not start a worker")
        parser.error("development execution failed; inspect the external attempt artifacts")
    print(json.dumps(report, sort_keys=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
