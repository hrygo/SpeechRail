"""Diarization reserves its own heavy capability lane (ADR-0016 extension)."""

from __future__ import annotations

import asyncio

import pytest

from speechrail.runtime.resource_governor import (
    GovernorLimits,
    ResourceGovernor,
    WorkClass,
)

LIMITS = GovernorLimits(
    total_capacity=4,
    realtime_reserved_capacity=1,
    max_pending_per_class=4,
)


@pytest.mark.parametrize("lane", [WorkClass.DIARIZATION, WorkClass.BATCH_ASR])
def test_busy_waiter_does_not_block_an_independent_batch_lane(lane):
    async def run():
        other = WorkClass.BATCH_ASR if lane.is_diarization else WorkClass.DIARIZATION
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=True)
        async with governor.reserve(lane):

            async def blocked():
                async with governor.reserve(lane):
                    pass

            waiter = asyncio.create_task(blocked())
            await asyncio.sleep(0)
            try:
                await asyncio.wait_for(governor.run(lambda: asyncio.sleep(0), other), 0.2)
                assert governor.snapshot().pending_batch == 1
            finally:
                waiter.cancel()
                await asyncio.gather(waiter, return_exceptions=True)
        assert governor.snapshot().pending_batch == 0
        assert governor.snapshot().active_batch == 0

    asyncio.run(run())


@pytest.mark.parametrize("bounded,overlap", [(True, True), (False, True), (True, False)])
def test_diarization_quarantine_preserves_resource_occupancy_and_policy(bounded, overlap):
    from speechrail.runtime.resource_governor import GovernorLaneIsolatedError

    async def run():
        governor = ResourceGovernor(
            LIMITS, allow_heavy_overlap=overlap, quarantine_resources_bounded=bounded
        )
        async with governor.reserve(WorkClass.DIARIZATION):
            governor.quarantine_diarization_lane()
        assert governor.snapshot().retained_diarization == 1
        assert governor.snapshot().active_diarization == 0
        with pytest.raises(GovernorLaneIsolatedError):
            async with governor.reserve(WorkClass.DIARIZATION):
                pytest.fail("isolated lane admitted")
        for other in (WorkClass.REALTIME_ASR, WorkClass.REALTIME_TTS):
            assert governor.lane_available(other) is (bounded and overlap)
            if bounded and overlap:
                async with governor.reserve(other):
                    pass
            else:
                with pytest.raises(GovernorLaneIsolatedError):
                    async with governor.reserve(other):
                        pytest.fail("unknown resource bound admitted")

    asyncio.run(run())


def test_bounded_asr_quarantine_does_not_quarantine_diarization():
    governor = ResourceGovernor(LIMITS, allow_heavy_overlap=True, quarantine_resources_bounded=True)
    governor.quarantine_asr_lane()
    assert not governor.lane_available(WorkClass.REALTIME_ASR)
    assert governor.lane_available(WorkClass.DIARIZATION)


def test_lane_available_obeys_the_same_serial_rules_as_admission():
    async def run():
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=False)
        async with governor.reserve(WorkClass.DIARIZATION):
            assert not governor.lane_available(WorkClass.REALTIME_ASR)
            assert not governor.lane_available(WorkClass.REALTIME_TTS)
            assert not governor.lane_available(WorkClass.DIARIZATION)
        assert governor.lane_available(WorkClass.REALTIME_ASR)

    asyncio.run(run())


def test_diarization_quarantine_wakes_queued_waiter_without_releasing_active_lease():
    from speechrail.runtime.resource_governor import GovernorLaneIsolatedError

    async def run():
        governor = ResourceGovernor(LIMITS, quarantine_resources_bounded=True)
        async with governor.reserve(WorkClass.DIARIZATION):
            task = asyncio.create_task(
                governor.run(lambda: asyncio.sleep(0), WorkClass.DIARIZATION)
            )
            await asyncio.sleep(0)
            assert governor.snapshot().pending_batch == 1
            governor.quarantine_diarization_lane()
            with pytest.raises(GovernorLaneIsolatedError):
                await asyncio.wait_for(task, 1)
            assert governor.snapshot().pending_batch == 0
            assert governor.snapshot().active_diarization == 1
        assert governor.snapshot().active_diarization == 0
        assert governor.snapshot().retained_diarization == 1

    asyncio.run(run())


def test_diarization_work_class_is_its_own_category() -> None:
    work_class = WorkClass.DIARIZATION
    assert work_class.value == "diarization"
    assert work_class.is_diarization
    assert not work_class.is_asr
    assert not work_class.is_tts
    assert not work_class.is_realtime


def test_diarization_reservation_is_not_counted_as_asr_or_tts() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=True)
        started = asyncio.Event()
        release = asyncio.Event()

        async def work() -> None:
            started.set()
            await release.wait()

        task = asyncio.create_task(governor.run(work, WorkClass.DIARIZATION))
        await started.wait()

        snapshot = governor.snapshot()
        assert snapshot.active_diarization == 1
        assert snapshot.active_asr == 0
        assert snapshot.active_tts == 0
        assert snapshot.active_batch == 1

        release.set()
        await task
        assert governor.snapshot().active_diarization == 0

    asyncio.run(scenario())


def test_only_one_diarization_reservation_is_active_at_a_time() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=True)
        first_started = asyncio.Event()
        release_first = asyncio.Event()
        second_started = asyncio.Event()

        async def first() -> None:
            first_started.set()
            await release_first.wait()

        async def second() -> None:
            second_started.set()

        first_task = asyncio.create_task(governor.run(first, WorkClass.DIARIZATION))
        await first_started.wait()
        second_task = asyncio.create_task(governor.run(second, WorkClass.DIARIZATION))
        await asyncio.sleep(0.01)

        assert governor.snapshot().active_diarization == 1
        assert governor.snapshot().pending_batch == 1
        assert not second_started.is_set()

        release_first.set()
        await asyncio.wait_for(second_started.wait(), timeout=1)
        await asyncio.gather(first_task, second_task)
        assert governor.snapshot().active_diarization == 0

    asyncio.run(scenario())


def test_diarization_overlaps_asr_only_when_policy_allows() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=True)
        asr_started = asyncio.Event()
        release_asr = asyncio.Event()
        diarization_started = asyncio.Event()
        release_diarization = asyncio.Event()

        async def asr() -> None:
            asr_started.set()
            await release_asr.wait()

        async def diarization() -> None:
            diarization_started.set()
            await release_diarization.wait()

        asr_task = asyncio.create_task(governor.run(asr, WorkClass.REALTIME_ASR))
        await asr_started.wait()
        diarization_task = asyncio.create_task(governor.run(diarization, WorkClass.DIARIZATION))
        await asyncio.wait_for(diarization_started.wait(), timeout=1)

        snapshot = governor.snapshot()
        assert snapshot.active_asr == 1
        assert snapshot.active_diarization == 1

        release_asr.set()
        release_diarization.set()
        await asyncio.gather(asr_task, diarization_task)

    asyncio.run(scenario())


def test_diarization_overlaps_tts_only_when_policy_allows() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=True)
        tts_started = asyncio.Event()
        release_tts = asyncio.Event()
        diarization_started = asyncio.Event()
        release_diarization = asyncio.Event()

        async def tts() -> None:
            tts_started.set()
            await release_tts.wait()

        async def diarization() -> None:
            diarization_started.set()
            await release_diarization.wait()

        tts_task = asyncio.create_task(
            governor.run(tts, WorkClass.BATCH_TTS, resource_key="voice_design")
        )
        await tts_started.wait()
        diarization_task = asyncio.create_task(governor.run(diarization, WorkClass.DIARIZATION))
        await asyncio.wait_for(diarization_started.wait(), timeout=1)

        snapshot = governor.snapshot()
        assert snapshot.active_tts == 1
        assert snapshot.active_diarization == 1

        release_tts.set()
        release_diarization.set()
        await asyncio.gather(tts_task, diarization_task)

    asyncio.run(scenario())


def test_diarization_serializes_beside_active_asr_when_overlap_disabled() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=False)
        asr_started = asyncio.Event()
        release_asr = asyncio.Event()
        diarization_started = asyncio.Event()

        async def asr() -> None:
            asr_started.set()
            await release_asr.wait()

        async def diarization() -> None:
            diarization_started.set()

        asr_task = asyncio.create_task(governor.run(asr, WorkClass.REALTIME_ASR))
        await asr_started.wait()
        diarization_task = asyncio.create_task(governor.run(diarization, WorkClass.DIARIZATION))
        await asyncio.sleep(0.02)

        snapshot = governor.snapshot()
        assert not diarization_started.is_set()
        assert snapshot.active_asr == 1
        assert snapshot.active_diarization == 0
        assert snapshot.pending_batch == 1

        release_asr.set()
        await asyncio.wait_for(diarization_started.wait(), timeout=1)
        await asyncio.gather(asr_task, diarization_task)

    asyncio.run(scenario())


def test_active_diarization_serializes_asr_when_overlap_disabled() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=False)
        diarization_started = asyncio.Event()
        release_diarization = asyncio.Event()
        asr_started = asyncio.Event()

        async def diarization() -> None:
            diarization_started.set()
            await release_diarization.wait()

        async def asr() -> None:
            asr_started.set()

        diarization_task = asyncio.create_task(governor.run(diarization, WorkClass.DIARIZATION))
        await diarization_started.wait()
        asr_task = asyncio.create_task(governor.run(asr, WorkClass.REALTIME_ASR))
        await asyncio.sleep(0.02)

        snapshot = governor.snapshot()
        assert not asr_started.is_set()
        assert snapshot.active_diarization == 1
        assert snapshot.pending_realtime == 1

        release_diarization.set()
        await asyncio.wait_for(asr_started.wait(), timeout=1)
        await asyncio.gather(diarization_task, asr_task)

    asyncio.run(scenario())


def test_asr_reservations_stay_serial_beside_the_diarization_lane() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=True)
        first_started = asyncio.Event()
        release_first = asyncio.Event()
        second_started = asyncio.Event()

        async def first() -> None:
            first_started.set()
            await release_first.wait()

        async def second() -> None:
            second_started.set()

        first_task = asyncio.create_task(governor.run(first, WorkClass.REALTIME_ASR))
        await first_started.wait()
        second_task = asyncio.create_task(governor.run(second, WorkClass.BATCH_ASR))
        await asyncio.sleep(0.02)

        snapshot = governor.snapshot()
        assert not second_started.is_set()
        assert snapshot.active_asr == 1
        assert snapshot.pending_batch == 1

        release_first.set()
        await asyncio.wait_for(second_started.wait(), timeout=1)
        await asyncio.gather(first_task, second_task)

    asyncio.run(scenario())


def test_same_key_tts_stays_serial_beside_the_diarization_lane() -> None:
    async def scenario() -> None:
        governor = ResourceGovernor(LIMITS, allow_heavy_overlap=True)
        first_started = asyncio.Event()
        release_first = asyncio.Event()
        second_started = asyncio.Event()

        async def first() -> None:
            first_started.set()
            await release_first.wait()

        async def second() -> None:
            second_started.set()

        first_task = asyncio.create_task(
            governor.run(first, WorkClass.REALTIME_TTS, resource_key="voice_clone")
        )
        await first_started.wait()
        second_task = asyncio.create_task(
            governor.run(second, WorkClass.REALTIME_TTS, resource_key="voice_clone")
        )
        await asyncio.sleep(0.02)

        snapshot = governor.snapshot()
        assert not second_started.is_set()
        assert snapshot.active_tts == 1
        assert snapshot.pending_realtime == 1

        release_first.set()
        await asyncio.wait_for(second_started.wait(), timeout=1)
        await asyncio.gather(first_task, second_task)

    asyncio.run(scenario())
