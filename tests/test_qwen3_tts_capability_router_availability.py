from __future__ import annotations

from collections.abc import AsyncIterator
from types import SimpleNamespace

import pytest

from speechrail.backends.qwen3_tts import Qwen3TtsCapabilityRouter
from speechrail.domain.ports import AudioChunk, SpeechRequest


class _Registry:
    def get_profile(self, voice: str) -> SimpleNamespace:
        mode = "clone" if voice == "cloned" else "instruction"
        return SimpleNamespace(mode=mode)


class _PrimaryWorker:
    model_variant = "voice_design"
    alive = False
    ready = False
    last_active = 0.0

    @property
    def lifecycle_stats(self) -> dict[str, int | bool]:
        return {
            "cooperative_cancel_supported": False,
            "fallback_abort_count": 0,
            "reload_count": 0,
        }

    async def start(self) -> None:
        self.alive = True
        self.ready = True

    def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        async def stream() -> AsyncIterator[AudioChunk]:
            yield AudioChunk(response_id="primary", chunk_index=0, audio=b"\x00\x00")

        return stream()

    async def trim_memory(self) -> None:
        return None

    async def close(self) -> None:
        self.alive = False
        self.ready = False


@pytest.mark.anyio
async def test_clone_request_reports_explicit_error_without_base_worker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        "speechrail.domain.tts.get_voice_registry",
        lambda: _Registry(),
    )
    primary = _PrimaryWorker()
    router = Qwen3TtsCapabilityRouter(primary)  # type: ignore[arg-type]
    request = SpeechRequest(text="test", voice="cloned", output_format="pcm16")

    with pytest.raises(RuntimeError, match="voice_clone_base_model_unavailable"):
        _ = [chunk async for chunk in router.synthesize(request)]


@pytest.mark.anyio
async def test_non_clone_request_still_uses_primary_without_base_worker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        "speechrail.domain.tts.get_voice_registry",
        lambda: _Registry(),
    )
    primary = _PrimaryWorker()
    router = Qwen3TtsCapabilityRouter(primary)  # type: ignore[arg-type]
    request = SpeechRequest(text="test", voice="designed", output_format="pcm16")

    chunks = [chunk async for chunk in router.synthesize(request)]
    assert [chunk.response_id for chunk in chunks] == ["primary"]
