"""Full outer scope with injected host/worker trees; never native process reads."""

import asyncio
import os
import threading
from types import SimpleNamespace

import pytest
from meeting_process_owner import capture_owned_process_scope
from meeting_process_snapshot import ProcessKey, ProcessUsage


class Tree:
    backend = "injected"

    def __init__(self):
        self.pid = os.getpid()
        self.workers = []

    def read(self, pid):
        if pid == self.pid:
            return ProcessUsage(ProcessKey(pid, 100), 10)
        if any(p.pid == pid and p.returncode is None for p in self.workers):
            return ProcessUsage(ProcessKey(pid, 200), 50)
        return None

    def children(self, pid):
        return tuple(p.pid for p in self.workers if p.returncode is None) if pid == self.pid else ()


def test_outer_scope_samples_host_before_load_and_after_worker_reaping():
    async def run():
        from meeting_runner_resources import observe_runner_process_tree

        tree = Tree()
        async with observe_runner_process_tree(
            reader=tree,
            expected_roles=("asr", "aligner"),
            phases=("cold_start", "steady_state", "finish"),
        ) as resources:
            tree.workers = [SimpleNamespace(pid=i, returncode=None) for i in (1, 2)]
            scope = await capture_owned_process_scope(
                get_processes=lambda: tuple(tree.workers), reader=tree
            )
            resources.register_owner(roles=("asr", "aligner"), scope=scope)
            resources.advance_phase("steady_state")
            await resources.checkpoint()
            resources.advance_phase("finish")
            await resources.checkpoint()
            for process in tree.workers:
                process.returncode = 0
        report = resources.report()
        assert report["status"] == "complete_metadata"
        assert report["post_cleanup_empty"] is True
        assert report["registered_handles_closed"] is True
        assert report["registered_roles"] == ["asr", "aligner"]
        samples = report["observation"]["samples"]
        assert samples[0]["sample_sum_bytes"] == samples[-1]["sample_sum_bytes"] == 10
        assert any(s["sample_sum_bytes"] == 110 for s in samples)
        assert report["peak_footprint_verified"] is False
        assert report["certification_eligible"] is False

    asyncio.run(run())


@pytest.mark.parametrize(
    "fault", ["missing_role", "alive", "orphan", "unknown", "pid_change", "pid_bool"]
)
def test_outer_scope_keeps_missing_or_unreaped_workers_as_incomplete(fault):
    async def run():
        from meeting_runner_resources import observe_runner_process_tree

        tree = Tree()
        async with observe_runner_process_tree(
            reader=tree,
            expected_roles=("diarization",),
            phases=("cold_start", "finish"),
        ) as resources:
            process = SimpleNamespace(pid=1, returncode=None)
            tree.workers.append(process)
            if fault != "missing_role":
                scope = await capture_owned_process_scope(
                    get_processes=lambda: (process,), reader=tree
                )
                resources.register_owner(roles=("diarization",), scope=scope)
            if fault == "unknown":
                tree.workers.append(SimpleNamespace(pid=2, returncode=None))
            resources.advance_phase("finish")
            await resources.checkpoint()
            if fault == "orphan":
                tree.workers.clear()
            elif fault in {"pid_change", "pid_bool"}:
                process.pid = 2 if fault == "pid_change" else True
                process.returncode = 0
            elif fault != "alive":
                process.returncode = 0
                for extra in tree.workers[1:]:
                    extra.returncode = 0
        report = resources.report()
        assert report["status"] == "incomplete_metadata"
        assert report["worker_reaping_verified"] is False
        if fault == "unknown":
            assert report["registered_handles_closed"] is True
            assert report["post_cleanup_empty"] is True
            assert report["unregistered_process_readings"] > 0

    asyncio.run(run())


def test_cancelled_outer_scope_joins_post_cleanup_read_and_releases_singleton():
    async def run():
        from meeting_runner_resources import observe_runner_process_tree

        class BlockedTree(Tree):
            block = False

            def read(self, pid):
                if self.block:
                    started.set()
                    assert release.wait(2)
                return super().read(pid)

        started, release, entered = threading.Event(), threading.Event(), asyncio.Event()
        tree = BlockedTree()

        async def work():
            async with observe_runner_process_tree(
                reader=tree,
                expected_roles=("diarization",),
                phases=("cold_start", "cancel"),
            ) as resources:
                resources.advance_phase("cancel")
                tree.block = True
                entered.set()
                await asyncio.Event().wait()

        task = asyncio.create_task(work())
        try:
            await entered.wait()
            task.cancel()
            async with asyncio.timeout(2):
                while not started.is_set():  # noqa: ASYNC110
                    await asyncio.sleep(0)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done()
        finally:
            release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        async with observe_runner_process_tree(
            reader=Tree(),
            expected_roles=("diarization",),
            phases=("cold_start", "cancel"),
        ) as resources:
            resources.advance_phase("cancel")
        assert resources.report()["status"] == "incomplete_metadata"

    asyncio.run(run())


def test_existing_descendants_are_rejected_without_running_or_stopping_them():
    async def run():
        from meeting_runner_resources import observe_runner_process_tree

        tree = Tree()
        tree.workers.append(SimpleNamespace(pid=1, returncode=None))
        with pytest.raises(ValueError, match="runner"):
            async with observe_runner_process_tree(
                reader=tree,
                expected_roles=("diarization",),
                phases=("cold_start", "finish"),
            ):
                pytest.fail("workload must not start")
        assert tree.workers[0].returncode is None

    asyncio.run(run())
