"""Owned observer tests with injected trees; no native process or model reads."""

import asyncio
import json
import threading

import pytest
from meeting_process_snapshot import ProcessKey, ProcessUsage


class Tree:
    backend = "injected"

    def __init__(self, *, block_on=0, fail=False):
        self.reads = 0
        self.block_on = block_on
        self.fail = fail
        self.blocked = threading.Event()
        self.release = threading.Event()
        self.thread = None

    def read(self, pid):
        self.thread = threading.current_thread()
        self.reads += 1
        if self.reads == self.block_on:
            self.blocked.set()
            assert self.release.wait(2), "test did not release reader"
        if self.fail:
            raise ValueError("private path and command line must never escape")
        return ProcessUsage(ProcessKey(pid, 100), 123)

    def children(self, pid):
        return ()


async def until(predicate):
    async with asyncio.timeout(2):
        while not predicate():  # noqa: ASYNC110 -- yields for injected thread state, bounded above
            await asyncio.sleep(0)


def observer(tree, **kwargs):
    from meeting_process_observer import observe_process_phases

    return observe_process_phases(
        roots=(ProcessKey(1, 100),), reader=tree, interval_seconds=0.01, **kwargs
    )


def test_phases_keep_exact_samples_and_shutdown_owned_thread():
    async def run():
        tree = Tree()
        async with observer(tree, phases=("steady_state", "finish")) as monitor:
            assert monitor.sample_count == 1
            with pytest.raises(ValueError, match="not closed"):
                monitor.report()
            monitor.advance_phase("finish")
            await until(lambda: monitor.sample_count >= 2)
        report = monitor.report()
        assert report["status"] == "complete_metadata"
        assert [p["valid_samples"] for p in report["phases"]] == [1, 1]
        assert [p["observed_max_sample_sum_bytes"] for p in report["phases"]] == [123, 123]
        sample = report["samples"][0]
        assert sample["processes"] == [[1, 100, 123]]
        assert sample["observer_span_seconds"] >= sample["read_span_seconds"] >= 0
        assert report["observer_thread_joined"] is True
        assert not tree.thread.is_alive()
        assert report["certification_eligible"] is False
        assert report["peak_footprint_verified"] is False
        assert report["worker_reaping_verified"] is False
        report["samples"].clear()
        assert len(monitor.report()["samples"]) == 2
        with pytest.raises(ValueError, match="closed"):
            monitor.advance_phase("finish")

    asyncio.run(run())


def test_missing_phase_and_failed_reads_remain_in_denominator_without_private_errors():
    async def run():
        tree = Tree(fail=True)
        async with observer(tree, phases=("cold_start", "finish")) as monitor:
            pass
        report = monitor.report()
        assert report["status"] == "incomplete_metadata"
        assert report["failed_reads"] == 1
        assert report["phases"][0]["valid_samples"] == 0
        assert report["phases"][1]["started_at"] is None
        assert report["phases"][1]["observed_max_sample_sum_bytes"] is None
        assert report["samples"][0]["status"] == "read_failed"
        assert "private" not in json.dumps(report)
        assert not tree.thread.is_alive()

    asyncio.run(run())


def test_cross_phase_read_is_visible_but_cannot_supply_either_phase_coverage():
    async def run():
        tree = Tree(block_on=3)
        try:
            async with observer(tree, phases=("steady_state", "finish")) as monitor:
                await until(tree.blocked.is_set)
                monitor.advance_phase("finish")
                tree.release.set()
                await until(lambda: monitor.sample_count >= 3)
        finally:
            tree.release.set()
        report = monitor.report()
        assert report["cross_phase_reads"] == 1
        assert report["samples"][1]["phase_index"] is None
        assert report["samples"][1]["status"] == "cross_phase"
        assert [p["valid_samples"] for p in report["phases"]] == [1, 1]

    asyncio.run(run())


@pytest.mark.parametrize("startup", [True, False])
def test_repeated_cancellation_joins_inflight_read_without_blocking_event_loop(startup):
    async def run():
        tree = Tree(block_on=1 if startup else 3)
        monitors = []

        async def work():
            async with observer(tree, phases=("cancel",)) as monitor:
                monitors.append(monitor)
                await asyncio.Event().wait()

        task = asyncio.create_task(work())
        try:
            await until(tree.blocked.is_set)
            task.cancel()
            await asyncio.sleep(0)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done()
            assert tree.thread.is_alive()
        finally:
            tree.release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert not tree.thread.is_alive()
        if monitors:
            report = monitors[0].report()
            assert report["observer_thread_joined"] is True
            assert report["cross_phase_reads"] == 1

    asyncio.run(run())


def test_sampling_budget_ends_observation_without_claiming_complete_coverage():
    async def run():
        tree = Tree()
        async with observer(tree, phases=("steady_state",), max_samples=2) as monitor:
            await until(lambda: monitor.sample_count == 2)
            await asyncio.sleep(0)
        report = monitor.report()
        assert report["sample_budget_exhausted"] is True
        assert report["status"] == "incomplete_metadata"
        assert len(report["samples"]) == 2
        assert not tree.thread.is_alive()

    asyncio.run(run())


def test_reader_backend_change_cannot_relabel_registered_evidence():
    async def run():
        tree = Tree()
        async with observer(tree, phases=("steady_state",)) as monitor:
            tree.backend = "libproc_rusage_info_v0"
            await until(lambda: monitor.sample_count >= 2)
        report = monitor.report()
        assert report["backend"] == "injected"
        assert report["failed_reads"] >= 1
        assert report["status"] == "incomplete_metadata"

    asyncio.run(run())


def test_exhausted_observer_cannot_accept_new_phase_markers():
    async def run():
        async with observer(Tree(), phases=("steady_state", "finish"), max_samples=1) as monitor:
            with pytest.raises(ValueError, match="active"):
                monitor.advance_phase("finish")
        assert monitor.report()["phases"][1]["started_at"] is None

    asyncio.run(run())


def test_configuration_is_copied_and_phase_order_cannot_skip_registered_slots():
    async def run():
        from meeting_process_observer import observe_process_phases

        roots, phases = [ProcessKey(1, 100)], ["steady_state", "finish"]
        context = observe_process_phases(roots=roots, reader=Tree(), phases=phases)
        # Construction snapshots policy before any native reader call or workload.
        roots.clear()
        phases.clear()
        async with context as monitor:
            with pytest.raises(ValueError, match="phase"):
                monitor.advance_phase("cancel")
        assert monitor.report()["roots"] == [[1, 100]]
        assert [p["label"] for p in monitor.report()["phases"]] == ["steady_state", "finish"]

    asyncio.run(run())


def test_checkpoint_requires_a_new_read_started_after_requested_boundary():
    async def run():
        import time

        tree = Tree()
        async with observer(tree, phases=("steady_state", "finish")) as monitor:
            monitor.advance_phase("finish")
            boundary = time.monotonic()
            index = await monitor.checkpoint()
        sample = monitor.report()["samples"][index]
        assert sample["started_at"] >= boundary
        assert sample["phase_index"] == 1
        assert sample["status"] == "ok"

    asyncio.run(run())


def test_checkpoint_does_not_reuse_a_sample_after_budget_exhaustion():
    async def run():
        async with observer(Tree(), phases=("steady_state",), max_samples=1) as monitor:
            with pytest.raises(ValueError, match="active"):
                await monitor.checkpoint()

    asyncio.run(run())


@pytest.mark.parametrize(
    "kwargs",
    [
        {"phases": ()},
        {"phases": ("arbitrary",)},
        {"phases": ("finish",) * 65},
        {"phases": ("finish",), "max_samples": True},
        {"phases": ("finish",), "max_samples": 4097},
        {"phases": ("finish",), "max_processes": 65},
        {"phases": ("finish",), "max_span_seconds": float("nan")},
        {"phases": ("finish",), "scope_guard": 0},
    ],
)
def test_invalid_policy_is_rejected_before_reader_or_thread_start(kwargs):
    tree = Tree()
    with pytest.raises(ValueError):
        observer(tree, **kwargs)
    assert tree.reads == 0
