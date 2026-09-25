"""The TTS router selects weights by plan role, never by a profile label."""

from __future__ import annotations

from collections.abc import AsyncIterator
from types import SimpleNamespace

import pytest

from speechrail.backends.qwen3_tts import Qwen3TtsCapabilityRouter
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts_stream import TtsStreamError, TtsStreamOptions

_ROLE_VARIANTS = {"tts_custom_voice": "custom_voice", "tts_base": "base"}


class _Registry:
    def __init__(self, modes: dict[str, str]) -> None:
        self._modes = modes

    def get_profile(self, voice: str) -> SimpleNamespace:
        mode = self._modes[voice]
        return SimpleNamespace(
            mode=mode,
            revision="vr_" + "0" * 32,
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


def _router(*variants: str) -> Qwen3TtsCapabilityRouter:
    return Qwen3TtsCapabilityRouter(
        {
            role: _Worker(variant)
            for role, variant in _ROLE_VARIANTS.items()
            if variant in variants
        }
    )


@pytest.mark.anyio
async def test_router_routes_builtin_speaker_and_clone_by_plan_role(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"serena": "system", "cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    router = _router("custom_voice", "base")
    custom = router._workers["tts_custom_voice"]
    base = router._workers["tts_base"]

    await router.start()
    assert router.warm_capability == "both"
    assert router.warm_capabilities == ("tts_custom_voice", "tts_base")
    assert router.resource_key_for_voice("serena") == "tts_custom_voice"
    assert router.resource_key_for_voice("cloned") == "tts_base"

    clone_request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")
    assert [chunk async for chunk in router.synthesize(clone_request)]
    builtin_request = SpeechRequest(text="hi", voice="serena", output_format="pcm16")
    assert [chunk async for chunk in router.synthesize(builtin_request)]

    assert base.requests == [clone_request]
    assert custom.requests == [builtin_request]
    assert custom.started == 1 and base.started == 1


@pytest.mark.anyio
async def test_router_rejects_clone_when_base_capability_is_absent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    router = _router("custom_voice")
    request = SpeechRequest(text="clone", voice="cloned", output_format="pcm16")

    with pytest.raises(RuntimeError, match="voice_clone_base_model_unavailable"):
        _ = [chunk async for chunk in router.synthesize(request)]


@pytest.mark.anyio
async def test_router_never_routes_design_candidates_through_runtime_synthesis(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _Registry({"designed": "instruction"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    router = _router("custom_voice", "base")
    custom = router._workers["tts_custom_voice"]
    request = SpeechRequest(text="design", voice="designed", output_format="pcm16")

    with pytest.raises(RuntimeError, match="voice_design_task_required"):
        _ = [chunk async for chunk in router.synthesize(request)]
    with pytest.raises(TtsStreamError) as raised:
        await router.open_incremental_stream(
            TtsStreamOptions(
                request_id="req_1", response_id="resp_1", voice="designed"
            )
        )

    assert raised.value.code == "tts_streaming_unsupported"
    assert custom.requests == []
    assert custom.alive is False
    assert router.resource_key_for_voice("designed") == "tts"


def test_router_rejects_a_worker_whose_variant_does_not_match_its_role() -> None:
    with pytest.raises(ValueError, match="backend_identity_mismatch"):
        Qwen3TtsCapabilityRouter({"tts_custom_voice": _Worker("base")})
    with pytest.raises(ValueError, match="unsupported TTS plan role"):
        Qwen3TtsCapabilityRouter({"narrator": _Worker("base")})


@pytest.mark.anyio
async def test_router_lifecycle_aggregates_every_plan_role() -> None:
    router = _router("custom_voice", "base")
    custom = router._workers["tts_custom_voice"]
    base = router._workers["tts_base"]
    custom.lifecycle_stats = {
        "cooperative_cancel_supported": False,
        "fallback_abort_count": 2,
        "reload_count": 1,
    }
    base.lifecycle_stats = {
        "cooperative_cancel_supported": False,
        "fallback_abort_count": 3,
        "reload_count": 4,
    }

    assert router.lifecycle_stats == {
        "cooperative_cancel_supported": False,
        "fallback_abort_count": 5,
        "reload_count": 5,
        "warm_capability": None,
        "warm_capabilities": [],
    }
    await router.trim_memory()
    assert (custom.trimmed, base.trimmed) == (1, 1)
    await router.close()
    assert (custom.closed, base.closed) == (1, 1)
