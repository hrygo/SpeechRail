import asyncio
from types import SimpleNamespace

import pytest

from speechrail.application.alignment import FixedTextAligner
from speechrail.domain.alignment import AlignmentRequest
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.runtime import worker_lease
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
