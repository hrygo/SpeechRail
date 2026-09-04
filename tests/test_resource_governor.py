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


def test_settings_reject_audio_seconds_beyond_worker_frame_limit() -> None:
    """max_audio_seconds that cannot be shipped to the worker must fail at startup."""
    with pytest.raises(ValueError, match="frame limit"):
        Settings(max_audio_seconds=5000, qwen3_model_dir=None, qwen3_python=None)
