"""ASR-preserving live diagnostic; no model discovery, CLI or certification.

The DIA relay always drains its source. Disabling a failed/slow observer never
silently counts that delivery as model acceptance or successful diarization.
"""

from __future__ import annotations

import asyncio
import hashlib
import math
import time
from collections import deque
from collections.abc import AsyncGenerator, AsyncIterator, Awaitable, Callable, Mapping
from contextlib import aclosing
from pathlib import Path
from typing import Any

from bench_asr_diarization_overlap import _report_digest, run_pcm_workload_schedule
from meeting_evaluation_identity import _freeze, canonical_digest
from meeting_live_text import LiveTextChannel, SealedBody
from meeting_pcm_feed import PcmChunk
from meeting_timing import MeetingTiming

from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.resource_governor import ResourceGovernor

Sink = Callable[[Mapping[str, Any]], Awaitable[None]]
AsrWorkload = Callable[
    [ResourceGovernor, AsyncIterator[PcmChunk], LiveTextChannel, SealedBody],
    Awaitable[Mapping[str, Any]],
]
DiarizationWorkload = Callable[
    [ResourceGovernor, AsyncIterator[PcmChunk], LiveTextChannel, Sink],
    Awaitable[Mapping[str, Any]],
]


def _source_digests() -> dict[str, str]:
    root = Path(__file__).parent
    return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in (
        "meeting_live_pipeline.py", "bench_asr_diarization_overlap.py", "meeting_pcm_feed.py",
        "meeting_live_text.py", "meeting_candidate_runner.py", "meeting_realtime_asr_replay.py",
        "meeting_asr_runtime.py", "meeting_timing.py",
    )}


def _dia_snapshot(report: Mapping[str, Any]) -> tuple[str, Mapping[str, Any]]:
    frozen = _freeze(report)
    if not isinstance(frozen, Mapping):
        raise ValueError("DIA report must be a mapping")
    return _report_digest(frozen), frozen


class _Ingress(AsyncIterator[PcmChunk]):
    def __init__(self, capacity: int) -> None:
        self.capacity = capacity
        self.queue: deque[PcmChunk] = deque()
        self.ready = asyncio.Event()
        self.finished = self.disabled = self.exhausted = self.reading = False
        self.high_water = 0

    def offer(self, frame: PcmChunk) -> bool:
        if self.disabled:
            return False
        if len(self.queue) == self.capacity:
            self.disable()
            return False
        self.queue.append(frame)
        self.high_water = max(self.high_water, len(self.queue))
        self.ready.set()
        return True

    def disable(self) -> None:
        self.disabled = True
        self.queue.clear()
        self.ready.set()

    def finish(self) -> None:
        self.finished = True
        self.ready.set()

    def __aiter__(self) -> _Ingress:
        return self

    async def __anext__(self) -> PcmChunk:
        if self.reading:
            raise ValueError("concurrent diarization ingress reads")
        self.reading = True
        try:
            while True:
                self.ready.clear()
                if self.disabled:
                    raise RuntimeError("diarization ingress disabled")
                if self.queue:
                    return self.queue.popleft()
                if self.finished:
                    self.exhausted = True
                    raise StopAsyncIteration
                await self.ready.wait()
        finally:
            self.reading = False


async def run_live_meeting_pipeline(
    *, pcm: bytes, expected_pcm_sha256: str, governor: ResourceGovernor,
    asr: AsrWorkload, diarization: DiarizationWorkload, sink: Sink,
    max_lateness_seconds: float, mode: str = "serial", overlap_enabled: bool = False,
    timeout_seconds: float = 900, chunk_samples: int = 320, queue_chunks: int = 8,
    diarization_queue_chunks: int = 8, finish_timeout_seconds: float = 15,
    sink_timeout_seconds: float = 5,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> dict[str, Any]:
    """Preserve complete ASR text while failed DIA remains an explicit no-go.

    Callbacks must join their own native cleanup. The generic schedule joins
    this entire relay scope; its DIA report describes the relay, not a model.
    No output claims trusted runtime bytes, real quality, reaping or P95.
    """
    if (
        mode not in {"serial", "overlap"}
        or type(diarization_queue_chunks) is not int or not 1 <= diarization_queue_chunks <= 64
        or any(type(v) not in (int, float) or not math.isfinite(v) or v <= 0 for v in (
            finish_timeout_seconds, sink_timeout_seconds,
        ))
        or finish_timeout_seconds > 15 or sink_timeout_seconds > 5
    ):
        raise ValueError("invalid live pipeline policy")
    channel = LiveTextChannel(samples=len(pcm) // 2, clock=clock)
    timing = MeetingTiming(samples=len(pcm) // 2, clock=clock)
    body = SealedBody(samples=len(pcm) // 2, timing=timing)
    ingress = _Ingress(diarization_queue_chunks)
    dia_done, relay_done = asyncio.Event(), asyncio.Event()
    operation: asyncio.Task[Mapping[str, Any]] | None = None
    dia_digest: str | None = None
    dia_report: Mapping[str, Any] | None = None
    failure: str | None = None

    def disable(code: str) -> None:
        nonlocal failure
        failure = failure or code
        ingress.disable()
        channel.fail()
        if operation is not None and not operation.done():
            operation.cancel()

    async def emit(row: Mapping[str, Any]) -> None:
        ticket = timing.begin_delivery(row)

        async def invoke() -> None:
            await sink(row)

        task = asyncio.create_task(invoke(), name="live-sink")
        deadline = asyncio.timeout(sink_timeout_seconds)
        try:
            async with deadline:
                await task
            if deadline.expired():
                raise TimeoutError("live sink exceeded deadline")
            owner = asyncio.current_task()
            if owner is not None and owner.cancelling():
                raise asyncio.CancelledError
            timing.end_delivery(ticket)
        except asyncio.CancelledError:
            timing.fail_delivery(ticket)
            owner = asyncio.current_task()
            if owner is not None and owner.cancelling():
                raise
            raise RuntimeError("live sink cancelled itself") from None
        except BaseException:
            timing.fail_delivery(ticket)
            raise

    async def run_asr(
        shared: ResourceGovernor, frames: AsyncIterator[PcmChunk],
    ) -> Mapping[str, Any]:
        async def tracked() -> AsyncGenerator[PcmChunk]:
            async for frame in frames:
                timing.source(frame)
                yield frame

        async with aclosing(tracked()) as observed_frames:
            result = await asr(shared, observed_frames, channel, body)
        timing.mark("asr_callback_complete")
        return result

    async def run_dia(
        shared: ResourceGovernor, frames: AsyncIterator[PcmChunk],
    ) -> Mapping[str, Any]:
        started = asyncio.Event()

        async def consume() -> None:
            nonlocal operation, dia_digest, dia_report

            async def invoke() -> Mapping[str, Any]:
                return await diarization(shared, ingress, channel, emit)

            operation = asyncio.create_task(
                invoke(), name="live-dia-operation"
            )
            started.set()
            try:
                result = await operation
                if not ingress.exhausted:
                    raise ValueError("DIA did not consume its ingress")
                dia_digest, dia_report = await join_cleanup(asyncio.create_task(
                    asyncio.to_thread(_dia_snapshot, result), name="live-dia-digest"
                ))
            except asyncio.CancelledError:
                owner = asyncio.current_task()
                if owner is not None and owner.cancelling():
                    raise
                disable("diarization_cancelled")
            except Exception:
                disable("diarization_failed")
            finally:
                timing.mark("dia_scope_closed")
                dia_done.set()

        async def relay() -> None:
            await started.wait()
            async for frame in frames:
                if failure is None and not ingress.offer(frame):
                    disable("diarization_ingress_full")
            ingress.finish()
            timing.mark("dia_input_eof")
            relay_done.set()

        async def deadline() -> None:
            await relay_done.wait()
            try:
                async with asyncio.timeout(finish_timeout_seconds):
                    await dia_done.wait()
            except TimeoutError:
                disable("diarization_finish_timeout")

        async with asyncio.TaskGroup() as tasks:
            tasks.create_task(consume(), name="live-dia-consumer")
            tasks.create_task(relay(), name="live-dia-relay")
            tasks.create_task(deadline(), name="live-dia-deadline")
        # This complete flag is only for the joined relay callback. Never
        # present it as the failed model's complete report or quality result.
        return {"complete": True, "scope": "diarization_relay", "degraded": failure is not None}

    try:
        sources = await join_cleanup(asyncio.create_task(asyncio.to_thread(_source_digests)))
        schedule = await run_pcm_workload_schedule(
            pcm=pcm, expected_pcm_sha256=expected_pcm_sha256, mode=mode, governor=governor,
            asr=run_asr, diarization=run_dia, overlap_enabled=overlap_enabled,
            timeout_seconds=timeout_seconds, chunk_samples=chunk_samples, queue_chunks=queue_chunks,
            max_lateness_seconds=max_lateness_seconds, clock=clock, sleep=sleep,
        )
        after_sources = await join_cleanup(asyncio.create_task(asyncio.to_thread(_source_digests)))
        if sources != after_sources:
            raise ValueError("live pipeline source changed")
        body_summary = body.summary()
        if body_summary["complete"] is not True:
            raise ValueError("ASR did not finish its independent body")
        observed = channel.summary()
        observations = timing.summary(schedule["pcm_feed"], body.items())
        complete = (
            failure is None and dia_report is not None and observed["consumer_exhausted"]
            and not observed["failed"]
            and dia_report.get("asr_text_source") == "live_sealed_session"
            and type(dia_report.get("text_characters")) is int
            and type(dia_report.get("emitted_text_characters")) is int
            and dia_report.get("asr_text_sha256") == body_summary["text_sha256"]
            and dia_report.get("text_characters") == body_summary["text_characters"]
            and dia_report.get("emitted_text_characters") == body_summary["text_characters"]
            and observations["text_delivery_verified"]
            and observations["open_sink_deliveries"] == 0
            and not observations["failed_sink_deliveries"]
            and timing.source_samples == timing.asr_sealed == timing.dia_stable == len(pcm) // 2
        )
        if not complete:
            await emit({
                "kind": "asr_body_snapshot", "replaces_all_attribution": True,
                "reason": "diarization_failed",
                "items": [{
                    "sequence": item.sequence, "text": item.text,
                    "start_sample": item.span.start, "end_sample": item.span.end,
                    "speaker": None, "state": "unknown", "granularity": "utterance",
                } for item in body.items()],
            })
            observations = timing.summary(schedule["pcm_feed"], body.items())
        policy = {
            "mode": mode, "overlap_enabled": overlap_enabled,
            "timeout_seconds": timeout_seconds, "finish_timeout_seconds": finish_timeout_seconds,
            "sink_timeout_seconds": sink_timeout_seconds,
            "diarization_queue_chunks": diarization_queue_chunks,
            "deadline_clock": "event_loop_monotonic",
            "dia_finish_deadline_origin": "diarization_relay_input_eof",
            "degradation": "drain_dia_keep_asr_replace_all_unknown_v1",
            "timing_schema_version": 1,
            "max_timing_records": MeetingTiming.MAX_RECORDS,
            "max_asr_timing_records": MeetingTiming.MAX_ASR_RECORDS,
            "max_publication_timing_records": MeetingTiming.MAX_PUBLICATION_RECORDS,
            "max_open_sink_deliveries": MeetingTiming.MAX_OPEN,
            "latency_sampling_policy": "not_registered",
            "pcm_feed_policy_sha256": schedule["pcm_feed"]["policy_sha256"],
            "source_digests": sources,
        }
        return {
            **schedule, "asr_complete": True, "asr_body": body_summary,
            "live_attribution_complete": bool(complete),
            "diarization_report_sha256": dia_digest,
            "diarization_failure": failure or (None if complete else "invalid_attribution"),
            "diarization_ingress_high_water": ingress.high_water,
            "joint_verdict": "diagnostic_not_certified" if complete else "no-go",
            "joint_quality_gate": "not_observed", "live_text": observed,
            "worker_reaping_verified": False,
            "timing_observations": observations,
            "pipeline_policy": policy, "pipeline_policy_sha256": canonical_digest(policy),
            "asr_preserved_as_unknown": not complete,
        }
    except asyncio.CancelledError:
        raise
    except Exception:
        raise ValueError("live meeting pipeline failed") from None
    finally:
        ingress.disable()
        await channel.aclose()
        body.close()
