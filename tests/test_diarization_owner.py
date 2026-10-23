"""Model ownership lasts from before factory/load until the exact child is reaped."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from speechrail.backends.diarization.coreml import MODEL_BUNDLE_NAME, CoreMLSortformerEngine
from speechrail.runtime.diarization_owner import DiarizationSessionOwner
from speechrail.runtime.resource_governor import GovernorLaneIsolatedError, GovernorQueueFullError


def test_owner_is_not_a_chunk_compute_lease():
    owner = DiarizationSessionOwner()
    first = owner.claim("first")
    with pytest.raises(GovernorQueueFullError):
        owner.claim("second")
    owner.release(first, reaped=True)
    second = owner.claim("second")
    assert second > first
    owner.release(first, reaped=True)
    assert owner.occupied
    owner.release(second, reaped=True)
    assert not owner.occupied


def test_failed_reap_retains_owner_and_isolates_new_sessions():
    owner = DiarizationSessionOwner()
    generation = owner.claim("first")
    child = object()
    owner.attach(generation, child)
    owner.release(generation, reaped=False)
    assert owner.occupied and owner.isolated
    with pytest.raises(GovernorLaneIsolatedError):
        owner.claim("other")
    # A stale failed close cannot quarantine or release a newer generation.
    owner.release(generation - 1, reaped=False)
    assert owner.occupied


def test_factory_runs_only_after_claim_and_factory_failure_releases(tmp_path: Path):
    calls = []

    class Worker:
        async def close(self):
            pass

    def factory():
        calls.append(1)
        return Worker()

    model = tmp_path / MODEL_BUNDLE_NAME
    model.mkdir()
    executable = tmp_path / "worker"
    executable.touch()
    engine = CoreMLSortformerEngine(
        model_path=model,
        executable=executable,
        required_hashes={},
        required_signatures={},
        worker_factory=factory,
    )

    async def run():
        session = engine.open(epoch="first")
        with pytest.raises(GovernorQueueFullError):
            engine.open(epoch="second")
        assert len(calls) == 1
        await session.cancel()
        next_session = engine.open(epoch="second")
        assert len(calls) == 2
        await next_session.cancel()

    asyncio.run(run())


def test_late_generation_cannot_attach_over_current_owner():
    owner = DiarizationSessionOwner()
    old = owner.claim("old")
    owner.release(old, reaped=True)
    current = owner.claim("current")
    with pytest.raises(ValueError):
        owner.attach(old, object())
    owner.release(old, reaped=True)
    assert owner.occupied
    owner.release(current, reaped=True)


@pytest.mark.parametrize("backend", ["coreml", "meeting"])
def test_cancel_during_launch_waits_for_exact_child_and_prevents_restart(backend):
    from speechrail.backends.diarization.coreml import CoreMLActivitySession
    from speechrail.backends.diarization.meeting import MeetingActivitySession
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass

    async def run():
        entered, launched = asyncio.Event(), asyncio.Event()
        governor = ResourceGovernor(GovernorLimits(3, 1, 8))

        class Worker:
            closed = False

            async def start(self):
                assert governor.snapshot().active_diarization == 1
                entered.set()
                from speechrail.runtime.cleanup import join_cleanup

                await join_cleanup(asyncio.create_task(launched.wait()))

            async def request(self, header, audio=b""):
                pytest.fail("cancelled launch must not start inference")

            async def close(self):
                assert launched.is_set()
                self.closed = True

        worker = Worker()
        factory = CoreMLActivitySession if backend == "coreml" else MeetingActivitySession
        session = factory(worker=worker, epoch="epoch", governor=governor)
        append = asyncio.create_task(session.append(start_sample=0, pcm16=bytes(320000)))
        await entered.wait()
        cancel = asyncio.create_task(session.cancel())
        await asyncio.sleep(0)
        assert governor.diarization_owner.occupied
        assert not cancel.done()
        assert not governor.lane_available(WorkClass.DIARIZATION)
        launched.set()
        await asyncio.wait_for(cancel, 1)
        await asyncio.gather(append, return_exceptions=True)
        assert worker.closed and not governor.diarization_owner.occupied
        assert governor.snapshot().active_diarization == 0
        await session.cancel()

    asyncio.run(run())


def test_cancel_interrupts_stuck_preflight_before_reaping():
    from speechrail.backends.diarization.coreml import CoreMLActivitySession
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor

    async def run():
        entered = asyncio.Event()
        governor = ResourceGovernor(GovernorLimits(2, 1, 8))

        class Worker:
            closed = False

            async def start(self):
                entered.set()  # Exact process is already assigned; only preflight is pending.
                await asyncio.Event().wait()

            async def close(self):
                self.closed = True

        worker = Worker()
        session = CoreMLActivitySession(worker=worker, epoch="epoch", governor=governor)
        append = asyncio.create_task(session.append(start_sample=0, pcm16=bytes(2)))
        await entered.wait()
        cancel = asyncio.create_task(session.cancel())
        try:
            # asyncio.wait does not add a second cancellation to owned cleanup.
            done, _ = await asyncio.wait({cancel}, timeout=0.1)
            assert cancel in done, "close must interrupt a blocked preflight"
            await cancel
            assert worker.closed and not governor.diarization_owner.occupied
        finally:
            if session._lease._start_task is not None:
                session._lease._start_task.cancel()
            await asyncio.gather(append, cancel, return_exceptions=True)

    asyncio.run(run())


def test_coreml_failed_reap_keeps_owner_without_poisoning_bounded_asr():
    from speechrail.backends.diarization.coreml import CoreMLActivitySession
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass

    async def run():
        governor = ResourceGovernor(
            GovernorLimits(3, 1, 8), allow_heavy_overlap=True, quarantine_resources_bounded=True
        )

        class Worker:
            async def close(self):
                raise RuntimeError("unconfirmed exact child")

        session = CoreMLActivitySession(worker=Worker(), epoch="epoch", governor=governor)
        with pytest.raises(RuntimeError, match="unconfirmed"):
            await session.cancel()
        assert governor.diarization_owner.occupied and governor.diarization_owner.isolated
        assert governor.snapshot().retained_diarization == 1
        with pytest.raises(GovernorLaneIsolatedError):
            governor.diarization_owner.claim("other")
        async with governor.reserve(WorkClass.REALTIME_ASR):
            assert governor.snapshot().active_asr == 1

    asyncio.run(run())


def test_streaming_and_meeting_engines_share_owner_before_both_factories(tmp_path, monkeypatch):
    from speechrail.backends.diarization import meeting
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor

    monkeypatch.setattr(
        meeting,
        "read_matching_policy",
        lambda _: {
            "certified_max_speakers": 4,
            "validation_digest": "a" * 64,
        },
    )
    monkeypatch.setattr(meeting, "inspect_meeting_dynamic_assets", lambda _: True)
    model = tmp_path / MODEL_BUNDLE_NAME
    model.mkdir()
    executable = tmp_path / "worker"
    executable.touch()
    executable.chmod(0o700)
    governor = ResourceGovernor(GovernorLimits(3, 1, 8))
    factories = []

    class Worker:
        async def close(self):
            pass

    def factory():
        factories.append(1)
        return Worker()

    streaming = CoreMLSortformerEngine(
        model_path=model,
        executable=executable,
        worker_factory=factory,
        required_hashes={},
        required_signatures={},
        governor=governor,
    )
    dynamic = meeting.MeetingDiarizationEngine(
        model_dir=model,
        policy_path=tmp_path / "policy",
        executable=executable,
        governor=governor,
        worker_factory=factory,
    )

    async def run():
        first = streaming.open(epoch="first")
        with pytest.raises(GovernorQueueFullError):
            dynamic.open(epoch="second")
        assert len(factories) == 1
        await first.cancel()
        second = dynamic.open(epoch="second")
        with pytest.raises(GovernorQueueFullError):
            streaming.open(epoch="third")
        assert len(factories) == 2
        await second.cancel()

    asyncio.run(run())


def test_slow_consumer_fails_boundedly_and_finish_is_idempotent():
    from speechrail.backends.diarization.coreml import CoreMLActivitySession
    from speechrail.domain.diarization.types import DiarizationError
    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor

    async def run():
        governor = ResourceGovernor(GovernorLimits(2, 1, 8), allow_heavy_overlap=False)
        class Worker:
            closes = 0
            finishes = 0
            async def start(self):
                assert governor.snapshot().active_diarization == 1
            async def request(self, header, audio=b""):
                assert governor.snapshot().active_diarization == 1
                operation = header["operation"]
                if operation == "finish":
                    self.finishes += 1
                end = (header["audio_start"] + header["audio_samples"]
                       if operation == "append" else header["through_sample"])
                return {"ok": True, "epoch": "epoch", "operation": operation,
                        "processed_through": end, "stable_through": end, "frames": []}, b""
            async def close(self):
                self.closes += 1
        worker = Worker()
        session = CoreMLActivitySession(worker=worker, epoch="epoch", governor=governor)
        for i in range(64):
            await session.append(start_sample=i, pcm16=bytes(2))
        with pytest.raises(DiarizationError, match="too slow"):
            await session.append(start_sample=64, pcm16=bytes(2))
        assert worker.closes == 1 and not governor.diarization_owner.occupied
        assert session._updates.qsize() == 64
        with pytest.raises(DiarizationError):
            _ = [update async for update in session.updates()]
        worker = Worker()
        session = CoreMLActivitySession(worker=worker, epoch="epoch", governor=governor)
        await session.finish(through_sample=0)
        await session.finish(through_sample=0)
        await session.cancel()
        assert worker.finishes == worker.closes == 1
    asyncio.run(run())
