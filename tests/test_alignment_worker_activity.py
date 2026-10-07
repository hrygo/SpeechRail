import asyncio
from types import SimpleNamespace

import pytest

from speechrail.application.alignment import FixedTextAligner
from speechrail.domain.alignment import AlignmentRequest
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.runtime import worker_lease
from speechrail.runtime.resource_governor import GovernorLaneIsolatedError
from speechrail.runtime.worker_lease import WorkerIdleEvictor, WorkerLeaseLock


def request() -> AlignmentRequest:
    return AlignmentRequest(
        task_id="task",
        epoch="epoch",
        utterance_id="utterance",
        transcript_revision=1,
        pcm16=b"\x00\x00" * 16000,
        span=SampleSpan(0, 16000),
        text="test",
        language="en",
    )


def test_production_aligner_is_protected_during_warm_exchange(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    now = [100.0]
    monkeypatch.setattr(worker_lease, "time", SimpleNamespace(monotonic=lambda: now[0]))

    async def run() -> None:
        entered, release = asyncio.Event(), asyncio.Event()

        class Worker:
            alive = True
            closes = 0

            async def close(self) -> None:
                self.closes += 1
                self.alive = False

            async def align_text(self, pcm: bytes, *, text: str, language: str | None):
                entered.set()
                await release.wait()
                assert self.alive
                return (("test", 0.0, 0.1),)

        worker, lease = Worker(), WorkerLeaseLock()
        evictor = WorkerIdleEvictor(
            [worker],
            idle_timeout_seconds=10,
            check_interval_seconds=0,
            lease_locks={worker: lease},
        )
        aligner = FixedTextAligner(worker, worker_lease=lease.lease)
        now[0] = 109
        aligning = asyncio.create_task(aligner.align(request()))
        await entered.wait()
        now[0] = 111
        await evictor.start()
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        await evictor.force_evict()
        assert worker.closes == 0
        release.set()
        assert (await aligning).status == "done"
        await evictor.close()
        assert lease.active_leases == 0
        assert lease.last_active == 111

    asyncio.run(run())


@pytest.mark.parametrize("eviction", ["force", "ttl"])
@pytest.mark.parametrize("failure", ["raises", "still_alive"])
def test_failed_eviction_isolates_production_aligner_until_confirmed_reap(
    monkeypatch: pytest.MonkeyPatch, eviction: str, failure: str,
) -> None:
    now = [100.0]
    monkeypatch.setattr(worker_lease, "time", SimpleNamespace(monotonic=lambda: now[0]))

    async def run() -> None:
        attempted = asyncio.Event()
        notifications: list[str] = []

        class Worker:
            alive = True
            failing = True
            closes = exchanges = 0

            async def close(self) -> None:
                self.closes += 1
                attempted.set()
                if self.failing:
                    if failure == "raises":
                        raise OSError("fake reap failure")
                    return
                self.alive = False

            async def align_text(self, pcm: bytes, *, text: str, language: str | None):
                self.exchanges += 1
                self.alive = True
                return (("test", 0.0, 0.1),)

        worker, lease = Worker(), WorkerLeaseLock()
        evictor = WorkerIdleEvictor(
            [worker], idle_timeout_seconds=10, check_interval_seconds=0,
            lease_locks={worker: lease},
            on_eviction=lambda _worker, state: notifications.append(state),
        )
        aligner = FixedTextAligner(worker, worker_lease=lease.lease)
        now[0] = 111
        if eviction == "force":
            await evictor.force_evict()
        else:
            await evictor.start()
            await attempted.wait()
            await asyncio.sleep(0)
            await asyncio.sleep(0)
        assert evictor.state_of(worker).value == "reclamation_failed"
        assert worker.alive
        assert notifications == ["reclamation_failed"]
        generation = lease.generation
        assert (await aligner.align(request())).failure == "alignment_unavailable"
        with pytest.raises(GovernorLaneIsolatedError):
            async with lease.lease():
                pytest.fail("isolated worker accepted a lease")
        assert worker.exchanges == lease.active_leases == 0
        assert lease.generation == generation
        evictor.touch(worker)
        now[0] = 200
        for _ in range(3):
            await asyncio.sleep(0)
        assert evictor.state_of(worker).value == "reclamation_failed"
        assert worker.closes == 1
        await evictor.close()

        # Even a lost ready/alive indicator cannot substitute for confirmed close.
        worker.alive = False
        worker.failing = False
        await evictor.force_evict()
        assert worker.closes == 2
        assert evictor.state_of(worker).value == "cold_evicted"
        assert (await aligner.align(request())).status == "done"
        assert worker.exchanges == 1
        assert lease.generation == generation + 1

    asyncio.run(run())


def test_cancelled_successful_eviction_records_confirmed_cold_state() -> None:
    async def run() -> None:
        entered, release = asyncio.Event(), asyncio.Event()

        class Worker:
            alive = True

            async def close(self) -> None:
                entered.set()
                await release.wait()
                self.alive = False

        worker = Worker()
        evictor = WorkerIdleEvictor([worker])
        closing = asyncio.create_task(evictor.force_evict())
        await entered.wait()
        closing.cancel()
        await asyncio.sleep(0)
        closing.cancel()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await closing
        assert evictor.state_of(worker).value == "cold_evicted"
        async with evictor.lease_lock_of(worker).lease():
            pass

    asyncio.run(run())


@pytest.mark.parametrize("cancel_closing", [False, True])
def test_request_waits_for_decided_eviction_before_restarting_worker(
    cancel_closing: bool,
) -> None:
    async def run() -> None:
        entered, release, accepted = asyncio.Event(), asyncio.Event(), asyncio.Event()

        class Worker:
            alive = True

            async def close(self) -> None:
                entered.set()
                await release.wait()
                self.alive = False

            async def align_text(self, pcm: bytes, *, text: str, language: str | None):
                self.alive = True
                accepted.set()
                return (("test", 0.0, 0.1),)

        worker, lease = Worker(), WorkerLeaseLock()
        evictor = WorkerIdleEvictor([worker], lease_locks={worker: lease})
        closing = asyncio.create_task(evictor.force_evict())
        await entered.wait()
        aligning = asyncio.create_task(
            FixedTextAligner(worker, worker_lease=lease.lease).align(request())
        )
        await asyncio.sleep(0)
        assert not accepted.is_set()
        if cancel_closing:
            closing.cancel()
            await asyncio.sleep(0)
            await asyncio.sleep(0)
            assert not closing.done()
            assert not accepted.is_set()
        release.set()
        if cancel_closing:
            with pytest.raises(asyncio.CancelledError):
                await closing
        else:
            await closing
        assert (await aligning).status == "done"
        assert worker.alive and accepted.is_set()

    asyncio.run(run())
