"""Synthetic owner handles and trees; no native processes or workloads."""

import asyncio
import threading
from types import SimpleNamespace

import pytest
from meeting_process_snapshot import ProcessKey, ProcessUsage


class Reader:
    backend = "injected"

    def __init__(self):
        self.token = 100
        self.started = threading.Event()
        self.release = threading.Event()
        self.block = False
        self.thread = None

    def read(self, pid):
        self.thread = threading.current_thread()
        self.started.set()
        if self.block:
            assert self.release.wait(2)
        return ProcessUsage(ProcessKey(pid, self.token), 50)

    def children(self, pid):
        return ()


def test_guarded_scope_captures_actual_handles_and_feeds_phase_observer():
    async def run():
        from meeting_process_owner import capture_owned_process_scope

        handles = (SimpleNamespace(pid=1, returncode=None), SimpleNamespace(pid=2, returncode=None))
        reader = Reader()
        scope = await capture_owned_process_scope(get_processes=lambda: handles, reader=reader)
        assert scope.roots == (ProcessKey(1, 100), ProcessKey(2, 100))
        assert not reader.thread.is_alive()
        async with scope.observe(phases=("steady_state",)) as monitor:
            assert monitor.sample_count == 1
        report = monitor.report()
        assert report["scope_guard_enabled"] is True
        assert report["scope_guard_failures"] == 0
        assert report["status"] == "complete_metadata"
        assert report["samples"][0]["sample_sum_bytes"] == 100
        assert report["runtime_identity_verified"] is False

    asyncio.run(run())


@pytest.mark.parametrize("change", ["object", "pid", "exit", "removed"])
def test_handle_replacement_exit_or_pid_change_cannot_supply_complete_evidence(change):
    async def run():
        from meeting_process_owner import capture_owned_process_scope

        process = SimpleNamespace(pid=1, returncode=None)
        current = [process]
        scope = await capture_owned_process_scope(
            get_processes=lambda: tuple(current), reader=Reader()
        )
        async with scope.observe(phases=("steady_state",)) as monitor:
            if change == "object":
                current[0] = SimpleNamespace(pid=1, returncode=None)
            elif change == "pid":
                process.pid = 2
            elif change == "exit":
                process.returncode = 0
            else:
                current.clear()
        report = monitor.report()
        assert report["scope_guard_failures"] > 0
        assert report["status"] == "incomplete_metadata"
        assert report["worker_reaping_verified"] is False

    asyncio.run(run())


def test_owner_change_during_enrollment_is_rejected_after_join():
    async def run():
        from meeting_process_owner import capture_owned_process_scope

        process = SimpleNamespace(pid=1, returncode=None)
        reader = Reader()
        reader.block = True
        task = asyncio.create_task(
            capture_owned_process_scope(get_processes=lambda: (process,), reader=reader)
        )
        async with asyncio.timeout(2):
            while not reader.started.is_set():  # noqa: ASYNC110
                await asyncio.sleep(0)
        process.returncode = 0
        reader.release.set()
        with pytest.raises(ValueError, match="owner"):
            await task
        assert not reader.thread.is_alive()

    asyncio.run(run())


def test_cancelled_enrollment_joins_native_read_and_dedicated_thread():
    async def run():
        from meeting_process_owner import capture_owned_process_scope

        reader = Reader()
        reader.block = True
        task = asyncio.create_task(
            capture_owned_process_scope(
                get_processes=lambda: (SimpleNamespace(pid=1, returncode=None),), reader=reader
            )
        )
        try:
            async with asyncio.timeout(2):
                while not reader.started.is_set():  # noqa: ASYNC110
                    await asyncio.sleep(0)
            task.cancel()
            await asyncio.sleep(0)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done()
        finally:
            reader.release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert not reader.thread.is_alive()

    asyncio.run(run())


def test_lifetime_change_after_enrollment_is_rejected_by_actual_tree_reader():
    async def run():
        from meeting_process_owner import capture_owned_process_scope

        process = SimpleNamespace(pid=1, returncode=None)
        reader = Reader()
        scope = await capture_owned_process_scope(get_processes=lambda: (process,), reader=reader)
        reader.token = 200
        async with scope.observe(phases=("steady_state",)) as monitor:
            pass
        assert monitor.report()["failed_reads"] == 1
        assert monitor.report()["status"] == "incomplete_metadata"

    asyncio.run(run())


def test_ready_handle_scope_cannot_label_observation_as_cold_start():
    async def run():
        from meeting_process_owner import capture_owned_process_scope

        process = SimpleNamespace(pid=1, returncode=None)
        scope = await capture_owned_process_scope(get_processes=lambda: (process,), reader=Reader())
        with pytest.raises(ValueError, match="cold"):
            scope.observe(phases=("cold_start", "steady_state"))

    asyncio.run(run())
