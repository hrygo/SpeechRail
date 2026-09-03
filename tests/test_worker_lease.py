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


def test_evictor_close_is_blocked_while_worker_lock_is_held() -> None:
    """When close() acquires a lock, evictor's close() call blocks until lock is released."""

    class _LockingWorker:
        def __init__(self) -> None:
            self.lock = asyncio.Lock()
            self.alive = True
            self.closed = False
            self.close_entered_at: float | None = None

        async def start(self) -> None:
            self.alive = True
            self.closed = False

        async def close(self) -> None:
            import time
            async with self.lock:
                self.close_entered_at = time.monotonic()
                self.closed = True
                self.alive = False

    async def run() -> None:
        import time
        worker = _LockingWorker()
        evictor = WorkerIdleEvictor(
            (worker,), idle_timeout_seconds=0.05, check_interval_seconds=0.02
        )
        # Simulate an active stream holding the lock
        await worker.lock.acquire()
        lock_acquired_at = time.monotonic()

        await evictor.start()
        try:
            # Give evictor time to attempt eviction (it should block on close)
            await asyncio.sleep(0.12)
            assert not worker.closed, "close should be blocked by the lock"

            # Release the lock — close should now proceed
            worker.lock.release()
            await asyncio.sleep(0.05)
            assert worker.closed
            assert worker.close_entered_at is not None
            assert worker.close_entered_at >= lock_acquired_at
        finally:
            await evictor.close()

    asyncio.run(run())


def test_evictor_respects_worker_last_active_attribute() -> None:
    """When a worker updates its own last_active attribute, eviction is postponed."""

    class _ActiveWorker:
        def __init__(self) -> None:
            import time

            self.alive = True
            self.closed = False
            self.last_active: float = time.monotonic()

        async def close(self) -> None:
            self.closed = True
            self.alive = False

    async def run() -> None:
        import time

        worker = _ActiveWorker()
        evictor = WorkerIdleEvictor(
            (worker,), idle_timeout_seconds=0.08, check_interval_seconds=0.02
        )
        await evictor.start()
        try:
            await asyncio.sleep(0.04)
            # Worker reports recent internal activity
            worker.last_active = time.monotonic()
            await asyncio.sleep(0.05)
            # Should still be alive because worker.last_active was updated
            assert worker.closed is False
            await asyncio.sleep(0.06)
            # Now it should be evicted
            assert worker.closed is True
        finally:
            await evictor.close()

    asyncio.run(run())


def test_evictor_resets_idle_timer_after_close() -> None:
    """After worker is evicted and restarted, it does not get immediately evicted next tick."""

    class _RestartableWorker:
        def __init__(self) -> None:
            self.alive = True
            self.close_count = 0

        async def close(self) -> None:
            self.close_count += 1
            self.alive = False

    async def run() -> None:
        worker = _RestartableWorker()
        evictor = WorkerIdleEvictor(
            (worker,), idle_timeout_seconds=0.04, check_interval_seconds=0.02
        )
        await evictor.start()
        try:
            # Wait for first eviction
            await asyncio.sleep(0.06)
            assert worker.close_count == 1

            # Simulate worker being restarted by a new request
            worker.alive = True

            # Wait less than idle_timeout_seconds (e.g. 0.02s)
            await asyncio.sleep(0.02)
            # Worker must NOT be immediately re-evicted on the next check tick!
            assert worker.close_count == 1

            # After full idle timeout, it gets evicted again
            await asyncio.sleep(0.04)
            assert worker.close_count == 2
        finally:
            await evictor.close()

    asyncio.run(run())


def test_two_stage_standby_and_eviction() -> None:
    from speechrail.runtime.worker_lease import WorkerLifecycleState

    class _TrimWorker(_FakeWorker):
        def __init__(self) -> None:
            super().__init__()
            self.trimmed = False

        def trim_memory(self) -> None:
            self.trimmed = True

    async def run() -> None:
        worker = _TrimWorker()
        evictor = WorkerIdleEvictor(
            (worker,),
            warm_standby_timeout_seconds=0.03,
            idle_timeout_seconds=0.08,
            check_interval_seconds=0.01,
        )
        await evictor.start()
        try:
            assert evictor.state_of(worker) == WorkerLifecycleState.ACTIVE
            # 1. Wait for warm standby
            await asyncio.sleep(0.04)
            assert evictor.state_of(worker) == WorkerLifecycleState.WARM_STANDBY
            assert worker.trimmed is True
            assert worker.closed is False

            # 2. Wait for cold eviction
            await asyncio.sleep(0.06)
            assert evictor.state_of(worker) == WorkerLifecycleState.COLD_EVICTED
            assert worker.closed is True
        finally:
            await evictor.close()

    asyncio.run(run())


def test_lease_lock_protects_against_eviction() -> None:
    from speechrail.runtime.worker_lease import WorkerLifecycleState

    async def run() -> None:
        worker = _FakeWorker()
        evictor = WorkerIdleEvictor(
            (worker,),
            warm_standby_timeout_seconds=0.02,
            idle_timeout_seconds=0.04,
            check_interval_seconds=0.01,
        )
        lease_lock = evictor.lease_lock_of(worker)
        await evictor.start()
        try:
            async with lease_lock.lease() as gen:
                assert gen == 1
                assert lease_lock.active_leases == 1
                # Wait past eviction timeout while lease held
                await asyncio.sleep(0.06)
                assert worker.closed is False
                assert evictor.state_of(worker) == WorkerLifecycleState.ACTIVE

            # After lease release, eviction proceeds
            await asyncio.sleep(0.06)
            assert worker.closed is True
            assert evictor.state_of(worker) == WorkerLifecycleState.COLD_EVICTED
        finally:
            await evictor.close()

    asyncio.run(run())


def test_min_uptime_guard_protects_freshly_loaded_worker() -> None:
    """A worker that just loaded (lazy start / restart) is not evicted
    before min_uptime_seconds even if the idle timeout already elapsed."""
    from speechrail.runtime.worker_lease import WorkerLifecycleState

    class _LazyWorker:
        def __init__(self) -> None:
            self.alive = False
            self.closed = False

        async def close(self) -> None:
            self.closed = True
            self.alive = False

    async def run() -> None:
        worker = _LazyWorker()
        evictor = WorkerIdleEvictor(
            (worker,),
            warm_standby_timeout_seconds=0.02,
            idle_timeout_seconds=0.03,
            min_uptime_seconds=0.15,
            check_interval_seconds=0.01,
        )
        await evictor.start()
        try:
            # Simulate the first request loading the worker (lazy start).
            worker.alive = True

            # Past the idle timeout (0.03s) but still inside min_uptime (0.15s):
            # the guard must hold eviction off.
            await asyncio.sleep(0.07)
            assert worker.closed is False
            assert evictor.state_of(worker) == WorkerLifecycleState.ACTIVE

            # Once min_uptime elapses and idle persists -> eviction proceeds.
            await asyncio.sleep(0.12)
            assert worker.closed is True
            assert evictor.state_of(worker) == WorkerLifecycleState.COLD_EVICTED
        finally:
            await evictor.close()

    asyncio.run(run())


def test_workers_expose_async_trim_memory() -> None:
    """Verify inference backend workers define callable trim_memory."""
    from unittest.mock import AsyncMock, MagicMock

    from speechrail.backends.qwen3_native import Qwen3BatchTranscriber, Qwen3Worker
    from speechrail.backends.qwen3_streaming import Qwen3StreamingWorker
    from speechrail.backends.qwen3_tts import Qwen3TtsWorker

    mock_transport = MagicMock()
    mock_transport.alive = True
    mock_transport.send = AsyncMock()

    # 1. Qwen3Worker
    native_worker = Qwen3Worker.__new__(Qwen3Worker)
    native_worker._transport = mock_transport
    assert hasattr(native_worker, "trim_memory")

    # 2. Qwen3BatchTranscriber
    mock_inner_worker = MagicMock()
    mock_inner_worker.trim_memory = AsyncMock()
    batch_transcriber = Qwen3BatchTranscriber(worker=mock_inner_worker, model_id="m")
    assert hasattr(batch_transcriber, "trim_memory")

    # 3. Qwen3StreamingWorker
    streaming_worker = Qwen3StreamingWorker.__new__(Qwen3StreamingWorker)
    streaming_worker._transport = mock_transport
    streaming_worker._write_lock = asyncio.Lock()
    assert hasattr(streaming_worker, "trim_memory")

    # 4. Qwen3TtsWorker
    tts_worker = Qwen3TtsWorker.__new__(Qwen3TtsWorker)
    tts_worker._transport = mock_transport
    assert hasattr(tts_worker, "trim_memory")
