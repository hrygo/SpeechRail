"""T6 workload scheduling core; not a complete quality/latency benchmark.

Callers bind already-approved ASR/DIA workloads to the same frozen source and
must use the supplied governor for actual compute. Each callback owns and joins
its inference/session cleanup before returning or propagating cancellation.
This module neither constructs models nor verifies that callback contract.
It records host callback intervals and result digests, never kernel overlap,
1x capture, stable labels, footprint, quality acceptance or trusted provenance.
No CLI, file writes, downloads, service changes or automatic workloads exist.
"""

from __future__ import annotations

import asyncio
import json
import math
import time
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from typing import Any

from meeting_evaluation_identity import _freeze, _thaw, canonical_digest
from meeting_pcm_feed import CommonPcmFeed, PcmChunk

from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass

Workload = Callable[[ResourceGovernor], Awaitable[Mapping[str, Any]]]
PcmWorkload = Callable[[ResourceGovernor, AsyncIterator[PcmChunk]], Awaitable[Mapping[str, Any]]]
_MODES = {
    "asr-only": ("asr",),
    "diarization-only": ("diarization",),
    "serial": ("asr", "diarization"),
    "overlap": ("asr", "diarization"),
}
_ERROR = "ASR diarization workload schedule failed"


def _report_digest(report: Mapping[str, Any]) -> str:
    report = _thaw(_freeze(report))
    if (
        not isinstance(report, Mapping)
        or not (
            report.get("complete") is True
            or report.get("status") == "completed"
            or report.get("quality_evidence_valid") is True
        )
        or ("complete" in report and report["complete"] is not True)
        or ("status" in report and report["status"] != "completed")
        or ("quality_evidence_valid" in report and report["quality_evidence_valid"] is not True)
        or report.get("failures", []) != []
    ):
        raise ValueError("workload did not report complete execution")
    # A report digest is consistency evidence, not producer attestation. No raw
    # report fields (which may include transcripts/paths) enter the schedule.
    if len(json.dumps(dict(report), allow_nan=False).encode("utf-8")) > 16 * 1024 * 1024:
        raise ValueError("workload report exceeds budget")
    return canonical_digest(report)


async def run_workload_schedule(
    *,
    mode: str,
    governor: ResourceGovernor,
    asr: Workload | None = None,
    diarization: Workload | None = None,
    overlap_enabled: bool = False,
    timeout_seconds: float = 900,
    clock: Callable[[], float] = time.monotonic,
) -> dict[str, Any]:
    """Join every scheduled workload; failures never return a complete report.

    Joint modes start both callbacks. Serial requires the governor to serialize
    compute; it never delays the entire DIA feed until the ASR session finishes.
    Overlap requires an explicit plan plus the supplied governor's permission.
    The deadline bounds execution, not the subsequent joined cleanup; a slow
    cleanup cannot be abandoned or counted as reclaimed worker ownership.
    """
    operation: asyncio.Task[dict[str, Any]] | None = None
    try:
        if (
            mode not in _MODES
            or type(overlap_enabled) is not bool
            or type(timeout_seconds) not in (int, float)
            or not math.isfinite(timeout_seconds)
            or not 0 < timeout_seconds <= 7200
        ):
            raise ValueError("invalid workload schedule")
        callbacks = {"asr": asr, "diarization": diarization}
        required = _MODES[mode]
        if any((callbacks[name] is None) != (name not in required) for name in callbacks):
            raise ValueError("workload callbacks differ from selected mode")
        snapshot = governor.snapshot()
        if (
            snapshot.reject_heavy_compute is not False
            or any(
                (
                    snapshot.active_realtime,
                    snapshot.active_batch,
                    snapshot.pending_realtime,
                    snapshot.pending_batch,
                    snapshot.retained_diarization,
                )
            )
            or (mode == "serial" and snapshot.allow_heavy_overlap is not False)
            or (
                mode == "overlap"
                and (overlap_enabled is not True or snapshot.allow_heavy_overlap is not True)
            )
            or any(
                not governor.lane_available(
                    WorkClass.REALTIME_ASR if name == "asr" else WorkClass.DIARIZATION
                )
                for name in required
            )
        ):
            raise ValueError("governor does not permit the isolated workload schedule")
        previous: float | None = None

        def tick() -> float:
            nonlocal previous
            value = clock()
            if (
                type(value) not in (int, float)
                or not math.isfinite(value)
                or (previous is not None and value < previous)
            ):
                raise ValueError("workload clock is invalid")
            previous = float(value)
            return previous

        origin = tick()

        async def lane(name: str) -> dict[str, Any]:
            callback = callbacks[name]
            assert callback is not None
            started = tick() - origin

            # Isolate callback cancellation from its lane. TaskGroup otherwise
            # treats a self-cancelled child as normal cancellation and leaves
            # its peer running until the global deadline.
            async def invoke(target: Workload) -> Mapping[str, Any]:
                return await target(governor)

            workload = asyncio.create_task(invoke(callback), name=f"joint-{name}-callback")
            try:
                report = await workload
            except asyncio.CancelledError:
                current = asyncio.current_task()
                if current is not None and current.cancelling():
                    raise
                raise ValueError("workload cancelled itself") from None
            ended = tick() - origin
            digest = await join_cleanup(
                asyncio.create_task(asyncio.to_thread(_report_digest, report))
            )
            return {
                "started_at_seconds": started,
                "ended_at_seconds": ended,
                "elapsed_seconds": ended - started,
                "report_sha256": digest,
            }

        async def run() -> dict[str, Any]:
            observations = {}
            async with asyncio.timeout(timeout_seconds) as deadline:
                if mode in {"serial", "overlap"}:
                    async with asyncio.TaskGroup() as group:
                        tasks = {
                            name: group.create_task(lane(name), name=f"joint-{name}")
                            for name in required
                        }
                    observations = {name: task.result() for name, task in tasks.items()}
                else:
                    for name in required:
                        observations[name] = await lane(name)
            if deadline.expired():
                raise TimeoutError("workload schedule deadline expired")
            return {
                "schema_version": 1,
                "mode": mode,
                "schedule_completed": True,
                "workloads": observations,
                "elapsed_seconds": tick() - origin,
                "clock_source": "monotonic" if clock is time.monotonic else "injected",
                "timing_scope": "host_workload_callbacks_including_cleanup",
                "verdict": "diagnostic",
                "runtime_identity_verified": False,
                "certification_eligible": False,
                "joint_latency_observed": False,
                "compute_overlap_observed": False,
                "worker_reaping_verified": False,
                "same_source_verified": False,
                "quality_gate": "not_observed",
                "footprint": "not_observed",
                "p95": "not_observed",
            }

        operation = asyncio.create_task(run(), name="joint-workload-schedule")
        return await asyncio.shield(operation)
    except asyncio.CancelledError:
        if operation is not None:
            if not operation.done():
                operation.cancel()

            async def drain() -> None:
                await asyncio.gather(operation, return_exceptions=True)

            await join_cleanup(asyncio.create_task(drain(), name="joint-workload-cleanup"))
        caller = asyncio.current_task()
        if caller is not None and caller.cancelling():
            raise
        raise ValueError(_ERROR) from None
    except Exception:
        raise ValueError(_ERROR) from None


async def run_pcm_workload_schedule(
    *,
    pcm: bytes,
    expected_pcm_sha256: str,
    mode: str,
    governor: ResourceGovernor,
    max_lateness_seconds: float,
    asr: PcmWorkload | None = None,
    diarization: PcmWorkload | None = None,
    overlap_enabled: bool = False,
    timeout_seconds: float = 900,
    chunk_samples: int = 320,
    queue_chunks: int = 8,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> dict[str, Any]:
    """Bind both callbacks to one immutable source and fixed 16 kHz deadlines.

    The PCM is already loaded by the caller. Digest/complete delivery prove
    in-memory source consistency only; no production adapter or capture claim.
    """
    operation: asyncio.Task[dict[str, Any]] | None = None
    feed: CommonPcmFeed | None = None
    error = "ASR diarization PCM workload schedule failed"
    try:
        if mode not in _MODES:
            raise ValueError("invalid PCM workload mode")
        required = _MODES[mode]
        callbacks = {"asr": asr, "diarization": diarization}
        if any((callbacks[name] is None) != (name not in required) for name in callbacks):
            raise ValueError("PCM callbacks differ from mode")
        source = CommonPcmFeed(
            pcm,
            expected_pcm_sha256=expected_pcm_sha256,
            lanes=required,
            chunk_samples=chunk_samples,
            queue_chunks=queue_chunks,
            max_lateness_seconds=max_lateness_seconds,
            clock=clock,
            sleep=sleep,
        )
        feed = source

        def bind(name: str) -> Workload:
            callback = callbacks[name]
            assert callback is not None

            async def invoke(shared: ResourceGovernor) -> Mapping[str, Any]:
                result = await callback(shared, source.stream(name))
                source.verify_drained(name)
                return result

            return invoke

        async def produce() -> None:
            producer = asyncio.create_task(source.produce(), name="pcm-producer")
            try:
                await producer
            except asyncio.CancelledError:
                current = asyncio.current_task()
                if current is not None and current.cancelling():
                    raise
                raise ValueError("PCM producer cancelled itself") from None

        async def run() -> dict[str, Any]:
            async with asyncio.TaskGroup() as group:
                group.create_task(produce(), name="pcm-source")
                schedule = group.create_task(
                    run_workload_schedule(
                        mode=mode,
                        governor=governor,
                        asr=bind("asr") if "asr" in required else None,
                        diarization=bind("diarization") if "diarization" in required else None,
                        overlap_enabled=overlap_enabled,
                        timeout_seconds=timeout_seconds,
                        clock=clock,
                    ),
                    name="pcm-workloads",
                )
            return {**schedule.result(), "pcm_feed": source.summary()}

        operation = asyncio.create_task(run(), name="pcm-schedule")
        return await asyncio.shield(operation)
    except asyncio.CancelledError:
        if operation is not None:
            if not operation.done():
                operation.cancel()

            async def drain() -> None:
                await asyncio.gather(operation, return_exceptions=True)

            await join_cleanup(asyncio.create_task(drain(), name="pcm-cleanup"))
        caller = asyncio.current_task()
        if caller is not None and caller.cancelling():
            raise
        raise ValueError(error) from None
    except Exception:
        raise ValueError(error) from None
    finally:
        if feed is not None:
            feed.close()
