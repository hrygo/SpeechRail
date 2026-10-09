"""Realtime clear control must cancel a frozen final without retiring the socket."""

import asyncio
import queue
import threading
import time
from collections.abc import Callable
from typing import Any

import pytest

from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.compatibility.openai_realtime import RealtimeAdapterError
from speechrail.config import Settings
from speechrail.domain.audio_timeline import RationalResampler
from speechrail.domain.ports import StreamingAsrEvent
from test_realtime_openai import (
    FakeStreamingFactory,
    FakeStreamingSession,
    _client,
    _pcm16,
    session_update,
)


class _BlockedFinalSession(FakeStreamingSession):
    """Hold the first final until clear cancels it or the test releases it."""

    def __init__(self, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self.commit_started = threading.Event()
        self.commit_cancelled = threading.Event()
        self.close_started = threading.Event()
        self._release_final = asyncio.Event()
        self._loop: asyncio.AbstractEventLoop | None = None

    async def commit(self, want_segments: bool = False) -> None:
        del want_segments
        self._loop = asyncio.get_running_loop()
        self.commit_started.set()
        try:
            await self._release_final.wait()
        except asyncio.CancelledError:
            self.commit_cancelled.set()
            raise

    async def close(self) -> None:
        self.close_started.set()
        await super().close()

    def release_from_test_thread(self) -> None:
        loop = self._loop
        if loop is not None and loop.is_running():
            loop.call_soon_threadsafe(self._release_final.set)


class _BlockFirstFinalFactory(FakeStreamingFactory):
    def __init__(self, blocked_type: type[_BlockedFinalSession] = _BlockedFinalSession) -> None:
        super().__init__()
        self._blocked_type = blocked_type
        self.first_session_created = threading.Event()
        self.first_session_released = threading.Event()
        self.blocked_session: _BlockedFinalSession | None = None

    def session_class(self) -> type[FakeStreamingSession]:
        return self._blocked_type if not self.sessions else FakeStreamingSession

    def create(self, **kwargs: Any) -> FakeStreamingSession:
        session = super().create(**kwargs)
        if isinstance(session, _BlockedFinalSession):
            self.blocked_session = session
        self.first_session_created.set()
        return session

    def release(self, session: FakeStreamingSession) -> None:
        super().release(session)
        if session is self.blocked_session:
            self.first_session_released.set()


class _SocketEventPump:
    """Read the synchronous TestClient socket with bounded main-thread waits."""

    def __init__(self, socket: Any) -> None:
        self._socket = socket
        self._events: queue.Queue[dict[str, Any] | BaseException] = queue.Queue()
        self.seen: list[dict[str, Any]] = []
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        while True:
            try:
                event = self._socket.receive_json()
            except BaseException as exc:
                self._events.put(exc)
                return
            self._events.put(event)

    def receive(self, timeout: float = 2.0) -> dict[str, Any]:
        try:
            event = self._events.get(timeout=timeout)
        except queue.Empty as exc:
            pytest.fail(f"timed out waiting for a Realtime event after {timeout:.1f}s")
            raise AssertionError from exc
        if isinstance(event, BaseException):
            raise AssertionError("Realtime WebSocket closed before the expected event") from event
        self.seen.append(event)
        return event

    def until(
        self,
        predicate: Callable[[dict[str, Any]], bool],
        *,
        timeout: float = 2.0,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                pytest.fail(f"timed out waiting for a matching Realtime event after {timeout:.1f}s")
            event = self.receive(remaining)
            if predicate(event):
                return event

    def join(self, timeout: float = 2.0) -> None:
        self._reader.join(timeout)


def test_clear_cancels_frozen_client_final_and_keeps_socket_usable() -> None:
    factory = _BlockFirstFinalFactory()
    client, _ = _client(factory=factory)
    pump: _SocketEventPump | None = None

    try:
        with client.websocket_connect("/v1/realtime") as socket:
            assert socket.receive_json()["type"] == "session.created"
            pump = _SocketEventPump(socket)
            blocked: _BlockedFinalSession | None = None
            try:
                socket.send_json({
                    "type": "input_audio_buffer.append",
                    "audio": _pcm16(b"\x00\x00" * 8),
                })
                socket.send_json({
                    "type": "input_audio_buffer.commit",
                    "event_id": "blocked-final",
                    "speechrail": {"request_receipt": True},
                })

                boundary = pump.until(
                    lambda event: event["type"] == "speechrail.transcription.segment_closed"
                )
                assert boundary["reason"] == "client_commit"
                assert factory.first_session_created.wait(2.0)
                blocked = factory.blocked_session
                assert blocked is not None
                assert blocked.commit_started.wait(2.0)

                socket.send_json({"type": "input_audio_buffer.clear"})
                failed = pump.until(
                    lambda event: (
                        event.get("item_id") == boundary["item_id"]
                        and event["type"]
                        in {
                            "conversation.item.input_audio_transcription.completed",
                            "conversation.item.input_audio_transcription.failed",
                        }
                    )
                )
                assert failed["type"] == "conversation.item.input_audio_transcription.failed"
                assert failed["commit_event_id"] == "blocked-final"
                assert blocked.commit_cancelled.wait(2.0)
                assert blocked.close_started.wait(2.0)
                assert factory.first_session_released.wait(2.0)
                canceled_barrier = pump.until(
                    lambda event: (
                        event["type"] == "error"
                        and event["error"].get("event_id") == "blocked-final"
                    )
                )
                assert canceled_barrier["error"]["code"] == "invalid_state"

                socket.send_json({
                    "type": "input_audio_buffer.append",
                    "audio": _pcm16(b"\x01\x00" * 8),
                })
                socket.send_json({
                    "type": "input_audio_buffer.commit",
                    "event_id": "fresh-final",
                    "speechrail": {"request_receipt": True},
                })
                fresh_boundary = pump.until(
                    lambda event: (
                        event["type"] == "speechrail.transcription.segment_closed"
                        and event.get("item_id") != boundary["item_id"]
                    )
                )
                fresh_terminal = pump.until(
                    lambda event: (
                        event.get("item_id") == fresh_boundary["item_id"]
                        and event["type"]
                        in {
                            "conversation.item.input_audio_transcription.completed",
                            "conversation.item.input_audio_transcription.failed",
                        }
                    )
                )
                receipt = pump.until(
                    lambda event: (
                        event["type"] == "speechrail.input_audio_buffer.committed"
                        and event.get("commit_event_id") == "fresh-final"
                    )
                )

                old_terminals = [
                    event
                    for event in pump.seen
                    if event.get("item_id") == boundary["item_id"]
                    and event["type"]
                    in {
                        "conversation.item.input_audio_transcription.completed",
                        "conversation.item.input_audio_transcription.failed",
                    }
                ]
                assert [event["type"] for event in old_terminals] == [
                    "conversation.item.input_audio_transcription.failed"
                ]
                assert not any(
                    event["type"] == "speechrail.input_audio_buffer.committed"
                    and event.get("commit_event_id") == "blocked-final"
                    for event in pump.seen
                )
                assert fresh_terminal["type"] == (
                    "conversation.item.input_audio_transcription.completed"
                )
                assert receipt["accepted_samples"] > 0
            finally:
                blocked = blocked or factory.blocked_session
                if blocked is not None:
                    blocked.release_from_test_thread()
    finally:
        if pump is not None:
            pump.join()


def test_pending_commit_receipts_keep_frozen_watermarks_and_remain_bounded(monkeypatch) -> None:
    from speechrail.http.routes import realtime_openai as transport

    class CompletingBlockedFinal(_BlockedFinalSession):
        async def commit(self, want_segments: bool = False) -> None:
            await super().commit(want_segments)
            await FakeStreamingSession.commit(self, want_segments)

    monkeypatch.setattr(transport, "INPUT_BARRIER_LIMIT", 2)
    factory = _BlockFirstFinalFactory(CompletingBlockedFinal)
    client, _ = _client(factory=factory)
    pump = None
    try:
        with client.websocket_connect("/v1/realtime") as socket:
            socket.receive_json()
            pump = _SocketEventPump(socket)
            try:
                for event_id in ("first", "second"):
                    socket.send_json({
                        "type": "input_audio_buffer.append", "audio": _pcm16(b"\x01\x00" * 8),
                    })
                    socket.send_json({
                        "type": "input_audio_buffer.commit", "event_id": event_id,
                        "speechrail": {"request_receipt": True},
                    })
                    boundary = pump.until(
                        lambda event, expected=event_id: (
                            event["type"] == "speechrail.transcription.segment_closed"
                            and event.get("commit_event_id") == expected
                        )
                    )
                    assert boundary["sample_span"] == (
                        {"start": 0, "end": 8} if event_id == "first"
                        else {"start": 8, "end": 16}
                    )
                blocked = factory.blocked_session
                assert blocked is not None and blocked.commit_started.wait(2)
                socket.send_json({
                    "type": "input_audio_buffer.commit", "event_id": "overflow",
                    "speechrail": {"request_receipt": True},
                })
                error = pump.until(lambda event: event["type"] == "error")
                assert error["error"]["code"] == "queue_full"
                assert error["error"]["event_id"] == "overflow"
                blocked.release_from_test_thread()
                receipts = {}
                while len(receipts) < 2:
                    event = pump.until(
                        lambda event: event["type"] == "speechrail.input_audio_buffer.committed"
                    )
                    assert event["commit_event_id"] not in receipts
                    receipts[event["commit_event_id"]] = event["accepted_samples"]
                assert receipts == {"first": 8, "second": 16}
                assert len(factory.released) == 2
            finally:
                if factory.blocked_session is not None:
                    factory.blocked_session.release_from_test_thread()
    finally:
        if pump is not None:
            pump.join()


@pytest.mark.parametrize("wire_samples", [24_001, 48_001])
def test_commit_tail_rollover_repeat_receipt_has_no_phantom_item(wire_samples) -> None:
    async def run() -> None:
        factory = FakeStreamingFactory()
        services = build_app_services(
            Settings(max_realtime_frame_bytes=128_000),
            AppOverrides(realtime_asr_factory=factory),
        )
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="commit-tail-rollover", send=send)
        update = session_update()
        update["session"]["speechrail"]["asr"] = {
            "preview_interval_ms": 1_000,
            "max_segment_ms": 1_000,
            "finalization": "full_segment",
        }
        await session.handle(update)
        pcm = b"\x01\x00" * wire_samples
        await session.handle({"type": "input_audio_buffer.append", "audio": _pcm16(pcm)})
        for event_id in ("first", "repeat"):
            await session.handle({
                "type": "input_audio_buffer.commit", "event_id": event_id,
                "speechrail": {"request_receipt": True},
            })
        boundaries = [e for e in sent if e["type"].endswith("segment_closed")]
        terminals = [e for e in sent if e["type"].endswith(("completed", "failed"))]
        assert len(boundaries) == len(terminals) == wire_samples // 24_000 + 1
        assert {e["item_id"] for e in boundaries} == {e["item_id"] for e in terminals}
        assert boundaries[-1]["sample_span"] == {
            "start": wire_samples - 1, "end": wire_samples,
        }
        receipts = [e for e in sent if e["type"] == "speechrail.input_audio_buffer.committed"]
        assert [e["commit_event_id"] for e in receipts] == ["first", "repeat"]
        assert [e["accepted_samples"] for e in receipts] == [wire_samples, wire_samples]
        resampler = RationalResampler(24_000, 16_000)
        expected = resampler.process(pcm) + resampler.flush()
        assert b"".join(chunk for item in factory.sessions for chunk in item.received) == expected
        await session.close()
        assert len(factory.released) == len(factory.sessions)

    asyncio.run(run())


def test_worker_failed_terminal_with_normal_cleanup_precedes_completion_receipt() -> None:
    class FailedTerminalSession(FakeStreamingSession):
        async def commit(self, want_segments: bool = False) -> None:
            await self.events_queue.put(
                StreamingAsrEvent(kind="error", error_code="backend_error"),
            )
            await self.events_queue.put(None)

    class FailedTerminalFactory(FakeStreamingFactory):
        def session_class(self):
            return FailedTerminalSession

    factory = FailedTerminalFactory()
    client, _ = _client(factory=factory)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(b"\x01\x00" * 8)})
        for event_id in ("first", "repeat"):
            socket.send_json({
                "type": "input_audio_buffer.commit", "event_id": event_id,
                "speechrail": {"request_receipt": True},
            })
            if event_id == "first":
                assert socket.receive_json()["type"] == "speechrail.transcription.segment_closed"
                terminal = socket.receive_json()
                assert terminal["type"] == "conversation.item.input_audio_transcription.failed"
                assert terminal["error"]["code"] == "backend_error"
            receipt = socket.receive_json()
            assert receipt["type"] == "speechrail.input_audio_buffer.committed"
            assert receipt["commit_event_id"] == event_id
            assert receipt["accepted_samples"] == 8
    assert len(factory.sessions) == len(factory.released) == 1


def test_completed_rollover_failure_is_retained_by_the_later_input_barrier() -> None:
    class FailedTerminalSession(FakeStreamingSession):
        async def commit(self, want_segments: bool = False) -> None:
            raise TimeoutError("worker final did not complete")

    class FirstFailedFactory(FakeStreamingFactory):
        def session_class(self):
            return FailedTerminalSession if not self.sessions else FakeStreamingSession

    async def run() -> None:
        factory = FirstFailedFactory()
        services = build_app_services(
            Settings(max_realtime_frame_bytes=128_000),
            AppOverrides(realtime_asr_factory=factory),
        )
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="earlier-rollover-failed", send=send)
        update = session_update()
        update["session"]["speechrail"]["asr"] = {
            "preview_interval_ms": 1_000, "max_segment_ms": 1_000,
            "finalization": "full_segment",
        }
        await session.handle(update)
        await session.handle({
            "type": "input_audio_buffer.append", "audio": _pcm16(b"\x01\x00" * 25_000),
        })
        await session._asr_owner._await_asr_finals()
        assert any(e["type"].endswith("transcription.failed") for e in sent)
        for event_id in ("first", "repeat"):
            with pytest.raises(RealtimeAdapterError) as exc:
                await session.handle({
                    "type": "input_audio_buffer.commit", "event_id": event_id,
                    "speechrail": {"request_receipt": True},
                })
            assert exc.value.code == "backend_timeout"
        assert not any(e["type"] == "speechrail.input_audio_buffer.committed" for e in sent)
        assert len([e for e in sent if e["type"].endswith(("completed", "failed"))]) == 2
        await session.close()
        assert len(factory.sessions) == len(factory.released) == 2

    asyncio.run(run())


def test_clear_gives_waiting_empty_commit_exactly_one_failed_terminal() -> None:
    from realtime_wire import server_vad
    from test_realtime_admission_commits import _EnergyScriptedVad, _sine_frame_16k

    async def run() -> None:
        factory = _BlockFirstFinalFactory()
        services = build_app_services(
            Settings(realtime_speech_admission_enabled=True),
            AppOverrides(realtime_asr_factory=factory),
        )
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="empty-commit-clear", send=send)
        await session.handle(session_update(endpointing=server_vad()))
        session._asr_owner._vad = _EnergyScriptedVad()
        for _ in range(12):
            await session.handle({
                "type": "input_audio_buffer.append", "audio": _pcm16(_sine_frame_16k()),
            })
        waiters = []
        try:
            for event_id in ("speech", "empty"):
                if event_id == "empty":
                    await session.handle({
                        "type": "input_audio_buffer.append", "audio": _pcm16(bytes(4_800)),
                    })
                completion = await session.handle({
                    "type": "input_audio_buffer.commit", "event_id": event_id,
                    "speechrail": {"request_receipt": True},
                }, defer_asr_commit=True)
                assert completion is not None
                waiters.append(asyncio.create_task(completion))
            assert not any(e["type"].endswith(("completed", "failed")) for e in sent)
            await session.handle({"type": "input_audio_buffer.clear"})
            errors = await asyncio.gather(*waiters, return_exceptions=True)
            assert all(isinstance(e, RealtimeAdapterError) and e.code == "invalid_state"
                       for e in errors)
            terminals = [e for e in sent if e["type"].endswith(("completed", "failed"))]
            assert len(terminals) == 2
            assert {e["commit_event_id"] for e in terminals} == {"speech", "empty"}
            assert all(e["type"].endswith("transcription.failed") for e in terminals)
            assert not any(e["type"] == "speechrail.input_audio_buffer.committed" for e in sent)
        finally:
            for waiter in waiters:
                waiter.cancel()
            await asyncio.gather(*waiters, return_exceptions=True)
            await session.close()
        assert len(factory.sessions) == len(factory.released) == 1

    asyncio.run(run())


def test_clear_revokes_barrier_before_a_slow_failed_terminal_send() -> None:
    class CompletingBlockedFinal(_BlockedFinalSession):
        async def commit(self, want_segments: bool = False) -> None:
            await super().commit(want_segments)
            await FakeStreamingSession.commit(self, want_segments)

    async def run() -> None:
        factory = _BlockFirstFinalFactory(CompletingBlockedFinal)
        services = build_app_services(
            Settings(), AppOverrides(realtime_asr_factory=factory),
        )
        failed_send_entered = asyncio.Event()
        finish_failed_send = asyncio.Event()
        sent = []

        async def send(event):
            sent.append(event)
            if event["type"].endswith("transcription.failed"):
                failed_send_entered.set()
                await finish_failed_send.wait()
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="clear-send-race", send=send)
        await session.handle({"type": "input_audio_buffer.append", "audio": _pcm16(bytes(16))})
        completion = await session.handle({
            "type": "input_audio_buffer.commit", "event_id": "blocked",
            "speechrail": {"request_receipt": True},
        }, defer_asr_commit=True)
        assert completion is not None
        waiter = asyncio.create_task(completion)
        clear = asyncio.create_task(session.handle({"type": "input_audio_buffer.clear"}))
        try:
            await asyncio.wait_for(failed_send_entered.wait(), 1)
            blocked = factory.blocked_session
            assert blocked is not None
            # Start/finish the model while clear is paused in transport.
            assert await asyncio.to_thread(blocked.commit_started.wait, 1)
            blocked.release_from_test_thread()
            with pytest.raises(RealtimeAdapterError) as exc:
                await asyncio.wait_for(asyncio.shield(waiter), 1)
            assert exc.value.code == "invalid_state"
            assert not any(e["type"] == "speechrail.input_audio_buffer.committed" for e in sent)
            assert len([e for e in sent if e["type"].endswith(("completed", "failed"))]) == 1
        finally:
            finish_failed_send.set()
            await clear
            await session.close()
        assert len(factory.sessions) == len(factory.released) == 1

    asyncio.run(run())


def test_rejected_append_cannot_clear_a_failed_barrier_generation() -> None:
    class TimeoutSession(FakeStreamingSession):
        async def commit(self, want_segments: bool = False) -> None:
            raise TimeoutError("final timeout")

    class TimeoutFactory(FakeStreamingFactory):
        def session_class(self):
            return TimeoutSession

    async def run() -> None:
        factory = TimeoutFactory()
        services = build_app_services(
            Settings(max_realtime_buffer_bytes=128_000, max_realtime_frame_bytes=256_000),
            AppOverrides(realtime_asr_factory=factory),
        )
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="rejected-append", send=send)
        try:
            await session.handle({"type": "input_audio_buffer.append", "audio": _pcm16(bytes(16))})
            with pytest.raises(RealtimeAdapterError) as first:
                await session.handle({
                    "type": "input_audio_buffer.commit", "event_id": "failed",
                    "speechrail": {"request_receipt": True},
                })
            assert first.value.code == "backend_timeout"
            with pytest.raises(RealtimeAdapterError) as rejected:
                await session.handle({
                    "type": "input_audio_buffer.append", "audio": _pcm16(bytes(130_000)),
                })
            assert rejected.value.code == "buffer_too_large"
            with pytest.raises(RealtimeAdapterError) as retry:
                await session.handle({
                    "type": "input_audio_buffer.commit", "event_id": "retry",
                    "speechrail": {"request_receipt": True},
                })
            assert retry.value.code == "backend_timeout"
            assert not any(e["type"] == "speechrail.input_audio_buffer.committed" for e in sent)
            assert len([e for e in sent if e["type"].endswith(("completed", "failed"))]) == 1
        finally:
            await session.close()
        assert len(factory.sessions) == len(factory.released) == 1

    asyncio.run(run())


def test_external_commit_cancellation_preserves_owned_final_without_receipt() -> None:
    class CompletingBlockedFinal(_BlockedFinalSession):
        async def commit(self, want_segments: bool = False) -> None:
            await super().commit(want_segments)
            await FakeStreamingSession.commit(self, want_segments)

    async def run() -> None:
        factory = _BlockFirstFinalFactory(CompletingBlockedFinal)
        services = build_app_services(
            Settings(), AppOverrides(realtime_asr_factory=factory),
        )
        sent = []

        async def send(event):
            sent.append(event)
            return len(sent)

        session = OpenAIRealtimeSession(services, session_id="caller-cancel", send=send)
        try:
            await session.handle({"type": "input_audio_buffer.append", "audio": _pcm16(bytes(16))})
            pending = asyncio.create_task(session.handle({
                "type": "input_audio_buffer.commit", "event_id": "caller",
                "speechrail": {"request_receipt": True},
            }))
            blocked = factory.blocked_session
            assert blocked is not None
            assert await asyncio.to_thread(blocked.commit_started.wait, 1)
            pending.cancel()
            with pytest.raises(asyncio.CancelledError):
                await pending
            assert not blocked.commit_cancelled.is_set()
            assert session._asr_owner._asr_finals and all(
                not t.cancelled() for t in session._asr_owner._asr_finals
            )
            blocked.release_from_test_thread()
            await asyncio.wait_for(session._asr_owner._await_asr_finals(), 1)
            assert len([e for e in sent if e["type"].endswith("transcription.completed")]) == 1
            assert not any(e["type"] == "speechrail.input_audio_buffer.committed" for e in sent)
        finally:
            await session.close()
        assert len(factory.sessions) == len(factory.released) == 1

    asyncio.run(run())


def test_background_final_transport_failure_is_observed_without_erasing_failure(caplog) -> None:
    import gc

    from speechrail.application.realtime_asr import _AsrItem

    class MissingTerminalSession(FakeStreamingSession):
        async def commit(self, want_segments: bool = False) -> None:
            raise TimeoutError("final deadline expired")

    async def run() -> None:
        services = build_app_services(Settings(), AppOverrides())
        sending = asyncio.Event()
        unhandled = []
        loop = asyncio.get_running_loop()
        loop.set_exception_handler(lambda _, context: unhandled.append(context))

        async def send(event):
            if event["type"].endswith("transcription.failed"):
                sending.set()
                raise OSError("transport unavailable")
            return 1

        session = OpenAIRealtimeSession(services, session_id="final-send-error", send=send)
        runtime = MissingTerminalSession(language="zh")
        item = _AsrItem(asr=runtime, item_id="frozen", generation=0, close_reason="budget_rollover")
        session._asr_owner._asr_closed_items[item.item_id] = item
        task = asyncio.create_task(session._asr_owner._finish_asr_item(item, False, 0))
        session._asr_owner._asr_finals[task] = 0
        task.add_done_callback(session._asr_owner._discard_asr_final)
        del task
        await asyncio.wait_for(sending.wait(), 1)
        await asyncio.sleep(0)
        gc.collect()
        assert not unhandled
        assert session._asr_owner._asr_barrier_failure == (0, "backend_timeout")
        with pytest.raises(RealtimeAdapterError) as exc:
            await session.handle({
                "type": "input_audio_buffer.commit", "event_id": "retry",
                "speechrail": {"request_receipt": True},
            })
        assert exc.value.code == "backend_timeout"
        await session.close()
        await runtime.close()
        loop.set_exception_handler(None)

    asyncio.run(run())
    assert "ASR final task ended with an error: type=OSError" in caplog.text
