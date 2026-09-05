from __future__ import annotations

import asyncio
import sys
from collections.abc import Coroutine
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from speechrail.backends.qwen3_shared import FrameRouter, Qwen3SharedWorker
from speechrail.runtime.asr_mode import AsrModeGate
from speechrail.runtime.worker_process import WorkerProcessSpec, offline_environment
from speechrail.runtime.worker_protocol import ProtocolError

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
FAKE_WORKER = Path(__file__).resolve().parent / "fixtures" / "fake_framed_worker.py"


@dataclass(frozen=True, slots=True)
class _Config:
    timeout_seconds: float = 0.3
    model_dir: Path = Path("/tmp/speechrail-shared-model")
    device: str = "cpu"
    dtype: str = "float32"

    def worker_spec(self) -> WorkerProcessSpec:
        return WorkerProcessSpec(
            command=(sys.executable, str(FAKE_WORKER)),
            cwd=REPOSITORY_ROOT,
            env=offline_environment(REPOSITORY_ROOT),
            io_timeout_seconds=self.timeout_seconds,
            shutdown_timeout_seconds=0.5,
        )


def _run(coro: Coroutine[Any, Any, Any]) -> Any:
    return asyncio.run(coro)


def test_batch_and_session_ids_have_separate_namespaces() -> None:
    assert FrameRouter.route_key({"request_id": "same", "type": "result"}) == (
        "batch",
        "same",
    )
    assert FrameRouter.route_key({"session_id": "same", "type": "event"}) == (
        "stream",
        "same",
    )
    assert FrameRouter.route_key({"type": "error"}) is None


def test_start_performs_ready_handshake_and_starts_one_dispatcher() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=0.05))
        mode_gate = worker.mode_gate
        try:
            assert isinstance(mode_gate, AsrModeGate)
            assert worker.ready is False
            assert worker.identity is None
            await worker.start()
            dispatcher = worker._dispatcher
            assert worker.alive is True
            assert worker.ready is True
            assert worker.identity == ("cpu", "float32")
            assert worker.mode_gate is mode_gate
            assert mode_gate.active_count == 0
            with pytest.raises(AttributeError):
                worker.ready = True  # type: ignore[misc]
            with pytest.raises(AttributeError):
                worker.identity = ("mps", "float16")  # type: ignore[misc]
            assert worker.timeout_seconds == 0.05
            assert dispatcher is not None
            assert dispatcher.done() is False
            await worker.trim_memory()
            assert worker.alive is True
        finally:
            await worker.close()
        assert worker.ready is False
        assert worker.identity is None
        assert worker.mode_gate is mode_gate
        assert mode_gate.active_count == 0

    _run(scenario())


def test_register_session_has_bounded_queue_and_hard_cap() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(), max_sessions=2)
        try:
            first = worker.register_session("one")
            second = worker.register_session("two")
            assert first.maxsize == 64
            assert second.maxsize == 64
            with pytest.raises(RuntimeError, match="session_limit"):
                worker.register_session("three")
        finally:
            await worker.close()

    _run(scenario())


def test_request_uses_dispatcher_and_preserves_batch_namespace() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        try:
            result = await worker.request(
                {"action": "shared_batch", "request_id": "same", "text": "hello"}
            )
            assert result == {"type": "result", "request_id": "same", "text": "hello"}
            assert worker.mode_gate.active_count == 0
            assert worker.metrics["unknown_frames"] == 0
        finally:
            await worker.close()

    _run(scenario())


def test_interleaved_sessions_are_routed_to_their_own_queues() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        first = worker.register_session("first")
        second = worker.register_session("second")
        try:
            await worker.start()
            await worker.send({"action": "shared_stream", "phase": "open", "session_id": "first"})
            await worker.send({"action": "shared_stream", "phase": "open", "session_id": "second"})
            await worker.send(
                {
                    "action": "shared_stream",
                    "phase": "event",
                    "session_id": "second",
                    "text": "B",
                }
            )
            await worker.send(
                {
                    "action": "shared_stream",
                    "phase": "event",
                    "session_id": "first",
                    "text": "A",
                }
            )
            assert (await asyncio.wait_for(first.get(), 1))["session_id"] == "first"
            assert (await asyncio.wait_for(first.get(), 1))["text"] == "A"
            assert (await asyncio.wait_for(second.get(), 1))["session_id"] == "second"
            assert (await asyncio.wait_for(second.get(), 1))["text"] == "B"
        finally:
            await worker.close()

    _run(scenario())


def test_full_session_queue_isolated_without_blocking_another_session() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        slow = worker.register_session("slow")
        other = worker.register_session("other")
        try:
            await worker.start()
            await worker.send(
                {
                    "action": "shared_burst",
                    "session_id": "slow",
                    "count": 65,
                    "cancel_probe_session_id": "other",
                }
            )
            for _ in range(100):
                if worker.metrics["queue_full_sessions"] == 1:
                    break
                await asyncio.sleep(0.01)
            assert worker.metrics["queue_full_sessions"] == 1
            terminal = await asyncio.wait_for(slow.get(), 1)
            assert terminal["type"] == "error"
            assert terminal["code"] == "session_queue_full"
            cancelled = await asyncio.wait_for(other.get(), 1)
            assert cancelled["text"] == "cancelled:slow"
            await worker.send(
                {
                    "action": "shared_stream",
                    "phase": "event",
                    "session_id": "other",
                    "text": "still-moving",
                }
            )
            assert (await asyncio.wait_for(other.get(), 1))["text"] == "still-moving"
        finally:
            await worker.close()

    _run(scenario())


def test_full_queue_does_not_report_finished_when_completed_is_queued() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        queue = worker.register_session("slow")
        try:
            await worker.start()
            await worker.send(
                {"action": "shared_completed_then_finish", "session_id": "slow"}
            )
            for _ in range(100):
                if worker.metrics["queue_full_sessions"] == 1:
                    break
                await asyncio.sleep(0.01)
            terminal = await asyncio.wait_for(queue.get(), 1)
            assert terminal["type"] == "error"
            assert terminal["code"] == "session_queue_full"
            assert queue.qsize() == 0
        finally:
            await worker.close()

    _run(scenario())


def test_full_queue_cancel_failure_fails_the_generation() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        slow = worker.register_session("slow")
        healthy = worker.register_session("healthy")
        original_send = worker._transport.send

        async def fail_cancel(payload: Any, **kwargs: Any) -> None:
            if payload.get("type") == "cancel":
                raise OSError("cancel pipe failed")
            await original_send(payload, **kwargs)

        try:
            await worker.start()
            worker._transport.send = fail_cancel
            await worker.send({"action": "shared_burst", "session_id": "slow", "count": 65})
            for _ in range(100):
                if worker.metrics["queue_full_sessions"] == 1:
                    break
                await asyncio.sleep(0.01)
            assert worker.metrics["queue_full_sessions"] == 1
            assert (await asyncio.wait_for(slow.get(), 1))["code"] == "session_queue_full"
            assert (await asyncio.wait_for(healthy.get(), 1))["code"] == "worker_unavailable"
            await _wait_until_dead(worker)
        finally:
            worker._transport.send = original_send
            await worker.close()

    _run(scenario())


def test_idle_dispatch_receive_does_not_become_a_worker_failure() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=0.05))
        queue = worker.register_session("idle")
        try:
            await worker.start()
            await asyncio.sleep(0.15)
            assert worker._dispatcher is not None
            assert worker._dispatcher.done() is False
            await worker.send(
                {
                    "action": "shared_stream",
                    "phase": "event",
                    "session_id": "idle",
                    "text": "after-idle",
                }
            )
            assert (await asyncio.wait_for(queue.get(), 1))["text"] == "after-idle"
        finally:
            await worker.close()

    _run(scenario())


def test_no_id_error_is_broadcast_once_to_each_session() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        first = worker.register_session("first")
        second = worker.register_session("second")
        try:
            await worker.start()
            await worker.send({"action": "shared_global_error"})
            first_error = await asyncio.wait_for(first.get(), 1)
            second_error = await asyncio.wait_for(second.get(), 1)
            assert first_error["code"] == "shared_global_failure"
            assert second_error["code"] == "shared_global_failure"
            assert first.qsize() == 0
            assert second.qsize() == 0
            assert worker.metrics["global_errors"] == 1
        finally:
            await worker.close()

    _run(scenario())


def test_eof_broadcasts_terminal_once_and_restart_gets_new_generation() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        old_queue = worker.register_session("same")
        try:
            await worker.start()
            first_generation = worker.generation
            await worker.send({"action": "shared_eof"})
            terminal = await asyncio.wait_for(old_queue.get(), 1)
            assert terminal["code"] == "worker_unavailable"
            await asyncio.wait_for(_wait_until_dead(worker), 1)

            await worker.start()
            assert worker.generation > first_generation
            new_queue = worker.register_session("same")
            await worker.send(
                {
                    "action": "shared_stream",
                    "phase": "event",
                    "session_id": "same",
                    "text": "new-generation",
                }
            )
            assert (await asyncio.wait_for(new_queue.get(), 1))["text"] == "new-generation"
            assert old_queue.qsize() == 0
        finally:
            await worker.close()

    _run(scenario())


async def _wait_until_dead(worker: Qwen3SharedWorker) -> None:
    for _ in range(100):
        if not worker.alive:
            return
        await asyncio.sleep(0.01)
    raise AssertionError("shared worker did not stop")


def test_request_timeout_aborts_old_process_and_allows_same_id_after_restart() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=0.05))
        try:
            with pytest.raises(TimeoutError, match="worker_request_timeout"):
                await worker.request({"action": "shared_hang", "request_id": "reuse"})
            assert worker.alive is False
            await worker.start()
            result = await worker.request(
                {"action": "shared_batch", "request_id": "reuse", "text": "fresh"}
            )
            assert result["text"] == "fresh"
        finally:
            await worker.close()

    _run(scenario())


def test_request_cancellation_aborts_old_process_and_cleans_future() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=1.0))
        try:
            request = asyncio.create_task(
                worker.request({"action": "shared_hang", "request_id": "cancel-me"})
            )
            await asyncio.sleep(0.05)
            request.cancel()
            with pytest.raises(asyncio.CancelledError):
                await request
            assert worker.alive is False
            assert worker.pending_request_count == 0
        finally:
            await worker.close()

    _run(scenario())


def test_mode_gate_lease_survives_timeout_and_owner_restart() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config(timeout_seconds=0.05))
        mode_gate = worker.mode_gate
        lease = mode_gate.acquire("streaming")
        try:
            with pytest.raises(TimeoutError, match="worker_request_timeout"):
                await worker.request({"action": "shared_hang", "request_id": "mode-reset"})
            assert worker.mode_gate is mode_gate
            assert mode_gate.active_mode == "streaming"
            assert mode_gate.active_count == 1
            mode_gate.release(lease)
            await worker.start()
            assert worker.mode_gate is mode_gate
            assert mode_gate.active_count == 0
        finally:
            if not lease.released:
                mode_gate.release(lease)
            await worker.close()

    _run(scenario())


@pytest.mark.parametrize(
    "failure",
    [OSError("broken pipe"), ProtocolError("bad frame")],
    ids=["os-error", "protocol-error"],
)
def test_send_failure_aborts_owner_and_next_request_recovers(
    monkeypatch: pytest.MonkeyPatch,
    failure: BaseException,
) -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())

        async def failing_send(*_args: Any, **_kwargs: Any) -> None:
            raise failure

        monkeypatch.setattr(worker._transport, "send", failing_send)
        try:
            with pytest.raises(type(failure), match=str(failure)):
                await worker.request({"action": "shared_batch", "request_id": "send-failure"})
            assert worker.alive is False
            assert worker.pending_request_count == 0
            monkeypatch.undo()
            result = await worker.request(
                {"action": "shared_batch", "request_id": "send-failure", "text": "fresh"}
            )
            assert result["text"] == "fresh"
        finally:
            await worker.close()

    _run(scenario())


def test_handshake_mismatch_aborts_without_starting_dispatcher() -> None:
    async def scenario() -> None:
        config = _Config(model_dir=Path("/tmp/shared-bad-ready"))
        worker = Qwen3SharedWorker(config)
        with pytest.raises(RuntimeError, match="backend_identity_mismatch"):
            await worker.start()
        assert worker.alive is False
        assert worker._dispatcher is None
        await worker.close()

    _run(scenario())


def test_unknown_and_duplicate_frames_use_bounded_metrics() -> None:
    async def scenario() -> None:
        worker = Qwen3SharedWorker(_Config())
        try:
            await worker.start()
            await worker.send(
                {"action": "shared_unknown_stream", "session_id": "retired"}
            )
            result = await worker.request(
                {
                    "action": "shared_batch_duplicate",
                    "request_id": "duplicate",
                }
            )
            assert result["request_id"] == "duplicate"
            await asyncio.sleep(0.05)
            assert worker.metrics["unknown_frames"] >= 1
            assert worker.metrics["duplicate_frames"] >= 1
            assert worker.pending_request_count == 0
        finally:
            await worker.close()

    _run(scenario())
