"""Phase diagnostics must distinguish admission and work without endangering cleanup."""

import asyncio

import pytest
from meeting_candidate_session import open_candidate_session

from speechrail.runtime.phase_trace import PhaseTrace
from speechrail.runtime.resource_governor import WorkClass
from test_meeting_candidate_session import Worker, governor


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def test_span_idempotence_and_bounded_failure():
    clock = Clock()
    trace = PhaseTrace(clock=clock, capacity=1)
    with trace.span("infer", "append", through_sample=160) as span:
        clock.now = 3
        span.finish()
        clock.now = 8
    event, = trace.drain()
    assert event["duration_seconds"] == 3
    assert event["status"] == "completed"
    assert trace.status()["event_count"] == 1
    for _ in range(2):
        with trace.span("close", "close"):
            pass
    assert trace.status()["reason"] == "capacity_exceeded"
    assert not trace.status()["complete"]
    assert len(trace.drain()) == 1


@pytest.mark.parametrize("value", [float("nan"), -1, True, "invalid"])
def test_invalid_clock_never_masks_work_or_failure(value):
    clock = Clock()
    trace = PhaseTrace(clock=clock)
    with pytest.raises(RuntimeError, match="original"), trace.span("infer", "append"):
        clock.now = value
        raise RuntimeError("original")
    assert trace.status()["reason"] == "invalid_clock"
    assert not trace.status()["complete"]


def test_actual_session_phases_and_queue_wait_are_separate():
    async def run():
        clock = Clock()
        trace = PhaseTrace(clock=clock)
        gov = governor()

        class TimedWorker(Worker):
            async def start(self):
                await super().start()
                clock.now += 3

            async def request(self, header, audio=b""):
                result = await super().request(header, audio)
                clock.now += 5 if header["operation"] == "append" else 7
                return result

            async def close(self):
                await super().close()
                clock.now += 11

        worker = TimedWorker(gov)
        session = open_candidate_session(
            epoch="one", governor=gov, worker_factory=lambda: worker, phase_trace=trace
        )
        async with gov.reserve(WorkClass.BATCH_ASR):
            task = asyncio.create_task(session.append(start_sample=0, pcm16=bytes(320)))
            while not gov.snapshot().pending_batch:  # noqa: ASYNC110 -- observe actual admission queue
                await asyncio.sleep(0)
            clock.now += 2
        await task
        await session.finish(through_sample=160)
        await session.cancel()
        events = trace.drain()
        assert [(e["phase"], e["duration_seconds"]) for e in events] == [
            ("compute_queue", 2), ("load", 3), ("infer", 5),
            ("compute_queue", 0), ("finalize", 7), ("close", 11),
        ]
        assert trace.status()["required_phases_observed"]
        assert trace.status()["clock_source"] == "injected"
        assert worker.closes == 1 and not gov.diarization_owner.occupied

    asyncio.run(asyncio.wait_for(run(), 2))


def test_close_event_waits_for_exact_child_and_bad_clock_cannot_skip_cleanup():
    async def run():
        clock = Clock()
        trace = PhaseTrace(clock=clock)
        gov = governor()
        worker = Worker(gov)
        worker.reap = asyncio.Event()
        session = open_candidate_session(
            epoch="one", governor=gov, worker_factory=lambda: worker, phase_trace=trace
        )
        task = asyncio.create_task(session.cancel())
        await worker.closing.wait()
        assert trace.drain() == () and gov.diarization_owner.occupied
        clock.now = float("nan")
        worker.reap.set()
        await task
        assert worker.closes == 1 and not gov.diarization_owner.occupied
        assert trace.status()["reason"] == "invalid_clock"

    asyncio.run(asyncio.wait_for(run(), 2))


def test_cancelled_admission_records_no_model_inference_and_closes_once():
    async def run():
        trace = PhaseTrace()
        gov = governor()
        worker = Worker(gov)
        session = open_candidate_session(
            epoch="one", governor=gov, worker_factory=lambda: worker, phase_trace=trace
        )
        async with gov.reserve(WorkClass.BATCH_ASR):
            task = asyncio.create_task(session.append(start_sample=0, pcm16=bytes(320)))
            while not gov.snapshot().pending_batch:  # noqa: ASYNC110 -- observe actual admission queue
                await asyncio.sleep(0)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
        await session.cancel()
        events = trace.drain()
        assert [(e["phase"], e["status"]) for e in events] == [
            ("compute_queue", "cancelled"), ("close", "completed")
        ]
        assert worker.starts == 0 and worker.closes == 1
        assert not gov.diarization_owner.occupied
        assert not trace.status()["required_phases_observed"]

    asyncio.run(asyncio.wait_for(run(), 2))


def test_failed_reaping_is_a_failed_phase_and_keeps_owner_isolated():
    async def run():
        trace = PhaseTrace()
        gov = governor()
        worker = Worker(gov, failed_close=True)
        session = open_candidate_session(
            epoch="one", governor=gov, worker_factory=lambda: worker, phase_trace=trace
        )
        with pytest.raises(RuntimeError):
            await session.cancel()
        assert trace.drain()[0]["status"] == "failed"
        assert gov.diarization_owner.isolated and gov.diarization_owner.occupied

    asyncio.run(asyncio.wait_for(run(), 2))


def test_runner_drains_outside_compute_and_does_not_certify_injected_trace():
    from meeting_candidate_runner import FixedTextReplay, run_candidate_stream

    async def run():
        clock = Clock()
        trace = PhaseTrace(clock=clock, capacity=8)
        gov = governor()
        worker = Worker(gov)
        rows = []

        async def pcm():
            for _ in range(100):
                yield bytes(320)

        async def sink(row):
            if row["kind"] == "phase" and row["phase"] in {
                "compute_queue", "load", "infer", "finalize", "close"
            }:
                assert gov.snapshot().active_diarization == 0
                clock.now += 10  # Slow artifact writes must not inflate append work.
            rows.append(row)

        result = await run_candidate_stream(
            pcm(), activity_factory=lambda: open_candidate_session(
                epoch="session", governor=gov, worker_factory=lambda: worker, phase_trace=trace
            ), text_replay=FixedTextReplay(iter(())), epoch="session", sink=sink, clock=clock,
        )
        assert result["phase_trace_observed"]
        assert result["phase_trace"]["clock_source"] == "injected"
        assert result["phase_trace"]["event_count"] == 204
        assert not result["certification_eligible"] and not result["joint_asr_latency_observed"]
        assert all(r["duration_seconds"] == 0 for r in rows
                   if r.get("phase") == "activity_append_including_admission_and_load")
        assert {r["phase"] for r in rows if r["kind"] == "phase"} >= {
            "compute_queue", "load", "infer", "finalize", "close"
        }

    asyncio.run(asyncio.wait_for(run(), 2))


@pytest.mark.parametrize("fault", ["overflow", "raises"])
def test_observation_faults_cannot_prevent_exact_child_close(fault):
    async def run():
        clock = Clock()

        def throwing_clock():
            raise RuntimeError("private path must never escape")

        trace = PhaseTrace(capacity=1, clock=throwing_clock if fault == "raises" else clock)
        gov = governor()
        worker = Worker(gov)
        session = open_candidate_session(
            epoch="one", governor=gov, worker_factory=lambda: worker, phase_trace=trace
        )
        await session.append(start_sample=0, pcm16=bytes(320))
        await session.finish(through_sample=160)
        await session.cancel()
        assert worker.closes == 1 and not gov.diarization_owner.occupied
        assert not trace.status()["complete"]
        assert trace.status()["reason"] == (
            "invalid_clock" if fault == "raises" else "capacity_exceeded"
        )

    asyncio.run(asyncio.wait_for(run(), 2))


def test_phase_sink_failure_is_sanitized_after_reaping():
    from meeting_candidate_runner import FixedTextReplay, run_candidate_stream

    async def run():
        trace = PhaseTrace()
        gov = governor()
        worker = Worker(gov)

        async def pcm():
            yield bytes(320)

        async def sink(row):
            if row.get("phase") == "close":
                raise ValueError("private output")

        with pytest.raises(RuntimeError, match=r"^candidate_run_failed$"):
            await run_candidate_stream(
                pcm(), activity_factory=lambda: open_candidate_session(
                    epoch="session", governor=gov, worker_factory=lambda: worker, phase_trace=trace
                ), text_replay=FixedTextReplay(iter(())), epoch="session", sink=sink,
            )
        assert worker.closes == 1 and not gov.diarization_owner.occupied

    asyncio.run(asyncio.wait_for(run(), 2))
