"""Bounded sealed-body transport; synthetic observations, no audio or models."""

import asyncio

import pytest
from meeting_candidate_evidence import CompletedText

from speechrail.domain.audio_timeline import SampleSpan


def test_live_channel_delivers_actual_timed_body_and_explicit_eof():
    from meeting_live_text import LiveTextChannel

    async def run():
        channel = LiveTextChannel(samples=160, queue_items=2, clock=lambda: 12.5)
        item = CompletedText(0, "甲乙", SampleSpan(0, 160))
        assert channel.publish(item)
        channel.finish()
        rows = [row async for row in channel]
        assert len(rows) == 1 and rows[0].item is item
        assert rows[0].observed_at == 12.5
        assert channel.summary()["consumer_exhausted"] is True
        assert channel.summary()["clock_source"] == "injected"
        assert "甲乙" not in str(channel.summary())
        await channel.aclose()
        assert channel.summary()["failed"] is False

    asyncio.run(run())


@pytest.mark.parametrize("fault", ["overflow", "bytes_budget", "sequence", "span", "clock"])
def test_live_channel_failure_is_bounded_wakes_reader_and_never_blocks_producer(fault):
    from meeting_live_text import LiveTextChannel

    async def run():
        channel = LiveTextChannel(
            samples=320, queue_items=1, queue_characters=2,
            clock=lambda: True if fault == "clock" else 10.,
        )
        item = CompletedText(0, "甲", SampleSpan(0, 160))
        if fault == "bytes_budget":
            item = CompletedText(0, "甲乙丙", SampleSpan(0, 160))
        elif fault == "sequence":
            item = CompletedText(1, "甲", SampleSpan(0, 160))
        elif fault == "span":
            item = CompletedText(0, "甲", SampleSpan(0, 321))
        if fault == "overflow":
            assert channel.publish(item)
            item = CompletedText(1, "乙", SampleSpan(160, 320))
        assert channel.publish(item) is False
        assert channel.summary()["failed"] is True
        assert channel.summary()["queued_items"] == 0
        with pytest.raises(RuntimeError, match="live_text_stream_failed"):
            await asyncio.wait_for(anext(channel), .2)
        channel.finish()
        assert channel.publish(item) is False
        await channel.aclose()

    asyncio.run(run())


def test_live_reader_close_detaches_without_cancelling_asr_publisher():
    from meeting_live_text import LiveTextChannel

    async def run():
        channel = LiveTextChannel(samples=160)
        reader = asyncio.create_task(anext(channel))
        await asyncio.sleep(0)
        reader.cancel()
        with pytest.raises(asyncio.CancelledError):
            await reader
        await channel.aclose()
        assert channel.publish(CompletedText(0, "正文仍由ASR保留", SampleSpan(0, 160))) is False
        assert channel.summary()["failed"] is True

    asyncio.run(run())


def test_actual_terminal_receiver_transfers_owned_spans_not_preview_or_reference():
    from meeting_live_text import LiveTextChannel
    from meeting_realtime_asr_replay import _Terminals

    async def run():
        channel = LiveTextChannel(samples=8)
        receiver = _Terminals(8, set(), text_channel=channel)
        await receiver.send({"type": "speechrail.transcription.window.preview", "text": "ignore"})
        await receiver.send({
            "type": "speechrail.transcription.window.sealed",
            "closed_span": {"start": 0, "end": 12},
            "coverage": [{"span": {"start": 0, "end": 12}, "outcome": "speech"}],
            "final_units": [
                {"owned_span": {"start": 6, "end": 12}, "text": "乙"},
                {"owned_span": {"start": 0, "end": 6}, "text": "甲"},
            ],
        })
        channel.finish()
        rows = [row.item async for row in channel]
        assert [(r.sequence, r.text, r.span) for r in rows] == [
            (0, "甲", SampleSpan(0, 4)), (1, "乙", SampleSpan(4, 8)),
        ]
        assert not any(row.units for row in rows)
        assert receiver.finals == ["甲", "乙"]

    asyncio.run(run())


@pytest.mark.parametrize("detach", [False, True])
def test_formal_asr_preserves_its_quality_body_when_live_observer_detaches(detach):
    from meeting_live_text import LiveTextChannel
    from meeting_realtime_asr_replay import replay_realtime_session

    from test_meeting_realtime_asr_replay import case, observe, setup

    async def run():
        services, _, _, spec = setup()
        data = case()
        channel = LiveTextChannel(samples=len(data.pcm16) // 2)
        if detach:
            await channel.aclose()
        result = await replay_realtime_session(
            data, spec, services, observe=observe(spec), text_channel=channel,
        )
        assert result["quality_evidence_valid"] is True
        if detach:
            assert result["diagnostics"]["live_text"]["failed"] is True
        else:
            rows = [r.item async for r in channel]
            assert "".join(r.text for r in rows) == "甲乙"
            assert channel.summary()["producer_finished"] is True
        await channel.aclose()

    asyncio.run(run())


def test_common_pcm_formal_asr_body_reaches_activity_attribution_without_sidecar():
    import hashlib

    from meeting_activity_workload import run_shared_activity_stream
    from meeting_live_text import LiveTextChannel
    from meeting_pcm_feed import CommonPcmFeed
    from meeting_realtime_asr_replay import replay_realtime_session

    from test_meeting_candidate_runner import Activity
    from test_meeting_pcm_feed import Clock
    from test_meeting_realtime_asr_replay import case, observe, setup

    async def run():
        services, _, _, spec = setup()
        data, output, activity = case(), [], Activity()
        channel = LiveTextChannel(samples=len(data.pcm16) // 2)
        clock = Clock()
        feed = CommonPcmFeed(
            data.pcm16, expected_pcm_sha256=hashlib.sha256(data.pcm16).hexdigest(),
            lanes=("asr", "diarization"), chunk_samples=16000, queue_chunks=8,
            max_lateness_seconds=1, clock=clock, sleep=clock.sleep,
        )

        async def sink(event):
            output.append(event)

        try:
            async with asyncio.TaskGroup() as tasks:
                tasks.create_task(feed.produce())
                asr = tasks.create_task(replay_realtime_session(
                    data, spec, services, observe=observe(spec), input_mode="shared_pcm",
                    pcm_frames=feed.stream("asr"), text_channel=channel,
                ))
                dia = tasks.create_task(run_shared_activity_stream(
                    data.pcm16, feed.stream("diarization"), activity_factory=lambda: activity,
                    epoch="session", sink=sink, text_channel=channel,
                ))
            assert asr.result()["quality_evidence_valid"] is True
            assert dia.result()["asr_text_source"] == "live_sealed_session"
            assert dia.result()["text_characters"] == dia.result()["emitted_text_characters"] == 2
            texts = [row for row in output if row["kind"] == "text"]
            assert "".join(row["text"] for row in texts) == "甲乙"
            assert all(
                row["speaker"] == "S1" and row["granularity"] == "utterance" for row in texts
            )
            ready = [row for row in output if row["kind"] == "asr_text_ready"]
            assert all(row["producer_observed_at"] > 0 for row in ready)
            assert channel.summary()["consumer_exhausted"] is True
            assert not channel.summary()["failed"]
            assert activity.cancels == 1
            assert dia.result()["certification_eligible"] is False
        finally:
            feed.close()

    asyncio.run(asyncio.wait_for(run(), 3))


def test_replay_startup_failure_wakes_waiting_live_reader():
    from meeting_live_text import LiveTextChannel
    from meeting_realtime_asr_replay import replay_realtime_session

    from test_meeting_realtime_asr_replay import case, observe, setup

    async def run():
        services, _, _, spec = setup()
        data = case()
        channel = LiveTextChannel(samples=len(data.pcm16) // 2)
        reader = asyncio.create_task(anext(channel))
        with pytest.raises(ValueError, match="wire packets"):
            await replay_realtime_session(
                data, spec, services, observe=observe(spec), text_channel=channel,
                wire_packet_samples=0,
            )
        with pytest.raises(RuntimeError, match="live_text_stream_failed"):
            await asyncio.wait_for(reader, .2)
        await channel.aclose()

    asyncio.run(run())


def test_reused_producer_channel_cannot_deliver_an_earlier_runs_body():
    from meeting_live_text import LiveTextChannel

    async def run():
        channel = LiveTextChannel(samples=160)
        assert channel.claim_producer()
        assert channel.publish(CompletedText(0, "旧正文", SampleSpan(0, 160)))
        channel.finish()
        assert channel.claim_producer() is False
        with pytest.raises(RuntimeError, match="live_text_stream_failed"):
            await anext(channel)
        assert channel.summary()["queued_items"] == 0
        await channel.aclose()

    asyncio.run(run())


@pytest.mark.parametrize("short_audio", [False, True])
def test_live_text_waits_for_actual_activity_acceptance_and_rejects_short_audio(short_audio):
    from meeting_candidate_runner import run_candidate_stream
    from meeting_live_text import LiveTextChannel

    from test_meeting_candidate_runner import Activity

    async def run():
        gate, entered = asyncio.Event(), asyncio.Event()
        output, activity = [], Activity()
        channel = LiveTextChannel(samples=160)
        assert channel.publish(CompletedText(0, "甲", SampleSpan(0, 160)))
        channel.finish()

        async def source():
            entered.set()
            await gate.wait()
            yield bytes(160 if short_audio else 320)

        async def sink(row):
            output.append(row)

        task = asyncio.create_task(run_candidate_stream(
            source(), activity_factory=lambda: activity, text_replay=None,
            text_channel=channel, epoch="session", sink=sink,
        ))
        await entered.wait()
        await asyncio.sleep(0)
        assert not output
        gate.set()
        if short_audio:
            with pytest.raises(RuntimeError, match="candidate_run_failed"):
                await asyncio.wait_for(task, .5)
            assert channel.summary()["failed"] is True
        else:
            result = await asyncio.wait_for(task, .5)
            assert result["complete"] is True
            ready = [row for row in output if row["kind"] == "asr_text_ready"]
            assert ready[0]["accepted_samples"] == 160
            assert ready[0]["producer_observed_at"] > 0
        assert activity.cancels == 1

    asyncio.run(run())
