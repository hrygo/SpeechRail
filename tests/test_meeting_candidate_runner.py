"""Bounded replay consumes activity while feeding; no real models are used."""

from __future__ import annotations

import asyncio
import wave

import pytest
from meeting_candidate_evidence import CompletedText
from meeting_candidate_runner import (
    FixedTextReplay,
    ScheduledText,
    iter_wav_pcm,
    run_candidate_stream,
)

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate


async def bounded_run(*args, **kwargs):
    """Regressions must fail in seconds rather than wait for a meeting deadline."""
    return await asyncio.wait_for(run_candidate_stream(*args, **kwargs), timeout=2)


class Activity:
    def __init__(self, *, broken=False):
        self.queue = asyncio.Queue(1)
        self.end = self.step = self.cancels = 0
        self.broken = broken
        self.consumed = 0

    async def append(self, *, start_sample, pcm16):
        assert start_sample == self.end
        if self.broken:
            raise RuntimeError("private transcription must never escape in errors")
        self.end += len(pcm16) // 2
        await self.queue.put(
            ActivityUpdate(
                "session",
                self.step,
                SampleSpan(start_sample, self.end),
                (ActivityFrame(SampleSpan(start_sample, self.end), None, frozenset({0})),),
                self.end,
                self.end,
            )
        )
        self.step += 1

    async def updates(self):
        while (event := await self.queue.get()) is not None:
            self.consumed += 1
            yield event

    async def finish(self, *, through_sample):
        assert through_sample == self.end
        await self.queue.put(None)

    async def cancel(self):
        self.cancels += 1


async def pcm(packets=100):
    for _ in range(packets):
        yield bytes(320)


def replay():
    return FixedTextReplay(
        iter([ScheduledText(16000, CompletedText(0, "hello", SampleSpan(0, 16000)))])
    )


def test_consumer_drains_during_input_and_text_is_attributed_without_reference():
    async def run():
        activity, output = Activity(), []

        async def sink(event):
            output.append(event)

        result = await asyncio.wait_for(
            bounded_run(
                pcm(100),
                activity_factory=lambda: activity,
                text_replay=replay(),
                epoch="session",
                sink=sink,
                input_mode="throughput",
            ),
            timeout=2,
        )
        assert activity.consumed == 100
        assert activity.cancels == 1
        assert result["complete"] is True
        assert result["accepted_samples"] == result["processed_samples"] == 16000
        assert result["text_characters"] == result["emitted_text_characters"] == 5
        assert result["certified_max_speakers"] is None
        assert result["joint_asr_latency_observed"] is False
        assert result["clock_scope"] == "diarization_with_fixed_asr_sidecar"
        assert result["stable_label_p95_seconds"] is None
        texts = [e for e in output if e["kind"] == "text"]
        assert texts[0]["text"] == "hello" and texts[0]["speaker"] == "S1"
        spans = [e for e in output if e["kind"] == "activity"]
        assert [(e["start_sample"], e["end_sample"]) for e in spans] == [(0, 16000)]

    asyncio.run(run())


def test_unavailable_activity_is_failure_and_cleanup_is_exactly_once():
    async def run():
        activity = Activity(broken=True)
        output = []

        async def sink(event):
            output.append(event)

        with pytest.raises(RuntimeError, match="candidate_run_failed") as error:
            await bounded_run(
                pcm(1),
                activity_factory=lambda: activity,
                text_replay=FixedTextReplay(iter([])),
                epoch="session",
                sink=sink,
            )
        assert "private transcription" not in str(error.value)
        assert activity.cancels == 1

    asyncio.run(run())


@pytest.mark.parametrize("bad_input", [True, False])
def test_input_and_sink_failures_cancel_activity_and_do_not_return_success(bad_input):
    async def run():
        activity = Activity()

        async def source():
            yield bytes(320)
            if bad_input:
                yield bytes(32001)
            else:
                yield bytes(320)

        async def sink(event):
            if not bad_input:
                raise ValueError("private sink failure")

        with pytest.raises(RuntimeError, match="candidate_run_failed"):
            await bounded_run(
                source(),
                activity_factory=lambda: activity,
                text_replay=FixedTextReplay(iter([])),
                epoch="session",
                sink=sink,
            )
        assert activity.cancels == 1

    asyncio.run(run())


def test_cancellation_joins_consumer_and_reaps_before_returning():
    async def run():
        activity = Activity()
        entered, release = asyncio.Event(), asyncio.Event()

        async def source():
            yield bytes(320)
            entered.set()
            await release.wait()

        async def sink(event):
            pass

        task = asyncio.create_task(
            bounded_run(
                source(),
                activity_factory=lambda: activity,
                text_replay=FixedTextReplay(iter([])),
                epoch="session",
                sink=sink,
            )
        )
        await asyncio.wait_for(entered.wait(), timeout=2)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert activity.cancels == 1
        assert not [t for t in asyncio.all_tasks() if t.get_name() == "candidate-activity-pump"]

    asyncio.run(run())


def test_fixed_replay_does_not_offer_future_asr_text_or_invent_post_finish_samples():
    source = FixedTextReplay(
        iter([ScheduledText(32000, CompletedText(0, "future", SampleSpan(0, 32000)))])
    )
    assert source.ready(16000) == ()
    with pytest.raises(ValueError, match="accepted"):
        source.finish(16000)


def test_empty_input_does_not_open_a_worker():
    async def run():
        async def source():
            for _ in ():
                yield b""

        def factory():
            pytest.fail("empty input must not claim a worker")

        async def sink(event):
            pass

        with pytest.raises(RuntimeError, match="candidate_run_failed"):
            await bounded_run(
                source(),
                activity_factory=factory,
                text_replay=FixedTextReplay(iter([])),
                epoch="session",
                sink=sink,
            )

    asyncio.run(run())


def test_wav_reader_is_bounded_and_validates_format_before_first_packet(tmp_path):
    path = tmp_path / "synthetic.wav"
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        output.writeframes(bytes(32002))

    async def run():
        parts = [p async for p in iter_wav_pcm(path)]
        assert [len(p) for p in parts] == [32000, 2]
        with wave.open(str(path), "wb") as output:
            output.setparams((2, 2, 16000, 0, "NONE", "not compressed"))
            output.writeframes(bytes(320))
        with pytest.raises(ValueError, match="mono"):
            _ = [p async for p in iter_wav_pcm(path)]

    asyncio.run(run())


def test_real_candidate_session_uses_shared_owner_and_reaps_after_pipeline_finish():
    from meeting_candidate_session import open_candidate_session

    from test_meeting_candidate_session import Worker, governor

    async def run():
        gov = governor()
        worker, events = Worker(gov), []

        async def sink(event):
            events.append(event)

        result = await bounded_run(
            pcm(),
            activity_factory=lambda: open_candidate_session(
                epoch="session", governor=gov, worker_factory=lambda: worker
            ),
            text_replay=replay(),
            epoch="session",
            sink=sink,
        )
        assert result["complete"]
        assert worker.starts == worker.closes == worker.finishes == 1
        assert not gov.diarization_owner.occupied
        assert next(e for e in events if e["kind"] == "text")["speaker"] == "S2"

    asyncio.run(run())


def test_failed_reclamation_is_not_reported_as_success_or_cancellation():
    from meeting_candidate_session import open_candidate_session

    from test_meeting_candidate_session import Worker, governor

    async def run():
        gov = governor()
        worker = Worker(gov, failed_close=True)

        async def sink(event):
            pass

        with pytest.raises(RuntimeError, match="candidate_cleanup_incomplete"):
            await bounded_run(
                pcm(1),
                activity_factory=lambda: open_candidate_session(
                    epoch="session", governor=gov, worker_factory=lambda: worker
                ),
                text_replay=FixedTextReplay(iter([])),
                epoch="session",
                sink=sink,
            )
        assert gov.diarization_owner.occupied
        assert gov.diarization_owner.isolated

    asyncio.run(run())


def test_realtime_pacing_uses_sample_clock_without_drift_but_does_not_certify_joint_latency():
    async def run():
        now, waits = [0.0], []
        activity = Activity()

        async def sleep(delay):
            waits.append(delay)
            now[0] += delay

        async def sink(event):
            pass

        result = await bounded_run(
            pcm(100),
            activity_factory=lambda: activity,
            text_replay=replay(),
            epoch="session",
            sink=sink,
            input_mode="realtime",
            clock=lambda: now[0],
            sleep=sleep,
        )
        assert sum(waits) == pytest.approx(1)
        assert result["input_finished_at_seconds"] == pytest.approx(1)
        assert result["max_input_lateness_seconds"] == 0
        assert result["joint_asr_latency_observed"] is False

    asyncio.run(run())


def test_overall_deadline_stops_blocked_input_and_joins_cleanup():
    async def run():
        activity = Activity()

        async def source():
            yield bytes(320)
            await asyncio.Event().wait()

        async def sink(event):
            pass

        with pytest.raises(RuntimeError, match="candidate_run_timeout"):
            await bounded_run(
                source(),
                activity_factory=lambda: activity,
                text_replay=FixedTextReplay(iter([])),
                epoch="session",
                sink=sink,
                timeout_seconds=0.01,
            )
        assert activity.cancels == 1

    asyncio.run(run())


def test_slow_sink_has_a_bounded_failure_and_still_cleans_up():
    async def run():
        activity = Activity()

        async def sink(event):
            await asyncio.Event().wait()

        with pytest.raises(RuntimeError, match="candidate_run_failed"):
            await asyncio.wait_for(
                bounded_run(
                    pcm(2),
                    activity_factory=lambda: activity,
                    text_replay=FixedTextReplay(iter([])),
                    epoch="session",
                    sink=sink,
                    sink_timeout_seconds=0.01,
                ),
                timeout=2,
            )
        assert activity.cancels == 1

    asyncio.run(run())


def test_premature_activity_end_cannot_be_reported_as_complete():
    class EarlyActivity(Activity):
        async def updates(self):
            yield await self.queue.get()

    async def run():
        activity = EarlyActivity()

        async def sink(event):
            await asyncio.sleep(0)

        with pytest.raises(RuntimeError, match="candidate_run_failed"):
            await bounded_run(
                pcm(2),
                activity_factory=lambda: activity,
                text_replay=FixedTextReplay(iter([])),
                epoch="session",
                sink=sink,
            )
        assert activity.cancels == 1

    asyncio.run(run())


def test_activity_cannot_close_while_final_asr_sidecar_items_are_being_registered():
    class EarlyActivity(Activity):
        async def updates(self):
            yield await self.queue.get()

        async def finish(self, *, through_sample):
            pass

    async def run():
        activity = EarlyActivity()
        source = FixedTextReplay(
            iter(
                [ScheduledText(160, CompletedText(0, "tail", SampleSpan(0, 160)), finish_only=True)]
            )
        )

        async def sink(event):
            if event["kind"] == "asr_text_ready":
                await asyncio.sleep(0)

        with pytest.raises(RuntimeError, match="candidate_run_failed"):
            await bounded_run(
                pcm(1),
                activity_factory=lambda: activity,
                text_replay=source,
                epoch="session",
                sink=sink,
            )
        assert activity.cancels == 1

    asyncio.run(run())


def test_empty_buffering_updates_are_consumed_without_waiting_for_tail_watermark():
    class BufferingActivity(Activity):
        async def append(self, *, start_sample, pcm16):
            assert start_sample == self.end
            self.end += len(pcm16) // 2
            await self.queue.put(ActivityUpdate("session", self.step, SampleSpan(0, 0), (), 0, 0))
            self.step += 1

        async def finish(self, *, through_sample):
            await self.queue.put(
                ActivityUpdate(
                    "session",
                    self.step,
                    SampleSpan(0, self.end),
                    (ActivityFrame(SampleSpan(0, self.end), None, frozenset({0})),),
                    self.end,
                    self.end,
                )
            )
            await self.queue.put(None)

    async def run():
        activity = BufferingActivity()

        async def sink(event):
            pass

        result = await asyncio.wait_for(
            bounded_run(
                pcm(2),
                activity_factory=lambda: activity,
                text_replay=FixedTextReplay(iter([])),
                epoch="session",
                sink=sink,
            ),
            timeout=2,
        )
        assert result["complete"]
        assert result["accepted_samples"] == result["processed_samples"] == 320

    asyncio.run(run())


def test_irregular_packets_and_final_sample_share_the_exact_attribution_clock():
    from meeting_candidate_session import open_candidate_session

    from test_meeting_candidate_session import Worker, governor

    async def run():
        gov = governor()
        worker, output = Worker(gov), []

        async def source():
            for samples in (1, 159, 321, 1):
                yield bytes(samples * 2)

        async def sink(event):
            output.append(event)

        text_source = FixedTextReplay(
            iter([ScheduledText(482, CompletedText(0, "tail", SampleSpan(0, 482)))])
        )
        result = await bounded_run(
            source(),
            activity_factory=lambda: open_candidate_session(
                epoch="session", governor=gov, worker_factory=lambda: worker
            ),
            text_replay=text_source,
            epoch="session",
            sink=sink,
        )
        assert result["accepted_samples"] == result["processed_samples"] == 482
        activity = [e for e in output if e["kind"] == "activity"]
        assert [(e["start_sample"], e["end_sample"]) for e in activity] == [(0, 482)]
        assert next(e for e in output if e["kind"] == "text")["speaker"] == "S2"

    asyncio.run(run())


def test_wav_reader_rejects_non_regular_inputs_before_open(tmp_path):
    async def run():
        with pytest.raises(ValueError, match="regular"):
            _ = [packet async for packet in iter_wav_pcm(tmp_path)]

    asyncio.run(run())


def test_activity_only_has_no_observed_asr_body():
    async def run():
        activity, output = Activity(), []

        async def sink(event):
            output.append(event)

        result = await bounded_run(
            pcm(3), activity_factory=lambda: activity, text_replay=None,
            epoch="session", sink=sink,
        )
        assert result["complete"] is True
        assert result["accepted_samples"] == result["processed_samples"] == 480
        assert result["clock_scope"] == "diarization_activity_only"
        assert result["asr_text_sha256"] is None
        assert result["asr_text_source"] == "not_observed"
        assert result["joint_asr_latency_observed"] is False
        assert not any(e["kind"] in {"text", "asr_text_ready"} for e in output)
        assert len([e for e in output if e["kind"] == "activity_watermark"]) == 3
        frames = [e for e in output if e["kind"] == "stable_activity_frame"]
        assert [(e["start_sample"], e["end_sample"]) for e in frames] == [
            (0, 160), (160, 320), (320, 480),
        ]
        assert all(e["active_slots"] == [0] for e in frames)
        assert all(0 <= e["observed_at_seconds"] <= e["elapsed_seconds"] for e in frames)
        # One continuous speaker run only closes at finish; those final spans
        # must not erase the earlier stable-frame observation times.
        assert len([e for e in output if e["kind"] == "activity"]) == 1
        assert activity.cancels == 1

    asyncio.run(run())


def test_common_feed_runs_activity_adapter_with_original_governor_and_tail():
    import hashlib

    from bench_asr_diarization_overlap import run_pcm_workload_schedule
    from meeting_activity_workload import run_shared_activity_stream

    from speechrail.domain.resource_limits import GovernorLimits
    from speechrail.runtime.resource_governor import ResourceGovernor, WorkClass

    async def run():
        shared = ResourceGovernor(GovernorLimits(3, 1, 4), allow_heavy_overlap=False)
        activity, reports, output = Activity(), [], []
        original = b"\x01\x00" * 481

        class GovernedActivity(Activity):
            async def append(self, *, start_sample, pcm16):
                async with shared.reserve(WorkClass.DIARIZATION):
                    await super().append(start_sample=start_sample, pcm16=pcm16)

        activity = GovernedActivity()

        async def sink(event):
            output.append(event)

        async def workload(received, frames):
            assert received is shared
            report = await run_shared_activity_stream(
                original, frames, activity_factory=lambda: activity,
                epoch="session", sink=sink,
            )
            reports.append(report)
            return report

        result = await asyncio.wait_for(run_pcm_workload_schedule(
            pcm=original, expected_pcm_sha256=hashlib.sha256(original).hexdigest(),
            mode="diarization-only", governor=shared, diarization=workload,
            chunk_samples=160, max_lateness_seconds=1,
        ), 2)
        assert result["schedule_completed"] is True
        assert result["certification_eligible"] is False
        assert reports[0]["processed_samples"] == 481
        assert reports[0]["shared_pcm"] == {"frames_verified": 4, "samples_verified": 481}
        assert activity.cancels == 1
        assert not shared.diarization_owner.occupied
        watermarks = [e for e in output if e["kind"] == "activity_watermark"]
        assert [e["stable_samples"] for e in watermarks] == [160, 320, 480, 481]

    asyncio.run(run())


@pytest.mark.parametrize("bad", [None, "bytes", "sequence", "short", "origin", "clock"])
def test_shared_activity_verifies_actual_source_and_joins_cleanup(bad):
    from dataclasses import replace

    from meeting_activity_workload import run_shared_activity_stream
    from meeting_pcm_feed import PcmChunk

    async def run():
        activity, output, closed = Activity(), [], []
        original = b"\x01\x00" * 7
        chunks = [
            PcmChunk(0, 0, 3, 10 + 3 / 16000, 10 + 3 / 16000, original[:6]),
            PcmChunk(1, 3, 7, 10 + 7 / 16000, 10 + 7 / 16000, original[6:]),
        ]
        if bad == "bytes":
            chunks[1] = replace(chunks[1], pcm=bytes(8))
        elif bad == "sequence":
            chunks[1] = replace(chunks[1], sequence=2)
        elif bad == "short":
            chunks.pop()
        elif bad == "origin":
            chunks[1] = replace(chunks[1], target_at=11., offered_at=11.)
        elif bad == "clock":
            chunks[1] = replace(chunks[1], offered_at=True)

        async def frames():
            try:
                for chunk in chunks:
                    yield chunk
            finally:
                closed.append(True)

        async def sink(event):
            output.append(event)

        call = run_shared_activity_stream(
            original, frames(), activity_factory=lambda: activity,
            epoch="session", sink=sink,
        )
        if bad is not None:
            with pytest.raises(RuntimeError, match="candidate_run_failed"):
                await asyncio.wait_for(call, 2)
        else:
            result = await asyncio.wait_for(call, 2)
            assert result["accepted_samples"] == result["processed_samples"] == 7
            assert result["input_mode"] == "shared_pcm"
            assert result["input_clock"] == "external_shared_source_unverified"
            assert result["shared_pcm"] == {"frames_verified": 2, "samples_verified": 7}
            assert result["asr_text_source"] == "not_observed"
            assert result["certification_eligible"] is False
        assert activity.cancels == 1
        assert closed == [True]
        assert not any(e["kind"] == "text" for e in output)

    asyncio.run(run())


def test_shared_activity_closes_source_when_startup_rejects_clock():
    from meeting_activity_workload import run_shared_activity_stream

    class Source:
        closed = reads = 0

        def __aiter__(self):
            return self

        async def __anext__(self):
            self.reads += 1
            raise AssertionError("invalid startup must not read the source")

        async def aclose(self):
            self.closed += 1

    async def run():
        source = Source()

        async def sink(event):
            raise AssertionError("invalid startup must not emit")

        with pytest.raises(ValueError, match="clock"):
            await run_shared_activity_stream(
                bytes(2), source, activity_factory=Activity, epoch="session", sink=sink,
                clock=lambda: True,
            )
        assert source.closed == 1 and source.reads == 0

    asyncio.run(run())


@pytest.mark.parametrize("self_cancel", [False, True])
def test_activity_pump_self_cancel_fails_without_waiting_for_input_deadline(self_cancel):
    class CancelledActivity(Activity):
        async def updates(self):
            if self_cancel:
                asyncio.current_task().cancel()
                await asyncio.sleep(0)
            raise asyncio.CancelledError
            yield  # Async generator, even when no update is produced.

    async def run():
        activity, source_closed = CancelledActivity(), []

        async def source():
            try:
                yield bytes(2)
                await asyncio.Event().wait()
            finally:
                source_closed.append(True)

        async def sink(event):
            pass

        with pytest.raises(RuntimeError, match="candidate_run_failed"):
            await asyncio.wait_for(
                run_candidate_stream(
                    source(), activity_factory=lambda: activity, text_replay=None,
                    epoch="session", sink=sink,
                ), .2,
            )
        assert source_closed == [True] and activity.cancels == 1

    asyncio.run(run())


def test_repeated_cancellation_joins_activity_reaping_and_source_close():
    async def run():
        consuming, reaping, release = asyncio.Event(), asyncio.Event(), asyncio.Event()
        closed = []

        class SlowActivity(Activity):
            async def cancel(self):
                self.cancels += 1
                reaping.set()
                await release.wait()

        activity = SlowActivity()

        async def source():
            try:
                yield bytes(320)
                consuming.set()
                await asyncio.Event().wait()
            finally:
                closed.append(True)

        async def sink(event):
            pass

        task = asyncio.create_task(run_candidate_stream(
            source(), activity_factory=lambda: activity, text_replay=None,
            epoch="session", sink=sink,
        ))
        try:
            await asyncio.wait_for(consuming.wait(), 1)
            task.cancel()
            await asyncio.wait_for(reaping.wait(), 1)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done()
        finally:
            release.set()
            with pytest.raises(asyncio.CancelledError):
                await task
        assert closed == [True] and activity.cancels == 1
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith("candidate-activity")]

    asyncio.run(run())
