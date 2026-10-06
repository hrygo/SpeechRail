"""Production ingress, policy and frozen-item ownership regression vectors."""

import asyncio
import base64
import contextlib
from itertools import pairwise

import pytest

from realtime_wire import server_vad, session_update
from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.backends.vad import VadEvent
from speechrail.compatibility.openai_realtime import RealtimeAdapterError
from speechrail.domain.audio_timeline import RationalResampler
from speechrail.domain.ports import StreamingAsrEvent
from test_realtime_admission_commits import _build
from test_realtime_openai import FakeStreamingSession


def _policy_update():
    update = session_update(turn_detection="manual")
    update["session"]["speechrail"]["asr"] = {
        "preview_interval_ms": 100,
        "max_segment_ms": 1000,
        "finalization": "full_segment",
        "final_deadline_ms": 1000,
    }
    return update


def test_failed_input_recovery_joins_teardown_and_terminal_delivery():
    async def run():
        services, factory = _build()
        cleanup_entered = asyncio.Event()
        cleanup_release = asyncio.Event()
        cleanup_finished = asyncio.Event()
        terminal_sending = asyncio.Event()
        terminal_release = asyncio.Event()

        class BlockedCleanup(FakeStreamingSession):
            async def close(self):
                cleanup_entered.set()
                await cleanup_release.wait()
                await super().close()
                cleanup_finished.set()

        factory.session_class = lambda: BlockedCleanup
        sent = []

        async def send(event):
            if event["type"].endswith("transcription.failed"):
                terminal_sending.set()
                await terminal_release.wait()
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="failure-recovery", send=send)
        await session._update_session(_policy_update())
        append = {
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(bytes(4800)).decode(),
        }
        await session._append_audio(append)
        runtime = factory.sessions[0]
        await runtime.events_queue.put(
            StreamingAsrEvent(kind="error", error_code="backend_error")
        )
        await runtime.events_queue.put(None)
        await asyncio.wait_for(terminal_sending.wait(), timeout=1)
        await asyncio.wait_for(cleanup_entered.wait(), timeout=1)
        recovery = asyncio.create_task(session._append_audio(append))
        try:
            assert not recovery.done()
            assert len(factory.sessions) == 1
            cleanup_release.set()
            await asyncio.wait_for(cleanup_finished.wait(), timeout=1)
            # Joining cleanup must not cancel an in-flight terminal send.
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(asyncio.shield(recovery), timeout=0.05)
        finally:
            cleanup_release.set()
            terminal_release.set()
            await asyncio.wait_for(recovery, timeout=1)
            await session._commit_audio()
            await session.close()
        failures = [e for e in sent if e["type"].endswith("transcription.failed")]
        completions = [e for e in sent if e["type"].endswith("transcription.completed")]
        assert len(failures) == len(completions) == 1
        assert failures[0]["item_id"] != completions[0]["item_id"]
        assert len(factory.sessions) == len(factory.released) == 2

    asyncio.run(run())


@pytest.mark.parametrize("first_samples", [1, 25, 80, 81])
def test_manual_commits_keep_exact_wire_anchors_and_single_sample_tail(first_samples):
    async def run():
        services, factory = _build()
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="short-tail", send=send)
        await session._update_session(_policy_update())
        first = (500).to_bytes(2, "little", signed=True) * first_samples
        second = (-300).to_bytes(2, "little", signed=True)
        for audio in (first, second):
            await session._append_audio({
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(audio).decode(),
            })
            await session._commit_audio()
        boundaries = [e for e in sent if e["type"].endswith("segment_closed")]
        assert [e["sample_span"] for e in boundaries] == [
            {"start": 0, "end": first_samples},
            {"start": first_samples, "end": first_samples + 1},
        ]
        resampler = RationalResampler(24000, 16000)
        expected = b"".join(
            resampler.process(audio) + resampler.flush() for audio in (first, second)
        )
        received = b"".join(chunk for item in factory.sessions for chunk in item.received)
        assert received == expected
        terminals = [e for e in sent if e["type"].endswith(("completed", "failed"))]
        assert len(terminals) == 2
        assert {e["item_id"] for e in terminals} == {e["item_id"] for e in boundaries}
        await session.close()

    asyncio.run(run())


@pytest.mark.parametrize("failure", ["missing_terminal", "timeout"])
def test_failed_barrier_is_not_repaired_by_retry_but_new_input_can_complete(failure):
    async def run():
        services, factory = _build()

        class FailureOnce(FakeStreamingSession):
            async def commit(self, want_segments=False):
                if len(factory.sessions) == 1:
                    if failure == "timeout":
                        raise TimeoutError
                    await self.events_queue.put(None)
                    return
                await super().commit(want_segments=want_segments)

        factory.session_class = lambda: FailureOnce
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="barrier-recovery", send=send)
        await session._update_session(_policy_update())
        append = {
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(bytes(160)).decode(),
        }
        try:
            await session._append_audio(append)
            for event_id in ("failed", "failed-retry"):
                with pytest.raises(RealtimeAdapterError) as rejected:
                    await session._commit_audio(
                        commit_event_id=event_id, request_receipt=True,
                    )
                assert rejected.value.code == (
                    "backend_timeout" if failure == "timeout" else "backend_error"
                )
            assert not any(e["type"].endswith("buffer.committed") for e in sent)
            assert len([e for e in sent if e["type"].endswith("transcription.failed")]) == 1
            assert len(factory.released) == 1
            await session._append_audio(append)
            await session._commit_audio(commit_event_id="new-input", request_receipt=True)
            receipts = [e for e in sent if e["type"].endswith("buffer.committed")]
            assert len(receipts) == 1
            assert receipts[0]["commit_event_id"] == "new-input"
            assert receipts[0]["accepted_samples"] == 160
            completions = [e for e in sent if e["type"].endswith("transcription.completed")]
            assert len(completions) == 1
            assert completions[0]["commit_event_id"] == "new-input"
            assert len(factory.released) == 2
        finally:
            await session.close()

    asyncio.run(run())


@pytest.mark.parametrize(
    ("task_set", "drain"),
    [
        ("_alignment_tasks", "_wait_for_pending_alignment"),
        ("_asr_finals", "_await_asr_finals"),
    ],
)
def test_drain_removes_completed_tasks_without_waiting_for_callbacks(task_set, drain):
    async def run():
        services, _ = _build()

        async def send(event):
            return 1

        async def finish():
            return None

        session = OpenAIRealtimeSession(services, session_id="done-drain", send=send)
        task = asyncio.create_task(finish())
        await task
        owned = getattr(session, task_set)
        owned.add(task)
        task.add_done_callback(owned.discard)
        # The discard callback is scheduled for the next loop tick. Draining
        # an already done task must not spin synchronously until that tick.
        await getattr(session, drain)()
        assert not owned
        await session.close()

    asyncio.run(run())


@pytest.mark.parametrize("packet_samples", [768, 1001, 2400, 24_000, 26_000])
def test_packet_boundaries_do_not_change_admitted_pcm_or_frozen_spans(packet_samples):
    async def run():
        services, factory = _build(
            max_realtime_buffer_bytes=512_000,
            max_realtime_frame_bytes=128_000,
        )
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="asr-vector", send=send)
        await session._update_session(_policy_update())
        wire = b"".join((i % 1024).to_bytes(2, "little") for i in range(57_601))
        for start in range(0, len(wire), packet_samples * 2):
            await session._append_audio({
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(wire[start:start + packet_samples * 2]).decode(),
            })
        await session._commit_audio(commit_event_id="commit-vector", request_receipt=True)
        resampler = RationalResampler(24_000, 16_000)
        expected = resampler.process(wire) + resampler.flush()
        received = b"".join(chunk for item in factory.sessions for chunk in item.received)
        assert received == expected
        assert [b"".join(item.received) for item in factory.sessions] == [
            expected[:32_000], expected[32_000:64_000], expected[64_000:],
        ]
        boundaries = [e for e in sent if e["type"] == "speechrail.transcription.segment_closed"]
        finals = [
            e for e in sent
            if e["type"] == "conversation.item.input_audio_transcription.completed"
        ]
        assert len(boundaries) == len(finals) == 3
        assert [b["reason"] for b in boundaries] == [
            "budget_rollover", "budget_rollover", "client_commit",
        ]
        assert [b["sample_span"] for b in boundaries] == [
            {"start": 0, "end": 24_000},
            {"start": 24_000, "end": 48_000},
            {"start": 48_000, "end": 57_601},
        ]
        assert boundaries[0]["sample_span"]["start"] == 0
        assert boundaries[-1]["sample_span"]["end"] == 57_601
        for left, right in pairwise(boundaries):
            assert left["sample_span"]["end"] == right["sample_span"]["start"]
        assert {b["item_id"] for b in boundaries} == {f["item_id"] for f in finals}
        for boundary in boundaries:
            final = next(f for f in finals if f["item_id"] == boundary["item_id"])
            assert sent.index(boundary) < sent.index(final)
        assert boundaries[-1]["commit_event_id"] == "commit-vector"
        assert not any("commit_event_id" in b for b in boundaries[:-1])
        assert session._asr_lane.retained_bytes == 0
        await session.close()

    asyncio.run(run())


def test_vad_stop_after_full_budget_does_not_move_the_previous_item_end():
    async def run():
        services, factory = _build(
            realtime_speech_admission_enabled=False,
            realtime_vad_engine="legacy",
        )
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        class StopOnSecondPacket:
            in_speech = True

            def __init__(self):
                self.calls = 0

            def process_chunk(self, pcm):
                self.calls += 1
                return [VadEvent(
                    is_speech=self.calls == 1,
                    speech_started=self.calls == 1,
                    speech_ended=self.calls == 2,
                )]

            def reset(self):
                pass

        session = OpenAIRealtimeSession(services, session_id="vad-budget", send=send)
        update = session_update(endpointing=server_vad())
        update["session"]["speechrail"]["asr"] = _policy_update()["session"]["speechrail"]["asr"]
        await session._update_session(update)
        session._vad = StopOnSecondPacket()
        wire = (500).to_bytes(2, "little", signed=True) * 26_400
        try:
            for pcm in (wire[:48_000], wire[48_000:]):
                await session._append_audio({
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(pcm).decode(),
                })
            await session._await_asr_finals()
            boundaries = [e for e in sent if e["type"].endswith("segment_closed")]
            assert [e["sample_span"] for e in boundaries] == [
                {"start": 0, "end": 24_000},
                {"start": 24_000, "end": 26_400},
            ]
            assert [e["reason"] for e in boundaries] == ["budget_rollover", "vad"]
            resampler = RationalResampler(24_000, 16_000)
            expected = resampler.process(wire)
            assert [b"".join(item.received) for item in factory.sessions] == [
                expected[:32_000], expected[32_000:],
            ]
        finally:
            await session.close()

    asyncio.run(run())


def test_empty_success_is_one_terminal_after_a_real_segment_boundary():
    async def run():
        services, factory = _build()
        factory.completed_text = ""
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="empty-vector", send=send)
        await session._update_session(_policy_update())
        await session._append_audio({
            "type": "input_audio_buffer.append", "audio": base64.b64encode(bytes(4800)).decode(),
        })
        await session._commit_audio()
        await session._commit_audio()
        terminals = [e for e in sent if e["type"].endswith((".completed", ".failed"))]
        assert len(terminals) == 1
        assert terminals[0]["transcript"] == ""
        assert len([e for e in sent if e["type"].endswith("segment_closed")]) == 1
        assert len(factory.released) == 1
        await session.close()

    asyncio.run(run())


def test_preview_uses_decoded_snapshot_watermark_and_policy_is_frozen():
    async def run():
        services, factory = _build()
        sent = []
        preview_sent = asyncio.Event()

        async def send(event):
            sent.append(event)
            if event["type"] == "speechrail.transcription.hypothesis":
                preview_sent.set()
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="snapshot-vector", send=send)
        update = _policy_update()
        await session._update_session(update)
        await session._append_audio({
            "type": "input_audio_buffer.append", "audio": base64.b64encode(bytes(24_000)).decode(),
        })
        # Updating unrelated session settings must preserve the same policy.
        await session._update_session(update)
        await session._update_session(session_update(turn_detection="manual"))
        changed = _policy_update()
        changed["session"]["speechrail"]["asr"]["preview_interval_ms"] = 200
        with pytest.raises(RealtimeAdapterError, match="policy cannot change"):
            await session._update_session(changed)
        await factory.sessions[0].events_queue.put(
            StreamingAsrEvent(kind="partial", text="revised", sample_watermark=1000)
        )
        await asyncio.wait_for(preview_sent.wait(), timeout=1)
        preview = next(e for e in sent if e["type"] == "speechrail.transcription.hypothesis")
        assert preview["sample_span"] == {"start": 0, "end": 1500}
        assert preview["stable_prefix_codepoints"] == 0
        await session._commit_audio()
        await session.close()

    asyncio.run(run())


def test_backlog_overflow_fails_retained_items_and_rejects_false_barrier():
    async def run():
        services, factory = _build(
            max_realtime_buffer_bytes=512_000, max_realtime_frame_bytes=240_000
        )
        blocked = asyncio.Event()

        class BlockedFinal(FakeStreamingSession):
            async def commit(self, want_segments=False):
                await blocked.wait()

        factory.session_class = lambda: BlockedFinal
        sent = []
        all_failed = asyncio.Event()

        async def send(event):
            sent.append(event)
            if len([e for e in sent if e["type"].endswith("transcription.failed")]) == 3:
                all_failed.set()
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="overflow-vector", send=send)
        await session._update_session(_policy_update())
        with pytest.raises(RealtimeAdapterError, match="capacity exhausted"):
            await session._append_audio({
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(bytes(240_000)).decode(),
            })
        await asyncio.wait_for(all_failed.wait(), timeout=1)
        failures = [e for e in sent if e["type"].endswith("transcription.failed")]
        assert len({e["item_id"] for e in failures}) == 3
        assert all(e["error"]["code"] == "asr_buffer_overflow" for e in failures)
        with pytest.raises(RealtimeAdapterError, match="rejected audio"):
            await session._commit_audio(request_receipt=True)
        assert not any(e["type"].endswith("buffer.committed") for e in sent)
        assert session._asr_lane.retained_bytes == 0
        await session._clear_audio()
        await session.close()

    asyncio.run(run())


def test_clear_discards_resampler_tail_before_new_input():
    async def run():
        services, factory = _build()
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="clear-vector", send=send)
        await session._update_session(_policy_update())
        first = (30000).to_bytes(2, "little", signed=True) * 25
        await session._append_audio({
            "type": "input_audio_buffer.append", "audio": base64.b64encode(first).decode(),
        })
        await session._clear_audio()
        second = (-30000).to_bytes(2, "little", signed=True) * 100
        await session._append_audio({
            "type": "input_audio_buffer.append", "audio": base64.b64encode(second).decode(),
        })
        await session._commit_audio()
        received = b"".join(factory.sessions[-1].received)
        assert received and {
            int.from_bytes(received[i:i + 2], "little", signed=True)
            for i in range(0, len(received), 2)
        } == {-30000}
        await session.close()

    asyncio.run(run())


def test_client_commit_interrupted_by_clear_fails_explicitly():
    """#294: a client commit awaiting its final must not leak CancelledError.

    Clear cancels in-flight finals after delivering the failed terminal;
    the commit caller sees input_cleared, and new input still completes.
    """

    async def run():
        services, factory = _build()
        entered = asyncio.Event()
        release = asyncio.Event()

        class SlowFinal(FakeStreamingSession):
            async def commit(self, want_segments=False):
                entered.set()
                await release.wait()
                return await super().commit(want_segments=want_segments)

        factory.session_class = lambda: SlowFinal
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="commit-clear", send=send)
        await session._update_session(_policy_update())
        await session._append_audio({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(bytes(4800)).decode(),
        })
        pending = asyncio.create_task(session._commit_audio(reason="client"))
        await asyncio.wait_for(entered.wait(), timeout=1)
        assert not pending.done()
        await asyncio.wait_for(session._clear_audio(), timeout=2)
        with pytest.raises(RealtimeAdapterError) as exc_info:
            await asyncio.wait_for(asyncio.shield(pending), timeout=5)
        assert exc_info.value.code == "input_cleared"
        release.set()
        with contextlib.suppress(RealtimeAdapterError, asyncio.CancelledError):
            await asyncio.wait_for(pending, timeout=5)
        # The cleared item already got its failed terminal; new input completes.
        await session._append_audio({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(bytes(4800)).decode(),
        })
        await session._commit_audio(reason="client", request_receipt=True)
        assert any(e["type"].endswith("transcription.failed") for e in sent)
        assert any(e["type"].endswith("transcription.completed") for e in sent)
        await session.close()

    asyncio.run(run())


def test_clear_gives_closed_pending_items_one_failed_terminal():
    async def run():
        services, factory = _build(max_realtime_buffer_bytes=512_000)
        entered = asyncio.Event()

        class BlockedFinal(FakeStreamingSession):
            async def commit(self, want_segments=False):
                entered.set()
                await asyncio.Event().wait()

        factory.session_class = lambda: BlockedFinal
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="clear-closed", send=send)
        await session._update_session(_policy_update())
        await session._append_audio({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(bytes(52_800)).decode(),
        })
        await asyncio.wait_for(entered.wait(), timeout=1)
        boundaries = [e for e in sent if e["type"].endswith("segment_closed")]
        assert len(boundaries) == 1
        await session._clear_audio()
        terminals = [e for e in sent if e["type"].endswith(("completed", "failed"))]
        assert len(terminals) == 1
        assert terminals[0]["item_id"] == boundaries[0]["item_id"]
        assert terminals[0]["type"].endswith("transcription.failed")
        assert terminals[0]["error"]["code"] == "backend_error"
        assert len([e for e in sent if e["type"].endswith("segment_closed")]) == 1
        assert not session._asr_finals
        assert len(factory.released) == 1
        # A new empty input still succeeds; it cannot reuse the canceled item.
        await session._commit_audio()
        assert sent[-1]["type"].endswith("transcription.completed")
        assert sent[-1]["transcript"] == ""
        assert sent[-1]["item_id"] != boundaries[0]["item_id"]
        await session.close()

    asyncio.run(run())
