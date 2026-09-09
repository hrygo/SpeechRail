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
    Span,
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
                replace_span=Span(0, through_sample),
                frames=(
                    ActivityFrame(
                        span=Span(0, through_sample),
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
        await session.register_completed("item_1", (TextUnit("unit_1", 0, 2, Span(0, 800)),))
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
        units = (TextUnit("unit", 0, 1, Span(0, 30 * 16_000 + 1)),)
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


def test_activity_failure_finalizes_pending_unknown_and_emits_one_status() -> None:
    async def scenario() -> None:
        session, activity = _session()
        await session.append(b"\x00\x00" * 800)
        await session.register_completed("item_1", (TextUnit("unit_1", 0, 2, Span(0, 800)),))
        await activity.queue.put(
            ActivityUpdate(
                epoch="epoch_1",
                step_id=0,
                replace_span=Span(0, 800),
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
                replace_span=Span(0, 800),
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
