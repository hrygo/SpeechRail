"""Router lifecycle: independent plan roles, never a silent re-route."""

from __future__ import annotations

from collections.abc import AsyncIterator
from types import SimpleNamespace

import anyio
import pytest

from speechrail.backends.qwen3_tts import Qwen3TtsCapabilityRouter, TtsWorkerBusyError
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.runtime.busy import BusyReason


class _Registry:
    def __init__(self, modes: dict[str, str]) -> None:
        self._modes = modes

    def get_profile(self, voice: str) -> SimpleNamespace:
        mode = self._modes[voice]
        return SimpleNamespace(
            mode=mode,
            revision=None,
            runtime_role=(
                "tts_base"
                if mode == "clone"
                else "tts_custom_voice"
                if mode == "system"
                else None
            ),
        )


class _Worker:
    def __init__(self, variant: str) -> None:
        self.model_variant = variant
        self.alive = False
        self.ready = False
        self.last_active = 0.0
        self.started = 0
        self.closed = 0
        self.requests: list[SpeechRequest] = []
        self.lifecycle_stats = {
            "cooperative_cancel_supported": False,
            "fallback_abort_count": 0,
            "reload_count": 0,
        }

    async def start(self) -> None:
        self.started += 1
        self.alive = True
        self.ready = True

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def stream() -> AsyncIterator[AudioChunk]:
            if not self.alive:
                await self.start()
            self.requests.append(request)
            yield AudioChunk(
                response_id=f"{self.model_variant}-1", chunk_index=0, audio=b"\x00\x00"
            )

        return stream()

    async def trim_memory(self) -> None:
        return None

    async def close(self) -> None:
        self.closed += 1
        self.alive = False
        self.ready = False


class _BlockingWorker(_Worker):
    def __init__(self, variant: str, entered: anyio.Event, release: anyio.Event) -> None:
        super().__init__(variant)
        self._entered = entered
        self._release = release

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def stream() -> AsyncIterator[AudioChunk]:
            if not self.alive:
                await self.start()
            self.requests.append(request)
            self._entered.set()
            await self._release.wait()
            yield AudioChunk(
                response_id=f"{self.model_variant}-1", chunk_index=0, audio=b"\x00\x00"
            )

        return stream()


class _FailOnceWorker(_Worker):
    def __init__(self, variant: str) -> None:
        super().__init__(variant)
        self._failed = False

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def stream() -> AsyncIterator[AudioChunk]:
            if not self.alive:
                await self.start()
            self.requests.append(request)
            if not self._failed:
                self._failed = True
                raise RuntimeError("synthetic worker failure")
            yield AudioChunk(
                response_id=f"{self.model_variant}-1", chunk_index=0, audio=b"\x00\x00"
            )

        return stream()


def _router(
    *,
    custom: _Worker | None = None,
    base: _Worker | None = None,
) -> Qwen3TtsCapabilityRouter:
    workers = {
        "tts_custom_voice": custom if custom is not None else _Worker("custom_voice"),
    }
    if base is not None:
        workers["tts_base"] = base
    return Qwen3TtsCapabilityRouter(workers)


@pytest.mark.anyio
async def test_router_allows_custom_and_clone_roles_concurrently(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"serena": "system", "cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    entered = anyio.Event()
    release = anyio.Event()
    custom = _Worker("custom_voice")
    base = _BlockingWorker("base", entered, release)
    router = _router(custom=custom, base=base)
    assert router.warm_capability is None
    await router.start()
    assert router.warm_capability == "both"
    assert router.warm_capabilities == ("tts_custom_voice", "tts_base")
    assert router.lifecycle_stats["warm_capability"] == "both"

    clone_request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")
    builtin_request = SpeechRequest(text="hi", voice="serena", output_format="pcm16")
    results: list[str] = []

    async def run_clone() -> None:
        _ = [chunk async for chunk in router.synthesize(clone_request)]
        results.append("clone")

    async def run_builtin() -> None:
        _ = [chunk async for chunk in router.synthesize(builtin_request)]
        results.append("builtin")

    async with anyio.create_task_group() as tg:
        tg.start_soon(run_clone)
        await entered.wait()
        assert router.warm_capability == "both"
        tg.start_soon(run_builtin)
        await anyio.lowlevel.checkpoint()
        assert base.alive is True
        assert custom.alive is True
        assert custom.requests == [builtin_request]
        release.set()

    assert set(results) == {"clone", "builtin"}
    assert base.alive is True
    assert custom.alive is True


@pytest.mark.anyio
async def test_router_releases_capability_lock_after_worker_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"serena": "system", "cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    custom = _Worker("custom_voice")
    base = _FailOnceWorker("base")
    router = _router(custom=custom, base=base)
    await router.start()

    clone_request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")
    with pytest.raises(RuntimeError, match="synthetic worker failure"):
        _ = [chunk async for chunk in router.synthesize(clone_request)]

    builtin_request = SpeechRequest(text="hi", voice="serena", output_format="pcm16")
    chunks = [chunk async for chunk in router.synthesize(builtin_request)]
    assert chunks
    assert base.alive is True
    assert custom.alive is True
    assert custom.requests == [builtin_request]


@pytest.mark.anyio
async def test_router_can_evict_every_plan_role(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"serena": "system", "cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    custom = _Worker("custom_voice")
    base = _Worker("base")
    router = _router(custom=custom, base=base)
    await router.start()

    request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")
    assert [chunk async for chunk in router.synthesize(request)]
    assert router.warm_capability == "both"

    await router.evict_warm_capability()

    assert router.warm_capability is None
    assert custom.alive is False
    assert base.alive is False


@pytest.mark.anyio
async def test_router_closes_child_stream_before_releasing_model_slot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from contextlib import aclosing

    registry = _Registry({"cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)

    class RetainedStreamWorker(_Worker):
        finalized = False

        def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
            async def stream() -> AsyncIterator[AudioChunk]:
                try:
                    yield AudioChunk(response_id="retained", chunk_index=0, audio=b"\0\0")
                finally:
                    self.finalized = True

            # Retain a reference: correctness must not depend on GC scheduling.
            self.source = stream()
            return self.source

    base = RetainedStreamWorker("base")
    router = _router(base=base)
    request = SpeechRequest(text="test", voice="cloned")
    async with aclosing(router.synthesize(request)) as source:
        await anext(source)
    assert base.finalized
    assert not router._capability_lock.locked()


@pytest.mark.anyio
async def test_start_preserves_already_warm_clone_capability(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    custom = _Worker("custom_voice")
    base = _Worker("base")
    router = _router(custom=custom, base=base)
    request = SpeechRequest(text="test", voice="cloned")
    assert [chunk async for chunk in router.synthesize(request)]
    await router.start()
    assert router.warm_capability == "both"
    assert custom.started == 1
    assert base.started == 1
    assert base.alive


@pytest.mark.anyio
async def test_router_reports_busy_instead_of_evicting_an_active_utterance(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A group-level evict must never cut off an utterance that still owns a worker."""

    registry = _Registry({"serena": "system"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    custom = _Worker("custom_voice")
    router = _router(custom=custom)
    await router.start()
    custom.active_incremental_stream = True  # type: ignore[attr-defined]

    assert router.active_incremental_streams == 1
    with pytest.raises(TtsWorkerBusyError) as raised:
        await router.evict_warm_capability()

    assert raised.value.code == "backend_busy"
    assert raised.value.busy_reason == BusyReason.BACKEND_TRANSITION
    assert custom.alive is True

    custom.active_incremental_stream = False  # type: ignore[attr-defined]
    await router.evict_warm_capability()
    assert custom.alive is False
