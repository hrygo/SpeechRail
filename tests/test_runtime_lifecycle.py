"""Failure and cancellation contracts for the physical runtime owners."""

import asyncio
import traceback

import pytest

from speechrail.application.lifecycle import RuntimeLifecycle


class Worker:
    def __init__(self) -> None:
        self.alive = False
        self.starts = 0
        self.closes = 0

    async def start(self) -> None:
        self.starts += 1
        self.alive = True

    async def close(self) -> None:
        self.closes += 1
        self.alive = False


def test_alignment_is_owned_without_eager_loading() -> None:
    async def run() -> None:
        aligner = Worker()
        life = RuntimeLifecycle(alignment=aligner)
        await life.start()
        assert aligner.starts == 0
        await life.close()
        assert aligner.closes == 1

    asyncio.run(run())


def test_failed_runner_does_not_skip_workers_and_reports_failure() -> None:
    async def run() -> None:
        entered = asyncio.Event()

        class Runner:
            async def run_once(self) -> bool:
                entered.set()
                raise RuntimeError("repository unavailable")

        worker = Worker()
        life = RuntimeLifecycle(asr=worker, runner=Runner())
        await life.start()
        await entered.wait()
        with pytest.raises(ExceptionGroup):
            await life.close()
        assert worker.closes == 1
        assert not worker.alive

    asyncio.run(run())


def test_monitor_and_worker_failure_do_not_skip_other_owners() -> None:
    async def run() -> None:
        class Monitor:
            async def start(self) -> None:
                pass

            async def close(self) -> None:
                raise RuntimeError("monitor failed")

        class FailingWorker(Worker):
            async def close(self) -> None:
                self.closes += 1
                raise RuntimeError("worker failed")

        worker, failing = Worker(), FailingWorker()
        life = RuntimeLifecycle(asr=worker, tts=failing, evictor=Monitor())
        await life.start()
        with pytest.raises(ExceptionGroup) as result:
            await life.close()
        assert len(result.value.exceptions) == 2
        assert worker.closes == failing.closes == 1
        assert not worker.alive

    asyncio.run(run())


def test_repeated_waiter_cancellation_joins_owned_cleanup() -> None:
    async def run() -> None:
        entered, release = asyncio.Event(), asyncio.Event()

        class GatedWorker(Worker):
            async def close(self) -> None:
                entered.set()
                await release.wait()
                await super().close()

        worker = GatedWorker()
        life = RuntimeLifecycle(asr=worker)
        await life.start()
        closing = asyncio.create_task(life.close())
        await entered.wait()
        closing.cancel()
        await asyncio.sleep(0)
        closing.cancel()
        await asyncio.sleep(0)
        assert not closing.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await closing
        assert worker.closes == 1
        await life.close()
        assert worker.closes == 1

    asyncio.run(run())


def test_partial_start_failure_closes_failing_owner_too() -> None:
    async def run() -> None:
        class PartialWorker(Worker):
            async def start(self) -> None:
                await super().start()
                raise RuntimeError("handshake failed")

        first, partial = Worker(), PartialWorker()
        life = RuntimeLifecycle(asr=first, tts=partial)
        with pytest.raises(RuntimeError, match="handshake"):
            await life.start()
        assert first.closes == partial.closes == 1
        assert not first.alive and not partial.alive

    asyncio.run(run())


def test_timed_out_cleanup_keeps_handle_and_closes_remaining_owners() -> None:
    async def run() -> None:
        release = asyncio.Event()

        class GatedWorker(Worker):
            async def close(self) -> None:
                await release.wait()
                await super().close()

        first, gated = Worker(), GatedWorker()
        life = RuntimeLifecycle(
            asr=first, tts=gated, cleanup_timeout_seconds=0.01
        )
        await life.start()
        with pytest.raises(ExceptionGroup, match="incomplete"):
            await life.close()
        assert first.closes == 1
        assert gated.alive
        task = life._cleanup_tasks["tts"]
        assert not task.done()
        release.set()
        await task
        assert gated.closes == 1

    asyncio.run(run())


def test_cleanup_report_does_not_expose_backend_exception_detail() -> None:
    async def run() -> None:
        class FailingWorker(Worker):
            async def close(self) -> None:
                raise RuntimeError("backend_private_detail")

        life = RuntimeLifecycle(asr=FailingWorker())
        await life.start()
        with pytest.raises(ExceptionGroup) as result:
            await life.close()
        report = "".join(traceback.format_exception(result.value))
        assert "backend_private_detail" not in report
        assert "asr cleanup failed (RuntimeError)" in report

    asyncio.run(run())
