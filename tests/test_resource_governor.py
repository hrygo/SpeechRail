from __future__ import annotations

import asyncio

import pytest

from speechrail.config import Settings
from speechrail.domain.resource_limits import GovernorLimits as DomainGovernorLimits
from speechrail.runtime.resource_governor import (
    GovernorLimits,
    GovernorQueueFullError,
    ResourceGovernor,
    WorkClass,
)


def test_runtime_reexports_the_domain_limits_value_object() -> None:
    assert GovernorLimits is DomainGovernorLimits


def test_realtime_slot_remains_available_when_batch_lane_is_saturated() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(total_capacity=3, realtime_reserved_capacity=1, max_pending_per_class=4)
        )
        batch_started = [asyncio.Event(), asyncio.Event()]
        release_batch = asyncio.Event()
        realtime_started = asyncio.Event()

        async def blocking_batch(index: int) -> None:
            batch_started[index].set()
            await release_batch.wait()

        async def realtime() -> None:
            realtime_started.set()

        batch_tasks = [
            asyncio.create_task(
                governor.run(lambda index=index: blocking_batch(index), WorkClass.BATCH_ASR)
            )
            for index in range(2)
        ]
        await asyncio.gather(*(event.wait() for event in batch_started))

        await governor.run(realtime, WorkClass.REALTIME_ASR)
        assert realtime_started.is_set()
        assert governor.snapshot().active_batch == 2

        release_batch.set()
        await asyncio.gather(*batch_tasks)

    asyncio.run(scenario())


def test_batch_waits_fifo_without_stealing_reserved_realtime_capacity() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(total_capacity=2, realtime_reserved_capacity=1, max_pending_per_class=4)
        )
        first_started = asyncio.Event()
        release_first = asyncio.Event()
        second_started = asyncio.Event()

        async def first() -> None:
            first_started.set()
            await release_first.wait()

        async def second() -> None:
            second_started.set()

        first_task = asyncio.create_task(governor.run(first, WorkClass.BATCH_TTS))
        await first_started.wait()
        second_task = asyncio.create_task(governor.run(second, WorkClass.BATCH_TTS))
        await asyncio.sleep(0)

        assert not second_started.is_set()
        assert governor.snapshot().pending_batch == 1

        release_first.set()
        await asyncio.gather(first_task, second_task)
        assert second_started.is_set()

    asyncio.run(scenario())


def test_batch_aging_wakes_without_another_release_or_notify() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(
                total_capacity=2,
                realtime_reserved_capacity=1,
                max_pending_per_class=4,
                batch_aging_seconds=0.02,
            )
        )
        first_started = asyncio.Event()
        release_first = asyncio.Event()
        second_started = asyncio.Event()

        async def first() -> None:
            first_started.set()
            await release_first.wait()

        async def second() -> None:
            second_started.set()

        first_task = asyncio.create_task(governor.run(first, WorkClass.BATCH_ASR))
        await first_started.wait()
        second_task = asyncio.create_task(governor.run(second, WorkClass.BATCH_ASR))
        try:
            await asyncio.wait_for(second_started.wait(), timeout=0.5)
        finally:
            release_first.set()
            await asyncio.wait_for(first_task, timeout=0.5)
            if not second_task.done():
                second_task.cancel()
            await asyncio.gather(second_task, return_exceptions=True)

        assert second_started.is_set()

    asyncio.run(scenario())


def test_batch_aging_hands_timer_to_next_waiter_after_admission() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(
                total_capacity=4,
                realtime_reserved_capacity=3,
                max_pending_per_class=4,
                batch_aging_seconds=0.02,
            )
        )
        holder_started = asyncio.Event()
        first_waiter_started = asyncio.Event()
        second_waiter_started = asyncio.Event()
        release_holder = asyncio.Event()
        release_first_waiter = asyncio.Event()
        release_second_waiter = asyncio.Event()

        async def holder() -> None:
            holder_started.set()
            await release_holder.wait()

        async def first_waiter() -> None:
            first_waiter_started.set()
            await release_first_waiter.wait()

        async def second_waiter() -> None:
            second_waiter_started.set()
            await release_second_waiter.wait()

        holder_task = asyncio.create_task(governor.run(holder, WorkClass.BATCH_ASR))
        await holder_started.wait()
        first_task = asyncio.create_task(
            governor.run(first_waiter, WorkClass.BATCH_ASR)
        )
        second_task = asyncio.create_task(
            governor.run(second_waiter, WorkClass.BATCH_ASR)
        )
        try:
            await asyncio.wait_for(first_waiter_started.wait(), timeout=0.5)
            await asyncio.wait_for(second_waiter_started.wait(), timeout=0.5)
        finally:
            release_holder.set()
            release_first_waiter.set()
            release_second_waiter.set()
            await asyncio.gather(
                holder_task, first_task, second_task, return_exceptions=True
            )

        assert second_waiter_started.is_set()

    asyncio.run(scenario())


def test_cancelled_batch_waiter_is_removed_without_leaking_capacity() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(
                total_capacity=2,
                realtime_reserved_capacity=1,
                max_pending_per_class=4,
                batch_aging_seconds=30.0,
            )
        )
        first_started = asyncio.Event()
        release_first = asyncio.Event()

        async def first() -> None:
            first_started.set()
            await release_first.wait()

        first_task = asyncio.create_task(governor.run(first, WorkClass.BATCH_ASR))
        await first_started.wait()
        waiting_task = asyncio.create_task(
            governor.run(lambda: asyncio.sleep(0), WorkClass.BATCH_ASR)
        )
        for _ in range(100):
            if governor.snapshot().pending_batch == 1:
                break
            await asyncio.sleep(0.01)
        assert governor.snapshot().pending_batch == 1

        waiting_task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await waiting_task
        assert governor.snapshot().pending_batch == 0
        assert governor.snapshot().active_batch == 1

        release_first.set()
        await first_task
        assert governor.snapshot().active_batch == 0
        await governor.run(lambda: asyncio.sleep(0), WorkClass.BATCH_ASR)
        assert governor.snapshot().active_batch == 0

    asyncio.run(scenario())


def test_batch_waiter_deadline_removes_waiter_without_leaking_capacity() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(
                total_capacity=2,
                realtime_reserved_capacity=1,
                max_pending_per_class=4,
                batch_aging_seconds=30.0,
            )
        )
        first_started = asyncio.Event()
        release_first = asyncio.Event()

        async def first() -> None:
            first_started.set()
            await release_first.wait()

        first_task = asyncio.create_task(governor.run(first, WorkClass.BATCH_ASR))
        await first_started.wait()
        waiting_task = asyncio.create_task(
            governor.run(
                lambda: asyncio.sleep(0), WorkClass.BATCH_ASR, deadline=0.02
            )
        )
        for _ in range(100):
            if governor.snapshot().pending_batch == 1:
                break
            await asyncio.sleep(0.01)
        assert governor.snapshot().pending_batch == 1

        with pytest.raises(TimeoutError):
            await waiting_task
        assert governor.snapshot().pending_batch == 0
        assert governor.snapshot().active_batch == 1

        release_first.set()
        await first_task
        assert governor.snapshot().active_batch == 0
        await governor.run(lambda: asyncio.sleep(0), WorkClass.BATCH_ASR)
        assert governor.snapshot().active_batch == 0

    asyncio.run(scenario())


def test_queue_limit_is_reported() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(total_capacity=2, realtime_reserved_capacity=1, max_pending_per_class=1)
        )
        hold = asyncio.Event()
        entered = asyncio.Event()

        async def blocking() -> None:
            entered.set()
            await hold.wait()

        task = asyncio.create_task(governor.run(blocking, WorkClass.BATCH_ASR))
        await entered.wait()

        waiting = asyncio.create_task(governor.run(lambda: asyncio.sleep(0), WorkClass.BATCH_ASR))
        await asyncio.sleep(0)
        try:
            await governor.run(lambda: asyncio.sleep(0), WorkClass.BATCH_ASR, deadline=0.01)
        except GovernorQueueFullError:
            pass
        else:
            raise AssertionError("expected bounded batch queue to reject admission")

        hold.set()
        await asyncio.gather(task, waiting)

    asyncio.run(scenario())


def test_settings_validate_resource_governor_reservation() -> None:
    with pytest.raises(ValueError, match="realtime_reserved_capacity"):
        Settings(runtime_total_capacity=2, realtime_reserved_capacity=2)

    settings = Settings(runtime_total_capacity=3, realtime_reserved_capacity=1)
    assert settings.governor_limits.total_capacity == 3


def test_governor_queue_full_fires_rejection_metric_callback() -> None:
    """Queue-full rejection increments speechrail_governor_queue_rejections_total."""
    from speechrail.observability.metrics import Metrics

    async def scenario() -> None:
        metrics = Metrics()
        governor = ResourceGovernor(
            GovernorLimits(total_capacity=2, realtime_reserved_capacity=1, max_pending_per_class=1),
            on_reject=metrics.record_governor_rejection,
        )
        hold = asyncio.Event()
        entered = asyncio.Event()

        async def blocking() -> None:
            entered.set()
            await hold.wait()

        # Occupy both lanes so a subsequent realtime request must queue.
        realtime_holder = asyncio.create_task(
            governor.run(blocking, WorkClass.REALTIME_ASR)
        )
        await entered.wait()
        batch_holder = asyncio.create_task(governor.run(blocking, WorkClass.BATCH_ASR))
        for _ in range(100):
            if governor.snapshot().active_batch == 1:
                break
            await asyncio.sleep(0.01)

        waiting = asyncio.create_task(
            governor.run(lambda: asyncio.sleep(0), WorkClass.REALTIME_ASR)
        )
        for _ in range(100):
            if governor.snapshot().pending_realtime == 1:
                break
            await asyncio.sleep(0.01)
        assert governor.snapshot().pending_realtime == 1

        with pytest.raises(GovernorQueueFullError):
            await governor.run(lambda: asyncio.sleep(0), WorkClass.REALTIME_ASR)

        hold.set()
        await asyncio.gather(realtime_holder, batch_holder, waiting)

        text = metrics.render_prometheus()
        assert "speechrail_governor_queue_rejections_total" in text
        assert 'class="realtime_asr"' in text
        assert 'reason="queue_full"' in text

    asyncio.run(scenario())


def test_settings_allow_audio_seconds_beyond_one_worker_frame() -> None:
    """逐窗 IPC 后，完整文件时长不再受单帧上限约束。"""

    settings = Settings(max_audio_seconds=5000, qwen3_model_dir=None, qwen3_python=None)

    assert settings.max_audio_seconds == 5000


def _aging_governor(now: dict) -> ResourceGovernor:
    return ResourceGovernor(
        GovernorLimits(
            total_capacity=2,
            realtime_reserved_capacity=1,
            max_pending_per_class=4,
            batch_aging_seconds=30.0,
        ),
        clock=lambda: now["t"],
    )


def test_batch_aging_admits_starved_batch_past_threshold() -> None:
    """A batch request that aged past the threshold may use the reserved lane."""

    async def scenario() -> None:
        now = {"t": 0.0}
        governor = _aging_governor(now)
        rt_release = asyncio.Event()
        batch_release = asyncio.Event()
        entered = asyncio.Event()

        async def blocking() -> None:
            entered.set()
            await rt_release.wait()

        async def blocking_batch() -> None:
            entered.set()
            await batch_release.wait()

        realtime_holder = asyncio.create_task(
            governor.run(blocking, WorkClass.REALTIME_ASR)
        )
        await entered.wait()
        entered.clear()
        batch_holder = asyncio.create_task(
            governor.run(blocking_batch, WorkClass.BATCH_ASR)
        )
        for _ in range(200):
            if governor.snapshot().active_batch == 1:
                break
            await asyncio.sleep(0.01)
        entered.clear()
        realtime_waiter = asyncio.create_task(
            governor.run(blocking, WorkClass.REALTIME_ASR)
        )
        for _ in range(200):
            if governor.snapshot().pending_realtime == 1:
                break
            await asyncio.sleep(0.01)
        entered.clear()

        starved_started = asyncio.Event()

        async def starved() -> None:
            starved_started.set()

        starved_task = asyncio.create_task(governor.run(starved, WorkClass.BATCH_ASR))
        await asyncio.sleep(0.01)
        assert not starved_started.is_set()

        # Age past the threshold, then churn the realtime lane only: the
        # waiter's release notifies the starved batch waiter, which may now
        # take the reserved lane even though the batch lane is still held.
        now["t"] = 31.0
        rt_release.set()
        await asyncio.wait_for(entered.wait(), timeout=1.0)
        rt_release.set()
        await asyncio.wait_for(starved_started.wait(), timeout=1.0)

        batch_release.set()
        await asyncio.gather(
            realtime_holder, batch_holder, realtime_waiter, starved_task
        )

    asyncio.run(scenario())


def test_batch_below_aging_threshold_still_defers_to_reserved_capacity() -> None:
    async def scenario() -> None:
        now = {"t": 0.0}
        governor = _aging_governor(now)
        rt_release = asyncio.Event()
        batch_release = asyncio.Event()
        entered = asyncio.Event()

        async def blocking() -> None:
            entered.set()
            await rt_release.wait()

        async def blocking_batch() -> None:
            entered.set()
            await batch_release.wait()

        realtime_holder = asyncio.create_task(
            governor.run(blocking, WorkClass.REALTIME_ASR)
        )
        await entered.wait()
        entered.clear()
        batch_holder = asyncio.create_task(
            governor.run(blocking_batch, WorkClass.BATCH_ASR)
        )
        for _ in range(200):
            if governor.snapshot().active_batch == 1:
                break
            await asyncio.sleep(0.01)
        entered.clear()
        realtime_waiter = asyncio.create_task(
            governor.run(blocking, WorkClass.REALTIME_ASR)
        )
        for _ in range(200):
            if governor.snapshot().pending_realtime == 1:
                break
            await asyncio.sleep(0.01)
        entered.clear()

        starved_started = asyncio.Event()

        async def starved() -> None:
            starved_started.set()

        starved_task = asyncio.create_task(governor.run(starved, WorkClass.BATCH_ASR))
        await asyncio.sleep(0.01)

        # Churn the realtime lane below the aging threshold: the batch waiter
        # must keep waiting for a non-reserved lane instead of stealing one.
        now["t"] = 10.0
        rt_release.set()
        await asyncio.wait_for(entered.wait(), timeout=1.0)
        rt_release.set()
        await asyncio.sleep(0.05)
        assert not starved_started.is_set()

        # Freeing the batch lane admits the starved request through the normal path.
        batch_release.set()
        await asyncio.gather(
            realtime_holder, batch_holder, realtime_waiter, starved_task
        )
        assert starved_started.is_set()

    asyncio.run(scenario())


def test_heavy_overlap_serialization_when_budget_constrained() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(
            GovernorLimits(total_capacity=4, realtime_reserved_capacity=1, max_pending_per_class=4),
            allow_heavy_overlap=False,
        )

        asr_started = asyncio.Event()
        release_asr = asyncio.Event()
        tts_started = asyncio.Event()

        async def asr_work() -> None:
            asr_started.set()
            await release_asr.wait()

        async def tts_work() -> None:
            tts_started.set()

        asr_task = asyncio.create_task(governor.run(asr_work, WorkClass.BATCH_ASR))
        await asr_started.wait()

        # While ASR is active, TTS should be blocked from admission
        # because allow_heavy_overlap=False.
        tts_task = asyncio.create_task(governor.run(tts_work, WorkClass.BATCH_TTS))
        await asyncio.sleep(0.02)
        assert not tts_started.is_set()
        assert governor.snapshot().active_asr == 1
        assert governor.snapshot().active_tts == 0
        assert governor.snapshot().pending_batch == 1

        # Releasing ASR unblocks TTS
        release_asr.set()
        await asr_task
        await asyncio.wait_for(tts_started.wait(), timeout=1.0)
        await tts_task
        assert governor.snapshot().active_asr == 0
        assert governor.snapshot().active_tts == 0

    asyncio.run(scenario())
