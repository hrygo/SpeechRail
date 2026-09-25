"""Worker-side bridge from the negotiated incremental protocol to the session.

These tests exercise the parent-process half of the private wire with a loopback
transport that answers exactly like the model worker host: the start/append/
finish/cancel frames are real, the receive path is single-reader, and no model,
mlx_audio or MLX import is required.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
from collections.abc import AsyncIterator, Iterator
from pathlib import Path
from sys import executable
from types import SimpleNamespace
from typing import Any

import pytest

from speechrail.backends import qwen3_tts as qwen3_tts_module
from speechrail.backends.qwen3_tts import (
    Qwen3TtsBackendConfig,
    Qwen3TtsCapabilityRouter,
    Qwen3TtsWorker,
)
from speechrail.backends.qwen3_tts_incremental import Qwen3TtsIncrementalModelSession
from speechrail.domain.ports import AudioChunk, SpeechRequest
from speechrail.domain.tts import VoiceProfile
from speechrail.domain.tts_stream import (
    TtsStreamError,
    TtsStreamEventKind,
    TtsStreamOptions,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION

_PCM = b"\x01\x00\x02\x00"


class _LoopbackTransport:
    """Answer both the incremental wire and the batch wire from one queue."""

    def __init__(self, *, answer: bool = True) -> None:
        self.alive = True
        self.answer = answer
        self.sent: list[dict[str, Any]] = []
        self.abort_count = 0
        self._queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()

    async def send(
        self, payload: Any, binary_payload: bytes | None = None
    ) -> None:
        frame = dict(payload)
        self.sent.append(frame)
        if self.answer:
            self._answer(frame)

    async def receive(self, *, wait_for_frame: bool = False) -> dict[str, Any]:
        return await self._queue.get()

    async def abort(self) -> None:
        self.abort_count += 1
        self.alive = False

    async def start(self) -> None:  # pragma: no cover - structural compatibility
        return None

    async def close(self) -> None:
        await self.abort()

    def _answer(self, frame: dict[str, Any]) -> None:
        kind = frame.get("type")
        request_id = frame.get("request_id")
        if kind == "tts_stream_start":
            self._queue.put_nowait(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "tts_stream_started",
                    "request_id": request_id,
                    "response_id": frame.get("response_id"),
                    "sample_rate": 24_000,
                    "stream_protocol": 1,
                }
            )
        elif kind == "tts_stream_text":
            self._queue.put_nowait(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "tts_stream_text_accepted",
                    "request_id": request_id,
                    "sequence": frame.get("sequence"),
                    "accepted_codepoints": len(str(frame.get("text", ""))),
                }
            )
        elif kind == "tts_stream_finish":
            self._queue.put_nowait(_audio_frame(request_id, 0))
            self._queue.put_nowait(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "tts_stream_done",
                    "request_id": request_id,
                    "terminal": "completed",
                }
            )
        elif kind == "tts_stream_cancel":
            self._queue.put_nowait(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "tts_stream_done",
                    "request_id": request_id,
                    "terminal": "cancelled",
                }
            )
        elif kind == "synthesize":
            self._queue.put_nowait(
                {
                    "version": PROTOCOL_VERSION,
                    "type": "audio",
                    "request_id": request_id,
                    "chunk_index": 0,
                    "pcm_b64": base64.b64encode(_PCM).decode(),
                }
            )
            self._queue.put_nowait(
                {"version": PROTOCOL_VERSION, "type": "completed", "request_id": request_id}
            )


def _audio_frame(request_id: Any, chunk_index: int) -> dict[str, Any]:
    return {
        "version": PROTOCOL_VERSION,
        "type": "tts_stream_audio",
        "request_id": request_id,
        "chunk_index": chunk_index,
        "sample_offset": chunk_index * 2,
        "sample_rate": 24_000,
        "pcm_b64": base64.b64encode(_PCM).decode(),
    }


def _worker(
    tmp_path: Path,
    *,
    variant: str,
    stream_protocol: int | None,
) -> tuple[Qwen3TtsWorker, _LoopbackTransport]:
    snapshot = tmp_path.parent / f"external-qwen3-{variant}"
    snapshot.mkdir(exist_ok=True)
    (snapshot / "config.json").write_text("{}")
    worker = Qwen3TtsWorker(
        Qwen3TtsBackendConfig(
            repository_root=tmp_path,
            python_executable=Path(executable),
            model_dir=snapshot,
            model_variant=variant,  # type: ignore[arg-type]
            device="mps",
            dtype="float16",
            sample_rate=24_000,
        )
    )
    transport = _LoopbackTransport()
    worker._transport = transport  # type: ignore[assignment]
    worker._started = True
    worker._supports_profile_snapshot = True
    worker._stream_protocol = stream_protocol
    return worker, transport


def _options(voice: str = "serena", **overrides: Any) -> TtsStreamOptions:
    values: dict[str, Any] = {
        "request_id": f"req_{voice}",
        "response_id": f"resp_{voice}",
        "voice": voice,
    }
    values.update(overrides)
    return TtsStreamOptions(**values)


async def _collect(source: AsyncIterator[Any]) -> list[Any]:
    return [item async for item in source]


def test_incremental_stream_fails_closed_without_negotiation(tmp_path: Path) -> None:
    worker, transport = _worker(tmp_path, variant="custom_voice", stream_protocol=None)

    async def run() -> None:
        with pytest.raises(TtsStreamError) as raised:
            await worker.open_incremental_stream(_options())
        assert raised.value.code == "tts_streaming_unsupported"
        assert transport.sent == []

    asyncio.run(run())


def test_voice_design_binding_never_declares_incremental_support(tmp_path: Path) -> None:
    worker, transport = _worker(tmp_path, variant="voice_design", stream_protocol=1)

    async def run() -> None:
        with pytest.raises(TtsStreamError) as raised:
            await worker.open_incremental_stream(_options())
        assert raised.value.code == "tts_streaming_unsupported"
        assert transport.sent == []

    asyncio.run(run())


def test_incremental_start_frame_carries_frozen_voice_profile(tmp_path: Path) -> None:
    worker, transport = _worker(tmp_path, variant="custom_voice", stream_protocol=1)

    async def run() -> None:
        session = await worker.open_incremental_stream(_options())
        try:
            start = transport.sent[0]
            assert start["type"] == "tts_stream_start"
            assert start["stream_protocol"] == 1
            assert start["speed"] == 1.0
            assert start["language"] == "auto"
            profile = start["voice_profile"]
            assert profile["id"] == "serena"
            assert profile["mode"] == "system"
            assert profile["seed"] == 42
            assert "ref_audio" not in start
        finally:
            await session.close()

    asyncio.run(run())


def test_base_start_frame_carries_the_clone_reference(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    reference = tmp_path / "reference.wav"
    reference.write_bytes(b"RIFF")
    profile = VoiceProfile(
        id="user_voice",
        mode="clone",
        ref_text="reference text",
        audio_path=str(reference),
        revision="rev_0123456789abcdef",
    )

    @contextlib.contextmanager
    def _lease() -> Iterator[VoiceProfile]:
        yield profile

    class _Registry:
        def lease_profile(self, voice: str, *, expected_revision: str | None = None) -> Any:
            assert voice == "user_voice"
            assert expected_revision == "rev_0123456789abcdef"
            return _lease()

    monkeypatch.setattr(
        "speechrail.domain.tts.get_voice_registry", lambda: _Registry()
    )
    worker, transport = _worker(tmp_path, variant="base", stream_protocol=1)

    async def run() -> None:
        session = await worker.open_incremental_stream(
            _options("user_voice", expected_voice_revision="rev_0123456789abcdef")
        )
        try:
            start = transport.sent[0]
            assert start["ref_audio"] == str(reference)
            assert start["ref_text"] == "reference text"
            assert "voice_profile" not in start
        finally:
            await session.close()

    asyncio.run(run())


def test_stream_events_and_cancel_stay_cooperative(tmp_path: Path) -> None:
    worker, transport = _worker(tmp_path, variant="custom_voice", stream_protocol=1)

    async def run() -> None:
        session = await worker.open_incremental_stream(_options())
        await session.append_text(0, "你好")
        await session.finish_text(0)
        kinds = [event.kind async for event in session.events()]
        assert kinds[-1] is TtsStreamEventKind.COMPLETED
        assert transport.abort_count == 0

        cancelled = await worker.open_incremental_stream(_options("vivian"))
        await cancelled.cancel()
        await cancelled.cancel()
        assert transport.abort_count == 0
        terminal = [event async for event in cancelled.events()]
        assert terminal[-1].kind is TtsStreamEventKind.CANCELLED

    asyncio.run(run())


def test_batch_synthesis_waits_for_the_active_incremental_stream(tmp_path: Path) -> None:
    worker, transport = _worker(tmp_path, variant="custom_voice", stream_protocol=1)
    request = SpeechRequest(text="你好", voice="serena", output_format="pcm16")

    async def run() -> None:
        session = await worker.open_incremental_stream(_options())
        batch = asyncio.create_task(_collect(worker.synthesize(request)))
        await asyncio.sleep(0.01)
        assert not any(frame.get("type") == "synthesize" for frame in transport.sent)

        await session.close()
        chunks = await batch
        assert [frame.get("type") for frame in transport.sent if frame.get("type") == "synthesize"]
        assert len(chunks) == 1
        assert isinstance(chunks[0], AudioChunk)

    asyncio.run(run())


class _RecordingStreamWorker:
    def __init__(self) -> None:
        self.calls: list[TtsStreamOptions] = []
        self.session = object()

    async def open_incremental_stream(self, options: TtsStreamOptions) -> Any:
        self.calls.append(options)
        return self.session


class _ModeRegistry:
    def __init__(self, modes: dict[str, str]) -> None:
        self._modes = modes

    def get_profile(self, voice: str) -> Any:
        return type("_Profile", (), {"mode": self._modes[voice]})()


def test_router_routes_incremental_streams_by_voice_mode(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _ModeRegistry({"designed": "instruction", "cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    primary = _RecordingStreamWorker()
    clone = _RecordingStreamWorker()
    router = Qwen3TtsCapabilityRouter(primary, clone=clone)  # type: ignore[arg-type]

    async def run() -> None:
        clone_options = _options("cloned")
        design_options = _options("designed")
        assert await router.open_incremental_stream(clone_options) is clone.session
        assert await router.open_incremental_stream(design_options) is primary.session
        assert clone.calls == [clone_options]
        assert primary.calls == [design_options]

    asyncio.run(run())


def test_router_fails_closed_when_the_clone_lane_is_absent(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    registry = _ModeRegistry({"cloned": "clone"})
    monkeypatch.setattr("speechrail.domain.tts.get_voice_registry", lambda: registry)
    router = Qwen3TtsCapabilityRouter(_RecordingStreamWorker())  # type: ignore[arg-type]

    async def run() -> None:
        with pytest.raises(TtsStreamError) as raised:
            await router.open_incremental_stream(_options("cloned"))
        assert raised.value.code == "tts_streaming_unsupported"

    asyncio.run(run())


def test_worker_exposes_incremental_capability_from_negotiation(tmp_path: Path) -> None:
    worker, _ = _worker(tmp_path, variant="custom_voice", stream_protocol=1)
    assert worker.supports_incremental_stream is True
    assert worker.lifecycle_stats["cooperative_cancel_supported"] is True
    assert qwen3_tts_module.Qwen3TtsWorker is Qwen3TtsWorker


class _FakeDriver:
    """Minimal stand-in for mlx_audio's IncrementalSessionDriver."""

    generation_identity = "generation-1"
    sample_rate = 24_000
    prefill_target_tokens = 1
    peak_memory_bytes = 4_096

    def __init__(self, *events: Any) -> None:
        self.events = list(events)
        self.appended: list[str] = []
        self.finished = 0
        self.cancelled = 0
        self.closed = 0
        self.max_steps: list[int] = []

    def append_text(self, text: str) -> tuple[int, ...]:
        self.appended.append(text)
        return (7, 8)

    def finish_input(self) -> None:
        self.finished += 1

    def step(self, *, max_steps: int) -> Any:
        self.max_steps.append(max_steps)
        return self.events.pop(0)

    def cancel(self) -> None:
        self.cancelled += 1

    def close(self) -> None:
        self.closed += 1


def test_vendor_adapter_maps_every_driver_event() -> None:
    driver = _FakeDriver(
        SimpleNamespace(kind="pcm", pcm16=_PCM),
        SimpleNamespace(kind="waiting_for_text", pcm16=b""),
        SimpleNamespace(kind="finished", pcm16=b""),
        SimpleNamespace(kind="error", pcm16=b"", error_code="vendor_internal"),
    )
    session = Qwen3TtsIncrementalModelSession(driver)

    assert session.generation_identity == "generation-1"
    assert session.sample_rate == 24_000
    assert session.prefill_target_tokens == 1
    assert session.peak_memory_bytes == 4_096
    assert session.append_text("你好") == (7, 8)
    session.finish_input()
    assert session.step(max_steps=3).kind == "pcm"
    assert session.step(max_steps=3).kind == "waiting_for_text"
    assert session.step(max_steps=3).kind == "finished"
    failure = session.step(max_steps=3)
    assert failure.kind == "error"
    assert failure.error_code == "tts_backend_failed"
    session.cancel()
    session.close()
    assert driver.appended == ["你好"]
    assert driver.finished == 1
    assert driver.max_steps == [3, 3, 3, 3]
    assert (driver.cancelled, driver.closed) == (1, 1)
