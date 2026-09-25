"""Public-wire tests for the incremental TTS extension (W8).

The fake below is a vendor-neutral ``IncrementalSpeechSession``: it owns the same
domain state table the worker uses, so these tests exercise the real
``TtsStreamService`` admission, the real ``StreamController`` lifecycle and the
Realtime translation layer end to end, without a model, MLX or real audio.
"""

from __future__ import annotations

import asyncio
import base64
import json
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from realtime_wire import (
    session_update,
    tts_append_text,
    tts_cancel,
    tts_finish_text,
    tts_start,
)
from speechrail.app import create_app
from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.domain.tts import VoiceRegistry
from speechrail.domain.tts_stream import (
    DEFAULT_TTS_STREAM_LIMITS,
    TtsStreamEvent,
    TtsStreamEventKind,
    TtsStreamOptions,
    TtsStreamStateMachine,
    TtsStreamTerminal,
)


class FakeIncrementalSession:
    """One deterministic append-only utterance owned by the parent process."""

    def __init__(
        self,
        options: TtsStreamOptions,
        *,
        audio_chunks: tuple[bytes, ...],
        fail_after_append: bool = False,
    ) -> None:
        self._options = options
        self._state = TtsStreamStateMachine(limits=DEFAULT_TTS_STREAM_LIMITS)
        self._queue: asyncio.Queue[TtsStreamEvent | None] = asyncio.Queue()
        self._audio_chunks = audio_chunks
        self._fail_after_append = fail_after_append
        self.appended: list[tuple[int, str]] = []
        self.finished: int | None = None
        self.cancelled = False
        self.closed = False
        self._chunk_index = 0
        self._sample_offset = 0

    @property
    def options(self) -> TtsStreamOptions:
        return self._options

    async def append_text(self, sequence: int, text: str) -> None:
        codepoints = self._state.accept_append(sequence, text)
        self.appended.append((sequence, text))
        await self._queue.put(
            TtsStreamEvent(
                kind=TtsStreamEventKind.TEXT_ACCEPTED,
                response_id=self._options.response_id,
                sequence=sequence,
                accepted_codepoints=codepoints,
            )
        )
        if self._fail_after_append:
            await self._queue.put(
                TtsStreamEvent(
                    kind=TtsStreamEventKind.FAILED,
                    response_id=self._options.response_id,
                    terminal=TtsStreamTerminal.FAILED,
                    error_code="tts_backend_failed",
                )
            )

    async def finish_text(self, last_sequence: int) -> None:
        self._state.accept_finish(last_sequence)
        self.finished = last_sequence
        if self._fail_after_append:
            return
        for chunk in self._audio_chunks:
            position = self._state.enqueue_audio(len(chunk))
            await self._queue.put(
                TtsStreamEvent(
                    kind=TtsStreamEventKind.AUDIO,
                    response_id=self._options.response_id,
                    pcm16=chunk,
                    chunk_index=position.chunk_index,
                    sample_offset=position.sample_offset,
                )
            )
            self._state.dequeue_audio(len(chunk))
        terminal = self._state.complete()
        await self._queue.put(
            TtsStreamEvent(
                kind=TtsStreamEventKind.COMPLETED,
                response_id=self._options.response_id,
                terminal=terminal,
            )
        )

    def events(self) -> AsyncIterator[TtsStreamEvent]:
        async def iterator() -> AsyncIterator[TtsStreamEvent]:
            yield TtsStreamEvent(
                kind=TtsStreamEventKind.STARTED, response_id=self._options.response_id
            )
            while True:
                item = await self._queue.get()
                if item is None:
                    return
                yield item

        return iterator()

    async def cancel(self) -> None:
        self.cancelled = True
        if self._state.terminal is None:
            terminal = self._state.cancel()
            await self._queue.put(
                TtsStreamEvent(
                    kind=TtsStreamEventKind.CANCELLED,
                    response_id=self._options.response_id,
                    terminal=terminal,
                )
            )

    async def close(self) -> None:
        self.closed = True
        await self._queue.put(None)


class FakeIncrementalSynthesizer:
    """Injected TTS adapter that exposes the negotiated incremental port."""

    def __init__(
        self,
        *,
        audio_chunks: tuple[bytes, ...] = (b"\x01\x02\x03\x04",),
        open_delay: float = 0.0,
        fail_after_append: bool = False,
        protocol_negotiated: bool = True,
    ) -> None:
        self.sessions: list[FakeIncrementalSession] = []
        self.open_calls = 0
        self._audio_chunks = audio_chunks
        self._open_delay = open_delay
        self._fail_after_append = fail_after_append
        self.supports_incremental_stream = protocol_negotiated

    async def open_incremental_stream(
        self, options: TtsStreamOptions
    ) -> FakeIncrementalSession:
        self.open_calls += 1
        if self._open_delay:
            await asyncio.sleep(self._open_delay)
        session = FakeIncrementalSession(
            options,
            audio_chunks=self._audio_chunks,
            fail_after_append=self._fail_after_append,
        )
        self.sessions.append(session)
        return session


_TERMINALS = frozenset(
    {
        "speechrail.tts.completed",
        "speechrail.tts.cancelled",
        "speechrail.tts.failed",
    }
)


def _tier_kwargs(tier: str = "quality") -> dict[str, Any]:
    """Build one explicit v2 selection; directory names never imply identity."""

    asr_key = required_spec_artifact(tier, "asr")  # type: ignore[arg-type]
    custom_key = required_spec_artifact(tier, "tts_custom_voice")  # type: ignore[arg-type]
    base_key = required_spec_artifact(tier, "tts_base")  # type: ignore[arg-type]
    design_key = required_spec_artifact(tier, "voice_design")  # type: ignore[arg-type]
    assert asr_key is not None and custom_key is not None and base_key is not None
    return {
        "qwen3_model_dir": Path(asr_key),
        "qwen3_python": None,
        "qwen3_tts_model_dir": Path(custom_key),
        "qwen3_tts_clone_model_dir": Path(base_key),
        "qwen3_tts_python": None,
        "selection_schema_version": 2,
        "selection_asr_spec": tier,
        "selection_tts_spec": tier,
        "asr_artifact_key": asr_key,
        "tts_artifact_key": custom_key,
        "tts_base_artifact_key": base_key,
        "voice_design_artifact_key": design_key,
    }


def _client(
    synthesizer: FakeIncrementalSynthesizer, *, tier: str = "quality"
) -> TestClient:
    return TestClient(
        create_app(Settings(**_tier_kwargs(tier)), tts_synthesizer=synthesizer)
    )


def _channel(socket: Any) -> None:
    """Negotiate caller-owned TTS on the single current session event."""

    socket.receive_json()  # session.created
    socket.send_json(session_update(tts={"enabled": True}))
    assert socket.receive_json()["type"] == "session.updated"


def _drain(socket: Any, *, limit: int = 40) -> list[dict[str, Any]]:
    """Read events up to the one namespaced terminal.

    A namespaced ``error`` is not a terminal: an utterance may report its
    failure code and then its single ``speechrail.tts.failed``.
    """

    events: list[dict[str, Any]] = []
    for _ in range(limit):
        event = socket.receive_json()
        events.append(event)
        if event["type"] in _TERMINALS:
            return events
    return events


def _until(socket: Any, kind: str, *, limit: int = 40) -> list[dict[str, Any]]:
    """Read events until ``kind`` arrives, failing instead of blocking forever."""

    events: list[dict[str, Any]] = []
    for _ in range(limit):
        event = socket.receive_json()
        events.append(event)
        if event["type"] == kind:
            return events
    raise AssertionError(f"never received {kind}: {[item['type'] for item in events]}")


def _append(socket: Any, request_id: str, sequence: int, text: str) -> None:
    socket.send_json(
        tts_append_text(request_id=request_id, sequence=sequence, text=text)
    )


def test_incremental_stream_emits_one_terminal_with_audio_positions() -> None:
    synthesizer = FakeIncrementalSynthesizer(audio_chunks=(b"\x01\x02\x03\x04", b"\x05\x06"))
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_001", voice="vivian"))
        _append(socket, "inc_001", 0, "你好，")
        _append(socket, "inc_001", 1, "世界。")
        socket.send_json(tts_finish_text(request_id="inc_001", last_sequence=1))
        events = _drain(socket)

    types = [event["type"] for event in events]
    assert types.count("speechrail.tts.started") == 1
    assert types.count("speechrail.tts.completed") == 1
    # Local TTS is never dressed up as an LLM response, and the render receipt
    # stays on REST instead of the WebSocket envelope.
    assert not [kind for kind in types if kind.startswith("response.")]
    assert "render_receipt" not in json.dumps(events)

    started = next(event for event in events if event["type"] == "speechrail.tts.started")
    assert started["limits"]["max_total_codepoints"] == 4096
    assert started["output_format"] == {
        "type": "audio/pcm",
        "sample_rate": 24_000,
        "channels": 1,
    }
    accepted = [event for event in events if event["type"] == "speechrail.tts.text_accepted"]
    # ``sequence`` belongs to the transport; the append index travels as
    # ``append_sequence`` and must not collide with it.
    assert [event["append_sequence"] for event in accepted] == [0, 1]
    assert [event["total_codepoints"] for event in accepted] == [3, 6]
    sequences = [event["sequence"] for event in events]
    assert sequences == list(range(sequences[0], sequences[0] + len(events)))
    deltas = [event for event in events if event["type"] == "speechrail.tts.audio.delta"]
    assert [event["chunk_index"] for event in deltas] == [0, 1]
    assert [event["sample_offset"] for event in deltas] == [0, 2]
    assert base64.b64decode(deltas[0]["delta"]) == b"\x01\x02\x03\x04"
    assert events[-1]["generated_samples"] == 3
    assert synthesizer.sessions[0].appended == [(0, "你好，"), (1, "世界。")]
    assert synthesizer.sessions[0].finished == 1
    assert synthesizer.sessions[0].closed is True


def test_start_does_not_block_appends_during_admission() -> None:
    synthesizer = FakeIncrementalSynthesizer(open_delay=0.05)
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_slow_open"))
        _append(socket, "inc_slow_open", 0, "第一段")
        _append(socket, "inc_slow_open", 1, "第二段")
        socket.send_json(tts_finish_text(request_id="inc_slow_open", last_sequence=1))
        events = _drain(socket)

    types = [event["type"] for event in events]
    assert types.count("speechrail.tts.started") == 1
    accepted = [
        event["append_sequence"]
        for event in events
        if event["type"] == "speechrail.tts.text_accepted"
    ]
    assert accepted == [0, 1]
    assert types[-1] == "speechrail.tts.completed"
    assert synthesizer.open_calls == 1


def test_cancel_emits_exactly_one_cancelled_terminal() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_cancel"))
        _append(socket, "inc_cancel", 0, "不要说完")
        _until(socket, "speechrail.tts.text_accepted")
        socket.send_json(tts_cancel(request_id="inc_cancel"))
        events = _drain(socket)

    types = [event["type"] for event in events]
    assert types == ["speechrail.tts.cancelled"]
    assert synthesizer.sessions[0].cancelled is True
    assert not [event for event in events if event["type"] == "speechrail.tts.audio.delta"]


def test_finish_without_audio_still_reaches_one_terminal() -> None:
    synthesizer = FakeIncrementalSynthesizer(audio_chunks=())
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_silent"))
        _append(socket, "inc_silent", 0, "静音")
        socket.send_json(tts_finish_text(request_id="inc_silent", last_sequence=0))
        events = _drain(socket)

    types = [event["type"] for event in events]
    assert types.count("speechrail.tts.completed") == 1
    assert types[-1] == "speechrail.tts.completed"
    assert "speechrail.tts.audio.delta" not in types


def test_backend_failure_reaches_one_failed_terminal() -> None:
    synthesizer = FakeIncrementalSynthesizer(fail_after_append=True)
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_fail"))
        _append(socket, "inc_fail", 0, "会失败")
        socket.send_json(tts_finish_text(request_id="inc_fail", last_sequence=0))
        events = _drain(socket)

    types = [event["type"] for event in events]
    assert types.count("speechrail.tts.failed") == 1
    terminal = events[-1]
    assert terminal["type"] == "speechrail.tts.failed"
    # The failure code rides on the single terminal instead of a second frame.
    assert terminal["error"]["code"] == "tts_backend_failed"
    assert not [event for event in events if event["type"] == "error"]


def test_append_rejects_non_contiguous_sequence_and_unknown_field() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_seq"))
        _until(socket, "speechrail.tts.started")
        _append(socket, "inc_seq", 3, "跳号")
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "tts_sequence_invalid"
        socket.send_json(
            {
                "type": "speechrail.tts.append_text",
                "request_id": "inc_seq",
                "sequence": 0,
                "text": "正常",
                "unexpected": True,
            }
        )
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "tts_request_invalid"
        socket.send_json(
            {
                "type": "speechrail.tts.append_text",
                "request_id": "inc_seq",
                "sequence": -1,
                "text": "负数",
            }
        )
        error = socket.receive_json()
        assert error["error"]["code"] == "tts_sequence_invalid"
        socket.send_json(tts_cancel(request_id="inc_seq"))
        assert socket.receive_json()["type"] == "speechrail.tts.cancelled"


def test_second_utterance_is_rejected_while_one_is_active() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_first"))
        _until(socket, "speechrail.tts.started")
        # Only one utterance may be live per connection, whatever request id a
        # second start carries.
        for request_id in ("inc_other", "inc_first", "inc_third"):
            socket.send_json(tts_start(request_id=request_id))
            error = socket.receive_json()
            assert error["error"]["code"] == "tts_in_progress"
        socket.send_json(tts_cancel(request_id="inc_first"))
        assert socket.receive_json()["type"] == "speechrail.tts.cancelled"


def test_voice_design_voice_has_no_incremental_path_on_any_surface(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An instruction voice stays design-only: every surface agrees on that."""

    registry = VoiceRegistry(tmp_path / "custom_voices.json")
    registry.create_custom_profile(
        name="W8 design",
        instruction="自然清晰的中文女声，用于设计任务。",
        voice_id="w8_design_fixture",
    )
    monkeypatch.setattr("speechrail.domain.tts._GLOBAL_VOICE_REGISTRY", registry)
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    voices = {voice["id"]: voice for voice in client.get("/v1/voices").json()["data"]}
    streaming = voices["w8_design_fixture"]["streaming"]
    assert streaming["supported"] is False
    assert streaming["reason"] == "voice_design_task_required"
    assert streaming["hint"]
    assert streaming["axes"]["variant_supported"] is False

    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(
            tts_start(request_id="inc_design", voice="w8_design_fixture")
        )
        error = socket.receive_json()
    assert error["type"] == "error"
    # A design-only profile has no runtime role, so the synthesis path refuses it
    # before any weights are touched; the REST verdict explains why.
    assert error["error"]["code"] == "voice_not_available"
    assert synthesizer.open_calls == 0


def test_start_rejects_a_widened_limit() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(
            tts_start(
                request_id="inc_limit", limits={"max_total_codepoints": 100_000}
            )
        )
        error = socket.receive_json()
        assert error["error"]["code"] == "tts_stream_limit_exceeded"
        assert synthesizer.open_calls == 0


def test_legacy_realtime_events_stay_rejected() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        for payload in (
            {"type": "transcription_session.update", "session": {}},
            {"type": "speechrail.tts.create", "request_id": "legacy", "text": "x"},
            {"type": "response.create", "response": {}},
            {"type": "response.done", "response": {}},
        ):
            socket.send_json(payload)
            error = socket.receive_json()
            assert error["type"] == "error"
            assert error["error"]["code"] == "unsupported_operation"


def test_render_receipt_tracks_only_sent_pcm() -> None:
    """A streamed utterance still books a REST receipt; the wire does not carry it."""

    async def scenario() -> tuple[list[dict[str, Any]], Any]:
        synthesizer = FakeIncrementalSynthesizer(audio_chunks=(b"\x01\x02\x03\x04",))
        services = build_app_services(
            Settings(**_tier_kwargs()),
            AppOverrides(tts_synthesizer=synthesizer),
        )
        events: list[dict[str, Any]] = []

        async def send(event: dict[str, Any]) -> int | None:
            events.append(event)
            return None

        session = OpenAIRealtimeSession(
            services, session_id="realtime_receipt", send=send
        )
        await session.start()
        await session.handle(session_update(tts={"enabled": True}))
        await session.handle(tts_start(request_id="inc_receipt"))
        await session.handle(
            tts_append_text(request_id="inc_receipt", sequence=0, text="收据")
        )
        await session.handle(
            tts_finish_text(request_id="inc_receipt", last_sequence=0)
        )
        for _ in range(200):
            if any(
                event.get("type") == "speechrail.tts.completed" for event in events
            ):
                break
            await asyncio.sleep(0.01)
        await session.close()
        return events, services

    events, services = asyncio.run(scenario())
    receipt = services.render_receipts.find_by_request_id("inc_receipt")
    assert receipt["audio"]["integrity_boundary"] == "pcm16_after_transport_send"
    assert receipt["audio"]["sample_count"] == 2
    assert receipt["audio"]["pcm_sample_rate"] == 24_000
    assert receipt["status"] == "completed"
    assert receipt["voice"]["id"] == "serena"
    assert "render_receipt" not in json.dumps(events)


def test_capability_surfaces_agree_per_voice() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    models = client.get("/v1/models").json()["data"]
    tts_model = next(item for item in models if item.get("family") == "qwen3_tts")
    streaming_input = tts_model["capabilities"]["streaming_input"]
    assert streaming_input["scope"] == "per_voice"
    assert streaming_input["axes"]["implementation_supported"] is True
    assert "supported" not in streaming_input

    voices = client.get("/v1/voices").json()["data"]
    serena = next(voice for voice in voices if voice["id"] == "serena")
    assert serena["streaming"]["supported"] is True
    assert serena["streaming"]["reason"] is None
    assert serena["streaming"]["voice_variant"] == "custom_voice"
    assert serena["streaming"]["axes"]["ready"] is True

    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        # Discovery lives on REST, so the session object advertises nothing.
        assert "speech_capabilities" not in created["session"]

    snapshot = client.get("/v1/speechrail/capabilities").json()
    snapshot_voice = next(voice for voice in snapshot["voices"] if voice["id"] == "serena")
    assert snapshot_voice["variant"] == "custom_voice"
    assert snapshot_voice["voice_revision"] == serena.get("revision")


def test_negotiation_failure_is_reported_as_unsupported() -> None:
    synthesizer = FakeIncrementalSynthesizer(protocol_negotiated=False)
    client = _client(synthesizer)
    voices = client.get("/v1/voices").json()["data"]
    serena = next(voice for voice in voices if voice["id"] == "serena")
    assert serena["streaming"]["supported"] is False
    assert serena["streaming"]["reason"] == "implementation_not_negotiated"
    assert serena["streaming"]["axes"]["protocol_negotiated"] is False
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_unnegotiated"))
        error = socket.receive_json()
    assert error["error"]["code"] == "tts_streaming_unsupported"


def test_slow_consumer_fails_the_utterance_with_backpressure() -> None:
    async def scenario() -> list[dict[str, Any]]:
        synthesizer = FakeIncrementalSynthesizer()
        settings = Settings(**_tier_kwargs())
        services = build_app_services(
            settings, AppOverrides(tts_synthesizer=synthesizer)
        )
        events: list[dict[str, Any]] = []

        async def send(event: dict[str, Any]) -> int | None:
            if event.get("type") == "speechrail.tts.audio.delta":
                await asyncio.sleep(0.3)
            events.append(event)
            return None

        session = OpenAIRealtimeSession(
            services, session_id="realtime_slow_consumer", send=send
        )
        await session.start()
        await session.handle(session_update(tts={"enabled": True}))
        await session.handle(
            tts_start(
                request_id="inc_backpressure",
                limits={"slow_consumer_seconds": 0.05},
            )
        )
        await session.handle(
            tts_append_text(
                request_id="inc_backpressure", sequence=0, text="慢消费者"
            )
        )
        await session.handle(
            tts_finish_text(request_id="inc_backpressure", last_sequence=0)
        )
        for _ in range(200):
            if any(
                event.get("type") == "speechrail.tts.failed" for event in events
            ):
                break
            await asyncio.sleep(0.01)
        await session.close()
        return events

    events = asyncio.run(scenario())
    terminals = [
        event for event in events if event.get("type") == "speechrail.tts.failed"
    ]
    assert len(terminals) == 1
    assert terminals[0]["error"]["code"] == "tts_backpressure"


def test_incremental_wire_round_trips_json_payloads() -> None:
    """Every emitted event must stay JSON-serialisable for the transport."""

    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(tts_start(request_id="inc_json"))
        _append(socket, "inc_json", 0, "json")
        socket.send_json(tts_finish_text(request_id="inc_json", last_sequence=0))
        events = _drain(socket)
    for event in events:
        assert json.loads(json.dumps(event))["type"] == event["type"]
