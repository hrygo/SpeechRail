from __future__ import annotations

import asyncio

import pytest

from speechrail.application.diarization.session import (
    DiarizationSession,
    ItemAttributionUpdated,
    SessionDone,
    StatusChanged,
)
from speechrail.domain.diarization.attribution import AttributionLedger
from speechrail.domain.diarization.types import (
    ActivityFrame,
    ActivityUpdate,
    Attribution,
    SampleSpan,
    TextUnit,
)


class _FakeActivitySession:
    def __init__(self) -> None:
        self.appended: list[tuple[int, bytes]] = []
        self.queue: asyncio.Queue[ActivityUpdate | None] = asyncio.Queue()
        self.finished_through: int | None = None
        self.cancelled = False

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        self.appended.append((start_sample, pcm16))

    def updates(self):
        async def iterator():
            while update := await self.queue.get():
                yield update

        return iterator()

    async def finish(self, *, through_sample: int) -> None:
        self.finished_through = through_sample
        await self.queue.put(
            ActivityUpdate(
                epoch="epoch_1",
                step_id=1,
                replace_span=SampleSpan(0, through_sample),
                frames=(
                    ActivityFrame(
                        span=SampleSpan(0, through_sample),
                        scores=(0.9, 0.0, 0.0, 0.0),
                        active_slots=frozenset({0}),
                    ),
                ),
                processed_through=through_sample,
                stable_through=through_sample,
            )
        )
        await self.queue.put(None)

    async def cancel(self) -> None:
        self.cancelled = True
        await self.queue.put(None)


def _session() -> tuple[DiarizationSession, _FakeActivitySession]:
    activity = _FakeActivitySession()
    session: DiarizationSession
    ledger = AttributionLedger(accepted_samples=lambda: session.accepted_samples)
    session = DiarizationSession(activity=activity, ledger=ledger)
    return session, activity


def test_session_keeps_text_fixed_then_publishes_final_attribution_before_done() -> None:
    async def scenario() -> None:
        session, activity = _session()
        await session.append(b"\x00\x00" * 800)
        await session.register_completed("item_1", (TextUnit("unit_1", 0, 2, SampleSpan(0, 800)),))
        done = await session.finish("finish_1")
        events = [event async for event in session.events()]

        assert activity.appended == [(0, b"\x00\x00" * 800)]
        assert activity.finished_through == 800
        assert done.status == "complete"
        assert isinstance(events[-1], SessionDone)
        updates = [event for event in events if isinstance(event, ItemAttributionUpdated)]
        assert updates[-1].attributions[0].speaker == "A"
        assert updates[-1].attributions[0].state == "final"
        assert events[-1].last_sequence == updates[-1].sequence

    asyncio.run(scenario())


def test_update_queue_preserves_every_revision_for_sona_continuity() -> None:
    async def scenario() -> None:
        session, _ = _session()
        await session._emit(
            ItemAttributionUpdated(
                "item_1",
                (Attribution("unit_1", None, (), "provisional", "pending", 1),),
                1,
            )
        )
        await session._emit(
            ItemAttributionUpdated(
                "item_1",
                (Attribution("unit_1", "A", ("A",), "provisional", None, 2),),
                2,
            )
        )
        await session._emit(
            ItemAttributionUpdated(
                "item_1",
                (Attribution("unit_1", "B", ("B",), "provisional", None, 3),),
                3,
            )
        )
        await session._close_events()

        events = [event async for event in session.events()]
        updates = [event for event in events if isinstance(event, ItemAttributionUpdated)]
        assert [event.attributions[0].revision for event in updates] == [1, 2, 3]

    asyncio.run(scenario())


def test_finish_is_idempotent_and_rejects_a_different_finish_id() -> None:
    async def scenario() -> None:
        session, _ = _session()
        first = await session.finish("finish_1")
        assert await session.finish("finish_1") == first
        try:
            await session.finish("finish_2")
        except ValueError as exc:
            assert "already been finished" in str(exc)
        else:
            raise AssertionError("different finish id must fail")

    asyncio.run(scenario())


def test_session_rejects_more_than_4096_completed_units() -> None:
    async def scenario() -> None:
        session, _ = _session()
        units = tuple(TextUnit(str(index), index, index + 1, None) for index in range(4097))
        try:
            await session.register_completed("item_1", units)
        except ValueError as exc:
            assert "unit limit" in str(exc)
        else:
            raise AssertionError("unit limit must fail closed")

    asyncio.run(scenario())


def test_session_rejects_completed_units_outside_the_30_second_window() -> None:
    async def scenario() -> None:
        session, _ = _session()
        units = (TextUnit("unit", 0, 1, SampleSpan(0, 30 * 16_000 + 1)),)
        with pytest.raises(ValueError, match="pending window"):
            await session.register_completed("item_1", units)

    asyncio.run(scenario())


def test_activity_backlog_deadline_degrades_without_blocking_canonical_audio() -> None:
    class _BlockedActivity(_FakeActivitySession):
        async def append(self, *, start_sample: int, pcm16: bytes) -> None:
            del start_sample, pcm16
            await asyncio.Event().wait()

    async def scenario() -> None:
        activity = _BlockedActivity()
        session: DiarizationSession
        ledger = AttributionLedger(accepted_samples=lambda: session.accepted_samples)
        session = DiarizationSession(
            activity=activity,
            ledger=ledger,
            activity_backlog_seconds=0.01,
        )

        await session.append(b"\x00\x00" * 16_000)
        await asyncio.sleep(0)

        assert session.accepted_samples == 16_000
        assert activity.cancelled is True
        done = await session.finish("finish_1")
        assert done.status == "degraded"
        events = [event async for event in session.events()]
        statuses = [event for event in events if isinstance(event, StatusChanged)]
        assert [(event.status, event.reason) for event in statuses] == [
            ("degraded", "diarization_backlog_exceeded")
        ]

    asyncio.run(scenario())


@pytest.mark.parametrize("failure", ["pcm_budget", "backend_failure"])
def test_activity_admission_failure_preserves_text_and_canonical_timeline(failure: str) -> None:
    from speechrail.domain.diarization.types import DiarizationError
    from speechrail.runtime.window_pcm import PcmBudgetExceededError

    class RefusedActivity(_FakeActivitySession):
        async def append(self, *, start_sample: int, pcm16: bytes) -> None:
            if failure == "pcm_budget":
                raise PcmBudgetExceededError("exhausted")
            raise DiarizationError("unavailable", code="worker_error")

    async def scenario() -> None:
        activity = RefusedActivity()
        session: DiarizationSession
        ledger = AttributionLedger(accepted_samples=lambda: session.accepted_samples)
        session = DiarizationSession(activity=activity, ledger=ledger)
        await session.append(b"\0\0" * 16000)
        await session.append(b"\0\0" * 800)
        await session.register_completed("text", (TextUnit("unit", 0, 2, SampleSpan(0, 16800)),))
        done = await session.finish("finish")
        events = [event async for event in session.events()]
        assert done.status == "degraded"
        assert session.accepted_samples == 16800
        assert activity.cancelled
        assert [event.reason for event in events if isinstance(event, StatusChanged)] == [
            "audio_expired" if failure == "pcm_budget" else "model_not_ready"
        ]
        updates = [event for event in events if isinstance(event, ItemAttributionUpdated)]
        assert updates[-1].attributions[0].state == "final"
        assert updates[-1].attributions[0].speaker is None

    asyncio.run(scenario())


def test_activity_update_cannot_outrun_the_accepted_sample_watermark() -> None:
    class _InterleavingActivity(_FakeActivitySession):
        def __init__(self) -> None:
            super().__init__()
            self.published = asyncio.Event()
            self.release_append = asyncio.Event()

        async def append(self, *, start_sample: int, pcm16: bytes) -> None:
            end = start_sample + len(pcm16) // 2
            await self.queue.put(
                ActivityUpdate(
                    epoch="epoch_1",
                    step_id=1,
                    replace_span=SampleSpan(start_sample, end),
                    frames=(
                        ActivityFrame(
                            span=SampleSpan(start_sample, end),
                            scores=(0.9, 0.0, 0.0, 0.0),
                            active_slots=frozenset({0}),
                        ),
                    ),
                    processed_through=end,
                    stable_through=end,
                )
            )
            self.published.set()
            await self.release_append.wait()

        async def finish(self, *, through_sample: int) -> None:
            self.finished_through = through_sample
            await self.queue.put(None)

    class _ObservedLedger(AttributionLedger):
        def __init__(self, *, accepted_samples):
            super().__init__(accepted_samples=accepted_samples)
            self.applied = asyncio.Event()

        def apply(self, update: ActivityUpdate) -> tuple[Attribution, ...]:
            try:
                return super().apply(update)
            finally:
                self.applied.set()

    async def scenario() -> None:
        activity = _InterleavingActivity()
        session: DiarizationSession
        ledger = _ObservedLedger(accepted_samples=lambda: session.accepted_samples)
        session = DiarizationSession(activity=activity, ledger=ledger)
        await session.start()
        append_task = asyncio.create_task(session.append(b"\x00\x00" * 16))

        await activity.published.wait()
        await asyncio.wait_for(ledger.applied.wait(), timeout=0.1)
        activity.release_append.set()
        await append_task

        done = await session.finish("finish_1")
        events = [event async for event in session.events()]
        statuses = [event for event in events if isinstance(event, StatusChanged)]

        assert done.status == "complete"
        assert session.accepted_samples == 16
        assert activity.finished_through == 16
        assert statuses == []

    asyncio.run(scenario())


def test_activity_failure_finalizes_pending_unknown_and_emits_one_status() -> None:
    async def scenario() -> None:
        session, activity = _session()
        await session.append(b"\x00\x00" * 800)
        await session.register_completed("item_1", (TextUnit("unit_1", 0, 2, SampleSpan(0, 800)),))
        await activity.queue.put(
            ActivityUpdate(
                epoch="epoch_1",
                step_id=0,
                replace_span=SampleSpan(0, 800),
                frames=(),
                processed_through=800,
                stable_through=0,
            )
        )
        await asyncio.sleep(0)
        await activity.queue.put(
            ActivityUpdate(
                epoch="wrong_epoch",
                step_id=1,
                replace_span=SampleSpan(0, 800),
                frames=(),
                processed_through=800,
                stable_through=0,
            )
        )
        await activity.queue.put(None)
        await asyncio.sleep(0)
        done = await session.finish("finish_1")
        events = [event async for event in session.events()]

        statuses = [event for event in events if isinstance(event, StatusChanged)]
        assert len(statuses) == 1
        assert done.status == "degraded"
        final = [event for event in events if isinstance(event, ItemAttributionUpdated)][-1]
        assert final.attributions[0].speaker is None
        assert final.attributions[0].state == "final"

    asyncio.run(scenario())


def test_slow_event_consumer_gets_a_bounded_latest_snapshot_with_final_units() -> None:
    async def scenario() -> None:
        activity = _FakeActivitySession()
        session: DiarizationSession
        ledger = AttributionLedger(accepted_samples=lambda: session.accepted_samples)
        session = DiarizationSession(
            activity=activity,
            ledger=ledger,
            max_pending_update_events=1,
        )
        provisional = Attribution("unit_1", None, (), "provisional", "pending", 1)
        final_one = Attribution("unit_1", "A", ("A",), "final", None, 2)
        final_two = Attribution("unit_2", "B", ("B",), "final", None, 1)

        await session._emit(ItemAttributionUpdated("item_1", (provisional,), 1))
        await session._emit(ItemAttributionUpdated("item_1", (final_one,), 2))
        await session._emit(ItemAttributionUpdated("item_2", (final_two,), 3))
        await session._close_events()
        events = [event async for event in session.events()]

        updates = [event for event in events if isinstance(event, ItemAttributionUpdated)]
        assert updates == []
        statuses = [event for event in events if isinstance(event, StatusChanged)]
        assert len(statuses) == 1
        assert statuses[0].reason == "diarization_event_backlog_exceeded"

    asyncio.run(scenario())


@pytest.mark.parametrize(
    "blocked_stage", ["native_finish", "event_drain", "cancel_failure", "event_failure"]
)
def test_finish_deadline_covers_native_and_event_drain_and_joins_cleanup(
    monkeypatch, blocked_stage: str
) -> None:
    from contextlib import asynccontextmanager
    from types import SimpleNamespace

    from speechrail.application.diarization import session as session_module

    entered: list[float] = []

    @asynccontextmanager
    async def immediate_deadline(seconds: float):
        entered.append(seconds)
        # A blocked operation, rather than machine speed, triggers expiration.
        async with asyncio.timeout(None if blocked_stage == "event_failure" else 0):
            yield

    monkeypatch.setattr(
        session_module,
        "asyncio",
        SimpleNamespace(
            **{name: getattr(asyncio, name) for name in dir(asyncio) if name != "timeout"},
            timeout=immediate_deadline,
        ),
    )

    failure_observed = asyncio.Event()

    class BlockedActivity(_FakeActivitySession):
        def updates(self):
            async def iterator():
                while update := await self.queue.get():
                    if isinstance(update, RuntimeError):
                        failure_observed.set()
                        raise update
                    yield update

            return iterator()

        async def finish(self, *, through_sample: int) -> None:
            assert entered == [30], "native finish must be inside the drain deadline"
            self.finished_through = through_sample
            if blocked_stage == "event_failure":
                await self.queue.put(RuntimeError("invalid native stream"))
                return
            if blocked_stage in {"native_finish", "cancel_failure"}:
                try:
                    await asyncio.Event().wait()
                finally:
                    if blocked_stage == "cancel_failure":
                        await self.queue.put(RuntimeError("native finish cancelled"))
                        await failure_observed.wait()
            # Otherwise leave the activity event stream open after native EOF.

    async def scenario() -> None:
        activity = BlockedActivity()
        session: DiarizationSession
        ledger = AttributionLedger(accepted_samples=lambda: session.accepted_samples)
        session = DiarizationSession(activity=activity, ledger=ledger)
        await session.append(b"\x00\x00" * 16)
        await session.register_completed("item", (TextUnit("unit", 0, 1, SampleSpan(0, 16)),))
        done = await session.finish("finish")
        events = [event async for event in session.events()]

        assert entered == [30]
        assert done.status == "degraded"
        if blocked_stage != "event_failure":
            assert activity.cancelled
        assert session._pump is not None and session._pump.done()
        assert events[-1] == done
        statuses = [event.reason for event in events if isinstance(event, StatusChanged)]
        assert statuses == [
            "diarization_invalid_output" if blocked_stage == "event_failure"
            else "finalization_timeout"
        ]
        updates = [event for event in events if isinstance(event, ItemAttributionUpdated)]
        assert updates[-1].attributions[0].state == "final"
        assert updates[-1].attributions[0].speaker is None
        assert await session.finish("finish") == done

    asyncio.run(scenario())
