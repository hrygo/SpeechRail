from __future__ import annotations

import asyncio
from typing import Any

import pytest

from speechrail.backends.qwen3_shared import GenerationGuard, Qwen3SharedWorker
from test_qwen3_shared import _Config


def test_old_generation_cannot_deliver_a_result() -> None:
    guard = GenerationGuard()
    first = guard.current
    guard.advance()
    assert not guard.accepts(first)
    assert guard.accepts(guard.current)


def test_concurrent_failures_reap_once_before_restart() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        await worker.start()
        generation = worker.generation
        entered, release = asyncio.Event(), asyncio.Event()
        abort = worker._transport.abort
        calls = 0

        async def delayed_abort() -> None:
            nonlocal calls
            calls += 1
            entered.set()
            await release.wait()
            await abort()

        worker._transport.abort = delayed_abort
        try:
            first = asyncio.create_task(worker._fail_generation(generation, code="failed"))
            await entered.wait()
            second = asyncio.create_task(worker._fail_generation(generation, code="failed"))
            restart = asyncio.create_task(worker.start())
            await asyncio.sleep(0)
            await asyncio.sleep(0)
            assert worker.generation == generation
            assert not restart.done()
            release.set()
            await asyncio.gather(first, second, restart)
            assert calls == 1
            assert worker.ready
            assert worker.generation == generation + 1
        finally:
            release.set()
            worker._transport.abort = abort
            await worker.close()

    asyncio.run(scenario())


def test_one_hundred_sent_cancellations_leave_no_process_or_pending_request() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=1))
        sent = asyncio.Event()
        send = worker.send
        errors: list[dict[str, Any]] = []
        loop = asyncio.get_running_loop()
        previous_handler = loop.get_exception_handler()
        loop.set_exception_handler(lambda _loop, context: errors.append(context))

        async def observed_send(*args: Any, **kwargs: Any) -> None:
            await send(*args, **kwargs)
            sent.set()

        worker.send = observed_send
        try:
            for index in range(100):
                sent.clear()
                request = asyncio.create_task(worker.request({
                    "action": "shared_hang", "request_id": f"cancel-{index}",
                }))
                await asyncio.wait_for(sent.wait(), 2)
                process = worker._transport._process
                assert process is not None
                request.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await request
                assert process.returncode is not None
                assert not worker.alive
                assert worker.pending_request_count == 0
            result = await worker.request({
                "action": "shared_batch", "request_id": "recovered", "text": "ok",
            })
            assert result["text"] == "ok"
            assert errors == []
        finally:
            await worker.close()
            loop.set_exception_handler(previous_handler)

    asyncio.run(scenario())
