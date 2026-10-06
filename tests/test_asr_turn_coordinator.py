"""The input lane stays bounded while the sole decoder is busy."""

import asyncio
import functools

import pytest

from speechrail.application.asr_turn_coordinator import AsrTurnCoordinator
from speechrail.domain.asr_policy import ASRPolicy
from speechrail.domain.ports import RealtimeTranscriptionOptions, StreamingAsrEvent


def async_test(test):
    @functools.wraps(test)
    def run():
        asyncio.run(test())
    return run


class ControlledSession:
    def __init__(self, factory):
        self.factory = factory
        self.audio = bytearray()
        self.queue = asyncio.Queue()
        self.final_started = asyncio.Event()
        self.finish = asyncio.Event()
        self.closed = False

    async def connect(self):
        self.factory.running += 1
        self.factory.peak = max(self.factory.peak, self.factory.running)

    async def append_audio(self, audio):
        self.audio.extend(audio)

    async def flush(self):
        await self.queue.put(StreamingAsrEvent(kind="partial", text="provisional"))

    async def commit(self, want_segments=False):
        self.final_started.set()
        await self.finish.wait()
        await self.queue.put(StreamingAsrEvent(kind="completed", text=""))
        await self.queue.put(None)

    async def close(self):
        if not self.closed:
            self.closed = True
            self.factory.running -= 1
            self.factory.closed.set()

    def events(self):
        async def iterate():
            while (event := await self.queue.get()) is not None:
                yield event
        return iterate()


class ControlledFactory:
    def __init__(self):
        self.sessions = []
        self.running = 0
        self.peak = 0
        self.created = asyncio.Queue()
        self.closed = asyncio.Event()

    def create(self, **kwargs):
        session = ControlledSession(self)
        self.sessions.append(session)
        self.created.put_nowait(session)
        return session

    def release(self, session):
        assert session.closed


async def new_segment(coordinator):
    session = coordinator.create(
        language=None, prompt="", options=RealtimeTranscriptionOptions()
    )
    await session.connect()
    return session


@pytest.mark.parametrize("code", ["language_not_supported", "queue_full"])
def test_create_or_admission_failure_preserves_public_terminal_code(code):
    async def scenario():
        class CodedAdmissionError(RuntimeError):
            pass

        class RejectingFactory(ControlledFactory):
            def create(self, **kwargs):
                if code == "language_not_supported":
                    raise RuntimeError("language_not_supported: xx-qq")
                return super().create(**kwargs)

        async def acquire():
            if code != "queue_full":
                return
            error = CodedAdmissionError("capacity unavailable")
            error.code = code
            raise error

        factory = RejectingFactory()
        coordinator = AsrTurnCoordinator(
            factory, capacity_bytes=128,
            acquire=acquire,
        )
        segment = await new_segment(coordinator)
        await segment.append_audio(b"\x01\x00" * 16)
        with pytest.raises(RuntimeError):
            await asyncio.wait_for(segment.commit(), timeout=1)
        events = [event async for event in segment.events()]
        assert len(events) == 1
        assert events[0].kind == "error"
        assert events[0].error_code == code
        assert coordinator.retained_bytes == 0
        await coordinator.close()

    asyncio.run(scenario())


@async_test
async def test_repeated_close_does_not_cancel_inflight_worker_teardown():
    factory = ControlledFactory()
    coordinator = AsrTurnCoordinator(factory, capacity_bytes=1000, max_segments=3)
    segment = await new_segment(coordinator)
    await segment.append_audio(b"\x01\x00" * 32)
    runtime = await factory.created.get()
    entered = asyncio.Event()
    release = asyncio.Event()
    original_close = runtime.close

    async def blocked_close():
        entered.set()
        await release.wait()
        await original_close()

    runtime.close = blocked_close
    first = asyncio.create_task(coordinator.close())
    await asyncio.wait_for(entered.wait(), timeout=1)
    second = asyncio.create_task(coordinator.close())
    try:
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert not first.done() and not second.done()
        assert coordinator.retained_bytes == 128
        assert factory.running == 1
    finally:
        release.set()
        await asyncio.wait_for(asyncio.gather(first, second), timeout=1)
    assert factory.running == 0
    assert coordinator.retained_bytes == 0


@async_test
async def test_canceling_close_waiter_keeps_worker_teardown_and_pcm_owned():
    factory = ControlledFactory()
    coordinator = AsrTurnCoordinator(factory, capacity_bytes=1000, max_segments=3)
    segment = await new_segment(coordinator)
    await segment.append_audio(b"\x01\x00" * 32)
    runtime = await factory.created.get()
    entered = asyncio.Event()
    release = asyncio.Event()
    original_close = runtime.close

    async def blocked_close():
        entered.set()
        await release.wait()
        await original_close()

    runtime.close = blocked_close
    closing = asyncio.create_task(coordinator.close())
    await asyncio.wait_for(entered.wait(), timeout=1)
    closing.cancel()
    try:
        with pytest.raises(asyncio.CancelledError):
            await closing
        assert not runtime.closed
        assert coordinator.retained_bytes == 128
        assert factory.running == 1
    finally:
        release.set()
        await asyncio.wait_for(coordinator.close(), timeout=1)
    assert factory.running == 0
    assert coordinator.retained_bytes == 0


@async_test
async def test_final_and_following_input_have_one_real_model_owner():
    factory = ControlledFactory()
    coordinator = AsrTurnCoordinator(factory, capacity_bytes=1000, max_segments=3)
    first = await new_segment(coordinator)
    await first.append_audio(b"\x01\x00" * 32)
    commit_first = asyncio.create_task(first.commit())
    real_first = await factory.created.get()
    await real_first.final_started.wait()
    second = await new_segment(coordinator)
    # This returns before first.finish is opened: capture is independent of GPU.
    await second.append_audio(b"\x02\x00" * 17)
    commit_second = asyncio.create_task(second.commit())
    assert factory.running == 1
    assert coordinator.retained_bytes >= 98
    real_first.finish.set()
    await commit_first
    real_second = await factory.created.get()
    await real_second.final_started.wait()
    assert bytes(real_first.audio) == b"\x01\x00" * 32
    assert bytes(real_second.audio) == b"\x02\x00" * 17
    real_second.finish.set()
    await commit_second
    assert [e.kind async for e in first.events()] == ["completed"]
    assert [e.kind async for e in second.events()] == ["completed"]
    assert factory.peak == 1
    assert coordinator.retained_bytes == 0
    await coordinator.close()


@async_test
async def test_backlog_overflow_keeps_accepted_pcm_and_is_explicit():
    factory = ControlledFactory()
    coordinator = AsrTurnCoordinator(factory, capacity_bytes=128, max_segments=2)
    first = await new_segment(coordinator)
    await first.append_audio(b"\x01\x00" * 16)
    task = asyncio.create_task(first.commit())
    real = await factory.created.get()
    await real.final_started.wait()
    second = await new_segment(coordinator)
    await second.append_audio(b"\x02\x00" * 8)
    with pytest.raises(RuntimeError, match="asr_buffer_overflow"):
        await second.append_audio(b"\x03\x00" * 48)
    real.finish.set()
    await task
    await coordinator.close()
    assert bytes(real.audio) == b"\x01\x00" * 16
    assert coordinator.retained_bytes == 0
    assert factory.running == 0


@async_test
async def test_clear_waits_for_real_owner_cleanup_before_reusing_capacity():
    factory = ControlledFactory()
    coordinator = AsrTurnCoordinator(factory, capacity_bytes=128, max_segments=2)
    segment = await new_segment(coordinator)
    await segment.append_audio(b"\x01\x00" * 16)
    task = asyncio.create_task(segment.commit())
    real = await factory.created.get()
    await real.final_started.wait()
    await coordinator.close()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert real.closed
    assert factory.running == 0
    assert coordinator.retained_bytes == 0


@pytest.mark.parametrize("operation", ["connect", "preview", "final"])
def test_final_deadline_interrupts_already_running_operations(operation):
    async def scenario():
        started = asyncio.Event()
        blocked = asyncio.Event()

        class DeadlineSession(ControlledSession):
            async def connect(self):
                await super().connect()
                if operation == "connect":
                    started.set()
                    await blocked.wait()

            async def flush(self):
                started.set()
                await blocked.wait()

            async def commit(self, want_segments=False):
                started.set()
                await blocked.wait()

        class DeadlineFactory(ControlledFactory):
            def create(self, **kwargs):
                session = DeadlineSession(self)
                self.sessions.append(session)
                return session

        factory = DeadlineFactory()
        coordinator = AsrTurnCoordinator(factory, capacity_bytes=1000)
        segment = coordinator.create(
            language=None, prompt="",
            options=RealtimeTranscriptionOptions(
                asr_policy=ASRPolicy(final_deadline_ms=20)
            ),
        )
        await segment.connect()
        await segment.append_audio(b"\x01\x00" * 16)
        if operation == "preview":
            await segment.flush()
        if operation != "final":
            await asyncio.wait_for(started.wait(), timeout=1)
        with pytest.raises(TimeoutError):
            await asyncio.wait_for(segment.commit(), timeout=1)
        assert [e.kind async for e in segment.events()] == ["error"]
        assert factory.sessions[0].closed
        assert coordinator.retained_bytes == 0
        await coordinator.close()

    asyncio.run(scenario())


@async_test
async def test_failed_teardown_quarantines_owner_until_retry():
    released = []

    async def release():
        released.append(True)

    class RetrySession(ControlledSession):
        async def close(self):
            if not self.factory.retry:
                raise RuntimeError("reap failed")
            await super().close()

    class RetryFactory(ControlledFactory):
        retry = False

        def create(self, **kwargs):
            session = RetrySession(self)
            self.sessions.append(session)
            self.created.put_nowait(session)
            return session

    factory = RetryFactory()
    coordinator = AsrTurnCoordinator(factory, capacity_bytes=128, release=release)
    segment = await new_segment(coordinator)
    await segment.append_audio(b"\x01\x00" * 16)
    task = asyncio.create_task(segment.commit())
    real = await factory.created.get()
    await real.final_started.wait()
    real.finish.set()
    with pytest.raises(RuntimeError, match="reap failed"):
        await task
    assert released == []
    assert coordinator.retained_bytes == 64
    assert factory.running == 1
    with pytest.raises(RuntimeError, match="closed"):
        await new_segment(coordinator)
    factory.retry = True
    await coordinator.close()
    assert released == [True]
    assert factory.running == 0
    assert coordinator.retained_bytes == 0
