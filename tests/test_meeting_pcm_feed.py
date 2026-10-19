"""Synthetic PCM and clocks only; no models, real audio, services or benchmark."""

import asyncio
import hashlib

import pytest

from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.resource_governor import ResourceGovernor


class Clock:
    def __init__(self):
        self.value = 10.0

    def __call__(self):
        return self.value

    async def sleep(self, delay):
        self.value += delay
        await asyncio.sleep(0)


def arguments(clock, pcm=b"\x01\x00" * 9):
    return {
        "pcm": pcm,
        "expected_pcm_sha256": hashlib.sha256(pcm).hexdigest(),
        "chunk_samples": 4,
        "queue_chunks": 4,
        "max_lateness_seconds": 0.01,
        "clock": clock,
        "sleep": clock.sleep,
    }


def governor(overlap=False):
    return ResourceGovernor(GovernorLimits(3, 1, 4), allow_heavy_overlap=overlap)


@pytest.mark.parametrize("mode", ["serial", "overlap"])
def test_joint_schedule_delivers_identical_chunks_on_common_sample_end_clock(mode):
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        clock, seen = Clock(), {"asr": [], "diarization": []}

        def callback(name):
            async def run(shared, frames):
                async for chunk in frames:
                    seen[name].append(chunk)
                    assert chunk.offered_at >= chunk.target_at
                return {"complete": True}

            return run

        result = await run_pcm_workload_schedule(
            mode=mode,
            governor=governor(mode == "overlap"),
            overlap_enabled=mode == "overlap",
            asr=callback("asr"),
            diarization=callback("diarization"),
            **arguments(clock),
        )
        left, right = seen.values()
        assert [(x.sequence, x.start_sample, x.end_sample) for x in left] == [
            (0, 0, 4),
            (1, 4, 8),
            (2, 8, 9),
        ]
        assert all(a is b for a, b in zip(left, right, strict=True))
        assert b"".join(x.pcm for x in left) == arguments(clock)["pcm"]
        assert left[-1].target_at - left[0].target_at == pytest.approx(5 / 16000)
        feed = result["pcm_feed"]
        assert feed["source_samples"] == 9
        assert feed["chunks"] == 3
        assert feed["clock_source"] == "injected"
        assert feed["delivered_samples"] == {"asr": 9, "diarization": 9}
        assert result["joint_latency_observed"] is False
        assert result["certification_eligible"] is False
        assert "pcm=" not in repr(left[0])

    asyncio.run(scenario())


def test_slow_consumer_full_queue_fails_and_joins_cleanup_instead_of_pausing_source():
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        clock, cleaned = Clock(), asyncio.Event()

        async def stalled(shared, frames):
            try:
                await anext(frames)
                await asyncio.Event().wait()
            finally:
                cleaned.set()

        options = arguments(clock, b"\x00\x00" * 32)
        options["queue_chunks"] = 1
        with pytest.raises(ValueError, match="PCM workload schedule failed"):
            await run_pcm_workload_schedule(
                mode="asr-only", governor=governor(), asr=stalled, **options
            )
        assert cleaned.is_set()

    asyncio.run(scenario())


@pytest.mark.parametrize("early", [True, False])
def test_missing_or_unexhausted_stream_never_completes(early):
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        async def partial(shared, frames):
            if not early:
                await anext(frames)
            return {"complete": True}

        with pytest.raises(ValueError, match="PCM workload schedule failed"):
            await run_pcm_workload_schedule(
                mode="asr-only", governor=governor(), asr=partial, **arguments(Clock())
            )

    asyncio.run(scenario())


def test_source_digest_mismatch_does_not_deliver_samples():
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        seen = []

        async def callback(shared, frames):
            async for chunk in frames:
                seen.append(chunk)
            return {"complete": True}

        options = arguments(Clock())
        options["expected_pcm_sha256"] = "0" * 64
        with pytest.raises(ValueError):
            await run_pcm_workload_schedule(
                mode="asr-only", governor=governor(), asr=callback, **options
            )
        assert not seen

    asyncio.run(scenario())


@pytest.mark.parametrize("delta", [-0.001, 0.1])
def test_early_or_late_clock_fails_instead_of_retiming_source(delta):
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        clock = Clock()

        async def invalid_sleep(delay):
            clock.value += delay + delta
            await asyncio.sleep(0)

        async def callback(shared, frames):
            async for _ in frames:
                pass
            return {"complete": True}

        options = arguments(clock)
        options["sleep"] = invalid_sleep
        with pytest.raises(ValueError):
            await run_pcm_workload_schedule(
                mode="asr-only", governor=governor(), asr=callback, **options
            )

    asyncio.run(scenario())


def test_repeated_external_cancel_joins_feed_and_callback_cleanup():
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        entered, cleaning, release = asyncio.Event(), asyncio.Event(), asyncio.Event()

        async def callback(shared, frames):
            try:
                await anext(frames)
                entered.set()
                await asyncio.Event().wait()
            finally:
                cleaning.set()
                await release.wait()

        task = asyncio.create_task(
            run_pcm_workload_schedule(
                mode="asr-only", governor=governor(), asr=callback, **arguments(Clock())
            )
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
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith(("joint-", "pcm-"))]

    asyncio.run(scenario())


@pytest.mark.parametrize(
    "parameter,value",
    [
        ("pcm", b""),
        ("pcm", b"\x00"),
        ("pcm", bytearray(b"\x00\x00")),
        ("chunk_samples", True),
        ("chunk_samples", 0),
        ("chunk_samples", 16001),
        ("queue_chunks", True),
        ("queue_chunks", 0),
        ("queue_chunks", 65),
        ("max_lateness_seconds", True),
        ("max_lateness_seconds", 0),
        ("max_lateness_seconds", 1.01),
        ("max_lateness_seconds", float("nan")),
        ("max_lateness_seconds", float("inf")),
        ("expected_pcm_sha256", "Z" * 64),
    ],
)
def test_invalid_feed_rejected_before_workload(parameter, value):
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def forbidden(shared, frames):
        pytest.fail("invalid feed cannot start workload")

    options = arguments(Clock())
    options[parameter] = value
    with pytest.raises(ValueError):
        asyncio.run(
            run_pcm_workload_schedule(
                mode="asr-only", governor=governor(), asr=forbidden, **options
            )
        )


def test_single_lane_deadline_cancels_waiting_source_and_joins_consumer():
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        cleaned = False

        async def callback(shared, frames):
            nonlocal cleaned
            try:
                await asyncio.Event().wait()
            finally:
                cleaned = True

        with pytest.raises(ValueError):
            await run_pcm_workload_schedule(
                mode="asr-only",
                governor=governor(),
                asr=callback,
                timeout_seconds=0.01,
                **arguments(Clock()),
            )
        assert cleaned
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith(("joint-", "pcm-"))]

    asyncio.run(scenario())


def test_producer_self_cancel_fails_and_cancels_consumers_promptly():
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        cleaned = asyncio.Event()

        async def cancelled_sleep(delay):
            asyncio.current_task().cancel()
            await asyncio.sleep(0)

        async def callback(shared, frames):
            try:
                async for _ in frames:
                    pass
                return {"complete": True}
            finally:
                cleaned.set()

        options = arguments(Clock())
        options["sleep"] = cancelled_sleep
        task = asyncio.create_task(
            run_pcm_workload_schedule(
                mode="asr-only", governor=governor(), asr=callback, timeout_seconds=10, **options
            )
        )
        try:
            await asyncio.wait_for(cleaned.wait(), timeout=0.2)
            with pytest.raises(ValueError):
                await task
        finally:
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    asyncio.run(scenario())


def test_retained_stream_cannot_read_pcm_after_schedule_scope_closes():
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def scenario():
        retained = []

        async def callback(shared, frames):
            retained.append(frames)
            async for _ in frames:
                pass
            return {"complete": True}

        await run_pcm_workload_schedule(
            mode="asr-only", governor=governor(), asr=callback, **arguments(Clock())
        )
        with pytest.raises(ValueError, match="closed"):
            await anext(retained[0])

    asyncio.run(scenario())


def test_default_host_clock_with_synthetic_pcm_does_not_claim_capture_or_quality():
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    async def callback(shared, frames):
        async for _ in frames:
            pass
        return {"complete": True}

    pcm = b"\x00\x00" * 320
    report = asyncio.run(
        run_pcm_workload_schedule(
            pcm=pcm,
            expected_pcm_sha256=hashlib.sha256(pcm).hexdigest(),
            mode="asr-only",
            governor=governor(),
            asr=callback,
            max_lateness_seconds=1,
        )
    )
    feed = report["pcm_feed"]
    assert feed["clock_source"] == "monotonic"
    assert feed["source_end_target_at"] - feed["source_origin_at"] == pytest.approx(0.02)
    assert feed["source_end_offered_at"] >= feed["source_end_target_at"]
    assert feed["model_acceptance_verified"] is False
    assert feed["microphone_capture_verified"] is False
    assert report["joint_latency_observed"] is False
    options = arguments(Clock(), pcm)
    options.update(chunk_samples=320, queue_chunks=8, max_lateness_seconds=1)
    simulated = asyncio.run(
        run_pcm_workload_schedule(
            mode="asr-only",
            governor=governor(),
            asr=callback,
            **options,
        )
    )
    assert simulated["pcm_feed"]["policy_sha256"] != feed["policy_sha256"]


def test_concurrent_reads_on_one_lane_are_rejected_and_scope_can_be_closed():
    from meeting_pcm_feed import CommonPcmFeed

    async def scenario():
        feed = CommonPcmFeed(lanes=["asr"], **arguments(Clock()))
        stream = feed.stream("asr")
        read = asyncio.create_task(anext(stream))
        await asyncio.sleep(0)
        try:
            with pytest.raises(ValueError, match="concurrent reads"):
                await anext(stream)
        finally:
            read.cancel()
            await asyncio.gather(read, return_exceptions=True)
            feed.close()

    asyncio.run(scenario())


def test_cancel_during_source_hashing_joins_the_off_loop_thread(monkeypatch):
    import threading
    from types import SimpleNamespace

    import meeting_pcm_feed as module
    from bench_asr_diarization_overlap import run_pcm_workload_schedule

    entered, release, done = threading.Event(), threading.Event(), threading.Event()
    original = hashlib.sha256

    def blocked(pcm):
        entered.set()
        assert release.wait(5)
        try:
            return original(pcm)
        finally:
            done.set()

    monkeypatch.setattr(module, "hashlib", SimpleNamespace(sha256=blocked))

    async def scenario():
        async def callback(shared, frames):
            async for _ in frames:
                pass
            return {"complete": True}

        task = asyncio.create_task(
            run_pcm_workload_schedule(
                mode="asr-only", governor=governor(), asr=callback, **arguments(Clock())
            )
        )
        try:
            assert await asyncio.to_thread(entered.wait, 5)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done() and not done.is_set()
            release.set()
            with pytest.raises(asyncio.CancelledError):
                await task
            assert done.is_set()
        finally:
            release.set()
            if not task.done():
                task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    asyncio.run(scenario())
