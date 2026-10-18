"""Isolated eight-slot session; never registered as a production capability.

Reuse the production session's cancellation-safe owner, compute leases and
bounded update queue. Only the private probability decoder differs. A caller
must inject a worker and the shared composition-root governor; this module
neither starts a separate service nor establishes cross-process exclusion.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import Callable, Mapping
from pathlib import Path

from meeting_candidate_protocol import candidate_activity_update

from speechrail.backends.diarization.coreml import CoreMLActivitySession
from speechrail.domain.diarization.types import DiarizationError
from speechrail.runtime.diarization_worker import CoreMLWorkerProcess
from speechrail.runtime.phase_trace import PhaseTrace
from speechrail.runtime.resource_governor import ResourceGovernor

MAX_APPEND_SAMPLES = 16_000


class CandidateActivitySession(CoreMLActivitySession):
    """One-second bounded input, eight-slot causal output, inherited ownership."""

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        if (
            type(start_sample) is not int
            or start_sample < 0
            or not isinstance(pcm16, bytes)
            or len(pcm16) % 2
            or len(pcm16) > MAX_APPEND_SAMPLES * 2
        ):
            await self.cancel()
            raise DiarizationError("invalid bounded candidate PCM", code="invalid_audio")
        await super().append(start_sample=start_sample, pcm16=pcm16)

    async def finish(self, *, through_sample: int) -> None:
        if type(through_sample) is not int or through_sample < 0:
            await self.cancel()
            raise DiarizationError("invalid candidate finish barrier", code="invalid_audio")
        await super().finish(through_sample=through_sample)

    async def _publish(self, response: dict[str, object], *, operation: str) -> None:
        try:
            update = candidate_activity_update(
                response,
                epoch=self._epoch,
                step_id=self._step_id,
                processed=self._processed,
                accepted=self._next_start,
                operation=operation,
            )
        except ValueError as exc:
            raise DiarizationError(
                "candidate probability packet is invalid", code="diarization_invalid_output"
            ) from exc
        self._step_id += 1
        self._processed = update.processed_through
        self._stable = update.stable_through
        try:
            self._updates.put_nowait(update)
        except asyncio.QueueFull as exc:
            raise DiarizationError("activity consumer is too slow", code="activity_gap") from exc


def open_candidate_session(
    *,
    epoch: str,
    governor: ResourceGovernor,
    worker_factory: Callable[[], CoreMLWorkerProcess],
    phase_trace: PhaseTrace | None = None,
) -> CandidateActivitySession:
    """Claim before construction; model loading remains inside compute admission."""
    generation = governor.diarization_owner.claim(epoch)
    try:
        worker = worker_factory()
        return CandidateActivitySession(
            worker=worker,
            epoch=epoch,
            governor=governor,
            generation=generation,
            phase_trace=phase_trace,
        )
    except BaseException:
        governor.diarization_owner.release(generation, reaped=True)
        raise


def decode_candidate_frames(header: Mapping[str, object], payload: bytes) -> dict[str, object]:
    """Large fast128 batches use bounded JSON payload, preserving the 64 KiB header."""
    if "frames" in header or not payload or len(payload) > 512 * 1024:
        raise ValueError("invalid candidate frame payload")
    try:
        frames = json.loads(payload)
    except (ValueError, UnicodeError) as exc:
        raise ValueError("invalid candidate frame payload") from exc
    if not isinstance(frames, list) or len(frames) > 2048:
        raise ValueError("candidate frames must be a bounded array")
    return {**header, "frames": frames}


class CandidateWorkerProcess(CoreMLWorkerProcess):
    """Supervised v3 child, with explicit preset and runtime preflight identity."""

    def __init__(
        self,
        *,
        executable: Path,
        model_path: Path,
        preset: str,
        compute_units: str,
    ) -> None:
        if preset not in {"fast32", "fast128"} or compute_units not in {
            "all",
            "cpuOnly",
            "cpuAndGPU",
            "cpuAndNeuralEngine",
        }:
            raise ValueError("invalid frozen candidate configuration")
        super().__init__(
            executable=executable,
            model_path=model_path,
            protocol_version=3,
            backend="nemotron3_candidate",
        )
        self.preset = preset
        self.compute_units = compute_units

    async def _launch(self, extra: list[str]) -> None:
        await super()._launch(
            [
                "--preset",
                self.preset,
                "--compute-units",
                self.compute_units,
            ]
        )

    async def request(
        self,
        header: Mapping[str, object],
        audio: bytes = b"",
    ) -> tuple[dict[str, object], bytes]:
        from meeting_candidate_protocol import SDK_REVISION

        response, payload = await super().request(header, audio)
        if (
            response.get("ok") is not True
            or response.get("backend") != "nemotron3_candidate"
            or response.get("sdk_revision") != SDK_REVISION
            or response.get("operation") != header.get("operation")
            or response.get("preset") != self.preset
            or response.get("compute_units") != self.compute_units
        ):
            raise RuntimeError("candidate runtime identity mismatch")
        if header.get("operation") == "preflight":
            if payload or response.get("model_shape_verified") is not True:
                raise RuntimeError("candidate model shape is unverified")
            return response, b""
        return decode_candidate_frames(response, payload), b""
