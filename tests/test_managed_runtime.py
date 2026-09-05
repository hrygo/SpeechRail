"""Tests for the stable, generation-aware runtime facade."""

from __future__ import annotations

import asyncio
import contextlib
from collections.abc import AsyncIterator

import pytest

import speechrail.application.services as services_module
from speechrail.application.managed_runtime import (
    ActiveWork,
    ManagedRuntime,
    RuntimeBundle,
    RuntimeBusyError,
    RuntimeDrainingError,
    RuntimeNotReadyError,
)
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import AudioChunk, SpeechRequest, TranscriptionRequest


class _FakeBatch:
    def __init__(self, *, wait: asyncio.Event | None = None) -> None:
        self.wait = wait
        self.calls: list[str] = []
        self.started = asyncio.Event()

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        self.calls.append(request.request_id)
        self.started.set()
        if self.wait is not None:
            await self.wait.wait()
        return TranscriptResult(
            request_id=request.request_id,
            model_id="fake/asr",
            text="ok",
            duration_ms=1,
        )

    async def transcribe_stream(
        self,
        request_id: str,
        audio: AsyncIterator[bytes],
        language: str | None = None,
        prompt: str | None = None,
        include_timestamps: bool = True,
    ) -> TranscriptResult:
        del language, prompt, include_timestamps
        payload = bytearray()
        async for chunk in audio:
            payload.extend(chunk)
        return TranscriptResult(
            request_id=request_id,
            model_id="fake/asr",
            text=payload.decode(),
            duration_ms=1,
        )


class _FakeTts:
    def __init__(self, *, wait: asyncio.Event | None = None) -> None:
        self.wait = wait
        self.closed = False

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def chunks() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id=request.text, chunk_index=0, audio=b"\x00\x00")
            if self.wait is not None:
                await self.wait.wait()

        return chunks()


class _FakeRealtimeSession:
    def __init__(self) -> None:
        self.closed = False

    async def connect(self) -> None:
        return

    async def append_audio(self, audio: bytes) -> None:
        del audio

    async def flush(self) -> None:
        return

    async def commit(self, want_segments: bool = False) -> None:
        del want_segments

    def events(self) -> AsyncIterator[object]:
        async def empty() -> AsyncIterator[object]:
            if False:
                yield object()

        return empty()

    async def close(self) -> None:
        self.closed = True


class _FakeFactory:
    def __init__(self) -> None:
        self.created: list[_FakeRealtimeSession] = []
        self.released: list[object] = []

    def create(self, *, language: str | None, prompt: str) -> _FakeRealtimeSession:
        del language, prompt
        session = _FakeRealtimeSession()
        self.created.append(session)
        return session

    def release(self, session: object) -> None:
        self.released.append(session)


def _bundle(
    *,
    asr: object | None = None,
    tts: object | None = None,
    realtime_factory: object | None = None,
    generation: int = 1,
    artifact_identity: object = "artifact-1",
    voice_catalog: object = ("default",),
) -> RuntimeBundle:
    return RuntimeBundle(
        asr=asr,
        tts=tts,
        realtime_factory=realtime_factory,
        artifact_identity=artifact_identity,
        voice_catalog=voice_catalog,
        generation=generation,
    )


def test_active_work_acquire_release_count_is_idempotent() -> None:
    work = ActiveWork()
    lease = work.acquire(generation=1)
    assert work.count == 1
    assert lease.generation == 1
    work.release(lease)
    work.release(lease)
    assert work.count == 0


def test_active_work_rejects_missing_or_foreign_release_tokens() -> None:
    work = ActiveWork()
    foreign = ActiveWork()
    token = work.acquire(generation=1)
    foreign_token = foreign.acquire(generation=2)

    with pytest.raises(TypeError):
        work.release()  # type: ignore[call-arg]
    with pytest.raises(ValueError, match="foreign"):
        work.release(foreign_token)
    assert work.count == 1
    assert foreign.count == 1

    work.release(token)
    foreign.release(foreign_token)
    assert work.count == 0
    assert foreign.count == 0


def test_streaming_tts_holds_generation_until_iterator_is_closed() -> None:
    async def run() -> None:
        first_tts = _FakeTts()
        second_tts = _FakeTts()
        runtime = ManagedRuntime(_bundle(tts=first_tts, generation=1))
        stream = runtime.synthesize(
            SpeechRequest(text="first", voice="default", output_format="pcm16")
        )

        assert (await anext(stream)).audio == b"\x00\x00"
        assert runtime.active_work.count == 1
        with pytest.raises(RuntimeBusyError):
            runtime.replace_bundle(_bundle(tts=second_tts, generation=2))

        await stream.aclose()
        assert runtime.active_work.count == 0
        runtime.replace_bundle(_bundle(tts=second_tts, generation=2))
        assert runtime.generation == 2

    asyncio.run(run())


def test_cancelled_tts_iterator_releases_generation_lease() -> None:
    async def run() -> None:
        blocked = asyncio.Event()
        started = asyncio.Event()

        class BlockingTts(_FakeTts):
            def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
                async def chunks() -> AsyncIterator[AudioChunk]:
                    started.set()
                    yield AudioChunk(response_id=request.text, chunk_index=0, audio=b"\x00\x00")
                    await blocked.wait()

                return chunks()

        runtime = ManagedRuntime(_bundle(tts=BlockingTts()))

        stream = runtime.synthesize(
            SpeechRequest(text="cancel", voice="default", output_format="pcm16")
        )
        assert (await anext(stream)).audio == b"\x00\x00"
        await started.wait()
        assert runtime.active_work.count == 1
        task = asyncio.create_task(anext(stream))
        await asyncio.sleep(0)
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        assert runtime.active_work.count == 0

    asyncio.run(run())


def test_realtime_factory_acquires_only_when_backend_session_is_created() -> None:
    async def run() -> None:
        factory = _FakeFactory()
        runtime = ManagedRuntime(_bundle(realtime_factory=factory))
        assert runtime.active_work.count == 0

        session = runtime.create(language="en", prompt="")
        assert runtime.active_work.count == 1
        await session.close()
        assert runtime.active_work.count == 0
        runtime.release(session)
        assert factory.released == [factory.created[0]]

    asyncio.run(run())


def test_realtime_terminal_event_releases_session_slot_and_lease() -> None:
    async def run() -> None:
        factory = _FakeFactory()
        runtime = ManagedRuntime(_bundle(realtime_factory=factory))
        session = runtime.create(language="en", prompt="")
        events = session.events()
        with pytest.raises(StopAsyncIteration):
            await anext(events)
        assert runtime.active_work.count == 0
        assert factory.released == [factory.created[0]]

    asyncio.run(run())


def test_realtime_connect_failure_closes_and_releases_the_old_generation() -> None:
    async def run() -> None:
        class FailingSession(_FakeRealtimeSession):
            async def connect(self) -> None:
                raise RuntimeError("connect failed")

        class FailingFactory(_FakeFactory):
            def create(self, *, language: str | None, prompt: str) -> FailingSession:
                del language, prompt
                session = FailingSession()
                self.created.append(session)
                return session

        factory = FailingFactory()
        runtime = ManagedRuntime(_bundle(realtime_factory=factory, generation=1))
        session = runtime.create(language="en", prompt="")

        with pytest.raises(RuntimeError, match="connect failed"):
            await session.connect()
        assert factory.created[0].closed is True
        assert factory.released == [factory.created[0]]
        assert runtime.active_work.count == 0
        runtime.replace_bundle(_bundle(realtime_factory=_FakeFactory(), generation=2))

    asyncio.run(run())


def test_realtime_connect_cancellation_closes_and_releases_the_old_generation() -> None:
    async def run() -> None:
        started = asyncio.Event()
        continue_connect = asyncio.Event()

        class BlockingSession(_FakeRealtimeSession):
            async def connect(self) -> None:
                started.set()
                await continue_connect.wait()

        class BlockingFactory(_FakeFactory):
            def create(self, *, language: str | None, prompt: str) -> BlockingSession:
                del language, prompt
                session = BlockingSession()
                self.created.append(session)
                return session

        factory = BlockingFactory()
        runtime = ManagedRuntime(_bundle(realtime_factory=factory, generation=1))
        session = runtime.create(language="en", prompt="")
        connect_task = asyncio.create_task(session.connect())
        await started.wait()
        connect_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await connect_task

        assert factory.created[0].closed is True
        assert factory.released == [factory.created[0]]
        assert runtime.active_work.count == 0

    asyncio.run(run())


def test_draining_rejects_new_work_with_stable_error() -> None:
    runtime = ManagedRuntime(_bundle(asr=_FakeBatch()))
    runtime.begin_draining()

    with pytest.raises(RuntimeDrainingError) as exc_info:
        runtime.acquire()
    assert exc_info.value.code == "runtime_draining"


def test_same_generation_snapshot_stays_consistent_for_a_batch_result() -> None:
    async def run() -> None:
        finished = asyncio.Event()
        first = _FakeBatch(wait=finished)
        runtime = ManagedRuntime(
            _bundle(
                asr=first,
                generation=1,
                artifact_identity={"asr": "old"},
                voice_catalog=("default",),
            )
        )
        request = TranscriptionRequest(request_id="req_1", audio=b"\x00\x00")
        pending = asyncio.create_task(runtime.transcribe(request))
        await first.started.wait()
        assert runtime.active_work.count == 1
        with pytest.raises(RuntimeBusyError):
            runtime.replace_bundle(
                _bundle(
                    asr=_FakeBatch(),
                    generation=2,
                    artifact_identity={"asr": "new"},
                    voice_catalog=("warm",),
                )
            )
        finished.set()
        result = await pending
        assert result.text == "ok"
        runtime.replace_bundle(
            _bundle(
                asr=_FakeBatch(),
                generation=2,
                artifact_identity={"asr": "new"},
                voice_catalog=("warm",),
            )
        )
        assert runtime.generation == 2
        assert runtime.artifact_identity == {"asr": "new"}
        assert runtime.voice_catalog == ("warm",)

    asyncio.run(run())


def test_streaming_batch_without_stream_port_fails_before_consuming_audio() -> None:
    async def run() -> None:
        consumed = asyncio.Event()

        class BatchOnly:
            async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
                del request
                raise AssertionError("batch fallback must not be used")

        async def infinite_audio() -> AsyncIterator[bytes]:
            blocked = asyncio.Event()
            while True:
                consumed.set()
                yield b"\x00\x00"
                await blocked.wait()

        runtime = ManagedRuntime(_bundle(asr=BatchOnly()))
        with pytest.raises(RuntimeNotReadyError) as exc_info:
            await asyncio.wait_for(
                runtime.transcribe_stream("stream", infinite_audio()),
                timeout=0.05,
            )
        assert exc_info.value.code == "backend_not_ready"
        assert not consumed.is_set()
        assert runtime.active_work.count == 0

    asyncio.run(run())


def test_bundle_recursively_freezes_identity_and_voice_snapshots() -> None:
    artifact_identity = {"asr": {"model": "old", "quantization": {"bits": 8}}}
    voice_catalog = {"default": {"description": "old", "aliases": ["alloy"]}}
    bundle = _bundle(
        artifact_identity=artifact_identity,
        voice_catalog=voice_catalog,
    )

    artifact_identity["asr"]["model"] = "new"  # type: ignore[index]
    artifact_identity["asr"]["quantization"]["bits"] = 4  # type: ignore[index]
    voice_catalog["default"]["description"] = "new"  # type: ignore[index]
    voice_catalog["default"]["aliases"].append("nova")  # type: ignore[index]

    assert bundle.artifact_identity == {
        "asr": {"model": "old", "quantization": {"bits": 8}}
    }
    assert bundle.voice_catalog == {
        "default": {"description": "old", "aliases": ("alloy",)}
    }
    with pytest.raises(TypeError):
        bundle.artifact_identity["asr"]["model"] = "mutated"  # type: ignore[index]
    with pytest.raises(TypeError):
        bundle.voice_catalog["default"]["description"] = "mutated"  # type: ignore[index]


def test_batch_streaming_and_legacy_callable_signatures_are_preserved() -> None:
    async def run() -> None:
        runtime = ManagedRuntime(_bundle(asr=_FakeBatch()))
        typed = await runtime.transcribe(
            TranscriptionRequest(request_id="typed", audio=b"\x00\x00")
        )
        assert typed.request_id == "typed"

        async def audio() -> AsyncIterator[bytes]:
            yield b"hello"

        streamed = await runtime.transcribe_stream("stream", audio())
        assert streamed.text == "hello"

        legacy = await runtime(b"\x00\x00", "en", "prompt", False)
        assert legacy.request_id
        assert runtime.active_work.count == 0

    asyncio.run(run())


def test_fake_port_override_preserves_exact_objects_without_building_a_facade(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    settings = Settings(_env_file=None, qwen3_model_dir=None, qwen3_python=None)
    fake = _FakeBatch()

    def forbidden(*args: object, **kwargs: object) -> object:
        del args, kwargs
        raise AssertionError("fake overrides must not construct a ManagedRuntime")

    monkeypatch.setattr(services_module, "ManagedRuntime", forbidden)
    services = build_app_services(settings, AppOverrides(batch_transcriber=fake))

    assert services.batch_transcriber is fake
    assert services.runtime is None
