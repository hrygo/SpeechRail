"""Bounded candidate replay with concurrent activity consumption.

Fixed ASR sidecars support controlled diarization comparisons. Their clocks do
not constitute live ASR or joint product-latency evidence. This library does not
create a governor, download models, issue receipts or modify a running service.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import math
import time
import wave
from collections.abc import AsyncIterator, Awaitable, Callable, Generator, Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from meeting_candidate_evidence import (
    AttributedText,
    CandidateEvidence,
    CompletedText,
    EvidenceEvent,
)

from speechrail.domain.diarization.ports import ActivitySession
from speechrail.runtime.cleanup import join_cleanup


@dataclass(frozen=True, slots=True)
class ScheduledText:
    ready_after_sample: int
    item: CompletedText
    finish_only: bool = False


class FixedTextReplay:
    """One-item lookahead over producer-timed, reference-free ASR observations."""

    def __init__(self, source: Iterator[ScheduledText]) -> None:
        self._source = source
        self._previous = self._through = 0
        self._finish_phase = self._closed = False
        self._next = next(source, None)

    def _take(self) -> ScheduledText:
        row = self._next
        if (
            not isinstance(row, ScheduledText)
            or type(row.ready_after_sample) is not int
            or row.ready_after_sample < self._previous
            or type(row.finish_only) is not bool
            or (self._finish_phase and not row.finish_only)
        ):
            raise ValueError("ASR replay observations must follow producer order")
        self._previous = row.ready_after_sample
        self._finish_phase |= row.finish_only
        self._next = next(self._source, None)
        return row

    def _ready(self, accepted: int, *, finish: bool) -> tuple[CompletedText, ...]:
        if type(accepted) is not int or accepted < self._through or self._closed:
            raise ValueError("invalid accepted ASR replay watermark")
        self._through = accepted
        items, characters = [], 0
        while self._next is not None:
            if not finish and (self._next.finish_only or self._next.ready_after_sample > accepted):
                break
            row = self._take()
            if row.ready_after_sample > accepted or row.item.span.end > accepted:
                raise ValueError("ASR replay timing exceeds accepted audio")
            items.append(row.item)
            characters += len(row.item.text)
            if len(items) > 4096 or characters > 262144:
                raise ValueError("ASR replay batch budget exceeded")
        if finish:
            self._closed = True
        return tuple(items)

    def ready(self, accepted: int) -> tuple[CompletedText, ...]:
        return self._ready(accepted, finish=False)

    def finish(self, accepted: int) -> tuple[CompletedText, ...]:
        return self._ready(accepted, finish=True)

    def close(self) -> None:
        self._closed = True
        close = getattr(self._source, "close", None)
        if close is not None:
            close()


def _wav_packets(path: Path) -> Generator[bytes]:
    path = path.expanduser()
    if (
        path.is_symlink()
        or not path.is_file()
        or path.resolve().is_relative_to(Path(__file__).resolve().parents[2])
    ):
        raise ValueError("evaluation WAV must be a regular external file without symlinks")
    with wave.open(str(path), "rb") as source:
        if (
            source.getnchannels() != 1
            or source.getsampwidth() != 2
            or source.getframerate() != 16000
            or source.getcomptype() != "NONE"
        ):
            raise ValueError("candidate WAV must be mono PCM16 at 16000 Hz")
        remaining = source.getnframes()
        if remaining <= 0:
            raise ValueError("candidate WAV contains no samples")
        while remaining:
            count = min(16000, remaining)
            packet = source.readframes(count)
            if len(packet) != count * 2:
                raise ValueError("candidate WAV is truncated")
            remaining -= count
            yield packet


def inspect_wav_pcm(path: Path) -> int:
    """Validate the entire WAV in bounded packets before any model construction."""
    return sum(len(packet) // 2 for packet in _wav_packets(path))


async def iter_wav_pcm(path: Path) -> AsyncIterator[bytes]:
    """Read bounded packets off-loop and join each read before closing on cancel."""
    packets = _wav_packets(path)
    try:
        while True:
            packet = await join_cleanup(asyncio.create_task(asyncio.to_thread(next, packets, None)))
            if packet is None:
                return
            yield packet
    finally:
        await join_cleanup(asyncio.create_task(asyncio.to_thread(packets.close)))


async def run_candidate_stream(
    pcm_source: AsyncIterator[bytes],
    *,
    activity_factory: Callable[[], ActivitySession],
    text_replay: FixedTextReplay,
    epoch: str,
    sink: Callable[[Mapping[str, Any]], Awaitable[None]],
    input_mode: str = "throughput",
    timeout_seconds: float = 1800,
    sink_timeout_seconds: float = 5,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> dict[str, Any]:
    """Run one controlled sidecar comparison with the caller's shared owner/lane.

    The factory must use the real composition-root governor. Cross-process
    service exclusion and artifact/runtime identities are the caller's duties.
    Sink is a raw external-artifact sink; returned summary never contains text.
    """
    if input_mode not in {"throughput", "realtime"} or any(
        type(v) not in (int, float) or not math.isfinite(v) or v <= 0
        for v in (timeout_seconds, sink_timeout_seconds)
    ):
        raise ValueError("invalid candidate replay mode or deadline")
    evidence = CandidateEvidence(epoch=epoch)
    activity: ActivitySession | None = None
    output_lock = asyncio.Lock()
    start = previous_time = clock()
    if not math.isfinite(start):
        raise ValueError("candidate monotonic clock must be finite")
    finishing = False
    appends = consumed_updates = 0
    updates_consumed = asyncio.Event()
    registered_characters = emitted_characters = 0
    transcript_digest = hashlib.sha256()
    input_finished_at = finish_started_at = finish_ended_at = None
    max_input_lateness = 0.0

    def elapsed() -> float:
        nonlocal previous_time
        now = clock()
        if not math.isfinite(now) or now < previous_time:
            raise ValueError("candidate monotonic clock moved backwards")
        previous_time = now
        return now - start

    async def emit(row: Mapping[str, Any]) -> None:
        async with output_lock, asyncio.timeout(sink_timeout_seconds):
            await sink({**row, "elapsed_seconds": elapsed()})

    async def publish(events: tuple[EvidenceEvent, ...]) -> None:
        nonlocal emitted_characters
        for event in events:
            row: dict[str, Any] = {
                "kind": "text" if isinstance(event, AttributedText) else "activity",
                "start_sample": event.span.start,
                "end_sample": event.span.end,
                "speaker": event.speaker,
            }
            if isinstance(event, AttributedText):
                row.update(
                    sequence=event.sequence,
                    unit_index=event.unit_index,
                    text=event.text,
                    reason=event.reason,
                    granularity=event.granularity,
                )
                emitted_characters += len(event.text)
            await emit(row)

    async def register(items: tuple[CompletedText, ...]) -> None:
        nonlocal registered_characters
        for item in items:
            events = evidence.register(item)
            registered_characters += len(item.text)
            transcript_digest.update(item.text.encode("utf-8"))
            await emit(
                {
                    "kind": "asr_text_ready",
                    "sequence": item.sequence,
                    "end_sample": item.span.end,
                    "accepted_samples": evidence.accepted,
                }
            )
            await publish(events)

    async def consume(session: ActivitySession) -> None:
        nonlocal consumed_updates
        async for update in session.updates():
            await publish(evidence.apply(update))
            await emit(
                {
                    "kind": "activity_watermark",
                    "accepted_samples": evidence.accepted,
                    "processed_samples": evidence.processed,
                    "stable_samples": update.stable_through,
                }
            )
            consumed_updates += 1
            updates_consumed.set()
        if not finishing:
            raise ValueError("candidate activity closed before input finish")

    try:
        async with asyncio.timeout(timeout_seconds), asyncio.TaskGroup() as tasks:
            pump = None
            async for packet in pcm_source:
                if (
                    not isinstance(packet, bytes)
                    or not packet
                    or len(packet) % 2
                    or len(packet) > 32000
                ):
                    raise ValueError("candidate PCM packet must be bounded whole samples")
                if activity is None:
                    activity = activity_factory()
                    pump = tasks.create_task(consume(activity), name="candidate-activity-pump")
                endpoint = evidence.accepted + len(packet) // 2
                if input_mode == "realtime":
                    delay = endpoint / 16000 - elapsed()
                    if delay > 0:
                        await sleep(delay)
                    max_input_lateness = max(max_input_lateness, elapsed() - endpoint / 16000)
                evidence.accept(len(packet) // 2)
                input_finished_at = elapsed()
                ready = await join_cleanup(
                    asyncio.create_task(asyncio.to_thread(text_replay.ready, evidence.accepted))
                )
                await register(ready)
                before = elapsed()
                await activity.append(start_sample=endpoint - len(packet) // 2, pcm16=packet)
                appends += 1
                await emit(
                    {
                        "kind": "phase",
                        "phase": "activity_append_including_admission_and_load",
                        "duration_seconds": elapsed() - before,
                        "through_sample": evidence.accepted,
                    }
                )
            if activity is None or pump is None:
                raise ValueError("candidate input contains no audio")
            # Candidate/C0 private sessions publish exactly one update per
            # append, including empty buffering updates. Drain those before
            # accepting iterator closure as a finish acknowledgement. This
            # waits for delivery, not processed==accepted (tail needs finish).
            while consumed_updates < appends:
                updates_consumed.clear()
                await updates_consumed.wait()
            final_text = await join_cleanup(
                asyncio.create_task(asyncio.to_thread(text_replay.finish, evidence.accepted))
            )
            await register(final_text)
            finish_started_at = elapsed()
            finishing = True
            await activity.finish(through_sample=evidence.accepted)
            await pump
            await publish(evidence.finish())
            finish_ended_at = elapsed()
            if not evidence.complete or registered_characters != emitted_characters:
                raise ValueError("candidate final activity or text coverage is incomplete")
    except asyncio.CancelledError:
        raise
    except TimeoutError:
        raise RuntimeError("candidate_run_timeout") from None
    except Exception:
        raise RuntimeError("candidate_run_failed") from None
    finally:
        cleanup_failed = False
        if not evidence.complete:
            # Failed sink cannot turn an incomplete run into a valid result.
            with contextlib.suppress(Exception):
                await publish(evidence.abort("finalization_incomplete"))
        if activity is not None:
            try:
                await activity.cancel()  # Shared exact-child lease owns bounded reaping/isolation.
            except Exception:
                cleanup_failed = True
        try:
            await join_cleanup(asyncio.create_task(asyncio.to_thread(text_replay.close)))
            close_source = getattr(pcm_source, "aclose", None)
            if close_source is not None:
                await close_source()
        except Exception:
            cleanup_failed = True
        if cleanup_failed:
            raise RuntimeError("candidate_cleanup_incomplete") from None
    return {
        "complete": True,
        "accepted_samples": evidence.accepted,
        "processed_samples": evidence.processed,
        "text_characters": registered_characters,
        "emitted_text_characters": emitted_characters,
        "asr_text_sha256": transcript_digest.hexdigest(),
        "input_mode": input_mode,
        "clock_source": "monotonic" if clock is time.monotonic else "injected",
        "elapsed_seconds": elapsed(),
        "input_finished_at_seconds": input_finished_at,
        "finish_started_at_seconds": finish_started_at,
        "finish_ended_at_seconds": finish_ended_at,
        "max_input_lateness_seconds": max_input_lateness if input_mode == "realtime" else None,
        "clock_scope": "diarization_with_fixed_asr_sidecar",
        "joint_asr_latency_observed": False,
        "runtime_identity_verified": False,
        "artifact_identity_verified": False,
        "asr_sidecar_identity_verified": False,
        "certification_eligible": False,
        "verdict": "diagnostic",
        "stable_label_p95_seconds": None,
        "certified_max_speakers": None,
    }
