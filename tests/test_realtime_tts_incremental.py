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

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog
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


def _preset_kwargs(preset_id: str) -> dict[str, Any]:
    catalog = load_catalog()
    preset = catalog.preset(preset_id)
    kwargs: dict[str, Any] = {
        "qwen3_model_dir": None,
        "qwen3_python": None,
        "qwen3_tts_model_dir": Path(preset.tts),
    }
    if preset.tts_clone is not None:
        kwargs["qwen3_tts_clone_model_dir"] = Path(preset.tts_clone)
    return kwargs


def _client(
    synthesizer: FakeIncrementalSynthesizer, *, preset: str = "balanced"
) -> TestClient:
    return TestClient(create_app(Settings(**_preset_kwargs(preset)), tts_synthesizer=synthesizer))


def _channel(socket: Any, *, preset: str = "balanced") -> None:
    socket.receive_json()  # session.created
    socket.send_json(
        {
            "type": "transcription_session.update",
            "session": {"speechrail": {"tts": {"enabled": True}}},
        }
    )
    assert socket.receive_json()["type"] == "transcription_session.updated"


def _drain(socket: Any, *, limit: int = 40) -> list[dict[str, Any]]:
    """Read events up to the single terminal.

    A namespaced ``error`` is not a terminal: an incremental utterance reports
    its failure code and then its one ``response.done``, so draining stops only
    on the terminal event.
    """

    events: list[dict[str, Any]] = []
    for _ in range(limit):
        event = socket.receive_json()
        events.append(event)
        if event["type"] == "response.done":
            return events
    return events


def _append(socket: Any, request_id: str, sequence: int, text: str) -> None:
    socket.send_json(
        {
            "type": "speechrail.tts.append_text",
            "request_id": request_id,
            "sequence": sequence,
            "text": text,
        }
    )


def test_incremental_stream_emits_one_terminal_with_audio_positions() -> None:
    synthesizer = FakeIncrementalSynthesizer(audio_chunks=(b"\x01\x02\x03\x04", b"\x05\x06"))
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(
            {"type": "speechrail.tts.start", "request_id": "inc_001", "voice": "vivian"}
        )
        _append(socket, "inc_001", 0, "你好，")
        _append(socket, "inc_001", 1, "世界。")
        socket.send_json(
            {
                "type": "speechrail.tts.finish_text",
                "request_id": "inc_001",
                "last_sequence": 1,
            }
        )
        events = _drain(socket)

    types = [event["type"] for event in events]
    assert types == [
        "response.created",
        "response.output_item.added",
        "response.content_part.added",
        "speechrail.tts.started",
        "speechrail.tts.text_accepted",
        "response.output_audio_transcript.delta",
        "speechrail.tts.text_accepted",
        "response.output_audio_transcript.delta",
        "response.output_audio.delta",
        "response.output_audio.delta",
        "response.output_audio_transcript.done",
        "response.output_audio.done",
        "response.content_part.done",
        "response.output_item.done",
        "response.done",
    ]
    started = events[3]
    assert started["protocol_version"] == 1
    assert started["limits"]["max_total_codepoints"] == 4096
    assert started["voice_mode"] == "system"
    accepted = [event for event in events if event["type"] == "speechrail.tts.text_accepted"]
    # ``sequence`` belongs to the transport; the append index travels as
    # ``append_sequence`` and must not collide with it.
    assert [event["append_sequence"] for event in accepted] == [0, 1]
    assert [event["total_codepoints"] for event in accepted] == [3, 6]
    sequences = [event["sequence"] for event in events]
    assert sequences == list(range(sequences[0], sequences[0] + len(events)))
    deltas = [event for event in events if event["type"] == "response.output_audio.delta"]
    assert [event["speechrail"]["chunk_index"] for event in deltas] == [0, 1]
    assert [event["speechrail"]["sample_offset"] for event in deltas] == [0, 2]
    assert base64.b64decode(deltas[0]["delta"]) == b"\x01\x02\x03\x04"
    assert events[-1]["response"]["status"] == "completed"
    assert events[-1]["speechrail"]["kind"] == "tts"
    assert synthesizer.sessions[0].appended == [(0, "你好，"), (1, "世界。")]
    assert synthesizer.sessions[0].finished == 1
    assert synthesizer.sessions[0].closed is True


def test_start_does_not_block_appends_during_admission() -> None:
    synthesizer = FakeIncrementalSynthesizer(open_delay=0.05)
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_slow_open"})
        _append(socket, "inc_slow_open", 0, "第一段")
        _append(socket, "inc_slow_open", 1, "第二段")
        socket.send_json(
            {
                "type": "speechrail.tts.finish_text",
                "request_id": "inc_slow_open",
                "last_sequence": 1,
            }
        )
        events = _drain(socket)

    assert [event["type"] for event in events].count("speechrail.tts.started") == 1
    accepted = [
        event["append_sequence"]
        for event in events
        if event["type"] == "speechrail.tts.text_accepted"
    ]
    assert accepted == [0, 1]
    assert events[-1]["response"]["status"] == "completed"
    assert synthesizer.open_calls == 1


def test_cancel_emits_exactly_one_cancelled_terminal() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_cancel"})
        _append(socket, "inc_cancel", 0, "不要说完")
        socket.receive_json()  # response.created
        socket.receive_json()  # response.output_item.added
        socket.receive_json()  # response.content_part.added
        socket.receive_json()  # speechrail.tts.started
        socket.receive_json()  # speechrail.tts.text_accepted
        socket.receive_json()  # response.output_audio_transcript.delta
        socket.send_json({"type": "speechrail.tts.cancel", "request_id": "inc_cancel"})
        events = _drain(socket)

    types = [event["type"] for event in events]
    assert types == ["response.done"]
    assert events[0]["response"]["status"] == "cancelled"
    assert synthesizer.sessions[0].cancelled is True
    assert not [event for event in events if event["type"] == "response.output_audio.delta"]


def test_finish_without_audio_still_reaches_one_terminal() -> None:
    synthesizer = FakeIncrementalSynthesizer(audio_chunks=())
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_silent"})
        _append(socket, "inc_silent", 0, "静音")
        socket.send_json(
            {
                "type": "speechrail.tts.finish_text",
                "request_id": "inc_silent",
                "last_sequence": 0,
            }
        )
        events = _drain(socket)

    assert [event["type"] for event in events].count("response.done") == 1
    assert events[-1]["response"]["status"] == "completed"
    assert not [event for event in events if event["type"] == "response.output_audio.delta"]


def test_backend_failure_reaches_one_failed_terminal() -> None:
    synthesizer = FakeIncrementalSynthesizer(fail_after_append=True)
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_fail"})
        _append(socket, "inc_fail", 0, "会失败")
        socket.send_json(
            {
                "type": "speechrail.tts.finish_text",
                "request_id": "inc_fail",
                "last_sequence": 0,
            }
        )
        events = _drain(socket)

    assert [event["type"] for event in events].count("response.done") == 1
    terminal = events[-1]
    assert terminal["response"]["status"] == "failed"
    errors = [event for event in events if event["type"] == "error"]
    assert [event["error"]["code"] for event in errors] == ["tts_backend_failed"]


def test_append_rejects_non_contiguous_sequence_and_unknown_field() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_seq"})
        socket.receive_json()  # response.created
        socket.receive_json()  # response.output_item.added
        socket.receive_json()  # response.content_part.added
        socket.receive_json()  # speechrail.tts.started
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
        socket.send_json({"type": "speechrail.tts.cancel", "request_id": "inc_seq"})
        assert socket.receive_json()["type"] == "response.done"


def test_second_utterance_is_rejected_while_one_is_active() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_first"})
        socket.receive_json()  # response.created
        socket.receive_json()  # response.output_item.added
        socket.receive_json()  # response.content_part.added
        socket.receive_json()  # speechrail.tts.started
        socket.send_json({"type": "speechrail.tts.create", "request_id": "inc_other", "text": "x"})
        error = socket.receive_json()
        assert error["error"]["code"] == "tts_in_progress"
        # A second start shares the complete-text ordering: the activity check
        # wins, then the per-connection request-id ledger.
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_first"})
        error = socket.receive_json()
        assert error["error"]["code"] == "tts_in_progress"
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_third"})
        error = socket.receive_json()
        assert error["error"]["code"] == "tts_in_progress"
        socket.send_json({"type": "speechrail.tts.cancel", "request_id": "inc_first"})
        assert socket.receive_json()["type"] == "response.done"


def test_voice_design_voice_is_not_supported_on_the_quality_profile() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer, preset="quality")
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_design"})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "tts_streaming_unsupported"
        assert "clone" in error["error"]["message"]


def test_start_rejects_a_widened_limit() -> None:
    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json(
            {
                "type": "speechrail.tts.start",
                "request_id": "inc_limit",
                "limits": {"max_total_codepoints": 100_000},
            }
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
            {"type": "session.update", "session": {}},
            {"type": "response.create", "response": {}},
        ):
            socket.send_json(payload)
            error = socket.receive_json()
            assert error["type"] == "error"
            assert error["error"]["code"] == "unsupported_operation"


def test_render_receipt_tracks_only_sent_pcm() -> None:
    synthesizer = FakeIncrementalSynthesizer(audio_chunks=(b"\x01\x02\x03\x04",))
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        socket.receive_json()  # session.created
        socket.send_json(
            {
                "type": "transcription_session.update",
                "session": {
                    "speechrail": {
                        "tts": {"enabled": True},
                        "render_receipts": {"enabled": True},
                    }
                },
            }
        )
        assert socket.receive_json()["type"] == "transcription_session.updated"
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_receipt"})
        _append(socket, "inc_receipt", 0, "收据")
        socket.send_json(
            {
                "type": "speechrail.tts.finish_text",
                "request_id": "inc_receipt",
                "last_sequence": 0,
            }
        )
        events = _drain(socket)

    receipt = events[-1]["speechrail"]["render_receipt"]
    assert receipt["audio"]["integrity_boundary"] == "pcm16_after_transport_send"
    assert receipt["audio"]["sample_count"] == 2
    assert receipt["audio"]["pcm_sample_rate"] == 24_000
    assert receipt["status"] == "completed"
    assert receipt["voice"]["id"] == "serena"


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
        capability = created["session"]["speech_capabilities"]["streaming_tts"]
    assert capability["supported"] is True
    assert capability["axes"]["reference_ready"] is True


def test_capability_surfaces_agree_when_the_voice_has_no_incremental_path() -> None:
    """``/v1/voices`` and the handshake must not disagree about one voice."""

    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer, preset="quality")
    voices = client.get("/v1/voices").json()["data"]
    serena = next(voice for voice in voices if voice["id"] == "serena")
    assert serena["streaming"]["supported"] is False
    assert serena["streaming"]["reason"] == "variant_not_supported"
    assert serena["streaming"]["hint"]
    assert serena["streaming"]["axes"]["variant_supported"] is False

    with client.websocket_connect("/v1/realtime") as socket:
        created = socket.receive_json()
        capability = created["session"]["speech_capabilities"]["streaming_tts"]
    assert capability["supported"] is False
    assert capability["reason"] == "variant_not_supported"
    assert capability["hint"]


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
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_unnegotiated"})
        error = socket.receive_json()
    assert error["error"]["code"] == "tts_streaming_unsupported"


def test_slow_consumer_fails_the_utterance_with_backpressure() -> None:
    async def scenario() -> list[dict[str, Any]]:
        synthesizer = FakeIncrementalSynthesizer()
        settings = Settings(**_preset_kwargs("balanced"))
        services = build_app_services(
            settings, AppOverrides(tts_synthesizer=synthesizer)
        )
        events: list[dict[str, Any]] = []

        async def send(event: dict[str, Any]) -> int | None:
            if event.get("type") == "response.output_audio.delta":
                await asyncio.sleep(0.3)
            events.append(event)
            return None

        session = OpenAIRealtimeSession(
            services, session_id="realtime_slow_consumer", send=send
        )
        await session.start()
        await session.handle(
            {
                "type": "transcription_session.update",
                "session": {"speechrail": {"tts": {"enabled": True}}},
            }
        )
        await session.handle(
            {
                "type": "speechrail.tts.start",
                "request_id": "inc_backpressure",
                "limits": {"slow_consumer_seconds": 0.05},
            }
        )
        await session.handle(
            {
                "type": "speechrail.tts.append_text",
                "request_id": "inc_backpressure",
                "sequence": 0,
                "text": "慢消费者",
            }
        )
        await session.handle(
            {
                "type": "speechrail.tts.finish_text",
                "request_id": "inc_backpressure",
                "last_sequence": 0,
            }
        )
        for _ in range(200):
            if any(event.get("type") == "response.done" for event in events):
                break
            await asyncio.sleep(0.01)
        await session.close()
        return events

    events = asyncio.run(scenario())
    codes = [
        event["error"]["code"]
        for event in events
        if event.get("type") == "error" and isinstance(event.get("error"), dict)
    ]
    assert codes == ["tts_backpressure"]
    terminals = [event for event in events if event.get("type") == "response.done"]
    assert len(terminals) == 1
    assert terminals[0]["response"]["status"] == "failed"


def test_incremental_wire_round_trips_json_payloads() -> None:
    """Every emitted event must stay JSON-serialisable for the transport."""

    synthesizer = FakeIncrementalSynthesizer()
    client = _client(synthesizer)
    with client.websocket_connect("/v1/realtime") as socket:
        _channel(socket)
        socket.send_json({"type": "speechrail.tts.start", "request_id": "inc_json"})
        _append(socket, "inc_json", 0, "json")
        socket.send_json(
            {
                "type": "speechrail.tts.finish_text",
                "request_id": "inc_json",
                "last_sequence": 0,
            }
        )
        events = _drain(socket)
    for event in events:
        assert json.loads(json.dumps(event))["type"] == event["type"]
