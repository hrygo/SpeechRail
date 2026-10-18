"""ASR-preserving diagnostic degradation, synthetic PCM and fake workloads."""

import asyncio
import hashlib

import pytest
from meeting_candidate_evidence import CompletedText

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.resource_governor import ResourceGovernor


def test_sealed_body_survives_observer_failure_and_requires_explicit_completion():
    from meeting_live_text import SealedBody

    body = SealedBody(samples=160)
    item = CompletedText(0, "甲乙", SampleSpan(0, 160))
    body.append(item)
    with pytest.raises(ValueError):
        body.items()
    body.finish()
    assert body.items() == (item,)
    assert body.summary()["text_sha256"] == hashlib.sha256("甲乙".encode()).hexdigest()
    assert "甲乙" not in str(body.summary())
    body.close()
    with pytest.raises(ValueError):
        body.items()


@pytest.mark.parametrize("failure", [
    None, "startup", "overflow", "self_cancel", "finish", "timing_budget",
])
def test_diarization_failure_preserves_entire_asr_body_and_does_not_pass_joint_gate(
    failure, monkeypatch,
):
    from meeting_activity_workload import run_shared_activity_stream
    from meeting_live_pipeline import run_live_meeting_pipeline

    from test_meeting_candidate_runner import Activity
    from test_meeting_pcm_feed import Clock

    if failure == "timing_budget":
        from meeting_timing import MeetingTiming

        monkeypatch.setattr(MeetingTiming, "MAX_PUBLICATION_RECORDS", 1)

    async def run():
        clock, output, closed = Clock(), [], []
        shared = ResourceGovernor(GovernorLimits(3, 1, 4), allow_heavy_overlap=False)

        async def asr(governor, frames, channel, body):
            assert governor is shared
            sequence = 0
            async for frame in frames:
                item = CompletedText(
                    sequence, "甲", SampleSpan(frame.start_sample, frame.end_sample)
                )
                sequence += 1
                body.append(item)
                body.record_terminal(frame.start_sample, frame.end_sample)
                channel.publish(item)
            body.finish()
            channel.finish()
            return {"complete": True}

        async def dia(governor, frames, channel, sink):
            assert governor is shared
            try:
                if failure == "startup":
                    raise RuntimeError("private error must not enter output")
                if failure == "self_cancel":
                    raise asyncio.CancelledError
                if failure == "overflow":
                    await asyncio.Event().wait()
                result = await run_shared_activity_stream(
                    bytes(200), frames, activity_factory=Activity, epoch="session",
                    sink=sink, text_channel=channel,
                )
                if failure == "finish":
                    await asyncio.Event().wait()
                return result
            finally:
                closed.append(True)

        async def sink(row):
            output.append(row)

        result = await asyncio.wait_for(run_live_meeting_pipeline(
            pcm=bytes(200), expected_pcm_sha256=hashlib.sha256(bytes(200)).hexdigest(),
            governor=shared, asr=asr, diarization=dia, sink=sink,
            max_lateness_seconds=1, chunk_samples=10, queue_chunks=16,
            diarization_queue_chunks=16 if failure != "overflow" else 1,
            finish_timeout_seconds=.01, clock=clock, sleep=clock.sleep,
        ), 2)
        assert result["asr_complete"] is True
        assert result["pcm_feed"]["delivered_samples"]["asr"] == 100
        assert closed == [True]
        assert result["certification_eligible"] is False
        snapshots = [row for row in output if row["kind"] == "asr_body_snapshot"]
        if failure is None:
            assert result["live_attribution_complete"] is True
            timing = result["timing_observations"]
            assert timing["source_samples_observed"] == timing["asr_sealed_through"] == 100
            assert timing["dia_stable_through"] == 100
            assert timing["text_delivery_verified"] is True
            assert timing["clock_source"] == "injected"
            assert timing["latency_gate"] == "not_evaluated"
            assert timing["stable_label_p95_seconds"] is None
            assert "甲" not in str(timing)
            assert not snapshots
            assert "".join(r["text"] for r in output if r["kind"] == "text") == "甲" * 10
        else:
            assert result["live_attribution_complete"] is False
            assert result["joint_verdict"] == "no-go"
            assert len(snapshots) == 1 and snapshots[0]["replaces_all_attribution"] is True
            assert "".join(r["text"] for r in snapshots[0]["items"]) == "甲" * 10
            assert all(r["speaker"] is None for r in snapshots[0]["items"])
            assert "private error" not in str(result) + str(output)

    asyncio.run(run())


@pytest.mark.parametrize("broken_dia", [False, True])
def test_actual_formal_session_populates_independent_body_even_when_dia_fails(broken_dia):
    from meeting_activity_workload import run_shared_activity_stream
    from meeting_live_pipeline import run_live_meeting_pipeline
    from meeting_realtime_asr_replay import replay_realtime_session

    from test_meeting_candidate_runner import Activity
    from test_meeting_pcm_feed import Clock
    from test_meeting_realtime_asr_replay import case, observe, setup

    async def run():
        services, _, _, spec = setup()
        data, output, clock = case(), [], Clock()

        async def asr(shared, frames, channel, body):
            assert shared is services.governor
            return await replay_realtime_session(
                data, spec, services, observe=observe(spec), input_mode="shared_pcm",
                pcm_frames=frames, text_channel=channel, sealed_body=body,
            )

        async def dia(shared, frames, channel, sink):
            if broken_dia:
                raise RuntimeError("synthetic DIA failure")
            return await run_shared_activity_stream(
                data.pcm16, frames, activity_factory=Activity, epoch="session",
                sink=sink, text_channel=channel,
            )

        async def sink(row):
            output.append(row)

        overlap = services.governor.snapshot().allow_heavy_overlap
        result = await asyncio.wait_for(run_live_meeting_pipeline(
            pcm=data.pcm16, expected_pcm_sha256=hashlib.sha256(data.pcm16).hexdigest(),
            governor=services.governor, asr=asr, diarization=dia, sink=sink,
            mode="overlap" if overlap else "serial", overlap_enabled=overlap,
            max_lateness_seconds=1, chunk_samples=16000, clock=clock, sleep=clock.sleep,
        ), 3)
        assert result["asr_complete"] is True
        assert result["asr_body"]["text_characters"] == 2
        assert result["timing_observations"]["asr_sealed_through"] == len(data.pcm16) // 2
        if broken_dia:
            snapshot = next(r for r in output if r["kind"] == "asr_body_snapshot")
            assert "".join(item["text"] for item in snapshot["items"]) == "甲乙"
        else:
            assert result["live_attribution_complete"] is True

    asyncio.run(run())


@pytest.mark.parametrize("fault", ["sequence", "span", "shape", "units", "characters", "reused"])
def test_sealed_body_rejects_invalid_or_reused_items_without_returning_partial_body(fault):
    from meeting_live_text import SealedBody

    body = SealedBody(samples=160)
    if fault == "reused":
        body.finish()
    item = CompletedText(
        1 if fault == "sequence" else 0,
        "甲" * (10001 if fault == "characters" else 1),
        None if fault == "shape" else SampleSpan(0, 161 if fault == "span" else 160),
        [] if fault == "units" else (),
    )
    with pytest.raises(ValueError):
        body.append(item)
    assert body.summary()["complete"] is False
    with pytest.raises(ValueError):
        body.items()


def policy_arguments():
    from test_meeting_pcm_feed import Clock

    clock = Clock()
    return {
        "pcm": bytes(20), "expected_pcm_sha256": hashlib.sha256(bytes(20)).hexdigest(),
        "governor": ResourceGovernor(GovernorLimits(3, 1, 4), allow_heavy_overlap=False),
        "max_lateness_seconds": 1, "chunk_samples": 10, "clock": clock, "sleep": clock.sleep,
    }


@pytest.mark.parametrize("fault", [
    "asr", "asr_cancel", "sink", "sink_cancel", "sink_timeout", "source",
])
def test_asr_or_sink_or_source_failures_cannot_be_reported_as_successful_degradation(
    fault, monkeypatch,
):
    import meeting_live_pipeline as module

    async def run():
        output, closed = [], []

        async def asr(shared, frames, channel, body):
            try:
                if fault == "asr_cancel":
                    raise asyncio.CancelledError
                async for frame in frames:
                    item = CompletedText(0, "甲", SampleSpan(frame.start_sample, frame.end_sample))
                    body.append(item)
                    body.record_terminal(frame.start_sample, frame.end_sample)
                    channel.publish(item)
                if fault == "asr":
                    raise RuntimeError("private ASR failure")
                body.finish()
                channel.finish()
                return {"complete": True}
            finally:
                closed.append("asr")

        async def dia(shared, frames, channel, sink):
            try:
                raise RuntimeError("private DIA failure")
            finally:
                closed.append("dia")

        async def sink(row):
            if fault == "sink":
                raise RuntimeError("private sink failure")
            if fault == "sink_cancel":
                raise asyncio.CancelledError
            if fault == "sink_timeout":
                try:
                    await asyncio.sleep(1)
                except asyncio.CancelledError:
                    return
            output.append(row)

        if fault == "source":
            calls = []

            def digests():
                calls.append(True)
                return {"pipeline": str(len(calls))}

            monkeypatch.setattr(module, "_source_digests", digests)
        with pytest.raises(ValueError, match=r"^live meeting pipeline failed$"):
            await asyncio.wait_for(module.run_live_meeting_pipeline(
                **policy_arguments(), asr=asr, diarization=dia, sink=sink,
                sink_timeout_seconds=.01,
            ), 1)
        assert sorted(closed) == ["asr", "dia"]
        assert not output
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith("live-")]

    asyncio.run(run())


def test_repeated_external_cancellation_joins_nested_native_cleanup_before_return():
    from meeting_live_pipeline import run_live_meeting_pipeline

    from speechrail.runtime.cleanup import join_cleanup

    async def run():
        entered, cleaning, release = asyncio.Event(), asyncio.Event(), asyncio.Event()
        closed = []

        async def asr(shared, frames, channel, body):
            async for _ in frames:
                pass
            entered.set()
            await asyncio.Event().wait()
            return {"complete": True}

        async def dia(shared, frames, channel, sink):
            try:
                await asyncio.Event().wait()
            finally:
                cleaning.set()
                await join_cleanup(asyncio.create_task(release.wait()))
                closed.append(True)

        async def sink(row):
            raise AssertionError("cancelled case must not publish a fallback snapshot")

        task = asyncio.create_task(run_live_meeting_pipeline(
            **policy_arguments(), asr=asr, diarization=dia, sink=sink,
        ))
        try:
            await asyncio.wait_for(entered.wait(), 1)
            task.cancel()
            await asyncio.wait_for(cleaning.wait(), 1)
            task.cancel()
            await asyncio.sleep(0)
            assert not task.done()
        finally:
            release.set()
            with pytest.raises(asyncio.CancelledError):
                await task
        assert closed == [True]
        assert not [t for t in asyncio.all_tasks() if t.get_name().startswith("live-")]

    asyncio.run(run())


def test_dia_finish_deadline_starts_at_input_eof_even_if_asr_final_review_is_pending():
    from meeting_live_pipeline import run_live_meeting_pipeline

    async def run():
        dia_closed, output = asyncio.Event(), []

        async def asr(shared, frames, channel, body):
            async for frame in frames:
                item = CompletedText(0, "甲", SampleSpan(frame.start_sample, frame.end_sample))
                body.append(item)
                body.record_terminal(frame.start_sample, frame.end_sample)
                channel.publish(item)
            await dia_closed.wait()
            body.finish()
            channel.finish()
            return {"complete": True}

        async def dia(shared, frames, channel, sink):
            try:
                async for _ in frames:
                    pass
                await asyncio.Event().wait()
            finally:
                dia_closed.set()

        async def sink(row):
            output.append(row)

        result = await asyncio.wait_for(run_live_meeting_pipeline(
            **policy_arguments(), asr=asr, diarization=dia, sink=sink,
            finish_timeout_seconds=.01,
        ), .5)
        assert result["asr_preserved_as_unknown"] is True
        assert result["diarization_failure"] == "diarization_finish_timeout"
        assert len(output) == 1

    asyncio.run(run())


@pytest.mark.parametrize("fault", ["boolean", "mutating"])
def test_joint_completion_uses_strict_counts_and_the_same_immutable_report_as_its_digest(
    fault, monkeypatch,
):
    import meeting_live_pipeline as module
    from meeting_activity_workload import run_shared_activity_stream

    from test_meeting_candidate_runner import Activity

    async def run():
        original_report, output = {}, []
        actual_digest = module._report_digest

        def digest(report):
            value = actual_digest(report)
            if fault == "mutating" and report.get("asr_text_source") == "live_sealed_session":
                original_report.update(
                    text_characters=1, emitted_text_characters=1,
                    asr_text_sha256=hashlib.sha256("甲".encode()).hexdigest(),
                )
            return value

        monkeypatch.setattr(module, "_report_digest", digest)

        async def asr(shared, frames, channel, body):
            async for frame in frames:
                item = CompletedText(0, "甲", SampleSpan(frame.start_sample, frame.end_sample))
                body.append(item)
                body.record_terminal(frame.start_sample, frame.end_sample)
                channel.publish(item)
            body.finish()
            channel.finish()
            return {"complete": True}

        async def dia(shared, frames, channel, sink):
            report = await run_shared_activity_stream(
                bytes(20), frames, activity_factory=Activity, epoch="session",
                sink=sink, text_channel=channel,
            )
            report.update(text_characters=True if fault == "boolean" else 0)
            original_report.update(report)
            return original_report

        async def sink(row):
            output.append(row)

        result = await module.run_live_meeting_pipeline(
            **policy_arguments(), asr=asr, diarization=dia, sink=sink,
        )
        assert result["live_attribution_complete"] is False
        assert result["joint_verdict"] == "no-go"
        assert output[-1]["kind"] == "asr_body_snapshot"

    asyncio.run(run())


@pytest.mark.parametrize("fault", ["missing", "different", "duplicate", "span"])
def test_actual_sink_delivery_must_match_body_even_when_dia_report_claims_complete(fault):
    from meeting_activity_workload import run_shared_activity_stream
    from meeting_live_pipeline import run_live_meeting_pipeline

    from test_meeting_candidate_runner import Activity

    async def run():
        output = []

        async def asr(shared, frames, channel, body):
            async for frame in frames:
                item = CompletedText(0, "甲", SampleSpan(frame.start_sample, frame.end_sample))
                body.append(item)
                body.record_terminal(frame.start_sample, frame.end_sample)
                channel.publish(item)
            body.finish()
            channel.finish()
            return {"complete": True}

        async def dia(shared, frames, channel, sink):
            async def corrupted(row):
                if row["kind"] == "text":
                    if fault == "missing":
                        return
                    row = dict(row)
                    if fault == "different":
                        row["text"] = "乙"
                    if fault == "span":
                        row["start_sample"] += 1
                    if fault == "duplicate":
                        await sink(row)
                await sink(row)

            return await run_shared_activity_stream(
                bytes(20), frames, activity_factory=Activity, epoch="session",
                sink=corrupted, text_channel=channel,
            )

        async def sink(row):
            output.append(row)

        result = await run_live_meeting_pipeline(
            **policy_arguments(), asr=asr, diarization=dia, sink=sink,
        )
        assert result["live_attribution_complete"] is False
        assert result["timing_observations"]["text_delivery_verified"] is False
        assert result["timing_observations"]["missing_or_invalid_text_units"] == 1
        assert result["joint_verdict"] == "no-go"
        assert output[-1]["kind"] == "asr_body_snapshot"
        assert output[-1]["items"][0]["text"] == "甲"

    asyncio.run(run())
