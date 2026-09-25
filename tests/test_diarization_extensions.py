"""Current-wire regressions for the caller-opted diarization/alignment extension.

The single protocol schema is ``contracts/realtime-events.schema.json``.  There
is no separate ``speechrail.diarization.v1`` negotiation, no
``transcription_session.update`` and no legacy ``.segment`` /
``input_audio_buffer.committed`` event: diarization is opted in on
``session.update`` (``session.speechrail.diarization``) and its units ride on
``speechrail.diarization.updated`` / ``.done`` / ``.failed``.  These tests pin
that vocabulary end to end against a fake ASR, a fake aligner and a scripted
diarization activity port.
"""

from __future__ import annotations

import asyncio
import base64
import json
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from realtime_wire import session_update
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.compatibility.openai_realtime import (
    apply_session_update,
    diarization_done_event,
    diarization_failed,
    diarization_updated,
)
from speechrail.config import Settings
from speechrail.domain.alignment import (
    AlignmentRequest,
    AlignmentResult,
    AlignmentUnit,
)
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import (
    ActivityFrame,
    ActivityUpdate,
    SampleSpan,
)
from speechrail.domain.ports import RealtimeTranscriptionOptions, StreamingAsrEvent
from speechrail.http.routes.realtime_openai import create_openai_realtime_router

ROOT = Path(__file__).resolve().parents[1]
_SCHEMA = json.loads(
    (ROOT / "contracts" / "realtime-events.schema.json").read_text(encoding="utf-8")
)


# ---------------------------------------------------------------------------
# Schema validation: the emitted extension events are current-wire members


def _validate(def_name: str, event: dict[str, Any]) -> None:
    schema = {"$ref": f"#/$defs/{def_name}", "$defs": _SCHEMA["$defs"]}
    Draft202012Validator(schema).validate(event)


def _envelope(payload: dict[str, Any], *, sequence: int) -> dict[str, Any]:
    return {
        "event_id": f"evt-{sequence}",
        "session_id": "sess-1",
        "sequence": sequence,
        **payload,
    }


def test_runtime_extension_events_match_the_current_schema() -> None:
    units = [{"speaker": "speaker_1", "sample_span": {"start": 0, "end": 24000}}]
    _validate(
        "server_diarization_updated",
        _envelope(
            diarization_updated(
                task_id="task-1",
                epoch=0,
                utterance_id="utt-1",
                transcript_revision=1,
                metadata_revision=1,
                units=units,
            ),
            sequence=1,
        ),
    )
    _validate(
        "server_diarization_done",
        _envelope(
            diarization_done_event(
                task_id="task-1",
                epoch=0,
                utterance_id="utt-1",
                transcript_revision=1,
                metadata_revision=1,
                units=units,
            ),
            sequence=2,
        ),
    )
    _validate(
        "server_diarization_failed",
        _envelope(
            diarization_failed(
                task_id="task-1",
                epoch=0,
                utterance_id="utt-1",
                transcript_revision=1,
                metadata_revision=1,
                code="diarization_failed",
                message="failed",
            ),
            sequence=3,
        ),
    )


# ---------------------------------------------------------------------------
# Fakes


class _FakeStreamingSession:
    def __init__(self, *, language: str | None, prompt: str) -> None:
        del language, prompt
        self.received: list[bytes] = []
        self.commits = 0
        self.events_queue: asyncio.Queue[StreamingAsrEvent | None] = asyncio.Queue()

    async def connect(self) -> None:
        return None

    async def append_audio(self, audio: bytes) -> None:
        self.received.append(audio)

    async def flush(self) -> None:
        return None

    async def commit(self, want_segments: bool = False) -> None:
        del want_segments
        self.commits += 1
        await self.events_queue.put(
            StreamingAsrEvent(
                kind="completed",
                text="你好",
                language="zh",
                segments=(
                    TranscriptSegment(id=0, start_ms=0, end_ms=500, text="你好"),
                ),
            )
        )
        await self.events_queue.put(None)

    def events(self):
        async def iterator():
            while (event := await self.events_queue.get()) is not None:
                yield event

        return iterator()

    async def close(self) -> None:
        return None


class _FakeStreamingFactory:
    def __init__(self) -> None:
        self.sessions: list[_FakeStreamingSession] = []
        self.released: list[object] = []

    def create(
        self,
        *,
        language: str | None,
        prompt: str,
        options: RealtimeTranscriptionOptions,
    ) -> _FakeStreamingSession:
        del options
        session = _FakeStreamingSession(language=language, prompt=prompt)
        self.sessions.append(session)
        return session

    def release(self, session: object) -> None:
        self.released.append(session)


class _FakeActivitySession:
    """Scripted activity port: speaker ownership is independent of ASR."""

    def __init__(self, *, epoch: str, mode: str = "normal") -> None:
        self._epoch = epoch
        self._mode = mode
        self._updates: asyncio.Queue[ActivityUpdate | None] = asyncio.Queue()
        self.closed = False
        self.next_start = 0
        self._step = 0

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        if start_sample != self.next_start:
            raise ValueError("non-contiguous fake activity input")
        end = start_sample + len(pcm16) // 2
        self.next_start = end
        await self._updates.put(
            ActivityUpdate(
                epoch=self._epoch,
                step_id=self._step,
                replace_span=SampleSpan(start_sample, end),
                frames=(
                    ActivityFrame(
                        SampleSpan(start_sample, end),
                        (0.9, 0.0, 0.0, 0.0),
                        frozenset({0}),
                    ),
                )
                if end > start_sample
                else (),
                processed_through=end,
                stable_through=end,
            )
        )
        self._step += 1

    async def updates(self):
        if self._mode == "raising":
            await self._updates.get()
            raise RuntimeError("native dimension mismatch")
        while update := await self._updates.get():
            yield update

    async def finish(self, *, through_sample: int) -> None:
        if self._mode == "hanging":
            await asyncio.sleep(3600)
        assert through_sample == self.next_start
        await self._updates.put(None)

    async def cancel(self) -> None:
        self.closed = True
        await self._updates.put(None)


class _FakeDiarizationEngine:
    """Streaming-capable engine the runtime may or may not be allowed to use."""

    def __init__(self, *, supports_stream: bool, mode: str = "normal") -> None:
        self._supports_stream = supports_stream
        self._mode = mode
        self.streams: list[_FakeActivitySession] = []

    @property
    def supports_stream(self) -> bool:
        return self._supports_stream

    def open(self, *, epoch: str) -> _FakeActivitySession:
        if not self._supports_stream:
            raise RuntimeError("streaming diarization is not supported")
        session = _FakeActivitySession(epoch=epoch, mode=self._mode)
        self.streams.append(session)
        return session


class _FakeTextAligner:
    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        return AlignmentResult(
            task_id=request.task_id,
            epoch=request.epoch,
            utterance_id=request.utterance_id,
            transcript_revision=request.transcript_revision,
            units=(
                AlignmentUnit("fixed", 0, len(request.text), request.span, "segment"),
            ),
        )


class _UnavailableTextAligner:
    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        return AlignmentResult(
            task_id=request.task_id,
            epoch=request.epoch,
            utterance_id=request.utterance_id,
            transcript_revision=request.transcript_revision,
            units=(),
            failure="alignment_unavailable",
        )


def _services(
    *,
    engine: object,
    aligner: object,
    streaming_factory: object,
    drain_deadline: float = 0.3,
):
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
        realtime_diarization_drain_deadline_seconds=drain_deadline,
    )
    return build_app_services(
        settings,
        AppOverrides(
            realtime_asr_factory=streaming_factory,  # type: ignore[arg-type]
            diarization_engine=engine,  # type: ignore[arg-type]
            text_aligner=aligner,  # type: ignore[arg-type]
        ),
    )


def _client(
    *,
    supports_stream: bool,
    aligner: object | None = None,
    drain_deadline: float = 0.3,
    mode: str = "normal",
) -> tuple[TestClient, _FakeStreamingFactory]:
    streaming_factory = _FakeStreamingFactory()
    services = _services(
        engine=_FakeDiarizationEngine(supports_stream=supports_stream, mode=mode),
        aligner=aligner if aligner is not None else _FakeTextAligner(),
        streaming_factory=streaming_factory,
        drain_deadline=drain_deadline,
    )
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))
    return TestClient(app), streaming_factory


# ---------------------------------------------------------------------------
# Helpers


def _pcm16(samples: int) -> str:
    return base64.b64encode(b"\x00\x00" * samples).decode("ascii")


def _open(socket) -> dict[str, Any]:
    created = socket.receive_json()
    assert created["type"] == "session.created"
    return created


def _update_session(socket, event: dict[str, Any]) -> dict[str, Any]:
    socket.send_json(event)
    while True:
        event_out = socket.receive_json()
        if event_out["type"] in {"session.updated", "error"}:
            return event_out


def _negotiate(socket, **kwargs: Any) -> dict[str, Any]:
    return _update_session(socket, session_update(diarization={"enabled": True}, **kwargs))


def _append_and_commit(socket, samples: int) -> list[dict[str, Any]]:
    socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(samples)})
    socket.send_json({"type": "input_audio_buffer.commit"})
    events: list[dict[str, Any]] = []
    while True:
        event = socket.receive_json()
        events.append(event)
        if event["type"] in {
            "conversation.item.input_audio_transcription.completed",
            "conversation.item.input_audio_transcription.failed",
            "error",
        }:
            return events


def _collect_until(socket, event_type: str, limit: int = 64) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for _ in range(limit):
        event = socket.receive_json()
        events.append(event)
        if event["type"] == event_type:
            return events
    raise AssertionError(f"never received {event_type}")


_FINISH = "speechrail.diarization.finish"


def _finish_event(finalization_id: str) -> dict[str, str]:
    return {"type": _FINISH, "event_id": finalization_id}


# ---------------------------------------------------------------------------
# Negotiation


def test_diarization_opt_in_uses_the_session_speechrail_switch() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        updated = _negotiate(socket)

    assert updated["type"] == "session.updated"
    assert updated["session"]["speechrail"]["diarization"] == {"enabled": True}
    assert "diarization_contract" not in updated["session"]


def test_second_diarization_session_fails_busy_without_affecting_the_first() -> None:
    client, _ = _client(supports_stream=True)
    with (
        client.websocket_connect("/v1/realtime") as first,
        client.websocket_connect("/v1/realtime") as second,
    ):
        _open(first)
        _open(second)
        assert _negotiate(first)["type"] == "session.updated"
        # Opting in eagerly claims the single diarization lane, so a second
        # session cannot negotiate it until the first releases it.
        rejected = _negotiate(second)
        assert rejected["type"] == "error"
        assert rejected["error"]["code"] == "backend_busy"

        assert _negotiate(first)["type"] == "session.updated"


def test_retired_diarization_shapes_are_rejected() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        legacy = _update_session(
            socket, {"type": "transcription_session.update", "session": {}}
        )
        assert legacy["type"] == "error"
        assert legacy["error"]["code"] == "unsupported_operation"

        # Diarization belongs under session.speechrail, never inside
        # audio.input.transcription; the retired shape is an unknown field.
        nested = _update_session(
            socket,
            session_update(extra_transcription={"diarization": {"enabled": True}}),
        )
        assert nested["type"] == "error"
        assert nested["error"]["code"] == "unsupported_operation"


def test_apply_session_update_rejects_unknown_extension_values() -> None:
    event = session_update(
        diarization={"enabled": True, "extensions": ["speechrail.diarization.v2"]}
    )
    with pytest.raises(Exception) as excinfo:
        apply_session_update(
            event,
            session_id="s",
            asr_model="speechrail/qwen3-asr-1.7b",
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
            current_config={},
        )
    # The retired ``extensions`` field is rejected, not silently ignored.
    assert getattr(excinfo.value, "code", "") == "invalid_event"


# ---------------------------------------------------------------------------
# Opted-out clients and unavailable capability


def test_client_without_opt_in_never_receives_extension_types() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        assert _update_session(socket, session_update())["type"] == "session.updated"

        events = _append_and_commit(socket, 8000)
        completed = events[-1]
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert "attribution_units" not in completed
        assert "diagnostics" not in completed
        assert "event_version" not in completed
        assert all(not event["type"].startswith("speechrail.") for event in events)


def test_unavailable_diarization_is_rejected_and_session_stays_current() -> None:
    client, _ = _client(supports_stream=False)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        rejected = _negotiate(socket)
        assert rejected["type"] == "error"
        assert rejected["error"]["code"] == "diarization_not_available"

        events = _append_and_commit(socket, 8000)
        assert events[-1]["type"] == (
            "conversation.item.input_audio_transcription.completed"
        )
        assert all(not event["type"].startswith("speechrail.") for event in events)


# ---------------------------------------------------------------------------
# Negotiated delivery


def test_negotiated_session_delivers_units_on_the_wire_timeline() -> None:
    client, factory = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        assert _negotiate(socket)["type"] == "session.updated"

        first = _append_and_commit(socket, 8000)
        completed = first[-1]
        # The text final is the current transcription final: no attribution
        # units, diagnostics or event_version ride on it, and there is no
        # legacy input_audio_buffer.committed acknowledgement.
        assert completed == {
            "type": "conversation.item.input_audio_transcription.completed",
            "event_id": completed["event_id"],
            "session_id": completed["session_id"],
            "sequence": completed["sequence"],
            "item_id": completed["item_id"],
            "content_index": 0,
            "transcript": "你好",
        }
        assert all(
            event["type"] != "input_audio_buffer.committed" for event in first
        )
        assert all(
            event["type"] != "conversation.item.input_audio_transcription.segment"
            for event in first
        )
        assert all(not event["type"].startswith("speechrail.") for event in first)

        alignment = _collect_until(socket, "speechrail.alignment.done")[-1]
        assert alignment["utterance_id"] == completed["item_id"]
        text_start = alignment["units"][0]["text_start"]
        text_end = alignment["units"][0]["text_end"]
        assert (text_start, text_end) == (0, len(completed["transcript"]))
        assert alignment["units"][0]["granularity"] == "segment"
        assert all(
            unit["granularity"] in {"segment", "word", "character"}
            for unit in alignment["units"]
        )
        # The wire clock is 24 kHz while the aligner owns 16 kHz kernel spans.
        assert alignment["sample_span"]["end"] == 8000
        assert alignment["units"][0]["audio_end_sample"] <= 8000

        update = _collect_until(socket, "speechrail.diarization.updated")[-1]
        assert update["units"], "a speaker revision must carry the frozen units"
        assert all({"speaker", "sample_span"} == set(unit) for unit in update["units"])
        assert all(
            unit["sample_span"]["end"] > unit["sample_span"]["start"]
            for unit in update["units"]
        )

        second = _append_and_commit(socket, 4000)
        completed2 = second[-1]
        assert completed2["item_id"] != completed["item_id"]
        # The manual wire releases and reopens the streaming slot per commit.
        assert len(factory.sessions) == 2
        assert sum(session.commits for session in factory.sessions) == 2


def test_diarization_cannot_change_after_first_audio() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _append_and_commit(socket, 8000)

        # Enabling diarization after accepted PCM is a mid-stream modification
        # and must fail closed instead of silently changing the session.
        response = _negotiate(socket)
        assert response["type"] == "error"
        assert response["error"]["code"] == "invalid_state"


# ---------------------------------------------------------------------------
# Finish barrier and degraded terminals


def test_finish_barrier_emits_done_with_units_and_is_idempotent() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        _append_and_commit(socket, 8000)
        _collect_until(socket, "speechrail.diarization.updated")

        socket.send_json(_finish_event("final_1"))
        done = _collect_until(socket, "speechrail.diarization.done")[-1]
        assert done["units"], "the barrier reports the final speaker units"
        assert all({"speaker", "sample_span"} == set(unit) for unit in done["units"])

        # The same finalization_id replays the same terminal payload.
        socket.send_json(_finish_event("final_1"))
        replay = _collect_until(socket, "speechrail.diarization.done")[-1]
        assert replay["units"] == done["units"]
        assert replay["task_id"] == done["task_id"]

        socket.send_json(_finish_event("final_2"))
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_state"


def test_finish_rejects_further_audio() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        _append_and_commit(socket, 8000)
        socket.send_json(_finish_event("final_1"))
        _collect_until(socket, "speechrail.diarization.done")

        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(100)})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_state"


def test_hung_native_finalization_degrades_without_losing_text() -> None:
    client, _ = _client(supports_stream=True, drain_deadline=0.3, mode="hanging")
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        events = _append_and_commit(socket, 8000)
        assert events[-1]["transcript"] == "你好"

        socket.send_json(_finish_event("final_hang"))
        tail = _collect_until(socket, "speechrail.diarization.failed")
        failed = tail[-1]
        assert failed["error"]["code"] == "finalization_timeout"


def test_native_exception_sends_one_failed_event() -> None:
    client, _ = _client(supports_stream=True, mode="raising")
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(8000)})
        socket.send_json({"type": "input_audio_buffer.commit"})

        completed: dict[str, Any] | None = None
        failed: dict[str, Any] | None = None
        for _ in range(64):
            event = socket.receive_json()
            if event["type"] == "conversation.item.input_audio_transcription.completed":
                completed = event
            elif event["type"] == "speechrail.diarization.failed":
                failed = event
            if completed is not None and failed is not None:
                break

        assert completed is not None
        assert completed["transcript"] == "你好"
        assert failed is not None
        assert failed["error"]["code"] in {
            "diarization_invalid_output",
            "diarization_overloaded",
        }


def test_unavailable_alignment_emits_failed_without_rewriting_text() -> None:
    class _MisalignedStreamingSession(_FakeStreamingSession):
        async def commit(self, want_segments: bool = False) -> None:
            del want_segments
            self.commits += 1
            await self.events_queue.put(
                StreamingAsrEvent(
                    kind="completed",
                    text="不同意。",
                    language="zh",
                    segments=(
                        TranscriptSegment(id=0, start_ms=0, end_ms=500, text="同意。"),
                    ),
                )
            )
            await self.events_queue.put(None)

    class _MisalignedStreamingFactory(_FakeStreamingFactory):
        def create(
            self,
            *,
            language: str | None,
            prompt: str,
            options: RealtimeTranscriptionOptions,
        ) -> _MisalignedStreamingSession:
            del language, prompt, options
            session = _MisalignedStreamingSession(language=None, prompt="")
            self.sessions.append(session)
            return session

    services = _services(
        engine=_FakeDiarizationEngine(supports_stream=True),
        aligner=_UnavailableTextAligner(),
        streaming_factory=_MisalignedStreamingFactory(),
    )
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))
    client = TestClient(app)

    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        events = _append_and_commit(socket, 8000)
        completed = events[-1]
        assert completed["type"] == (
            "conversation.item.input_audio_transcription.completed"
        )
        assert completed["transcript"] == "不同意。"
        assert "attribution_units" not in completed

        tail = _collect_until(socket, "speechrail.alignment.failed")
        failed = tail[-1]
        assert failed["error"]["code"] == "alignment_unavailable"
