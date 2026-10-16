"""Deterministic window scheduling and terminal barriers (no models)."""

import asyncio
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from speechrail.application.asr_window_coordinator import AsrWindowCoordinator
from speechrail.domain.asr_window import WindowDecodeResult, WindowIdentity, WindowPolicy
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.realtime.speech_admission import SpeechAdmission


class Decoder:
    def __init__(self):
        self.calls = []
        self.closed = False
        self.gate = None
        self.entered = asyncio.Event()

    async def decode(self, request):
        self.calls.append(request)
        self.entered.set()
        if self.gate is not None:
            await self.gate.wait()
        return WindowDecodeResult(
            request.identity,
            request.attempt_id,
            request.input_span,
            "修正正文" if request.kind == "review" else "预览",
            "Chinese",
            request.kind == "review",
        )

    async def close(self):
        self.closed = True


async def setup(scene="caption", **options):
    decoder = Decoder()
    events = []
    finals = []

    async def send(event):
        events.append(event)

    async def frozen(unit, pcm):
        finals.append((unit, pcm))

    coordinator = AsrWindowCoordinator(
        identity=WindowIdentity("session", 0, "window"),
        policy=WindowPolicy.for_scene(scene),
        scene=scene,
        decoder=decoder,
        send=send,
        on_final=frozen,
        **options,
    )
    return coordinator, decoder, events, finals


@pytest.mark.anyio
async def test_caption_closed_tail_is_previewed_before_context_review_is_due():
    c, d, events, _ = await setup()
    await c.append(0, bytes(4 * 16000 * 2))
    c.admit(SampleSpan(0, 4 * 16000))
    await c.flush_intents()
    assert d.calls and d.calls[0].kind == "preview"
    assert events[-1]["units"][0]["text"] == "预览"
    assert not any(event["type"].endswith("sealed") for event in events)
    await c.freeze()
    await c.close()


@pytest.mark.anyio
@pytest.mark.parametrize("permanent", [False, True])
async def test_closed_tail_preview_retries_once_after_backoff_without_waiting_for_review(permanent):
    now = [0.0]
    c, d, events, _ = await setup(clock=lambda: now[0])
    original = d.decode
    attempts = []

    async def transient(request):
        if request.kind == "preview":
            attempts.append(now[0])
            if permanent or len(attempts) == 1:
                raise RuntimeError("temporary decode failure")
        return await original(request)

    d.decode = transient
    try:
        await c.append(0, bytes(4 * 16000 * 2))
        c.admit(SampleSpan(0, 4 * 16000))
        await c.flush_intents()
        assert attempts == [0.0]
        now[0] = 0.1
        c.wake()
        await c.flush_intents()
        assert attempts == [0.0]
        now[0] = 0.5
        c.wake()
        await c.flush_intents()
        assert attempts == [0.0, 0.5]
        if not permanent:
            assert events[-1]["units"][0]["text"] == "预览"
        now[0] = 1.0
        c.wake()
        await c.flush_intents()
        assert attempts == [0.0, 0.5]
        assert not any(event["type"].endswith("sealed") for event in events)
        assert (await c.freeze()).failed_items_count == 0
    finally:
        await c.close()


@pytest.mark.anyio
async def test_same_text_preview_queued_during_review_gets_a_fresh_event_revision():
    now = [0.0]
    c, d, events, _ = await setup(clock=lambda: now[0])
    entered, release = asyncio.Event(), asyncio.Event()
    original = d.decode

    async def delayed_review(request):
        if request.kind == "review":
            entered.set()
            await release.wait()
        return await original(request)

    d.decode = delayed_review
    try:
        await c.append(0, bytes(4 * 16000 * 2))
        c.admit(SampleSpan(0, 4 * 16000))
        await c.flush_intents()
        await c.append(4 * 16000, bytes(16000 * 2))
        c.admit(SampleSpan(4 * 16000, 5 * 16000))
        await c.flush_intents()
        now[0] = 8.0
        c.wake()
        await entered.wait()
        await c.append(5 * 16000, bytes(16000 * 2))
        c.admit(SampleSpan(5 * 16000, 6 * 16000))
        release.set()
        await c.flush_intents()
        fingerprints = {}
        for event in events:
            if not event["type"].startswith("speechrail.transcription.window."):
                continue
            revision = event["window_revision"]
            body = json.dumps(event, sort_keys=True)
            assert fingerprints.setdefault(revision, body) == body
        assert any(event["type"].endswith("sealed") for event in events)
        await c.freeze()
    finally:
        release.set()
        await c.close()


@pytest.mark.anyio
async def test_window_resource_gauges_are_finite_and_clear_after_close():
    from speechrail.observability.metrics import Metrics

    metrics = Metrics()
    c, _, _, _ = await setup(metrics=metrics)
    await c.append(0, bytes(2 * 16000 * 2))
    c.admit(SampleSpan(0, 2 * 16000))
    assert (
        metrics.read_state().gauge_total("speechrail_asr_window_capture_backlog_samples") == 32000
    )
    assert metrics.read_state().gauge_total("speechrail_asr_window_retained_pcm_bytes") == 64000
    await c.freeze()
    await c.close()
    state = metrics.read_state()
    assert state.gauge_total("speechrail_asr_window_retained_pcm_bytes") == 0
    assert state.gauge_total("speechrail_asr_window_mutable_units") == 0


@pytest.mark.anyio
async def test_review_failure_diagnostic_identifies_decode_without_echoing_backend_message():
    from speechrail.observability.metrics import Metrics

    metrics = Metrics()
    c, decoder, events, _ = await setup(metrics=metrics)

    async def invalid(_request):
        raise ValueError("private text /private/model")

    decoder.decode = invalid
    await c.append(0, bytes(8000 * 2))
    c.admit(SampleSpan(0, 8000))
    assert (await c.freeze()).failed_items_count == 1
    state = metrics.read_state()
    assert state.counter_total("speechrail_asr_window_failures_total") == 1
    failed = next(e for e in events if e["type"].endswith("window.failed"))
    assert failed["failed_items"][0]["reason"] == "window_review_failed"
    assert "private" not in json.dumps(failed)
    await c.close()


@pytest.mark.anyio
async def test_caption_reports_three_sustained_lag_observations_while_decoder_waits():
    now = [0.0]
    c, d, events, _ = await setup(clock=lambda: now[0])
    d.gate = asyncio.Event()
    await c.append(0, bytes(16000 * 2))
    c.admit(SampleSpan(0, 16000))
    await d.entered.wait()
    for index in range(1, 5):
        now[0] = index * 0.5
        start = 16000 + (index - 1) * 8000
        await c.append(start, bytes(8000 * 2))
        c.admit(SampleSpan(start, start + 8000))
    assert c.falling_behind
    assert events[-1]["falling_behind"] is True
    assert len(d.calls) == 1  # status does not start another model operation
    d.gate.set()
    await c.flush_intents()
    assert not c.falling_behind and events[-1]["falling_behind"] is False
    await c.freeze()
    await c.close()


@pytest.mark.anyio
async def test_commit_reviews_without_preview_and_sends_transaction_before_terminal():
    c, d, events, finals = await setup()
    await c.append(0, b"\x00\x00" * 513)
    c.admit(SampleSpan(0, 513))
    receipt = await c.freeze()
    assert receipt.sealed_through_sample == 513
    assert receipt.failed_items_count == 0
    types = [e["type"] for e in events]
    assert (
        types.index("speechrail.transcription.window.sealed")
        < types.index("speechrail.transcription.segment_closed")
        < types.index("conversation.item.input_audio_transcription.completed")
    )
    assert len(finals) == 1 and len(finals[0][1]) == 1026
    assert all(call.kind == "review" for call in d.calls)
    assert c.ring.active_borrows == 0
    await c.close()


@pytest.mark.anyio
async def test_duplicate_freeze_is_idempotent_and_only_owns_accepted_input():
    c, _, events, _ = await setup()
    await c.append(0, bytes(1600))
    c.admit(SampleSpan(0, 800))
    first = c.freeze()
    assert first is c.freeze()
    await first
    assert len([e for e in events if e["type"].endswith("completed")]) == 1
    await c.append(800, bytes(320))
    c.admit(SampleSpan(800, 960))
    second = await c.freeze()
    assert second.sealed_through_sample == 960
    await c.close()


@pytest.mark.anyio
@pytest.mark.parametrize("scene", ["meeting", "caption"])
async def test_capture_backlog_is_twenty_seconds_before_any_successful_decode(scene):
    from speechrail.runtime.window_pcm import PcmBudgetExceededError

    c, _, _, _ = await setup(scene)
    try:
        await c.append(0, bytes(20 * 16000 * 2))
        charged = c.ring.charged_bytes
        with pytest.raises(PcmBudgetExceededError):
            await c.append(20 * 16000, bytes(2))
        assert c.ledger.accepted_samples == 20 * 16000
        assert c.ring.charged_bytes == charged
    finally:
        await c.close()


@pytest.mark.anyio
async def test_auxiliary_backlog_preserves_text_and_reports_unknown_without_pcm_copy():
    gate = asyncio.Event()
    unavailable = []
    events = []

    async def send(event):
        events.append(event)

    async def final(unit, pcm):
        return asyncio.create_task(gate.wait())

    async def missing(unit, reason):
        unavailable.append((unit.item_id, reason))

    c = AsrWindowCoordinator(
        identity=WindowIdentity("s", 0, "w"),
        policy=WindowPolicy.for_scene("caption"),
        decoder=Decoder(),
        send=send,
        on_final=final,
        on_auxiliary_unavailable=missing,
    )
    try:
        for index in range(3):
            await c.append(index * 16000, bytes(32000))
            c.admit(SampleSpan(index * 16000, (index + 1) * 16000))
            await c.freeze()
        assert len([e for e in events if e["type"].endswith("completed")]) == 3
        assert len(unavailable) == 1 and unavailable[0][1] == "alignment_overloaded"
        assert c.ring.active_borrows == 2
    finally:
        gate.set()
        await c.close()


@pytest.mark.anyio
async def test_silence_frontier_does_not_finalize_retained_preroll():
    c, _, events, _ = await setup()
    await c.append(0, bytes(32000))
    c.silence_before(11200)
    await c.flush_intents()
    assert c.ledger.sealed_through_sample == 11200
    c.admit(SampleSpan(11200, 16000))
    await c.freeze()
    coverage = [v for e in events if e["type"].endswith("sealed") for v in e["coverage"]]
    assert coverage[0]["outcome"] == "silence"
    assert coverage[1]["outcome"] == "speech"
    await c.close()


@pytest.mark.anyio
async def test_canceled_waiter_retains_pcm_until_actual_decode_finishes():
    c, d, _, _ = await setup()
    d.gate = asyncio.Event()
    await c.append(0, bytes(3200))
    c.admit(SampleSpan(0, 1600))
    barrier = c.freeze()
    await d.entered.wait()

    async def wait():
        return await asyncio.shield(barrier)

    waiter = asyncio.create_task(wait())
    waiter.cancel()
    with pytest.raises(asyncio.CancelledError):
        await waiter
    assert c.ring.active_borrows == 1
    d.gate.set()
    await barrier
    assert c.ring.active_borrows == 0
    await c.close()


@pytest.mark.anyio
async def test_failed_decode_emits_recovery_and_receipt_counts_failure():
    c, d, events, _ = await setup()

    async def fail(request):
        raise TimeoutError()

    d.decode = fail
    await c.append(0, bytes(1600))
    c.admit(SampleSpan(0, 800))
    receipt = await c.freeze()
    assert receipt.failed_items_count == 1
    assert len([e for e in events if e["type"].endswith("failed")]) == 2
    failed = next(e for e in events if e["type"].endswith("window.failed"))
    schema = json.loads(
        (Path(__file__).parents[1] / "contracts/realtime-events.schema.json").read_text()
    )
    Draft202012Validator(schema).validate({**failed, "event_id": "failed-test", "sequence": 1})
    assert "final_units" not in failed
    assert c.ledger.sealed_through_sample == 800
    await c.close()


@pytest.mark.parametrize("frames", [1, 10, 100])
def test_admission_retained_frontier_covers_candidate_and_prefix(frames):
    admission = SpeechAdmission(start_frames=3, prefix_samples=4800)
    for n in range(frames):
        admission.push(bytes(1024), start_sample=n * 512, probability=0)
    assert admission.retained_from_sample <= max(0, (frames - 9) * 512)
    frontier = admission.retained_from_sample
    admission.push(bytes(1024), start_sample=frames * 512, probability=1)
    assert admission.retained_from_sample == frontier


@pytest.mark.anyio
async def test_forced_adjacent_closed_blocks_are_reviewed_as_one_owned_interval():
    c, d, events, _ = await setup()
    await c.append(0, bytes(16000 * 2 * 8))
    c.admit(SampleSpan(0, 16000 * 8))
    await c.freeze()
    reviews = [call for call in d.calls if call.kind == "review"]
    assert [call.input_span for call in reviews] == [SampleSpan(0, 128000)]
    terminals = [e for e in events if e["type"].endswith("window.sealed")]
    assert len(terminals) == 1
    assert terminals[0]["final_units"][0]["owned_span"] == {"start": 0, "end": 192000}
    await c.close()


@pytest.mark.anyio
async def test_auxiliary_pcm_is_charged_until_actual_consumer_finishes():
    c, _, _, _ = await setup()
    done = asyncio.Event()
    task = None

    async def final(unit, pcm):
        nonlocal task

        async def consume():
            await done.wait()
            assert len(pcm) == 1600

        task = asyncio.create_task(consume())
        return task

    c._on_final = final
    await c.append(0, bytes(1600))
    c.admit(SampleSpan(0, 800))
    await c.freeze()
    assert c.ring.active_borrows == 1
    closing = asyncio.create_task(c.close())
    await asyncio.sleep(0)
    assert not closing.done()
    done.set()
    await closing
    assert c.ring.active_borrows == 0
