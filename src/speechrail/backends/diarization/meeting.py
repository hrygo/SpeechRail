"""Local Community-1 windows; vectors never cross the native IPC boundary."""

from __future__ import annotations

import asyncio
import json
import math
import os
import time
from collections.abc import AsyncIterator, Callable
from pathlib import Path

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.types import (
    ActivityFrame,
    ActivityUpdate,
    DiarizationError,
    DiarizationReadiness,
)
from speechrail.observability.metrics import Metrics
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.diarization_worker import CoreMLWorkerProcess
from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass
from speechrail.runtime.window_pcm import PcmBudget, WindowPcmRing
from speechrail.service.diarization_assets import (
    MEETING_MODEL_REVISION,
    inspect_meeting_dynamic_assets,
)


def read_matching_policy(path: Path) -> dict[str, object]:
    """Policy has no implicit acoustic thresholds or production certification."""
    if path.is_symlink() or path.stat().st_size > 16384:
        raise ValueError("invalid matching policy file")
    value = json.loads(path.read_text())
    required = {
        "version",
        "prototype_policy",
        "match_distance_max",
        "match_margin_min",
        "update_distance_max",
        "minimum_new_voice_ms",
        "minimum_update_voice_ms",
        "candidate_retention_ms",
        "model_snapshot",
        "calibration_digest",
    }
    if not isinstance(value, dict) or not required <= set(value):
        raise ValueError("matching policy is incomplete")
    if (
        value["model_snapshot"] != MEETING_MODEL_REVISION
        or value["prototype_policy"] != "anchor_farthest_v1"
        or not isinstance(value["version"], str)
        or not value["version"]
        or len(value["version"].encode("utf-8")) > 128
    ):
        raise ValueError("matching policy provenance is invalid")
    for key in ("match_distance_max", "match_margin_min", "update_distance_max"):
        if type(value[key]) not in (float, int) or not math.isfinite(value[key]):
            raise ValueError("matching distances must be finite")
    if not (
        0 < value["update_distance_max"] < value["match_distance_max"] < 2
        and 0 <= value["match_margin_min"] <= 2
    ):
        raise ValueError("matching distances are inconsistent")
    for key, minimum in (("minimum_new_voice_ms", 1500), ("minimum_update_voice_ms", 2000)):
        if type(value[key]) is not int or not minimum <= value[key] <= 60000:
            raise ValueError("voice support policy is invalid")
    digest = value["calibration_digest"]
    if (
        value["candidate_retention_ms"] != 60000
        or not isinstance(digest, str)
        or len(digest) != 64
        or any(c not in "0123456789abcdef" for c in digest)
    ):
        raise ValueError("policy calibration provenance is invalid")
    return value


class MeetingDiarizationEngine:
    supports_stream = True
    backend = "meeting_dynamic"
    system_cap = 32

    def __init__(
        self,
        *,
        model_dir: Path,
        policy_path: Path,
        executable: Path,
        governor: ResourceGovernor,
        worker_factory: Callable[[], CoreMLWorkerProcess] | None = None,
        allow_uncertified_evaluation: bool = False,
        pcm_budget: PcmBudget | None = None,
        metrics: Metrics | None = None,
    ) -> None:
        self._model_dir, self._policy_path, self._executable = model_dir, policy_path, executable
        self._governor, self._worker_factory = governor, worker_factory
        self._pcm_budget = pcm_budget
        self._metrics = metrics
        self.max_speakers: int | None = None
        ready = False
        code = "model_not_ready"
        try:
            policy = read_matching_policy(policy_path)
            count = policy.get("certified_max_speakers")
            validation = policy.get("validation_digest")
            certified = (
                type(count) is int
                and 5 <= count <= 32
                and isinstance(validation, str)
                and len(validation) == 64
                and all(c in "0123456789abcdef" for c in validation)
            )
            if certified and isinstance(count, int):
                self.max_speakers = count
            ready = (
                inspect_meeting_dynamic_assets(model_dir)
                and executable.is_file()
                and os.access(executable, os.X_OK)
                and (certified or allow_uncertified_evaluation)
            )
            if not certified:
                code = "quality_not_certified"
        except OSError, ValueError, TypeError:
            pass
        self.readiness = DiarizationReadiness(
            True,
            ready,
            None if ready else code,
            "meeting diarization is ready"
            if ready
            else "meeting diarization prerequisites are not ready",
            profile="meeting-dynamic-community1",
        )

    def open(self, *, epoch: str) -> MeetingActivitySession:
        if not self.readiness.ready:
            raise DiarizationError(
                self.readiness.message, code=self.readiness.code or "model_not_ready"
            )
        worker = (
            self._worker_factory()
            if self._worker_factory
            else CoreMLWorkerProcess(
                executable=self._executable,
                model_path=self._model_dir,
                protocol_version=2,
                backend=self.backend,
                policy_path=self._policy_path,
            )
        )
        return MeetingActivitySession(
            worker=worker,
            epoch=epoch,
            governor=self._governor,
            pcm_budget=self._pcm_budget,
            metrics=self._metrics,
        )


class MeetingActivitySession:
    """Append is bounded RAM admission; one task owns every actual native call."""

    def __init__(
        self,
        *,
        worker: CoreMLWorkerProcess,
        epoch: str,
        governor: ResourceGovernor,
        pcm_budget: PcmBudget | None = None,
        metrics: Metrics | None = None,
    ) -> None:
        if not epoch:
            raise ValueError("activity epoch is required")
        self._worker, self._epoch, self._governor = worker, epoch, governor
        self._metrics = metrics
        self.ring = WindowPcmRing(budget_account=pcm_budget)
        self._next_tick = 160000
        self._stable = self._processed = self._step = 0
        self._wake = asyncio.Event()
        self._queue: asyncio.Queue[ActivityUpdate | BaseException | None] = asyncio.Queue(64)
        self._pump: asyncio.Task[None] | None = None
        self._finishing = self._closed = False
        self._failure: BaseException | None = None
        self._close_task: asyncio.Task[None] | None = None

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        if self._closed or self._finishing or self._failure is not None:
            raise DiarizationError("activity session is closed", code="audio_expired")
        self.ring.append(start_sample, pcm16)
        self._wake.set()
        if self._pump is None:
            self._pump = asyncio.create_task(self._run(), name="meeting-diarization-pump")

    async def updates(self) -> AsyncIterator[ActivityUpdate]:
        while True:
            update = await self._queue.get()
            if update is None:
                return
            if isinstance(update, BaseException):
                raise DiarizationError(
                    "meeting activity failed", code="model_not_ready"
                ) from update
            yield update

    async def finish(self, *, through_sample: int) -> None:
        if through_sample != self.ring.accepted_samples or self._closed:
            raise DiarizationError("invalid activity finish barrier", code="invalid_audio")
        self._finishing = True
        self._wake.set()
        if self._pump is None:
            self._pump = asyncio.create_task(self._run(), name="meeting-diarization-pump")
        await asyncio.shield(self._pump)
        if self._failure is not None:
            raise DiarizationError(
                "meeting activity failed", code="activity_gap"
            ) from self._failure

    async def cancel(self) -> None:
        if self._close_task is None:
            self._close_task = asyncio.create_task(self._close(), name="meeting-diarization-close")
        await join_cleanup(self._close_task)

    async def _close(self) -> None:
        self._closed = True
        self._wake.set()
        # A stopped waiter is not a stopped CoreML task. Reap this exact child
        # before cancelling its pump and allowing the compute lease to exit.
        try:
            started = time.monotonic()
            await self._worker.close()
            self._record_phase("close", started)
        except BaseException:
            if self._metrics:
                self._metrics.record_diarization_failure("close")
            self._governor.quarantine_asr_lane()
            raise
        if self._pump is not None and not self._pump.done():
            self._pump.cancel()
            await asyncio.gather(self._pump, return_exceptions=True)
        self.ring.clear()

    async def _run(self) -> None:
        try:
            while not self._closed:
                self._wake.clear()
                accepted = self.ring.accepted_samples
                if accepted < self._next_tick and not self._finishing:
                    await self._wake.wait()
                    continue
                if accepted == 0 or (self._finishing and self._stable == accepted):
                    await join_cleanup(asyncio.create_task(self._worker.close()))
                    self.ring.clear()
                    await self._queue.put(None)
                    return
                end = min(accepted, max(self._next_tick, self.ring.retained_from_sample + 1))
                span = SampleSpan(max(self.ring.retained_from_sample, end - 480000), end)
                final = self._finishing and end == accepted
                with self.ring.borrow(span) as pin:
                    # No lane declaration for dynamic inference: share the serial
                    # heavy-ASR lane until a measured profile permits otherwise.
                    waiting = time.monotonic()
                    async with self._governor.reserve(WorkClass.REALTIME_ASR):
                        self._record_phase("wait", waiting)
                        stage = "load"
                        try:
                            async with asyncio.timeout(30):
                                started = time.monotonic()
                                await self._worker.start()
                                self._record_phase("load", started)
                                stage = "infer"
                                started = time.monotonic()
                                response, payload = await self._worker.request(
                                    {
                                        "operation": "infer",
                                        "epoch": self._epoch,
                                        "audio_start": span.start,
                                        "audio_samples": span.length,
                                        "previous_stable": self._stable,
                                        "final": final,
                                    },
                                    pin.pcm16,
                                )
                                self._record_phase("infer", started)
                            stage = "protocol"
                            if payload:
                                raise ValueError("activity IPC returned unexpected binary data")
                            if response.get("ok") is False:
                                reported = response.get("diagnostic_stage")
                                if isinstance(reported, str) and reported in {
                                    "load",
                                    "infer",
                                    "protocol",
                                }:
                                    stage = reported
                                raise RuntimeError(
                                    f"dynamic diarization worker failed during {stage}"
                                )
                            update = self._parse(response, span, final)
                            if final:
                                await join_cleanup(asyncio.create_task(self._worker.close()))
                        except BaseException:
                            if self._metrics:
                                self._metrics.record_diarization_failure(stage)
                            try:
                                await join_cleanup(asyncio.create_task(self._worker.close()))
                            except BaseException:
                                self._governor.quarantine_asr_lane()
                                raise
                            raise
                self._processed, self._stable = update.processed_through, update.stable_through
                self._next_tick = end + 160000
                await self._queue.put(update)
                if final:
                    self.ring.clear()
                    await self._queue.put(None)
                    return
        except asyncio.CancelledError:
            raise
        except BaseException as exc:
            self._failure = exc
            await self._queue.put(exc)

    def _record_phase(self, phase: str, started: float) -> None:
        if self._metrics:
            self._metrics.record_diarization_phase(phase, time.monotonic() - started)

    def _parse(self, response: dict[str, object], span: SampleSpan, final: bool) -> ActivityUpdate:
        def integer(value: object) -> int:
            if type(value) is not int or value < 0:
                raise ValueError("activity IPC integer is invalid")
            return value

        if (
            response.get("ok") is not True
            or type(response.get("protocol_version")) is not int
            or response.get("protocol_version") != 2
            or response.get("backend") != "meeting_dynamic"
            or response.get("epoch") != self._epoch
        ):
            raise ValueError("activity IPC identity is invalid")
        processed = integer(response.get("processed_through"))
        stable = integer(response.get("stable_through"))
        if (
            processed != span.end
            or not self._stable <= stable <= processed
            or (final and stable != processed)
        ):
            raise ValueError("activity IPC watermark is invalid")
        raw_frames = response.get("frames")
        if not isinstance(raw_frames, list) or len(raw_frames) > 4096:
            raise ValueError("activity IPC frames are invalid")
        frames = []
        cursor = self._stable
        for raw in raw_frames:
            if not isinstance(raw, dict) or "scores" in raw:
                raise ValueError("dynamic activity must not fabricate scores")
            start, end = integer(raw.get("start")), integer(raw.get("end"))
            slots = raw.get("active_slots")
            if (
                start != cursor
                or end <= start
                or end > processed
                or not isinstance(slots, list)
                or any(type(s) is not int for s in slots)
                or len(set(slots)) != len(slots)
            ):
                raise ValueError("activity IPC coverage is invalid")
            reason = raw.get("reason")
            if reason is not None and not isinstance(reason, str):
                raise ValueError("invalid dynamic activity reason")
            frames.append(ActivityFrame(SampleSpan(start, end), None, frozenset(slots), reason))
            cursor = end
        if cursor != processed:
            raise ValueError("activity IPC omits accepted input")
        diagnostics = response.get("diagnostics")
        counts: dict[str, int] = {}
        if diagnostics is not None:
            limits = {"identities": 32, "prototypes": 96, "candidates": 32}
            if not isinstance(diagnostics, dict) or set(diagnostics) != set(limits):
                raise ValueError("invalid activity diagnostics")
            for key, maximum in limits.items():
                value = integer(diagnostics[key])
                if value > maximum:
                    raise ValueError("activity diagnostic capacity exceeded")
                counts[key] = value
        if self._metrics:
            self._metrics.record_diarization_state(
                lag=processed - stable, pcm_bytes=self.ring.charged_bytes, counts=counts
            )
        self._step += 1
        return ActivityUpdate(
            self._epoch,
            self._step,
            SampleSpan(self._stable, processed),
            tuple(frames),
            processed,
            stable,
        )
