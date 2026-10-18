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
