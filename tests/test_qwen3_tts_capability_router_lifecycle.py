from __future__ import annotations

from collections.abc import AsyncIterator
from types import SimpleNamespace

import anyio
import pytest

from speechrail.backends.qwen3_tts import Qwen3TtsCapabilityRouter
from speechrail.domain.ports import AudioChunk, SpeechRequest


class _Registry:
    def __init__(self, modes: dict[str, str]) -> None:
        self._modes = modes

    def get_profile(self, voice: str) -> SimpleNamespace:
        return SimpleNamespace(mode=self._modes[voice])


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


@pytest.mark.anyio
async def test_router_serializes_capability_switches_for_concurrent_streams(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"designed": "instruction", "cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    entered = anyio.Event()
    release = anyio.Event()
    primary = _Worker("voice_design")
    clone = _BlockingWorker("base", entered, release)
    router = Qwen3TtsCapabilityRouter(primary, clone=clone)  # type: ignore[arg-type]
    await router.start()

    clone_request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")
    design_request = SpeechRequest(text="design", voice="designed", output_format="pcm16")
    results: list[str] = []

    async def run_clone() -> None:
        _ = [chunk async for chunk in router.synthesize(clone_request)]
        results.append("clone")

    async def run_design() -> None:
        _ = [chunk async for chunk in router.synthesize(design_request)]
        results.append("design")

    async with anyio.create_task_group() as tg:
        tg.start_soon(run_clone)
        await entered.wait()
        tg.start_soon(run_design)
        await anyio.lowlevel.checkpoint()
        assert clone.alive is True
        assert primary.alive is False
        assert primary.requests == []
        release.set()

    assert results == ["clone", "design"]
    assert clone.alive is False
    assert primary.alive is True
    assert primary.requests == [design_request]


@pytest.mark.anyio
async def test_router_releases_capability_lock_after_worker_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"designed": "instruction", "cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    primary = _Worker("voice_design")
    clone = _FailOnceWorker("base")
    router = Qwen3TtsCapabilityRouter(primary, clone=clone)  # type: ignore[arg-type]
    await router.start()

    clone_request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")
    with pytest.raises(RuntimeError, match="synthetic worker failure"):
        _ = [chunk async for chunk in router.synthesize(clone_request)]

    design_request = SpeechRequest(text="design", voice="designed", output_format="pcm16")
    chunks = [chunk async for chunk in router.synthesize(design_request)]
    assert chunks
    assert clone.alive is False
    assert primary.alive is True
    assert primary.requests == [design_request]
