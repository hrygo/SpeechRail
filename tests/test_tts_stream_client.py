"""Deterministic tests for the parent-side incremental TTS stream client.

The integration cases drive the real worker-side host over an in-memory
transport, so the wire vocabulary, the acknowledgement path and the audio
position contract are exercised end to end without MLX or a child process.

The repository has no async pytest plugin, so every case runs its scenario
through ``asyncio.run`` exactly like the existing worker tests.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Callable, Coroutine, Mapping
from typing import Any

import pytest

from speechrail.backends.qwen3_tts_stream_client import (
    Qwen3TtsIncrementalSession,
    Qwen3TtsIncrementalSynthesizer,
)
from speechrail.backends.qwen3_tts_stream_host import (
    FRAME_STREAM_AUDIO,
    FRAME_STREAM_CANCEL,
    FRAME_STREAM_DONE,
    FRAME_STREAM_ERROR,
    FRAME_STREAM_FINISH,
    FRAME_STREAM_START,
    FRAME_STREAM_STARTED,
    FRAME_STREAM_TEXT,
    FRAME_STREAM_TEXT_ACCEPTED,
    ModelStepEvent,
    StreamFrame,
    TtsStreamHost,
)
from speechrail.domain.tts_stream import (
    TtsStreamError,
    TtsStreamEventKind,
    TtsStreamOptions,
    TtsStreamTerminal,
)
from speechrail.runtime.worker_protocol import PROTOCOL_VERSION


def _pcm(samples: int) -> bytes:
    return b"\x00\x01" * samples


def _options() -> TtsStreamOptions:
    return TtsStreamOptions(request_id="req-1", response_id="resp-1", voice="serena")


def _run(scenario: Callable[[], Coroutine[Any, Any, None]]) -> None:
    asyncio.run(scenario())


class ScriptedSession:
    """Model session whose step events are scripted by the test."""

    def __init__(self, events: list[ModelStepEvent] | None = None) -> None:
        self.sample_rate = 24_000
        self.generation_identity = "gen-scripted"
        self.prefill_target_tokens = 1
        self.events = list(events or [])
        self.appended: list[str] = []
        self.finished = False
        self.cancelled = 0
        self.closed = 0

    def append_text(self, text: str) -> tuple[int, ...]:
        if self.finished:
            raise RuntimeError("input already finished")
        self.appended.append(text)
        return tuple(range(len(text)))

    def finish_input(self) -> None:
        self.finished = True

    def step(self, *, max_steps: int) -> ModelStepEvent:
        del max_steps
        if self.events:
            return self.events.pop(0)
        if self.finished:
            # The real driver answers a closed input with EOS/pad until the
            # backend reports codec EOS, never with "waiting".
            return ModelStepEvent(kind="finished")
        return ModelStepEvent(kind="waiting_for_text")

    def cancel(self) -> None:
        self.cancelled += 1

    def close(self) -> None:
        self.closed += 1


class LoopbackTransport:
    """In-memory worker: parse commands, drive the real host, replay frames."""

    def __init__(self, session_factory: Any, *, steps_per_append: int = 3) -> None:
        self._session_factory = session_factory
        self._steps_per_append = steps_per_append
        self.host: TtsStreamHost | None = None
        self.sent: list[dict[str, object]] = []
        self.outbound: list[dict[str, object]] = []
        self.aborts = 0
        self.alive = True
        self._inbox: asyncio.Queue[dict[str, object]] = asyncio.Queue()

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        del binary_payload
        frame = dict(payload)
        self.sent.append(frame)
        self._apply(frame)

    async def receive(self, *, wait_for_frame: bool = False) -> dict[str, object]:
        del wait_for_frame
        return await self._inbox.get()

    async def abort(self) -> None:
        self.aborts += 1
        self.alive = False

    def _apply(self, frame: dict[str, object]) -> None:
        frame_type = frame["type"]
        if frame_type == FRAME_STREAM_START:
            host = TtsStreamHost(self._session_factory(), _options())
            self.host = host
            for outbound in host.started_frames():
                self._emit(outbound)
            return
        host = self.host
        assert host is not None
        if frame_type == FRAME_STREAM_TEXT:
            for outbound in host.accept_text(int(frame["sequence"]), str(frame["text"])):
                self._emit(outbound)
            for _ in range(self._steps_per_append):
                if host.terminal is not None:
                    break
                for outbound in host.step().frames:
                    self._emit(outbound)
            return
        if frame_type == FRAME_STREAM_FINISH:
            for outbound in host.finish_input(int(frame["last_sequence"])):
                self._emit(outbound)
            for _ in range(64):
                if host.terminal is not None:
                    break
                for outbound in host.step().frames:
                    self._emit(outbound)
            return
        if frame_type == FRAME_STREAM_CANCEL:
            for outbound in host.cancel():
                self._emit(outbound)

    def _emit(self, outbound: StreamFrame) -> None:
        payload = dict(outbound.payload)
        if outbound.binary is not None:
            payload["_binary"] = outbound.binary
        if outbound.on_sent is not None:
            outbound.on_sent()
        self.outbound.append(payload)
        self._inbox.put_nowait(payload)


async def _collect(events: AsyncIterator[Any], limit: int = 100) -> list[Any]:
    collected: list[Any] = []
    async for event in events:
        collected.append(event)
        if len(collected) >= limit:
            break
    return collected


async def _open(
    transport: Any, *, cancel_grace_seconds: float = 0.05
) -> Qwen3TtsIncrementalSession:
    synth = Qwen3TtsIncrementalSynthesizer(
        transport,
        stream_protocol=1,
        cancel_grace_seconds=cancel_grace_seconds,
    )
    return await synth.open_stream(_options())


def test_unsupported_worker_fails_closed_before_sending() -> None:
    async def scenario() -> None:
        transport = LoopbackTransport(ScriptedSession)
        synth = Qwen3TtsIncrementalSynthesizer(transport, stream_protocol=None)
        assert synth.supported is False
        with pytest.raises(TtsStreamError) as failure:
            await synth.open_stream(_options())
        assert failure.value.code == "tts_streaming_unsupported"
        assert transport.sent == []

    _run(scenario)


def test_append_is_acknowledged_and_audio_arrives_before_finish() -> None:
    async def scenario() -> None:
        def factory() -> ScriptedSession:
            # The fake keeps answering "waiting" until input closes, then it
            # reports the codec EOS that the real driver only allows afterwards.
            return ScriptedSession(
                events=[
                    ModelStepEvent(kind="pcm", pcm16=_pcm(120)),
                    ModelStepEvent(kind="waiting_for_text"),
                    ModelStepEvent(kind="pcm", pcm16=_pcm(80)),
                ]
            )

        transport = LoopbackTransport(factory)
        session = await _open(transport)
        await session.append_text(0, "你好，")
        # Audio is already flowing while the text side is still open.
        assert session.terminal is None
        assert any(frame["type"] == FRAME_STREAM_AUDIO for frame in transport.outbound)
        await session.append_text(1, "继续。")
        await session.finish_text(1)
        events = await _collect(session.events())

        assert events[0].kind is TtsStreamEventKind.STARTED
        audio = [event for event in events if event.kind is TtsStreamEventKind.AUDIO]
        assert [event.sample_offset for event in audio] == [0, 120]
        assert [event.chunk_index for event in audio] == [0, 1]
        assert [event.pcm16 for event in audio] == [_pcm(120), _pcm(80)]
        assert events[-1].kind is TtsStreamEventKind.COMPLETED
        assert events[-1].terminal is TtsStreamTerminal.COMPLETED
        assert transport.host is not None
        assert transport.host.terminal is TtsStreamTerminal.COMPLETED

    _run(scenario)


def test_audio_burst_is_paced_without_losing_chunks_or_the_terminal() -> None:
    async def scenario() -> None:
        transport = ScriptedTransport([_frame(FRAME_STREAM_STARTED)])
        session = await _open(transport)

        append = asyncio.create_task(session.append_text(0, ""))
        await asyncio.sleep(0)
        transport.push(
            _frame(FRAME_STREAM_TEXT_ACCEPTED, sequence=0, accepted_codepoints=0)
        )
        await append
        await session.finish_text(0)

        chunk_count = 96
        for index in range(chunk_count):
            transport.push(
                _frame(
                    FRAME_STREAM_AUDIO,
                    chunk_index=index,
                    sample_offset=index * 10,
                    _binary=_pcm(10),
                )
            )
        transport.push(_frame(FRAME_STREAM_DONE, terminal="completed"))

        events = await asyncio.wait_for(
            _collect(session.events(), limit=chunk_count + 4), timeout=2.0
        )
        audio = [event for event in events if event.kind is TtsStreamEventKind.AUDIO]
        assert [event.chunk_index for event in audio] == list(range(chunk_count))
        assert [event.sample_offset for event in audio] == [
            index * 10 for index in range(chunk_count)
        ]
        assert events[-1].kind is TtsStreamEventKind.COMPLETED
        assert events[-1].terminal is TtsStreamTerminal.COMPLETED

    _run(scenario)


def test_sequence_gap_is_rejected_locally_without_a_round_trip() -> None:
    async def scenario() -> None:
        transport = LoopbackTransport(ScriptedSession)
        session = await _open(transport)
        await session.append_text(0, "abc")
        sent_before = len(transport.sent)
        with pytest.raises(TtsStreamError) as failure:
            await session.append_text(2, "def")
        assert failure.value.code == "tts_sequence_invalid"
        assert len(transport.sent) == sent_before
        await session.finish_text(0)
        events = await _collect(session.events())
        assert events[-1].terminal is TtsStreamTerminal.COMPLETED

    _run(scenario)


def test_finish_requires_the_last_accepted_sequence() -> None:
    async def scenario() -> None:
        transport = LoopbackTransport(ScriptedSession)
        session = await _open(transport)
        await session.append_text(0, "abc")
        with pytest.raises(TtsStreamError) as failure:
            await session.finish_text(4)
        assert failure.value.code == "tts_sequence_invalid"
        await session.finish_text(0)
        events = await _collect(session.events())
        assert events[-1].terminal is TtsStreamTerminal.COMPLETED

    _run(scenario)


def test_cancel_reports_a_single_cancelled_terminal() -> None:
    async def scenario() -> None:
        transport = LoopbackTransport(ScriptedSession)
        session = await _open(transport)
        await session.append_text(0, "abc")
        await session.cancel()
        await session.cancel()
        events = await _collect(session.events())
        terminals = [
            event for event in events if event.kind is TtsStreamEventKind.CANCELLED
        ]
        assert len(terminals) == 1
        assert terminals[0].terminal is TtsStreamTerminal.CANCELLED
        assert any(frame["type"] == FRAME_STREAM_CANCEL for frame in transport.sent)
        assert transport.host is not None
        assert transport.host.terminal is TtsStreamTerminal.CANCELLED

    _run(scenario)


def test_close_cancels_a_live_session_without_hanging() -> None:
    async def scenario() -> None:
        transport = LoopbackTransport(ScriptedSession)
        session = await _open(transport)
        await session.append_text(0, "abc")
        await asyncio.wait_for(session.close(), timeout=2.0)
        events = await _collect(session.events())
        assert any(event.kind is TtsStreamEventKind.CANCELLED for event in events)
        assert transport.aborts == 0

    _run(scenario)


class ScriptedTransport:
    """Replay canned worker frames for the pure client-side failure paths."""

    def __init__(self, frames: list[dict[str, object]] | None = None) -> None:
        self._inbox: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self.sent: list[dict[str, object]] = []
        self.aborts = 0
        self.alive = True
        for frame in frames or []:
            self.push(frame)

    def push(self, frame: dict[str, object]) -> None:
        self._inbox.put_nowait(frame)

    async def send(
        self, payload: Mapping[str, object], binary_payload: bytes | None = None
    ) -> None:
        del binary_payload
        self.sent.append(dict(payload))

    async def receive(self, *, wait_for_frame: bool = False) -> dict[str, object]:
        del wait_for_frame
        return await self._inbox.get()

    async def abort(self) -> None:
        self.aborts += 1
        self.alive = False


def _frame(frame_type: str, **extra: object) -> dict[str, object]:
    base: dict[str, object] = {
        "version": PROTOCOL_VERSION,
        "type": frame_type,
        "request_id": "req-1",
    }
    base.update(extra)
    return base


def test_terminal_error_frame_becomes_a_failed_event() -> None:
    async def scenario() -> None:
        transport = ScriptedTransport(
            [
                _frame(FRAME_STREAM_STARTED),
                _frame(FRAME_STREAM_ERROR, code="tts_backpressure", terminal=True),
            ]
        )
        session = await _open(transport)
        events = await _collect(session.events())
        assert events[-1].kind is TtsStreamEventKind.FAILED
        assert events[-1].error_code == "tts_backpressure"

    _run(scenario)


def test_unregistered_worker_error_code_normalises() -> None:
    async def scenario() -> None:
        transport = ScriptedTransport(
            [
                _frame(FRAME_STREAM_STARTED),
                _frame(
                    FRAME_STREAM_ERROR,
                    code="codec_eos_before_text_eos",
                    terminal=True,
                ),
            ]
        )
        session = await _open(transport)
        events = await _collect(session.events())
        assert events[-1].error_code == "tts_backend_failed"

    _run(scenario)


def test_recoverable_rejection_releases_the_waiting_append() -> None:
    async def scenario() -> None:
        transport = ScriptedTransport([_frame(FRAME_STREAM_STARTED)])
        session = await _open(transport)
        waiter = asyncio.create_task(session.append_text(0, "abc"))
        await asyncio.sleep(0)
        transport.push(
            _frame(
                FRAME_STREAM_ERROR,
                code="tts_sequence_invalid",
                terminal=False,
                sequence=0,
            )
        )
        with pytest.raises(TtsStreamError) as failure:
            await asyncio.wait_for(waiter, timeout=2.0)
        assert failure.value.code == "tts_sequence_invalid"
        assert session.notices == ("tts_sequence_invalid",)
        await session.close()

    _run(scenario)


def test_foreign_request_id_fails_the_utterance() -> None:
    async def scenario() -> None:
        transport = ScriptedTransport(
            [
                _frame(FRAME_STREAM_STARTED),
                {"version": PROTOCOL_VERSION, "type": FRAME_STREAM_DONE, "request_id": "other"},
            ]
        )
        session = await _open(transport)
        events = await _collect(session.events())
        assert events[-1].kind is TtsStreamEventKind.FAILED
        assert events[-1].error_code == "tts_backend_failed"

    _run(scenario)


def test_non_contiguous_audio_positions_fail_the_utterance() -> None:
    async def scenario() -> None:
        transport = ScriptedTransport(
            [
                _frame(FRAME_STREAM_STARTED),
                _frame(
                    FRAME_STREAM_AUDIO, chunk_index=1, sample_offset=0, _binary=_pcm(10)
                ),
            ]
        )
        session = await _open(transport)
        events = await _collect(session.events())
        assert events[-1].kind is TtsStreamEventKind.FAILED

    _run(scenario)


def test_start_timeout_aborts_only_this_worker_child() -> None:
    async def scenario() -> None:
        transport = ScriptedTransport()
        synth = Qwen3TtsIncrementalSynthesizer(
            transport, stream_protocol=1, io_timeout_seconds=0.05
        )
        with pytest.raises(TtsStreamError) as failure:
            await synth.open_stream(_options())
        assert failure.value.code == "tts_input_timeout"
        assert transport.aborts == 1

    _run(scenario)


def test_started_frame_never_carries_audio() -> None:
    async def scenario() -> None:
        transport = LoopbackTransport(ScriptedSession)
        session = await _open(transport)
        started = transport.outbound[0]
        assert started["type"] == FRAME_STREAM_STARTED
        assert "_binary" not in started
        await session.close()

    _run(scenario)


def test_text_accepted_frame_is_emitted_for_every_append() -> None:
    async def scenario() -> None:
        transport = LoopbackTransport(ScriptedSession)
        session = await _open(transport)
        await session.append_text(0, "abc")
        await session.append_text(1, "de")
        acks = [
            frame for frame in transport.outbound if frame["type"] == FRAME_STREAM_TEXT_ACCEPTED
        ]
        assert [(frame["sequence"], frame["accepted_codepoints"]) for frame in acks] == [
            (0, 3),
            (1, 2),
        ]
        await session.cancel()

    _run(scenario)
