"""Deterministic lifecycle tests for the managed runtime drain protocol."""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import AsyncIterator

import pytest

from speechrail.application.managed_runtime import (
    ActiveWork,
    DrainState,
    ManagedRuntime,
    RuntimeBundle,
    RuntimeDrainActivationError,
    RuntimeDrainBusyError,
    RuntimeDrainingError,
    RuntimeDrainTokenError,
)
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import AudioChunk, SpeechRequest, TranscriptionRequest


class _BlockingBatch:
    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.finish = asyncio.Event()

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        self.started.set()
        await self.finish.wait()
        return TranscriptResult(
            request_id=request.request_id,
            model_id="fake/asr",
            text="ok",
            duration_ms=1,
        )


class _BlockingTts:
    def __init__(self) -> None:
        self.finish = asyncio.Event()

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id=request.text, chunk_index=0, audio=b"\x00\x00")
            await self.finish.wait()

        return chunks()


def _bundle(*, asr: object | None = None, tts: object | None = None) -> RuntimeBundle:
    return RuntimeBundle(
        asr=asr,
        tts=tts,
        realtime_factory=None,
        artifact_identity="fake",
        voice_catalog=("default",),
        generation=1,
    )


def test_drain_state_seed_expires_and_restores_admission() -> None:
    now = 10.0
    state = DrainState(clock=lambda: now)

    token = state.begin(now=10.0, ttl_seconds=5.0)
    assert token
    assert not state.accepting

    now = 16.0
    assert state.expire()
    assert state.accepting


@pytest.mark.parametrize("ttl", [True, 0.0, -1.0, float("inf"), float("nan")])
def test_drain_state_rejects_invalid_ttl(ttl: float) -> None:
    with pytest.raises(ValueError, match="deadline"):
        DrainState(clock=lambda: 10.0).begin(ttl_seconds=ttl)


def test_drain_state_rejects_non_finite_clock() -> None:
    with pytest.raises(ValueError, match="clock"):
        DrainState(clock=lambda: float("nan")).begin()


def test_active_work_waits_for_zero_and_release_is_idempotent() -> None:
    async def run() -> None:
        work = ActiveWork()
        lease = work.acquire(generation=1)
        waiter = asyncio.create_task(work.wait_for_zero())
        await asyncio.sleep(0)
        assert not waiter.done()

        lease.release()
        await waiter
        lease.release()
        assert work.count == 0

    asyncio.run(run())


def test_drain_waits_for_active_work_before_returning_token() -> None:
    async def run() -> None:
        batch = _BlockingBatch()
        runtime = ManagedRuntime(_bundle(asr=batch))
        work = asyncio.create_task(
            runtime.transcribe(TranscriptionRequest(request_id="req", audio=b"\x00\x00"))
        )
        await batch.started.wait()

        draining = asyncio.create_task(runtime.drain(deadline_seconds=1.0))
        await asyncio.sleep(0)
        assert runtime.is_draining
        assert not draining.done()
        with pytest.raises(RuntimeDrainingError):
            runtime.acquire()

        batch.finish.set()
        assert (await work).text == "ok"
        token = await draining
        assert runtime.is_draining
        await runtime.resume(token)
        assert not runtime.is_draining

    asyncio.run(run())


def test_drain_deadline_restores_admission_without_cancelling_work() -> None:
    async def run() -> None:
        batch = _BlockingBatch()
        runtime = ManagedRuntime(_bundle(asr=batch))
        work = asyncio.create_task(
            runtime.transcribe(TranscriptionRequest(request_id="req", audio=b"\x00\x00"))
        )
        await batch.started.wait()

        with pytest.raises(TimeoutError):
            await runtime.drain(deadline_seconds=0.01)
        assert runtime.active_count == 1
        assert not runtime.is_draining
        admission = runtime.acquire()
        admission.release()

        batch.finish.set()
        assert (await work).text == "ok"

    asyncio.run(run())


def test_cancelling_drain_restores_admission_without_cancelling_tts() -> None:
    async def run() -> None:
        tts = _BlockingTts()
        runtime = ManagedRuntime(_bundle(tts=tts))
        stream = runtime.synthesize(
            SpeechRequest(text="hello", voice="default", output_format="pcm16")
        )
        assert (await anext(stream)).audio == b"\x00\x00"
        assert runtime.active_count == 1

        draining = asyncio.create_task(runtime.drain(deadline_seconds=1.0))
        await asyncio.sleep(0)
        draining.cancel()
        with pytest.raises(asyncio.CancelledError):
            await draining
        assert not runtime.is_draining
        assert runtime.active_count == 1

        tts.finish.set()
        await stream.aclose()
        assert runtime.active_count == 0

    asyncio.run(run())


def test_only_one_drain_owner_is_allowed() -> None:
    async def run() -> None:
        work = ActiveWork()
        lease = work.acquire(generation=1)
        runtime = ManagedRuntime(_bundle(), active_work=work)
        first = asyncio.create_task(runtime.drain(deadline_seconds=1.0))
        await asyncio.sleep(0)

        with pytest.raises(RuntimeDrainBusyError):
            await runtime.drain(deadline_seconds=1.0)

        first.cancel()
        with pytest.raises(asyncio.CancelledError):
            await first
        lease.release()

    asyncio.run(run())


def test_resume_is_single_use_and_rejects_foreign_token() -> None:
    state = DrainState(clock=lambda: 10.0)
    token = state.begin(now=10.0, ttl_seconds=120.0)
    other = DrainState(clock=lambda: 10.0)
    foreign = other.begin(now=10.0, ttl_seconds=120.0)

    state.resume(token)
    assert state.accepting
    with pytest.raises(RuntimeDrainTokenError):
        state.resume(token)
    with pytest.raises(RuntimeDrainTokenError):
        state.resume(foreign)


def test_expired_unclaimed_token_restores_admission_after_owner_loss() -> None:
    now = 10.0
    state = DrainState(clock=lambda: now)
    state.begin(ttl_seconds=5.0)
    assert not state.accepting

    now = 16.0
    assert state.expire()
    assert state.accepting


def test_activation_claimed_token_cannot_be_resumed() -> None:
    async def run() -> None:
        runtime = ManagedRuntime(_bundle())
        token = await runtime.drain(deadline_seconds=1.0)

        runtime.claim_activation(token)
        with pytest.raises(RuntimeDrainActivationError):
            await runtime.resume(token)
        assert runtime.is_draining

    asyncio.run(run())


def test_drain_rejects_second_call_after_first_completed() -> None:
    async def run() -> None:
        runtime = ManagedRuntime(_bundle())
        token = await runtime.drain(deadline_seconds=1.0)
        with pytest.raises(RuntimeDrainBusyError):
            await runtime.drain(deadline_seconds=1.0)
        await runtime.resume(token)

    asyncio.run(run())


def test_drain_timeout_keeps_current_batch_result_successful() -> None:
    async def run() -> None:
        batch = _BlockingBatch()
        runtime = ManagedRuntime(_bundle(asr=batch))
        current = asyncio.create_task(
            runtime.transcribe(TranscriptionRequest(request_id="current", audio=b"\x00\x00"))
        )
        await batch.started.wait()
        with pytest.raises(TimeoutError):
            await runtime.drain(deadline_seconds=0.01)
        assert not current.done()
        batch.finish.set()
        result = await current
        assert result.request_id == "current"

    asyncio.run(run())


def test_tts_stream_keeps_drain_waiting_until_iterator_is_closed() -> None:
    async def run() -> None:
        tts = _BlockingTts()
        runtime = ManagedRuntime(_bundle(tts=tts))
        stream = runtime.synthesize(
            SpeechRequest(text="hold", voice="default", output_format="pcm16")
        )
        await anext(stream)
        draining = asyncio.create_task(runtime.drain(deadline_seconds=1.0))
        await asyncio.sleep(0)
        assert not draining.done()

        await stream.aclose()
        token = await draining
        await runtime.resume(token)

    asyncio.run(run())


def test_runtime_resume_and_cancel_cleanup_do_not_cancel_active_lease() -> None:
    async def run() -> None:
        work = ActiveWork()
        lease = work.acquire(generation=1)
        runtime = ManagedRuntime(_bundle(), active_work=work)
        draining = asyncio.create_task(runtime.drain(deadline_seconds=1.0))
        await asyncio.sleep(0)
        draining.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await draining
        assert work.count == 1
        lease.release()

    asyncio.run(run())
