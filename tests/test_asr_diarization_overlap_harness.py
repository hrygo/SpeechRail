"""T6 scheduling only: real asyncio/governor, fake compute, no model or PCM."""

import asyncio
import json

import pytest

from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass


def governor(overlap=True):
    return ResourceGovernor(GovernorLimits(3, 1, 4), allow_heavy_overlap=overlap)


def test_serial_feeds_both_callbacks_but_governor_serializes_actual_compute():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        shared = governor(False)
        entered = {name: asyncio.Event() for name in ("asr", "diarization")}
        phases = []

        def workload(name, work_class):
            async def run(received):
                assert received is shared
                entered[name].set()
                await entered["diarization" if name == "asr" else "asr"].wait()
                async with received.reserve(work_class):
                    phases.append((name, "start"))
                    snapshot = received.snapshot()
                    assert snapshot.active_asr + snapshot.active_diarization == 1
                    await asyncio.sleep(0)
                    phases.append((name, "end"))
                return {"complete": True, "private": "private transcript /private/audio"}

            return run

        result = await run_workload_schedule(
            mode="serial",
            governor=shared,
            timeout_seconds=1,
            asr=workload("asr", WorkClass.REALTIME_ASR),
            diarization=workload("diarization", WorkClass.DIARIZATION),
        )
        assert phases[0][0] == phases[1][0]
        assert phases[2][0] == phases[3][0]
        assert phases[0][0] != phases[2][0]
        assert result["schedule_completed"] is True
        assert result["certification_eligible"] is False
        assert result["joint_latency_observed"] is False
        assert "private" not in json.dumps(result)
        assert len(result["workloads"]["asr"]["report_sha256"]) == 64

    asyncio.run(scenario())


def test_overlap_calls_share_governor_and_both_real_lanes_can_enter():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        shared = governor()
        entered = {name: asyncio.Event() for name in ("asr", "diarization")}

        def workload(name, work_class):
            async def run(received):
                assert received is shared
                async with received.reserve(work_class):
                    entered[name].set()
                    await entered["diarization" if name == "asr" else "asr"].wait()
                    snapshot = received.snapshot()
                    assert snapshot.active_asr == snapshot.active_diarization == 1
                    await asyncio.sleep(0)
                return {"complete": True}

            return run

        result = await run_workload_schedule(
            mode="overlap",
            governor=shared,
            overlap_enabled=True,
            asr=workload("asr", WorkClass.REALTIME_ASR),
            diarization=workload("diarization", WorkClass.DIARIZATION),
        )
        assert set(result["workloads"]) == {"asr", "diarization"}
        assert result["compute_overlap_observed"] is False
        assert shared.snapshot().active_asr == shared.snapshot().active_diarization == 0

    asyncio.run(scenario())


@pytest.mark.parametrize("mode,name", [("asr-only", "asr"), ("diarization-only", "diarization")])
def test_single_lane_baseline_never_calls_missing_peer(mode, name):
    from bench_asr_diarization_overlap import run_workload_schedule

    async def workload(shared):
        return {"complete": True}

    result = asyncio.run(run_workload_schedule(mode=mode, governor=governor(), **{name: workload}))
    assert set(result["workloads"]) == {name}


@pytest.mark.parametrize("allowed,enabled", [(True, False), (False, True), (True, 1)])
def test_overlap_requires_explicit_plan_and_governor_permission_before_callbacks(allowed, enabled):
    from bench_asr_diarization_overlap import run_workload_schedule

    async def forbidden(shared):
        pytest.fail("rejected overlap must not enter a workload")

    with pytest.raises(ValueError, match="workload schedule failed"):
        asyncio.run(
            run_workload_schedule(
                mode="overlap",
                governor=governor(allowed),
                overlap_enabled=enabled,
                asr=forbidden,
                diarization=forbidden,
            )
        )


def test_failed_lane_cancels_and_joins_sibling_cleanup_without_private_error():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        started, cleanup_started, release = asyncio.Event(), asyncio.Event(), asyncio.Event()

        async def asr(shared):
            await started.wait()
            raise RuntimeError("private transcript /private/weights")

        async def dia(shared):
            try:
                started.set()
                await asyncio.Event().wait()
            finally:
                cleanup_started.set()
                await release.wait()

        task = asyncio.create_task(
            run_workload_schedule(
                mode="overlap",
                governor=governor(),
                overlap_enabled=True,
                asr=asr,
                diarization=dia,
            )
        )
        await cleanup_started.wait()
        assert not task.done()
        release.set()
        with pytest.raises(ValueError, match=r"^ASR diarization workload schedule failed$"):
            await task

    asyncio.run(scenario())


def test_timeout_waits_for_single_lane_cleanup():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        cleaned = False

        async def asr(shared):
            nonlocal cleaned
            try:
                await asyncio.Event().wait()
            finally:
                await asyncio.sleep(0)
                cleaned = True

        with pytest.raises(ValueError):
            await run_workload_schedule(
                mode="asr-only",
                governor=governor(),
                asr=asr,
                timeout_seconds=0.01,
            )
        assert cleaned

    asyncio.run(scenario())


@pytest.mark.parametrize(
    "report",
    [
        {},
        {"complete": False},
        {"status": "failed"},
        {"quality_evidence_valid": True, "failures": ["timeout"]},
        {"complete": True, "value": float("nan")},
    ],
)
def test_partial_or_nonfinite_workload_cannot_complete_schedule(report):
    from bench_asr_diarization_overlap import run_workload_schedule

    async def workload(shared):
        return report

    with pytest.raises(ValueError):
        asyncio.run(run_workload_schedule(mode="asr-only", governor=governor(), asr=workload))


def test_repeated_external_cancel_does_not_abandon_cleanup():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        entered, cleaning, release = asyncio.Event(), asyncio.Event(), asyncio.Event()

        async def workload(shared):
            try:
                entered.set()
                await asyncio.Event().wait()
            finally:
                cleaning.set()
                await release.wait()

        task = asyncio.create_task(
            run_workload_schedule(mode="asr-only", governor=governor(), asr=workload)
        )
        await entered.wait()
        task.cancel()
        await cleaning.wait()
        task.cancel()
        await asyncio.sleep(0)
        assert not task.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith("joint-")]

    asyncio.run(scenario())


def test_self_cancelled_workload_is_failure_not_success():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def cancelled(shared):
        raise asyncio.CancelledError

    with pytest.raises(ValueError):
        asyncio.run(run_workload_schedule(mode="asr-only", governor=governor(), asr=cancelled))


@pytest.mark.parametrize("clock_values", [[True], [float("nan")], [float("inf")], [2, 1]])
def test_invalid_or_backwards_host_clock_cannot_report_completion(clock_values):
    from bench_asr_diarization_overlap import run_workload_schedule

    async def workload(shared):
        return {"complete": True}

    values = iter(clock_values)
    with pytest.raises(ValueError):
        asyncio.run(
            run_workload_schedule(
                mode="asr-only", governor=governor(), asr=workload, clock=lambda: next(values)
            )
        )


@pytest.mark.parametrize("timeout", [True, 0, -1, 7201, float("nan"), float("inf")])
def test_invalid_timeout_is_rejected_before_workload(timeout):
    from bench_asr_diarization_overlap import run_workload_schedule

    async def forbidden(shared):
        pytest.fail("invalid timeout cannot start workloads")

    with pytest.raises(ValueError):
        asyncio.run(
            run_workload_schedule(
                mode="asr-only", governor=governor(), asr=forbidden, timeout_seconds=timeout
            )
        )


def test_governor_with_other_active_compute_cannot_start_trial():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        shared = governor()

        async def forbidden(shared):
            pytest.fail("unrelated compute must prevent trial start")

        async with shared.reserve(WorkClass.BATCH_ASR):
            with pytest.raises(ValueError):
                await run_workload_schedule(mode="asr-only", governor=shared, asr=forbidden)

    asyncio.run(scenario())


def test_report_hashing_is_off_loop_and_cancellation_joins_it(monkeypatch):
    import threading

    import bench_asr_diarization_overlap as module

    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    original = module._report_digest

    def blocked(report):
        entered.set()
        assert release.wait(5)
        try:
            return original(report)
        finally:
            finished.set()

    monkeypatch.setattr(module, "_report_digest", blocked)

    async def scenario():
        async def workload(shared):
            return {"complete": True}

        task = asyncio.create_task(
            module.run_workload_schedule(mode="asr-only", governor=governor(), asr=workload)
        )
        assert await asyncio.to_thread(entered.wait, 5)
        task.cancel()
        await asyncio.sleep(0)
        assert not finished.is_set() and not task.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert finished.is_set()

    asyncio.run(scenario())


def test_external_cancel_during_peer_failure_does_not_cancel_cleanup_again():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        started, cleaning, release = asyncio.Event(), asyncio.Event(), asyncio.Event()
        cleaned = False

        async def asr(shared):
            await started.wait()
            raise ValueError("compute failed")

        async def dia(shared):
            nonlocal cleaned
            try:
                started.set()
                await asyncio.Event().wait()
            finally:
                cleaning.set()
                await release.wait()
                cleaned = True

        task = asyncio.create_task(
            run_workload_schedule(
                mode="overlap",
                governor=governor(),
                overlap_enabled=True,
                asr=asr,
                diarization=dia,
            )
        )
        await cleaning.wait()
        task.cancel()
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert not task.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert cleaned

    asyncio.run(scenario())


def test_serial_requires_nonoverlap_governor_before_callbacks():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def forbidden(shared):
        pytest.fail("serial compute cannot use an overlap-enabled governor")

    with pytest.raises(ValueError):
        asyncio.run(
            run_workload_schedule(
                mode="serial", governor=governor(True), asr=forbidden, diarization=forbidden
            )
        )


def test_swallowed_deadline_cancellation_cannot_report_completion():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def workload(shared):
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            return {"complete": True}

    with pytest.raises(ValueError):
        asyncio.run(
            run_workload_schedule(
                mode="asr-only", governor=governor(), asr=workload, timeout_seconds=0.01
            )
        )


@pytest.mark.parametrize("self_cancel", [False, True])
def test_joint_self_cancelled_callback_fails_and_joins_peer_without_waiting_for_deadline(
    self_cancel,
):
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        entered, cleaned = asyncio.Event(), asyncio.Event()

        async def asr(shared):
            await entered.wait()
            if self_cancel:
                asyncio.current_task().cancel()
                await asyncio.sleep(0)
            raise asyncio.CancelledError

        async def dia(shared):
            try:
                entered.set()
                await asyncio.Event().wait()
            finally:
                cleaned.set()

        task = asyncio.create_task(
            run_workload_schedule(
                mode="serial",
                governor=governor(False),
                asr=asr,
                diarization=dia,
                timeout_seconds=10,
            )
        )
        try:
            await asyncio.wait_for(cleaned.wait(), timeout=0.2)
            with pytest.raises(ValueError, match="workload schedule failed"):
                await task
        finally:
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    asyncio.run(scenario())


def test_callback_may_return_a_future_awaitable():
    from bench_asr_diarization_overlap import run_workload_schedule

    async def scenario():
        def workload(shared):
            future = asyncio.get_running_loop().create_future()
            future.set_result({"complete": True})
            return future

        report = await run_workload_schedule(mode="asr-only", governor=governor(), asr=workload)
        assert report["schedule_completed"] is True

    asyncio.run(scenario())
