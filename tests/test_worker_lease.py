"""Tests for worker lease management and idle eviction."""

from __future__ import annotations

import asyncio

from speechrail.application.lifecycle import RuntimeLifecycle
from speechrail.runtime.worker_lease import WorkerIdleEvictor


class _FakeWorker:
    def __init__(self) -> None:
        self.started = False
        self.closed = False
        self.alive = True

    async def start(self) -> None:
        self.started = True
        self.closed = False
        self.alive = True

    async def close(self) -> None:
        self.closed = True
        self.alive = False


def test_worker_idle_evictor_closes_idle_worker() -> None:
    async def run() -> None:
        worker = _FakeWorker()
        worker.started = True
        evictor = WorkerIdleEvictor(
            (worker,), idle_timeout_seconds=0.05, check_interval_seconds=0.02
        )
        await evictor.start()
        try:
            await asyncio.sleep(0.08)
            assert worker.closed is True
            assert worker.alive is False
        finally:
            await evictor.close()

    asyncio.run(run())


def test_worker_idle_evictor_touch_postpones_eviction() -> None:
    async def run() -> None:
        worker = _FakeWorker()
        worker.started = True
        evictor = WorkerIdleEvictor(
            (worker,), idle_timeout_seconds=0.08, check_interval_seconds=0.02
        )
        await evictor.start()
        try:
            await asyncio.sleep(0.04)
            evictor.touch(worker)
            await asyncio.sleep(0.05)
            # Should still be alive because of touch
            assert worker.closed is False
            await asyncio.sleep(0.06)
            # Now it should be closed
            assert worker.closed is True
        finally:
            await evictor.close()

    asyncio.run(run())


def test_runtime_lifecycle_with_lazy_load_does_not_start_immediately() -> None:
    async def run() -> None:
        worker = _FakeWorker()
        lifecycle = RuntimeLifecycle(asr=worker, lazy_load=True)
        await lifecycle.start()
        try:
            assert worker.started is False
        finally:
            await lifecycle.close()

    asyncio.run(run())


def test_runtime_lifecycle_eager_load_starts_immediately() -> None:
    async def run() -> None:
        worker = _FakeWorker()
        lifecycle = RuntimeLifecycle(asr=worker, lazy_load=False)
        await lifecycle.start()
        try:
            assert worker.started is True
        finally:
            await lifecycle.close()

    asyncio.run(run())
