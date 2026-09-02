"""Fault-matrix tests for the shared async framed worker transport."""

from __future__ import annotations

import asyncio
import sys
from collections.abc import Callable, Coroutine
from pathlib import Path
from typing import Any

import pytest

from speechrail.runtime.worker_process import (
    AsyncFramedWorkerProcess,
    WorkerProcessSpec,
    offline_environment,
)
from speechrail.runtime.worker_protocol import ProtocolError

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
FAKE_WORKER = Path(__file__).resolve().parent / "fixtures" / "fake_framed_worker.py"


def _spec(
    tmp_path: Path, *, io_timeout: float = 5.0, shutdown_timeout: float = 2.0
) -> WorkerProcessSpec:
    del tmp_path
    return WorkerProcessSpec(
        command=(sys.executable, str(FAKE_WORKER)),
        cwd=REPOSITORY_ROOT,
        env=offline_environment(REPOSITORY_ROOT),
        io_timeout_seconds=io_timeout,
        shutdown_timeout_seconds=shutdown_timeout,
    )


def _run(coro_factory: Callable[[], Coroutine[Any, Any, None]]) -> None:
    asyncio.run(coro_factory())


def test_offline_environment_inherits_only_allowlisted_keys() -> None:
    environment = offline_environment(REPOSITORY_ROOT)

    assert environment["PYTHONPATH"].endswith("src")
    assert environment["HF_HUB_OFFLINE"] == "1"
    assert environment["PYTORCH_ENABLE_MPS_FALLBACK"] == "0"
    assert environment["TOKENIZERS_PARALLELISM"] == "false"


def test_offline_environment_accepts_installed_package_root(tmp_path: Path) -> None:
    package_root = tmp_path / "site-packages"
    package_root.mkdir()

    environment = offline_environment(package_root)

    assert environment["PYTHONPATH"] == str(package_root)


def test_send_and_receive_require_a_started_process(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        with pytest.raises(RuntimeError, match="worker_not_started"):
            await transport.send({"action": "echo"})
        with pytest.raises(RuntimeError, match="worker_not_started"):
            await transport.receive()

    _run(scenario)


def test_start_is_idempotent_and_frames_round_trip(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        try:
            await transport.start()
            first = transport._process
            await transport.start()
            assert transport._process is first
            await transport.send({"action": "echo", "text": "hello"})
            assert await transport.receive() == {"type": "echo", "text": "hello"}
        finally:
            await transport.close()

    _run(scenario)


def test_receive_times_out_when_child_never_answers(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path, io_timeout=0.3))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "hang"})
            with pytest.raises(TimeoutError):
                await transport.receive()
        finally:
            await transport.close()

    _run(scenario)


def test_send_times_out_when_child_stops_draining_stdin(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path, io_timeout=0.3))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "hang"})
            payload = {"action": "echo", "text": "x" * (512 * 1024)}
            with pytest.raises(TimeoutError):
                for _ in range(4):
                    await transport.send(payload)
        finally:
            await transport.close()

    _run(scenario)


def test_receive_rejects_a_malformed_frame(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "malformed"})
            with pytest.raises(ProtocolError, match="worker frame"):
                await transport.receive()
        finally:
            await transport.close()

    _run(scenario)


def test_child_exit_closes_the_stream_without_orphan_frames(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "exit"})
            with pytest.raises(ProtocolError, match="truncated worker frame"):
                await transport.receive()
            with pytest.raises((BrokenPipeError, ConnectionResetError, RuntimeError)):
                await transport.send({"action": "echo", "text": "late"})
        finally:
            await transport.close()

    _run(scenario)


def test_close_is_idempotent_and_terminates_the_child(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        await transport.start()
        process = transport._process
        assert process is not None
        await transport.close()
        assert transport._process is None
        assert process.returncode is not None
        await transport.close()
        assert not transport.alive

    _run(scenario)


def test_abort_then_restart_does_not_leak_old_frames(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "echo", "text": "stale"})
            await transport.abort()
            await transport.start()
            await transport.send({"action": "echo", "text": "fresh"})
            assert await transport.receive() == {"type": "echo", "text": "fresh"}
        finally:
            await transport.close()

    _run(scenario)


def test_terminate_timeout_falls_back_to_kill(tmp_path: Path) -> None:
    transport = AsyncFramedWorkerProcess(_spec(tmp_path, shutdown_timeout=0.3))

    async def scenario() -> None:
        await transport.start()
        await transport.send({"action": "stubborn"})
        process = transport._process
        assert process is not None
        await transport.close()
        assert process.returncode is not None

    _run(scenario)


def test_child_exit_surfaces_stderr_in_protocol_error(tmp_path: Path) -> None:
    """When the child writes to stderr and dies, the ProtocolError includes the output."""
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "stderr_and_exit"})
            # Give the child a moment to write stderr and exit
            await asyncio.sleep(0.1)
            with pytest.raises(ProtocolError, match="transformers") as exc_info:
                await transport.receive()
            assert "stderr" in str(exc_info.value).lower()
        finally:
            await transport.close()

    _run(scenario)


def test_child_exit_without_stderr_reports_no_stderr_captured(tmp_path: Path) -> None:
    """When the child exits silently, the ProtocolError reports no stderr captured."""
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "exit"})
            await asyncio.sleep(0.1)
            with pytest.raises(ProtocolError, match="no stderr captured"):
                await transport.receive()
        finally:
            await transport.close()

    _run(scenario)


def test_error_frame_embeds_worker_stderr_tail(tmp_path: Path) -> None:
    """A valid error frame still surfaces the worker stderr on the decoded frame."""
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "error_with_stderr"})
            await asyncio.sleep(0.1)
            frame = await transport.receive()
            assert frame["type"] == "error"
            assert frame["code"] == "worker_load_error"
            assert "failed to allocate" in str(frame["stderr_tail"])
        finally:
            await transport.close()

    _run(scenario)


def test_error_frame_without_stderr_reports_no_stderr_captured(tmp_path: Path) -> None:
    """An error frame with an empty stderr ring carries the explicit placeholder."""
    transport = AsyncFramedWorkerProcess(_spec(tmp_path))

    async def scenario() -> None:
        try:
            await transport.start()
            await transport.send({"action": "unknown-action"})
            frame = await transport.receive()
            assert frame["type"] == "error"
            assert frame["code"] == "unknown_action"
            assert frame["stderr_tail"] == "(no stderr captured)"
        finally:
            await transport.close()

    _run(scenario)
