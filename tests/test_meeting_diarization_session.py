"""Rolling activity uses no model or device in deterministic tests."""

import asyncio

import pytest

from speechrail.backends.diarization.meeting import MeetingActivitySession
from speechrail.domain.diarization.types import DiarizationError
from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.resource_governor import ResourceGovernor


@pytest.mark.anyio
@pytest.mark.parametrize("infer_fails", [False, True])
async def test_diarization_close_failure_isolates_only_diarization_when_overlap_allowed(
    infer_fails,
):
    from speechrail.runtime.resource_governor import WorkClass

    class FailedReapWorker(Worker):
        async def request(self, header, pcm):
            if infer_fails:
                raise RuntimeError("infer failed")
            return await super().request(header, pcm)

        async def close(self):
            raise RuntimeError("exact child is unconfirmed")

    governor = ResourceGovernor(
        GovernorLimits(3, 1, 8), allow_heavy_overlap=True, quarantine_resources_bounded=True
    )
    session = MeetingActivitySession(worker=FailedReapWorker(), epoch="epoch", governor=governor)
    await session.append(start_sample=0, pcm16=bytes(320000))
    if infer_fails:
        with pytest.raises(DiarizationError):
            await asyncio.wait_for(anext(session.updates()), 1)
    else:
        await asyncio.wait_for(anext(session.updates()), 1)
    with pytest.raises(RuntimeError, match="unconfirmed"):
        await session.cancel()
    assert governor.diarization_owner.occupied and governor.diarization_owner.isolated
    assert governor.snapshot().retained_diarization == 1
    async with governor.reserve(WorkClass.REALTIME_ASR):
        assert governor.snapshot().active_asr == 1


class Worker:
    def __init__(self):
        self.calls = []
        self.closed = False
        self.gate = None
        self.entered = asyncio.Event()

    async def start(self):
        pass

    async def request(self, header, pcm):
        self.calls.append((header.copy(), len(pcm)))
        self.entered.set()
        if self.gate:
            await self.gate.wait()
        end = header["audio_start"] + header["audio_samples"]
        return {
            "protocol_version": 2,
            "backend": "meeting_dynamic",
            "epoch": header["epoch"],
            "ok": True,
            "processed_through": end,
            "stable_through": end
            if header["final"]
            else max(header["previous_stable"], end - 160000),
            "frames": [{"start": header["previous_stable"], "end": end, "active_slots": [3]}],
        }, b""

    async def close(self):
        self.closed = True
        if self.gate:
            self.gate.set()


@pytest.mark.anyio
async def test_windows_10_20_30_40_and_one_sample_tail():
    worker = Worker()
    governor = ResourceGovernor(GovernorLimits(2, 1, 8), allow_heavy_overlap=False)
    from speechrail.observability.metrics import Metrics

    metrics = Metrics()
    session = MeetingActivitySession(
        worker=worker, epoch="epoch", governor=governor, metrics=metrics
    )

    async def consume():
        return [u async for u in session.updates()]

    reader = asyncio.create_task(consume())
    await session.append(start_sample=0, pcm16=bytes(640001 * 2))
    await session.finish(through_sample=640001)
    updates = await reader
    assert [count // 2 for _, count in worker.calls] == [160000, 320000, 480000, 480000, 480000]
    assert updates[-1].stable_through == 640001
    assert all(frame.scores is None for u in updates for frame in u.frames)
    assert worker.closed, "finish must reap the child before acknowledging the barrier"
    assert session.ring.charged_bytes == 0
    snapshot = metrics.read_state()
    assert snapshot.histograms["speechrail_diarization_phase_seconds"]
    assert snapshot.gauge_total("speechrail_diarization_watermark_lag_samples") == 0
    await session.cancel()
    assert session.ring.active_borrows == 0 and worker.closed


@pytest.mark.anyio
async def test_append_does_not_wait_for_model_and_cancel_reaps_before_lease_release():
    worker = Worker()
    worker.gate = asyncio.Event()
    governor = ResourceGovernor(GovernorLimits(2, 1, 8), allow_heavy_overlap=False)
    session = MeetingActivitySession(worker=worker, epoch="epoch", governor=governor)
    await session.append(start_sample=0, pcm16=bytes(320000))
    await worker.entered.wait()
    await asyncio.wait_for(session.append(start_sample=160000, pcm16=bytes(320000)), 0.1)
    assert governor.snapshot().active_diarization == 1
    await session.cancel()
    assert worker.closed and governor.snapshot().active_diarization == 0


@pytest.mark.anyio
async def test_cancel_closes_waiting_consumer():
    worker = Worker()
    session = MeetingActivitySession(
        worker=worker, epoch="epoch", governor=ResourceGovernor(GovernorLimits(2, 1, 8))
    )
    waiting = asyncio.create_task(anext(session.updates(), None))
    await asyncio.sleep(0)
    await session.cancel()
    assert await asyncio.wait_for(waiting, 0.1) is None


@pytest.mark.anyio
async def test_repeated_meeting_finish_and_cancel_reap_once():
    class CountedWorker(Worker):
        closes = 0

        async def close(self):
            self.closes += 1
            await super().close()

    worker = CountedWorker()
    session = MeetingActivitySession(
        worker=worker, epoch="epoch", governor=ResourceGovernor(GovernorLimits(2, 1, 8))
    )
    await session.append(start_sample=0, pcm16=bytes(320000))
    await session.finish(through_sample=160000)
    await session.finish(through_sample=160000)
    await session.cancel()
    assert worker.closes == 1


@pytest.mark.anyio
async def test_slow_meeting_consumer_fails_without_retaining_worker():
    worker = Worker()
    governor = ResourceGovernor(GovernorLimits(2, 1, 8))
    session = MeetingActivitySession(worker=worker, epoch="epoch", governor=governor)
    await session.append(start_sample=0, pcm16=bytes(320000))
    first = await asyncio.wait_for(anext(session.updates()), 1)
    for _ in range(64):
        session._queue.put_nowait(first)
    await session.append(start_sample=160000, pcm16=bytes(320000))
    assert session._pump is not None
    try:
        await asyncio.wait_for(asyncio.shield(session._pump), 0.1)
        assert worker.closed and not governor.diarization_owner.occupied
        with pytest.raises(DiarizationError, match="meeting activity failed"):
            _ = [update async for update in session.updates()]
    finally:
        await session.cancel()


@pytest.mark.anyio
async def test_malformed_dynamic_frame_cannot_invent_a_score_or_advance_watermark():
    worker = Worker()
    governor = ResourceGovernor(GovernorLimits(2, 1, 8))
    session = MeetingActivitySession(worker=worker, epoch="epoch", governor=governor)
    from speechrail.domain.audio_timeline import SampleSpan

    with pytest.raises(ValueError):
        session._parse(
            {
                "ok": True,
                "backend": "meeting_dynamic",
                "protocol_version": 2,
                "epoch": "epoch",
                "processed_through": 160000,
                "stable_through": 0,
                "frames": [{"start": 0, "end": 160000, "active_slots": [32]}],
            },
            SampleSpan(0, 160000),
            False,
        )
    assert session._stable == 0


@pytest.mark.anyio
async def test_invalid_native_state_counts_cannot_certify_unbounded_retention():
    from speechrail.domain.audio_timeline import SampleSpan

    worker = Worker()
    session = MeetingActivitySession(
        worker=worker, epoch="epoch", governor=ResourceGovernor(GovernorLimits(2, 1, 8))
    )
    response, _ = await worker.request(
        {
            "audio_start": 0,
            "audio_samples": 160000,
            "previous_stable": 0,
            "epoch": "epoch",
            "final": False,
        },
        b"",
    )
    response["diagnostics"] = {"identities": 33, "prototypes": 96, "candidates": 0}
    with pytest.raises(ValueError, match="capacity"):
        session._parse(response, SampleSpan(0, 160000), False)
    assert session._step == 0 and session._stable == 0


@pytest.mark.anyio
@pytest.mark.parametrize(
    "reported,expected", [("infer", "infer"), ("load", "load"), ("/private/untrusted", "protocol")]
)
async def test_native_failure_keeps_a_bounded_diagnostic_stage(reported, expected):
    from speechrail.observability.metrics import Metrics

    class FailedWorker(Worker):
        async def request(self, header, pcm):
            return {
                "protocol_version": 2,
                "backend": "meeting_dynamic",
                "ok": False,
                "diagnostic_stage": reported,
                "error": "untrusted error details",
            }, b""

    metrics = Metrics()
    worker = FailedWorker()
    session = MeetingActivitySession(
        worker=worker,
        epoch="epoch",
        metrics=metrics,
        governor=ResourceGovernor(GovernorLimits(2, 1, 8)),
    )
    await session.append(start_sample=0, pcm16=bytes(320000))
    try:
        with pytest.raises(DiarizationError, match="meeting activity failed") as failure:
            await anext(session.updates())
        assert failure.value.code == "model_not_ready"
        labels = metrics.read_state().counters["speechrail_diarization_failures_total"]
        assert labels == {(("stage", expected),): 1.0}
        assert worker.closed
    finally:
        await session.cancel()
