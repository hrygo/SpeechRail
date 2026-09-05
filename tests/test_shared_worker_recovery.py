from __future__ import annotations

import asyncio
from dataclasses import replace
from typing import Any

import pytest

from speechrail.backends.qwen3_native import Qwen3Worker
from speechrail.backends.qwen3_shared import (
    GenerationGuard,
    Qwen3SharedWorker,
    WorkerTransportError,
)
from speechrail.runtime.worker_protocol import ProtocolError
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


def test_request_cancellation_before_transport_send_keeps_generation_ready() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=1.0))
        await worker.start()
        generation = worker.generation
        entered = asyncio.Event()
        release = asyncio.Event()
        original_send = worker._transport.send

        async def blocked_send(*args: Any, **kwargs: Any) -> None:
            entered.set()
            await release.wait()
            await original_send(*args, **kwargs)

        worker._transport.send = blocked_send
        try:
            request = asyncio.create_task(
                worker.request({"action": "shared_batch", "request_id": "pre-send-cancel"})
            )
            await asyncio.wait_for(entered.wait(), 1)
            request.cancel()
            with pytest.raises(asyncio.CancelledError):
                await request
            release.set()
            await asyncio.sleep(0)
            assert worker.ready is True
            assert worker.alive is True
            assert worker.generation == generation
            assert worker.pending_request_count == 0

            worker._transport.send = original_send
            result = await worker.request(
                {"action": "shared_batch", "request_id": "after-pre-send-cancel", "text": "ok"}
            )
            assert result["text"] == "ok"
            assert worker.generation == generation
        finally:
            release.set()
            worker._transport.send = original_send
            await worker.close()

    asyncio.run(scenario())


def test_request_cancellation_after_transport_send_aborts_generation_and_recovers() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=1.0))
        sent = asyncio.Event()
        original_send = worker._transport.send

        async def observed_send(payload: Any, **kwargs: Any) -> None:
            await original_send(payload, **kwargs)
            if payload.get("request_id") == "post-send-cancel":
                sent.set()

        worker._transport.send = observed_send
        try:
            request = asyncio.create_task(
                worker.request({"action": "shared_hang", "request_id": "post-send-cancel"})
            )
            await asyncio.wait_for(sent.wait(), 1)
            generation = worker.generation
            request.cancel()
            with pytest.raises(asyncio.CancelledError):
                await request
            assert worker.alive is False
            assert worker.ready is False
            assert worker.pending_request_count == 0

            worker._transport.send = original_send
            result = await worker.request(
                {"action": "shared_batch", "request_id": "after-post-send-cancel", "text": "ok"}
            )
            assert result["text"] == "ok"
            assert worker.generation == generation + 1
        finally:
            worker._transport.send = original_send
            await worker.close()

    asyncio.run(scenario())


def test_one_hundred_pre_send_cancellations_keep_one_ready_process_and_no_leaks() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=1.0))
        errors: list[dict[str, Any]] = []
        loop = asyncio.get_running_loop()
        previous_handler = loop.get_exception_handler()
        loop.set_exception_handler(lambda _loop, context: errors.append(context))
        entered = asyncio.Event()
        release = asyncio.Event()
        original_send = worker._transport.send

        async def blocked_send(*args: Any, **kwargs: Any) -> None:
            entered.set()
            await release.wait()
            await original_send(*args, **kwargs)

        try:
            await worker.start()
            generation = worker.generation
            process = worker._transport._process
            assert process is not None
            worker._transport.send = blocked_send
            for index in range(100):
                entered.clear()
                release.clear()
                request = asyncio.create_task(
                    worker.request(
                        {"action": "shared_batch", "request_id": f"pre-send-{index}"}
                    )
                )
                await asyncio.wait_for(entered.wait(), 1)
                request.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await request
                release.set()
                await asyncio.sleep(0)
                assert worker.ready is True
                assert worker.generation == generation
                assert worker._transport._process is process
                assert process.returncode is None
                assert worker.pending_request_count == 0
                assert not worker._requests

            assert errors == []
        finally:
            release.set()
            worker._transport.send = original_send
            await worker.close()
            loop.set_exception_handler(previous_handler)

    asyncio.run(scenario())


@pytest.mark.parametrize(
    "action",
    ["shared_eof", "malformed", "partial_header", "partial_body"],
)
def test_receive_side_loss_preserves_transport_cause_and_restarts_generation(
    action: str,
) -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=0.05))
        try:
            if action.startswith("partial"):
                # Keep the request wait longer than the transport's partial-frame
                # deadline so the dispatcher owns the failure classification.
                worker.config = replace(worker.config, timeout_seconds=0.5)
            with pytest.raises(WorkerTransportError) as exc_info:
                await worker.request({"action": action, "request_id": f"loss-{action}"})
            assert isinstance(exc_info.value.__cause__, ProtocolError)
            old_generation = worker.generation
            assert worker.alive is False

            await worker.start()
            assert worker.generation == old_generation + 1
        finally:
            await worker.close()

    asyncio.run(scenario())


@pytest.mark.parametrize("failure_action", ["shared_eof", "partial_header", "partial_body"])
def test_receive_side_loss_gets_one_real_batch_retry(
    failure_action: str,
) -> None:
    async def scenario() -> None:
        worker_config = _Config(timeout_seconds=0.05)
        worker = Qwen3SharedWorker(worker_config)
        if failure_action.startswith("partial"):
            # Let the dispatcher classify the partial frame before the request
            # deadline fires. The transport deadline remains 50 ms.
            worker.config = replace(worker.config, timeout_seconds=0.5)
        transcribe_calls = 0
        original_send = worker._transport.send
        original_receive = worker._transport.receive

        async def send(payload: Any, **kwargs: Any) -> None:
            nonlocal transcribe_calls
            if payload.get("type") == "transcribe":
                transcribe_calls += 1
                payload = dict(payload)
                payload["action"] = (
                    failure_action if transcribe_calls == 1 else "shared_batch"
                )
                if transcribe_calls > 1:
                    payload["text"] = "retried"
            await original_send(payload, **kwargs)

        async def receive(*, wait_for_frame: bool = False) -> dict[str, object]:
            frame = await original_receive(wait_for_frame=wait_for_frame)
            if frame.get("type") == "result":
                frame["language"] = "zh"
            return frame

        worker._transport.send = send
        worker._transport.receive = receive
        facade = Qwen3Worker(object(), shared_owner=worker)  # type: ignore[arg-type]
        try:
            result = await facade.transcribe(
                b"\0\0",
                "zh",
                "",
                request_id=f"real-retry-{failure_action}",
            )
            assert result.text == "retried"
            assert transcribe_calls == 2
            assert worker.generation == 2
            assert worker.ready is True
        finally:
            worker._transport.send = original_send
            worker._transport.receive = original_receive
            await worker.close()

    asyncio.run(scenario())
