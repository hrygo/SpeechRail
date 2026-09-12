from __future__ import annotations

from collections.abc import AsyncIterator
from types import SimpleNamespace

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
        self.trimmed = 0
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
            self.last_active += 1.0
            yield AudioChunk(
                response_id=f"{self.model_variant}-1", chunk_index=0, audio=b"\x00\x00"
            )

        return stream()

    async def trim_memory(self) -> None:
        self.trimmed += 1

    async def close(self) -> None:
        self.closed += 1
        self.alive = False
        self.ready = False


@pytest.mark.anyio
async def test_router_keeps_base_lazy_and_swaps_one_tts_model_slot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"designed": "instruction", "cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    primary = _Worker("voice_design")
    clone = _Worker("base")
    router = Qwen3TtsCapabilityRouter(primary, clone=clone)  # type: ignore[arg-type]

    await router.start()
    assert primary.alive is True
    assert clone.alive is False
    assert clone.started == 0

    clone_request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")
    assert [chunk async for chunk in router.synthesize(clone_request)]
    assert primary.alive is False
    assert primary.closed == 1
    assert clone.alive is True
    assert clone.started == 1
    assert clone.requests == [clone_request]

    design_request = SpeechRequest(text="design", voice="designed", output_format="pcm16")
    assert [chunk async for chunk in router.synthesize(design_request)]
    assert clone.alive is False
    assert clone.closed == 1
    assert primary.alive is True
    assert primary.started == 2
    assert primary.requests == [design_request]


@pytest.mark.anyio
async def test_router_rejects_clone_when_base_capability_is_absent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    router = Qwen3TtsCapabilityRouter(_Worker("custom_voice"))  # type: ignore[arg-type]
    request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")

    with pytest.raises(RuntimeError, match="voice_clone_base_model_unavailable"):
        _ = [chunk async for chunk in router.synthesize(request)]


@pytest.mark.anyio
async def test_router_lifecycle_aggregates_both_workers() -> None:
    primary = _Worker("voice_design")
    clone = _Worker("base")
    primary.lifecycle_stats = {
        "cooperative_cancel_supported": False,
        "fallback_abort_count": 2,
        "reload_count": 1,
    }
    clone.lifecycle_stats = {
        "cooperative_cancel_supported": False,
        "fallback_abort_count": 3,
        "reload_count": 4,
    }
    router = Qwen3TtsCapabilityRouter(primary, clone=clone)  # type: ignore[arg-type]

    assert router.lifecycle_stats == {
        "cooperative_cancel_supported": False,
        "fallback_abort_count": 5,
        "reload_count": 5,
        "warm_capability": None,
    }
    await router.trim_memory()
    assert (primary.trimmed, clone.trimmed) == (1, 1)
    await router.close()
    assert (primary.closed, clone.closed) == (1, 1)
