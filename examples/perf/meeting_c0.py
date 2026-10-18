"""Pinned four-slot C0 control for the shared development evaluator.

Protocol 1 confirms liveness, not SDK/configuration/shape provenance. The file
identity binds those source declarations; it does not certify the built worker.
"""

from __future__ import annotations

import json
import math
from collections.abc import Callable, Mapping
from pathlib import Path

from meeting_candidate_evidence import attribution_configuration
from meeting_evaluation_identity import (
    MeetingCandidateSpec,
    canonical_digest,
    file_digest,
    model_file_digests,
)

from speechrail.backends.diarization import coreml
from speechrail.domain.diarization.types import DiarizationError
from speechrail.runtime.diarization_worker import CoreMLWorkerProcess
from speechrail.runtime.phase_trace import PhaseTrace
from speechrail.runtime.resource_governor import ResourceGovernor

C0_IMPLEMENTATION = "sortformer-four-slot-control-v1"


C0_ADAPTER_SOURCES = (
    "examples/perf/meeting_c0.py",
    "examples/perf/probe_meeting_candidate.py",
    "examples/perf/meeting_candidate_execution.py",
    "examples/perf/meeting_checkpoint_execution.py",
    "examples/perf/meeting_candidate_evidence.py",
    "examples/perf/meeting_candidate_runner.py",
    "examples/perf/meeting_activity_workload.py",
    "examples/perf/meeting_pcm_feed.py",
    "examples/perf/meeting_live_text.py",
    "examples/perf/meeting_timing.py",
    "examples/perf/meeting_latency_policy.py",
    "examples/perf/meeting_asr_sidecar.py",
    "examples/perf/meeting_development_fixture.py",
    "examples/perf/meeting_candidate_schedule.py",
    "examples/perf/prepare_meeting_evaluation_manifest.py",
    "examples/perf/meeting_evaluation_identity.py",
    "native/diarization/Package.swift",
    "native/diarization/Package.resolved",
    "native/diarization/Sources/SpeechRailDiarizationWorker/main.swift",
    "native/diarization/Sources/SpeechRailDiarizationProtocol/PacketCodec.swift",
    "native/diarization/Sources/SpeechRailDiarizationProtocol/RetainedFrameCursor.swift",
    "src/speechrail/backends/diarization/coreml.py",
    "src/speechrail/runtime/server_lock.py",
    "src/speechrail/runtime/diarization_owner.py",
    "src/speechrail/runtime/diarization_worker.py",
    "src/speechrail/runtime/phase_trace.py",
    "src/speechrail/runtime/resource_governor.py",
    "src/speechrail/runtime/cleanup.py",
    "src/speechrail/domain/diarization/types.py",
    "src/speechrail/domain/diarization/attribution.py",
    "src/speechrail/domain/audio_timeline.py",
)


def static_c0_spec(*, worker: Path, model_directory: Path) -> MeetingCandidateSpec:
    """Require production-pinned model bytes; record every effective local file."""
    from probe_meeting_candidate import POLICY, ROOT, _source_digest

    if worker.is_symlink() or not worker.is_file() or model_directory.is_symlink():
        raise ValueError("exact C0 artifacts are required")
    models = model_directory.resolve(strict=True)
    if models.is_relative_to(ROOT):
        raise ValueError("C0 models must remain outside the repository")
    bundle = models / coreml.MODEL_BUNDLE_NAME
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError("the pinned C0 compiled bundle is required")
    digests = model_file_digests(models)
    for name, expected in coreml.MODEL_FILE_SHA256.items():
        if digests.get(f"{coreml.MODEL_BUNDLE_NAME}/{name}") != expected:
            raise ValueError("C0 model differs from the production-pinned artifact")
    for name, signatures in coreml.MODEL_MIL_SIGNATURES.items():
        data = (bundle / name).read_bytes()
        if any(signature.encode() not in data for signature in signatures):
            raise ValueError("C0 compiled model signature mismatch")
    policy = json.loads(POLICY.read_text(encoding="utf-8"))
    return MeetingCandidateSpec(
        implementation_id=C0_IMPLEMENTATION,
        adapter_sha256=_source_digest(C0_ADAPTER_SOURCES),
        sdk_revision=coreml.FLUIDAUDIO_COMMIT,
        worker_sha256=file_digest(worker),
        model_revision=coreml.MODEL_REVISION,
        model_files_sha256=digests,
        dtype=coreml.MODEL_DTYPE,
        compute_units="all",
        preset={
            "name": "balancedV2_1",
            "num_speakers": 4,
            "configuration": "SortformerConfig.balancedV2_1",
            "debug_mode": False,
            "timeline": "DiarizerTimelineConfig.sortformerDefault",
            "timeline_max_stored_seconds": 60,
            "timeline_store_segments": False,
            "model_file_name": coreml.MODEL_BUNDLE_NAME,
        },
        decoder={
            "threshold": 0.25,
            "comparison": ">=",
            "consolidation": False,
            "minimum_turn_seconds": 0,
            "bridge_seconds": 0,
            "ghost_merge": False,
            "vad_gate": False,
            "eof_padding": "one_right_context",
            "tail": "clip_to_accepted_samples",
        },
        attribution=attribution_configuration(),
        scorer={
            "policy_sha256": canonical_digest(policy),
            "source_sha256": _source_digest(
                ("examples/perf/meeting_quality_metrics.py", "examples/perf/diarization_quality.py",
                 "examples/perf/meeting_latency_policy.py")
            ),
            "versions": policy["scorer_versions"],
        },
    )


class C0WorkerProcess(CoreMLWorkerProcess):
    """Observe only what the existing protocol-1 preflight actually declares."""

    preflight_observed = False

    async def request(
        self, header: Mapping[str, object], audio: bytes = b""
    ) -> tuple[dict[str, object], bytes]:
        response, payload = await super().request(header, audio)
        if payload or response.get("ok") is not True:
            raise RuntimeError("invalid C0 packet")
        if header.get("operation") == "preflight":
            self.preflight_observed = True
        return response, payload


class C0ActivitySession(coreml.CoreMLActivitySession):
    """Production four-slot decoding, with fail-closed evaluation coverage checks."""

    async def _publish(self, response: dict[str, object], *, operation: str) -> None:
        end, stable, frames = (
            response.get(name) for name in ("processed_through", "stable_through", "frames")
        )
        if not isinstance(end, int) or type(end) is not int:
            raise DiarizationError(
                "invalid C0 probability coverage", code="diarization_invalid_output"
            )
        valid = (
            type(stable) is int
            and end == stable
            and self._processed <= end <= self._next_start
            and (operation != "finish" or end == self._next_start)
            and isinstance(frames, list)
            and len(frames) <= 2048
        )
        cursor = self._processed
        if valid and isinstance(frames, list):
            for frame in frames:
                if not isinstance(frame, dict):
                    valid = False
                    break
                start, stop, scores = (frame.get(name) for name in ("start", "end", "scores"))
                if (
                    type(start) is not int
                    or type(stop) is not int
                    or start != cursor
                    or not start < stop <= end
                    or not isinstance(scores, list)
                    or len(scores) != 4
                    or any(
                        type(score) not in {int, float}
                        or not math.isfinite(score)
                        or not 0 <= score <= 1
                        for score in scores
                    )
                ):
                    valid = False
                    break
                cursor = stop
        if not valid or cursor != end:
            raise DiarizationError(
                "invalid C0 probability coverage", code="diarization_invalid_output"
            )
        await super()._publish(response, operation=operation)


def open_c0_session(
    *,
    worker_factory: Callable[[], C0WorkerProcess],
    governor: ResourceGovernor,
    phase_trace: PhaseTrace,
) -> C0ActivitySession:
    generation = governor.diarization_owner.claim("session")
    try:
        return C0ActivitySession(
            worker=worker_factory(),
            epoch="session",
            governor=governor,
            generation=generation,
            phase_trace=phase_trace,
        )
    except BaseException:
        governor.diarization_owner.release(generation, reaped=True)
        raise
