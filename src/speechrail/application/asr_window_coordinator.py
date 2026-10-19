"""One bounded decoder pump over continuous PCM and immutable window terminals."""

from __future__ import annotations

import asyncio
import json
import time
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from contextlib import suppress
from dataclasses import asdict, dataclass, replace
from typing import Literal, cast
from uuid import uuid4

from speechrail.compatibility.openai_realtime import (
    transcription_completed,
    transcription_failed,
    transcription_segment_closed,
)
from speechrail.domain.asr_window import (
    MAX_EVENT_BYTES,
    FailedWindowItem,
    FinalWindowUnit,
    WindowDecodeRequest,
    WindowDecodeResult,
    WindowIdentity,
    WindowLedger,
    WindowPolicy,
    WindowSeal,
    WindowUnit,
)
from speechrail.domain.audio_timeline import RateMap, SampleSpan
from speechrail.domain.ports import SegmentCloseReason, WindowAsrSession
from speechrail.domain.transcript_cleanup import CollapseResult
from speechrail.observability.metrics import Metrics
from speechrail.runtime.cleanup import join_cleanup
from speechrail.runtime.window_pcm import (
    PcmBorrow,
    PcmBudget,
    PcmBudgetExceededError,
    WindowPcmRing,
)


@dataclass(frozen=True, slots=True)
class WindowReceipt:
    window_revision: int
    sealed_through_sample: int
    failed_items_count: int


@dataclass(frozen=True, slots=True)
class _Closed:
    unit: WindowUnit
    due: float
    deadline: float
    reason: str


Review = Callable[
    [WindowDecodeRequest, WindowDecodeResult, SampleSpan, float],
    Awaitable[tuple[str, Literal["contextual", "owned_only"]]],
]


class AsrWindowCoordinator:
    def __init__(
        self,
        *,
        identity: WindowIdentity,
        policy: WindowPolicy,
        scene: Literal["meeting", "caption"] = "caption",
        decoder: WindowAsrSession,
        send: Callable[[dict[str, object]], Awaitable[object]],
        on_final: Callable[[FinalWindowUnit, bytes], Awaitable[asyncio.Task[None] | None]],
        on_auxiliary_unavailable: Callable[[FinalWindowUnit, str], Awaitable[object]] | None = None,
        review: Review | None = None,
        language: str | None = None,
        context: str = "",
        clock: Callable[[], float] = time.monotonic,
        start_sample: int = 0,
        to_wire_sample: Callable[[int], int] | None = None,
        pcm_budget: PcmBudget | None = None,
        metrics: Metrics | None = None,
        clean_final: Callable[[str], CollapseResult] | None = None,
    ) -> None:
        self.ledger = WindowLedger(identity, policy)
        self.ring = WindowPcmRing(budget_bytes=policy.pcm_budget_bytes, budget_account=pcm_budget)
        # A cleared epoch keeps the connection's absolute sample axis.
        self.ledger.accepted_samples = start_sample
        self.ledger.sealed_through_sample = start_sample
        self.ring.accepted_samples = start_sample
        self.ring.retained_from_sample = start_sample
        self.policy, self.decoder, self.scene = policy, decoder, scene
        self._metrics = metrics
        self._send, self._on_final, self._review = send, on_final, review
        self._clean_final = clean_final
        self._on_auxiliary_unavailable = on_auxiliary_unavailable
        self._language, self._context, self._clock = language, context, clock
        self._closed: OrderedDict[str, _Closed] = OrderedDict()
        self._active: SampleSpan | None = None
        self._preview: SampleSpan | None = None
        self._last_preview_end = start_sample
        self._decoded_through = start_sample
        self._shown_through: dict[str, int] = {}
        self._previewed_through: dict[str, int] = {}
        self._closed_preview_attempts: dict[str, tuple[int, float]] = {}
        self.falling_behind = False
        self._lag_observations = 0
        self._last_lag_observation = -float("inf")
        self._silence = start_sample
        self._wake = asyncio.Event()
        self._idle = asyncio.Event()
        self._idle.set()
        self._pump: asyncio.Task[None] | None = None
        self._close_task: asyncio.Task[None] | None = None
        self._barriers: dict[int, asyncio.Future[WindowReceipt]] = {}
        self._force_through = start_sample
        self._failed = 0
        self._last_event_revision = -1
        self._failure: BaseException | None = None
        self._stopping = False
        self._auxiliary_tasks: set[asyncio.Task[None]] = set()
        self._rate = RateMap(16000, 24000)
        self._to_wire = to_wire_sample or self._rate.to_target

    async def append(self, start: int, pcm16: bytes) -> None:
        if self._stopping or self._failure is not None:
            raise RuntimeError("window input is closed or failed")
        # Refuse before copying; never overwrite unresolved input.
        if (
            start + len(pcm16) // 2 - max(self.ledger.sealed_through_sample, self._decoded_through)
            > 20 * 16000
        ):
            raise PcmBudgetExceededError("capture to ASR backlog exceeds twenty seconds")
        self.ring.append(start, pcm16)
        if pcm16:
            self.ledger.append(SampleSpan(start, start + len(pcm16) // 2))
        if self._observe_lag():
            await self._snapshot()
        self._record_state()
        self.wake()

    def _record_state(self) -> None:
        if self._metrics is not None:
            self._metrics.record_asr_window_state(
                self.scene,
                capture_backlog_samples=max(
                    0,
                    self.ledger.accepted_samples
                    - max(self._decoded_through, self.ledger.sealed_through_sample),
                ),
                retained_pcm_bytes=self.ring.charged_bytes,
                mutable_units=len(self.ledger.snapshot().units),
                pending_closed=len(self._closed),
                falling_behind=int(self.falling_behind),
            )

    def _observe_lag(self) -> bool:
        if self.scene != "caption":
            return False
        units = self.ledger.snapshot().units
        live = {u.unit_id for u in units}
        self._shown_through = {k: v for k, v in self._shown_through.items() if k in live}
        self._previewed_through = {k: v for k, v in self._previewed_through.items() if k in live}
        self._closed_preview_attempts = {
            k: v for k, v in self._closed_preview_attempts.items() if k in live
        }
        oldest = min(
            (
                max(u.owned_span.start, self._shown_through.get(u.unit_id, u.owned_span.start))
                for u in units
                if self._shown_through.get(u.unit_id, u.owned_span.start) < u.owned_span.end
            ),
            default=self.ledger.accepted_samples,
        )
        lagging = self.ledger.accepted_samples - oldest >= 2 * 16000
        before = self.falling_behind
        if not lagging:
            self._lag_observations = 0
            self.falling_behind = False
        elif self._clock() - self._last_lag_observation >= 0.5:
            self._last_lag_observation = self._clock()
            self._lag_observations += 1
            self.falling_behind = self._lag_observations >= 3
        if before != self.falling_behind:
            # Status is part of the full snapshot, so it needs a fresh revision
            # even if a same-text preview just completed with no new PCM.
            self.ledger.window_revision += 1
            return True
        return False

    def wake(self) -> None:
        self._idle.clear()
        self._wake.set()
        if self._pump is None:
            self._pump = asyncio.create_task(self._run(), name="asr-window-pump")

    def admit(self, span: SampleSpan) -> None:
        if (
            span.start < self.ledger.sealed_through_sample
            or span.end > self.ledger.accepted_samples
        ):
            raise ValueError("admission rewrites a sealed or unaccepted span")
        cursor = span.start
        while cursor < span.end:
            begin = self._active.start if self._active else cursor
            if self._active and self._active.end != cursor:
                raise ValueError("admitted PCM must be continuous inside an owned block")
            end = min(span.end, begin + self.policy.owned_ms * 16)
            old = self._active
            self._active = SampleSpan(begin, end)
            # Reserve its identity/range now, independent of lost preview delivery.
            previous = next(
                (
                    u.text
                    for u in self.ledger.snapshot().units
                    if old is not None and u.owned_span == old
                ),
                "",
            )
            self.ledger.preview(self._active, previous)
            if end - self._last_preview_end >= self.policy.preview_interval_ms * 16:
                self._preview = self._active
            cursor = end
            if end - begin == self.policy.owned_ms * 16:
                self.close_block("budget_rollover")
        self.wake()

    def close_block(self, reason: str = "vad") -> None:
        if self._active is None:
            return
        block = self.ledger.close_block(self._active.end, reason, start=self._active.start)
        unit = next(u for u in self.ledger.snapshot().units if u.unit_id == block.unit_id)
        due = self._clock() + self.policy.review_grace_ms / 1000
        self._closed[unit.unit_id] = _Closed(
            unit, due, due + self.policy.finalization_budget_ms / 1000, reason
        )
        self._active = None
        self._preview = None
        self._record_state()
        self.wake()

    def silence_before(self, sample: int) -> None:
        self._silence = max(self._silence, min(sample, self.ledger.accepted_samples))
        self.wake()

    def freeze(self) -> asyncio.Future[WindowReceipt]:
        target = self.ledger.accepted_samples
        if target in self._barriers:
            return self._barriers[target]
        self.close_block("client_commit")
        future: asyncio.Future[WindowReceipt] = asyncio.get_running_loop().create_future()
        self._barriers[target] = future
        # Keep only the current completed receipt, never a whole meeting history.
        for old in tuple(self._barriers):
            if old != target and self._barriers[old].done():
                self._barriers.pop(old)
        deadline = self._clock() + self.policy.finalization_budget_ms / 1000
        for uid, closed in self._closed.items():
            if closed.unit.owned_span.end <= target:
                self._closed[uid] = replace(closed, deadline=min(closed.deadline, deadline))
        self._force_through = max(self._force_through, target)
        self._silence = max(self._silence, target)
        self.wake()
        return future

    async def flush_intents(self) -> None:
        await self._idle.wait()
        if self._failure is not None:
            raise self._failure

    async def close(self) -> None:
        if self._close_task is None:
            self._close_task = asyncio.create_task(self._close(), name="asr-window-close")
        await join_cleanup(self._close_task)

    async def _close(self) -> None:
        self._stopping = True
        self._wake.set()
        if self._pump is not None:
            await self._pump
        await self.decoder.close()
        if self._auxiliary_tasks:
            await asyncio.gather(*self._auxiliary_tasks, return_exceptions=True)
        for future in self._barriers.values():
            if not future.done():
                future.set_exception(RuntimeError("window was cleared"))
        self.ring.clear()
        if self._metrics is not None:
            self._metrics.record_asr_window_state(
                self.scene,
                capture_backlog_samples=0,
                retained_pcm_bytes=0,
                mutable_units=0,
                pending_closed=0,
                falling_behind=0,
            )

    def _span(self, span: SampleSpan) -> dict[str, int]:
        return {"start": self._to_wire(span.start), "end": self._to_wire(span.end)}

    def _unit(self, unit: WindowUnit) -> dict[str, object]:
        value = asdict(unit)
        value["owned_span"] = self._span(unit.owned_span)
        return value

    async def _emit(self, event: dict[str, object]) -> None:
        # A tail preview after a terminal has a distinct payload even if its
        # text is unchanged. Reserve its revision before the first send await.
        revision = cast(int, event["window_revision"])
        if revision <= self._last_event_revision:
            self.ledger.window_revision = (
                max(self.ledger.window_revision, self._last_event_revision) + 1
            )
            event = {**event, "window_revision": self.ledger.window_revision}
        self._last_event_revision = cast(int, event["window_revision"])
        if len(json.dumps(event, ensure_ascii=False).encode()) + 512 > MAX_EVENT_BYTES:
            raise ValueError("window event exceeds its wire budget")
        await self._send(event)

    def _base(self, kind: str) -> dict[str, object]:
        snapshot = self.ledger.snapshot()
        return {
            "type": "speechrail.transcription.window." + kind,
            **asdict(snapshot.identity),
            "window_revision": snapshot.window_revision,
            "audio_span": self._span(snapshot.audio_span),
            "sealed_through_sample": self._to_wire(snapshot.sealed_through_sample),
            "falling_behind": self.falling_behind,
        }

    async def _snapshot(self) -> None:
        self._record_state()
        await self._emit(
            {
                **self._base("updated"),
                "units": [self._unit(u) for u in self.ledger.snapshot().units],
            }
        )

    async def _terminal(
        self, seal: WindowSeal | None, reason: SegmentCloseReason = "client_commit"
    ) -> None:
        if seal is None:
            return
        self._observe_lag()
        event = {
            **self._base("failed" if seal.failed_items else "sealed"),
            "transaction_id": seal.transaction_id,
            "closed_span": self._span(seal.closed_span),
            "audio_span": self._span(
                SampleSpan(seal.closed_span.start, self.ledger.accepted_samples)
            ),
            "remaining_units": [self._unit(u) for u in seal.remaining_units],
            "coverage": [{**asdict(c), "span": self._span(c.span)} for c in seal.coverage],
        }
        # Optional fields must be absent rather than null under the strict contract.
        event["coverage"] = [
            {k: v for k, v in {**asdict(c), "span": self._span(c.span)}.items() if v is not None}
            for c in seal.coverage
        ]
        if seal.failed_items:
            event["failed_items"] = [
                {**asdict(u), "owned_span": self._span(u.owned_span)} for u in seal.failed_items
            ]
        else:
            event["final_units"] = [self._unit(u) for u in seal.final_units]
        await self._emit(event)
        for unit in cast(
            tuple[FinalWindowUnit | FailedWindowItem, ...], seal.final_units + seal.failed_items
        ):
            span = unit.owned_span
            await self._send(
                transcription_segment_closed(
                    item_id=unit.item_id,
                    sample_span=(self._to_wire(span.start), self._to_wire(span.end)),
                    reason=reason,
                )
            )
            if isinstance(unit, FinalWindowUnit):
                cleaned = self._clean_final(unit.text) if self._clean_final is not None else None
                transcript = cleaned.text if cleaned is not None else unit.text
                await self._send(
                    transcription_completed(
                        item_id=unit.item_id,
                        transcript=transcript,
                        repetition_collapsed=(
                            cleaned.collapsed_runs or None if cleaned is not None else None
                        ),
                    )
                )
                if transcript:
                    pin = None
                    if len(self._auxiliary_tasks) < 2:
                        with suppress(RuntimeError):
                            pin = self.ring.borrow(span)
                    if pin is None:
                        if self._on_auxiliary_unavailable is not None:
                            await self._on_auxiliary_unavailable(unit, "alignment_overloaded")
                        continue
                    try:
                        task = await self._on_final(unit, pin.pcm16)
                    except BaseException:
                        pin.release()
                        raise
                    if task is None:
                        pin.release()
                    else:
                        self._auxiliary_tasks.add(task)

                        def release_pcm(_task: asyncio.Task[None], pin: PcmBorrow = pin) -> None:
                            pin.release()

                        task.add_done_callback(release_pcm)
                        task.add_done_callback(self._auxiliary_tasks.discard)
            else:
                self._failed += 1
                await self._send(
                    transcription_failed(
                        item_id=unit.item_id,
                        code=unit.reason,
                        message=(
                            "Transcription review failed; recovery text remains "
                            "in the window transaction"
                        ),
                    )
                )
        keep = max(
            self.ring.retained_from_sample,
            seal.sealed_through_sample - self.policy.left_context_ms * 16,
        )
        self.ring.discard_before(min(keep, self.ring.discardable_through))
        self._record_state()

    async def _decode(
        self, span: SampleSpan, kind: Literal["preview", "review"]
    ) -> WindowDecodeResult:
        with self.ring.borrow(span) as pin:
            request = WindowDecodeRequest(
                self.ledger.identity,
                "attempt_" + uuid4().hex,
                kind,
                span,
                pin.pcm16,
                self._language,
                self._context,
            )
            result = await self.decoder.decode(request)
            if (
                result.identity != request.identity
                or result.attempt_id != request.attempt_id
                or result.input_span != request.input_span
            ):
                raise ValueError("stale window decode result")
            self._decoded_through = max(self._decoded_through, span.end)
            return result

    async def _review_closed(self, parents: list[_Closed]) -> None:
        closed = parents[0]
        owned = SampleSpan(closed.unit.owned_span.start, parents[-1].unit.owned_span.end)
        deadline = min(parent.deadline for parent in parents)
        if owned.end <= self._force_through:
            deadline = min(deadline, self._clock() + self.policy.finalization_budget_ms / 1000)
        stage = "queue"
        try:
            remaining = deadline - self._clock()
            if remaining <= 0:
                raise TimeoutError()
            async with asyncio.timeout(remaining):
                # Contextual cropping is injected by the boundary evidence adapter.
                scope: Literal["contextual", "owned_only"] = "owned_only"
                span = owned
                if self._review is not None:
                    span = SampleSpan(
                        max(
                            self.ring.retained_from_sample,
                            owned.start - self.policy.left_context_ms * 16,
                        ),
                        min(
                            self.ledger.accepted_samples,
                            owned.end + self.policy.review_grace_ms * 16,
                            max(
                                self.ring.retained_from_sample,
                                owned.start - self.policy.left_context_ms * 16,
                            )
                            + self.policy.max_decode_ms * 16,
                        ),
                    )
                with self.ring.borrow(span) as pin:
                    request = WindowDecodeRequest(
                        self.ledger.identity,
                        "attempt_" + uuid4().hex,
                        "review",
                        span,
                        pin.pcm16,
                        self._language,
                        self._context,
                    )
                    stage = "decode"
                    result = await self.decoder.decode(request)
                    if (
                        result.identity != request.identity
                        or result.attempt_id != request.attempt_id
                        or result.input_span != span
                    ):
                        raise ValueError("review returned stale evidence")
                    if not result.complete and self._review is not None and span != owned:
                        # One fresh attempt on exactly the owned samples, under
                        # the same deadline and pin. A failed retry is terminal.
                        if self._metrics is not None:
                            self._metrics.record_asr_window_fallback("contextual_decode_incomplete")
                        begin = (owned.start - span.start) * 2
                        request = replace(
                            request,
                            attempt_id="attempt_" + uuid4().hex,
                            input_span=owned,
                            pcm16=pin.pcm16[begin : begin + owned.length * 2],
                        )
                        span = owned
                        result = await self.decoder.decode(request)
                    if (
                        result.identity != request.identity
                        or result.attempt_id != request.attempt_id
                        or result.input_span != span
                        or not result.complete
                    ):
                        raise ValueError("review returned incomplete or stale evidence")
                    self._decoded_through = max(self._decoded_through, span.end)
                    text = result.text
                    if self._review is not None:
                        stage = "boundary"
                        text, scope = await self._review(request, result, owned, deadline)
                reviewed = WindowUnit(
                    closed.unit.unit_id if len(parents) == 1 else "unit_" + uuid4().hex,
                    text,
                    closed.unit.text_revision,
                    owned,
                    "reviewed",
                )
                stage = "ledger"
                self.ledger.accept(
                    [reviewed],
                    {parent.unit.unit_id: parent.unit.text_revision for parent in parents},
                    identity=self.ledger.identity,
                    review_scope=scope,
                )
            seal = self.ledger.seal(owned.end, allow_silence=True)
        except (TimeoutError, ValueError, RuntimeError) as exc:
            if self._metrics is not None:
                self._metrics.record_asr_window_failure(
                    stage,
                    "timeout"
                    if isinstance(exc, TimeoutError)
                    else "invalid_evidence"
                    if isinstance(exc, ValueError)
                    else "runtime_error",
                )
            reason = (
                "window_review_timeout" if isinstance(exc, TimeoutError) else "window_review_failed"
            )
            seal = self.ledger.fail(owned.end, reason)
        # Delivery errors invalidate the barrier; never retry a mutated transaction.
        await self._terminal(seal, cast(SegmentCloseReason, closed.reason))

    async def _run(self) -> None:
        try:
            while not self._stopping:
                self._wake.clear()
                closed = next(iter(self._closed.values()), None)
                if closed is not None and (
                    closed.due <= self._clock() or closed.unit.owned_span.end <= self._force_through
                ):
                    parents = [closed]
                    maximum_owned = (
                        min(20000, self.policy.max_decode_ms - self.policy.left_context_ms) * 16
                    )
                    for candidate in list(self._closed.values())[1:]:
                        if (
                            candidate.unit.owned_span.start != parents[-1].unit.owned_span.end
                            or candidate.unit.owned_span.end - closed.unit.owned_span.start
                            > maximum_owned
                            or (
                                candidate.due > self._clock()
                                and candidate.unit.owned_span.end > self._force_through
                            )
                        ):
                            break
                        parents.append(candidate)
                    for parent in parents:
                        self._closed.pop(parent.unit.unit_id)
                    await self._review_closed(parents)
                    continue
                closed_preview = next(
                    (
                        candidate
                        for candidate in self._closed.values()
                        if self.scene == "caption"
                        and self._closed_preview_attempts.get(candidate.unit.unit_id, (0, 0))[0] < 2
                        and self._closed_preview_attempts.get(candidate.unit.unit_id, (0, 0))[1]
                        <= self._clock()
                        and self._previewed_through.get(
                            candidate.unit.unit_id, candidate.unit.owned_span.start
                        )
                        < candidate.unit.owned_span.end
                    ),
                    None,
                )
                if self._preview is not None or closed_preview is not None:
                    span = closed_preview.unit.owned_span if closed_preview else self._preview
                    assert span is not None
                    if closed_preview is None:
                        self._preview = None
                    else:
                        uid = closed_preview.unit.unit_id
                        attempts, _ = self._closed_preview_attempts.get(uid, (0, 0))
                        self._closed_preview_attempts[uid] = (attempts + 1, self._clock() + 0.5)
                    self._last_preview_end = span.end
                    try:
                        result = await self._decode(span, "preview")
                        if self._active is not None and self._active.start == span.start:
                            unit = self.ledger.preview(self._active, result.text)
                        else:
                            preview_parent = next(
                                (
                                    parent
                                    for parent in self._closed.values()
                                    if parent.unit.owned_span.start == span.start
                                    and parent.unit.owned_span.end >= span.end
                                ),
                                None,
                            )
                            if preview_parent is None:
                                continue
                            unit = self.ledger.settle_closed_preview(
                                preview_parent.unit.unit_id, result.text
                            )
                            self._closed[unit.unit_id] = replace(preview_parent, unit=unit)
                        self._previewed_through[unit.unit_id] = span.end
                        if result.text:
                            self._shown_through[unit.unit_id] = span.end
                        self._observe_lag()
                        await self._snapshot()
                    except RuntimeError, ValueError, TimeoutError:
                        pass  # A preview failure never invents a final or discards PCM.
                    continue
                limit = min(
                    self._silence,
                    self._active.start if self._active else self.ledger.accepted_samples,
                    closed.unit.owned_span.start if closed else self.ledger.accepted_samples,
                )
                if limit > self.ledger.sealed_through_sample:
                    await self._terminal(self.ledger.seal(limit, allow_silence=True))
                    continue
                for target, future in self._barriers.items():
                    if target <= self.ledger.sealed_through_sample and not future.done():
                        future.set_result(
                            WindowReceipt(self.ledger.window_revision, target, self._failed)
                        )
                self._idle.set()
                if self._wake.is_set():
                    continue
                timeout = max(0, closed.due - self._clock()) if closed is not None else None
                if self.scene == "caption":
                    retry_at = min(
                        (
                            retry
                            for uid, (attempts, retry) in self._closed_preview_attempts.items()
                            if attempts < 2
                            and uid in self._closed
                            and self._previewed_through.get(
                                uid, self._closed[uid].unit.owned_span.start
                            )
                            < self._closed[uid].unit.owned_span.end
                        ),
                        default=None,
                    )
                    if retry_at is not None:
                        delay = max(0, retry_at - self._clock())
                        timeout = delay if timeout is None else min(timeout, delay)
                with suppress(TimeoutError):
                    await asyncio.wait_for(self._wake.wait(), timeout)
        except BaseException as exc:
            self._failure = exc
            self._idle.set()
            for future in self._barriers.values():
                if not future.done():
                    future.set_exception(exc)
