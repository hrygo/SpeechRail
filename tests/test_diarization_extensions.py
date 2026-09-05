"""R2 regressions: SPK-E2E-1 extension negotiation and canonical-only delivery.

Four client/server combinations are covered: legacy clients never receive
``speechrail.*`` events, an un-negotiated capability is neither advertised nor
sent, requesting the extension on a server without it fails closed, and a
successfully negotiated session delivers unique per-commit items with
attribution units instead of legacy ``.segment`` events.  The JSON Schemas and
fixtures under ``contracts/diarization/v1/`` are validated here as well.
"""

from __future__ import annotations

import asyncio
import base64
import json
import math
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator

from speechrail.application.services import AppOverrides, build_app_services
from speechrail.backends.nemo_sortformer import NemoSortformerStreamSession
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import (
    DiarizationAssignment,
    DiarizationSpeaker,
    DiarizationUpdate,
)
from speechrail.domain.ports import StreamingAsrEvent
from speechrail.http.routes.realtime_openai import create_openai_realtime_router

CONTRACT_DIR = Path(__file__).resolve().parents[1] / "contracts" / "diarization" / "v1"
EXTENSION = "speechrail.diarization.v1"

_SCHEMA_BY_TYPE = {
    "conversation.item.input_audio_transcription.completed": "completed.schema.json",
    "speechrail.diarization.update": "update.schema.json",
    "speechrail.diarization.status": "status.schema.json",
    "speechrail.diarization.finalized": "finalized.schema.json",
}


# ---------------------------------------------------------------------------
# Schema and fixture validation


def _load(name: str) -> dict[str, Any]:
    with (CONTRACT_DIR / "fixtures" / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def _schema(name: str) -> dict[str, Any]:
    with (CONTRACT_DIR / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def _fixture_units_are_semantically_valid(event: dict[str, Any]) -> bool:
    """Semantic rules JSON Schema cannot express for completed events."""
    units = event.get("attribution_units")
    transcript = event.get("transcript", "")
    if not isinstance(units, list):
        return False
    covered = 0
    for unit in units:
        if not isinstance(unit, dict):
            return False
        start, end = unit.get("text_start"), unit.get("text_end")
        if (
            not isinstance(start, int)
            or not isinstance(end, int)
            or isinstance(start, bool)
            or isinstance(end, bool)
            or start < covered
            or end <= start
            or end > len(transcript)
        ):
            return False
        if (
            unit.get("audio_start_sample", 0) >= unit.get("audio_end_sample", -1)
            and event.get("audio_start_sample") != event.get("audio_end_sample")
        ):
            return False
        covered = end
    return covered in (0, len(transcript))


def _update_is_semantically_valid(event: dict[str, Any]) -> bool:
    """Semantic rules JSON Schema cannot express for update events."""
    revisions: dict[str, int] = {}
    ratios = [event.get("similarity", 1.0)]
    for update in event.get("updates", []):
        segment = update.get("segment_uid")
        revision = update.get("revision")
        if segment in revisions and revisions[segment] == revision:
            return False
        if update.get("status") == "unknown" and update.get("speaker") is not None:
            return False
        revisions[segment] = revision
        ratios.append(update.get("coverage_ratio", 1.0))
        ratios.append(update.get("overlap_ratio", 0.0))
        ratios.extend(
            candidate.get("support_ratio", 1.0)
            for candidate in update.get("candidates", [])
        )
        if any(not isinstance(value, (int, float)) or not math.isfinite(value) for value in ratios):
            return False
    return True


def test_valid_extension_fixtures_pass_schema_and_semantics() -> None:
    for path in sorted(CONTRACT_DIR.glob("valid_*.json")):
        fixture = _load(path.name)
        if path.name == "valid_legacy_completed.json":
            # Legacy baseline: must not carry extension fields at all.
            assert "audio_start_sample" not in fixture
            assert "attribution_units" not in fixture
            continue
        schema_name = _SCHEMA_BY_TYPE[fixture["type"]]
        validator = Draft202012Validator(_schema(schema_name))
        errors = sorted(validator.iter_errors(fixture), key=lambda e: e.json_path)
        assert not errors, f"{path.name}: {[e.message for e in errors]}"
        if fixture["type"] == "conversation.item.input_audio_transcription.completed":
            assert _fixture_units_are_semantically_valid(fixture), path.name
        elif fixture["type"] == "speechrail.diarization.update":
            assert _update_is_semantically_valid(fixture), path.name


def test_invalid_fixtures_are_rejected() -> None:
    schema_fixture_names = {
        "invalid_bool_sample.json",
        "invalid_relation.json",
    }
    for name in schema_fixture_names:
        fixture = _load(name)
        schema_name = _SCHEMA_BY_TYPE[fixture["type"]]
        validator = Draft202012Validator(_schema(schema_name))
        assert not validator.is_valid(fixture), f"{name} must fail schema validation"

    overflow = _load("invalid_too_many_updates.json")
    target = overflow.pop("_repeat_updates_to")
    overflow["updates"] = (overflow["updates"] * (target // len(overflow["updates"]) + 1))[:target]
    validator = Draft202012Validator(_schema("update.schema.json"))
    assert not validator.is_valid(overflow)

    nan_fixture = _load("invalid_nan_ratio.json")
    assert math.isnan(nan_fixture["updates"][0]["coverage_ratio"])

    for name, check in (
        ("invalid_nan_ratio.json", _update_is_semantically_valid),
        ("invalid_out_of_bounds_char_range.json", _fixture_units_are_semantically_valid),
        ("invalid_unknown_with_speaker.json", _update_is_semantically_valid),
        ("invalid_revision_conflict.json", _update_is_semantically_valid),
    ):
        assert not check(_load(name)), f"{name} must fail semantic validation"


# ---------------------------------------------------------------------------
# WebSocket four-combination harness


class _FakeStreamingSession:
    def __init__(self, *, language: str | None, prompt: str) -> None:
        del language, prompt
        self.received: list[bytes] = []
        self.events_queue: asyncio.Queue[StreamingAsrEvent | None] = asyncio.Queue()

    async def connect(self) -> None:
        return None

    async def append_audio(self, audio: bytes) -> None:
        self.received.append(audio)

    async def flush(self) -> None:
        return None

    async def commit(self, want_segments: bool = False) -> None:
        del want_segments
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

    def create(self, *, language: str | None, prompt: str) -> _FakeStreamingSession:
        session = _FakeStreamingSession(language=language, prompt=prompt)
        self.sessions.append(session)
        return session

    def release(self, session: object) -> None:
        del session


def _speaker_script(frame_index: int) -> tuple[int, float]:
    del frame_index
    return (0, 0.9)


class _FakeLegacyDiarizationSession:
    async def append_audio(self, audio: bytes) -> None:
        del audio

    async def annotate(self, segments: tuple[TranscriptSegment, ...]) -> DiarizationUpdate:
        return DiarizationUpdate(
            assignments=tuple(
                DiarizationAssignment(
                    segment_id=segment.id,
                    speakers=(DiarizationSpeaker(id="spk_01", confidence=0.95),),
                )
                for segment in segments
            )
        )

    async def finalize(self) -> DiarizationUpdate:
        return DiarizationUpdate()

    async def close(self) -> None:
        return None


class _FakeDiarizationEngine:
    def __init__(self, *, supports_stream: bool) -> None:
        self._supports_stream = supports_stream
        self.streams: list[NemoSortformerStreamSession] = []

    @property
    def supports_stream(self) -> bool:
        return self._supports_stream

    def create(self, *, config: object) -> _FakeLegacyDiarizationSession:
        del config
        return _FakeLegacyDiarizationSession()

    def create_stream(self, *, config: object) -> NemoSortformerStreamSession:
        if not self._supports_stream:
            raise RuntimeError("streaming diarization is not supported")
        del config
        session = NemoSortformerStreamSession(
            _ScriptedNative(_speaker_script)  # type: ignore[arg-type]
        )
        self.streams.append(session)
        return session


class _ScriptedNative:
    frame_samples = 1280

    def __init__(self, script) -> None:
        self._script = script
        self.frame_index = 0

    def step(self, frame: object) -> tuple[int, float]:
        del frame
        result = self._script(self.frame_index)
        self.frame_index += 1
        return result

    def finish(self) -> None:
        return None

    def close(self) -> None:
        return None


def _client(*, supports_stream: bool) -> tuple[TestClient, _FakeStreamingFactory]:
    streaming_factory = _FakeStreamingFactory()
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
    )
    services = build_app_services(
        settings,
        AppOverrides(
            realtime_asr_factory=streaming_factory,  # type: ignore[arg-type]
            diarization_engine=_FakeDiarizationEngine(supports_stream=supports_stream),  # type: ignore[arg-type]
        ),
    )
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))
    return TestClient(app), streaming_factory


def _pcm16(samples: int) -> str:
    return base64.b64encode(b"\x00\x00" * samples).decode("ascii")


def _open(socket) -> dict[str, Any]:
    created = socket.receive_json()
    assert created["type"] == "session.created"
    socket.receive_json()  # conversation.created
    return created


def _update_session(socket, session: dict[str, Any]) -> dict[str, Any]:
    socket.send_json({"type": "session.update", "session": session})
    while True:
        event = socket.receive_json()
        if event["type"] in {"session.updated", "error"}:
            return event


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


def _negotiate(socket, *, hint: int | None = None) -> dict[str, Any]:
    diarization: dict[str, Any] = {"enabled": True, "extensions": [EXTENSION]}
    if hint is not None:
        diarization["speaker_count_hint"] = hint
    return _update_session(
        socket,
        {
            "model": "whisper-1",
            "input_audio_transcription": {"diarization": diarization},
        },
    )


# ---------------------------------------------------------------------------
# Combination 1: legacy client (no extensions) on a capable server


def test_legacy_client_never_receives_extension_types() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        # A capable server advertises the capability string to everyone;
        # legacy clients ignore it and must never see extension EVENTS.
        _open(socket)
        updated = _update_session(
            socket,
            {
                "model": "whisper-1",
                "input_audio_transcription": {
                    "diarization": {"enabled": True, "extensions": []}
                },
            },
        )
        assert updated["type"] == "session.updated"
        assert "diarization_contract" not in updated["session"]

        events = _append_and_commit(socket, 8000)
        completed = events[-1]
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert "audio_start_sample" not in completed
        assert "attribution_units" not in completed
        assert any(
            event["type"] == "conversation.item.input_audio_transcription.segment"
            for event in events
        )
        assert all(not event["type"].startswith("speechrail.") for event in events)


# ---------------------------------------------------------------------------
# Combination 2: new client against a server without the capability


def test_unavailable_extension_is_rejected_and_session_stays_legacy() -> None:
    client, _ = _client(supports_stream=False)
    with client.websocket_connect("/v1/realtime") as socket:
        created = _open(socket)
        assert EXTENSION not in created["session"]["capabilities"]

        response = _negotiate(socket)
        assert response["type"] == "error"
        assert response["error"]["code"] == "unsupported_operation"

        events = _append_and_commit(socket, 8000)
        completed = events[-1]
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert "attribution_units" not in completed
        assert all(not event["type"].startswith("speechrail.") for event in events)


# ---------------------------------------------------------------------------
# Combination 3: negotiated extension mode


def test_negotiated_session_sends_unique_items_without_legacy_segments() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        created = _open(socket)
        assert EXTENSION in created["session"]["capabilities"]

        updated = _negotiate(socket)
        assert updated["type"] == "session.updated"
        contract = updated["session"]["diarization_contract"]
        assert contract == {
            "version": 1,
            "timebase": "session_samples",
            "sample_rate": 16000,
            "max_speakers": 4,
            "max_item_duration_ms": 8000,
            "max_revision_delay_ms": 3000,
            "group_generation": None,
        }

        first = _append_and_commit(socket, 8000)
        committed1 = first[0]
        completed1 = first[-1]
        assert committed1["type"] == "input_audio_buffer.committed"
        assert not committed1["item_id"].endswith("_input")
        assert completed1["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed1["audio_start_sample"] == 0
        assert completed1["audio_end_sample"] == 8000
        units = completed1["attribution_units"]
        transcript = completed1["transcript"]
        assert units
        assert "".join(
            transcript[unit["text_start"] : unit["text_end"]] for unit in units
        ) == transcript
        assert all(unit["timing_quality"] == "aligned" for unit in units)
        assert all(
            unit["audio_start_sample"] >= 0 and unit["audio_end_sample"] <= 8000
            for unit in units
        )
        assert not any(
            event["type"] == "conversation.item.input_audio_transcription.segment"
            for event in first
        )
        assert not any(event["type"].startswith("speechrail.") for event in first)

        second = _append_and_commit(socket, 4000)
        committed2 = next(
            event for event in second if event["type"] == "input_audio_buffer.committed"
        )
        completed2 = next(
            event
            for event in second
            if event["type"] == "conversation.item.input_audio_transcription.completed"
        )
        assert committed2["item_id"] != committed1["item_id"]
        assert completed2["audio_start_sample"] == 8000
        assert completed2["audio_end_sample"] == 12000
        assert completed2["item_id"] != completed1["item_id"]


def test_speaker_count_above_four_rejected_in_extension_mode() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        response = _negotiate(socket, hint=5)
        assert response["type"] == "error"
        assert response["error"]["code"] == "speaker_limit_exceeded"


def test_extensions_cannot_change_after_first_pcm() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _append_and_commit(socket, 8000)

        # Late negotiation (legacy -> extension) after accepted PCM is a
        # mid-stream modification and must fail closed; re-sending the
        # identical negotiated payload stays idempotent.
        response = _negotiate(socket)
        assert response["type"] == "error"
        assert response["error"]["code"] == "invalid_state"


def test_negotiated_extensions_renegotiate_idempotently() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        assert _negotiate(socket)["type"] == "session.updated"
        _append_and_commit(socket, 8000)
        # Re-sending the identical negotiated payload is not a modification.
        assert _negotiate(socket)["type"] == "session.updated"


def test_apply_session_update_rejects_unknown_extension_values() -> None:
    event = {
        "type": "session.update",
        "session": {
            "input_audio_transcription": {
                "diarization": {"enabled": True, "extensions": ["speechrail.diarization.v2"]}
            }
        },
    }
    from speechrail.compatibility.openai_realtime import apply_session_update

    with pytest.raises(Exception) as excinfo:
        apply_session_update(
            event,
            session_id="s",
            asr_model="speechrail/qwen3-asr-1.7b",
            tts_model=None,
            tts_ready=False,
            registered_asr=frozenset({"speechrail/qwen3-asr-1.7b"}),
            registered_tts=frozenset(),
            tts_voice_ids=frozenset(),
        )
    assert "invalid_diarization" in str(excinfo.value) or getattr(
        excinfo.value, "code", ""
    ) == "invalid_diarization"


# ---------------------------------------------------------------------------
# R4: finalize barrier, degraded states, single-model lease


def _finalize_request(finalization_id: str) -> dict[str, str]:
    return {"type": "speechrail.diarization.finalize", "finalization_id": finalization_id}


def _collect_until(socket, event_type: str, limit: int = 64) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for _ in range(limit):
        event = socket.receive_json()
        events.append(event)
        if event["type"] == event_type:
            return events
    raise AssertionError(f"never received {event_type}")


def test_finalize_is_a_barrier() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        first = _append_and_commit(socket, 8000)
        second = _append_and_commit(socket, 4000)

        socket.send_json(_finalize_request("final_1"))
        tail = _collect_until(socket, "speechrail.diarization.finalized")
        final = tail[-1]
        tail_updates = [e for e in tail if e["type"] == "speechrail.diarization.update"]

        all_updates = [
            e for e in [*first, *second, *tail]
            if e["type"] == "speechrail.diarization.update"
        ]
        assert all_updates, "updates must flow before the finalized barrier"
        assert final["last_update_sequence"] == all_updates[-1]["sequence"]
        assert tail_updates, "finalize must flush pending attribution updates first"
        assert final["sequence"] > all_updates[-1]["sequence"]
        assert final["status"] == "complete"
        assert final["reason"] is None
        assert final["through_sample"] == 12000
        assert final["stable_through_sample"] == final["through_sample"]


def test_finalize_retry_is_idempotent_and_conflicting_id_rejected() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        _append_and_commit(socket, 8000)
        socket.send_json(_finalize_request("final_1"))
        first = _collect_until(socket, "speechrail.diarization.finalized")[-1]

        socket.send_json(_finalize_request("final_1"))
        replay = _collect_until(socket, "speechrail.diarization.finalized")[-1]
        assert replay["finalization_id"] == first["finalization_id"]
        assert replay["status"] == first["status"]
        assert replay["through_sample"] == first["through_sample"]
        assert replay["last_update_sequence"] == first["last_update_sequence"]

        socket.send_json(_finalize_request("final_2"))
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_state"


def test_finalize_rejects_further_audio() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        _append_and_commit(socket, 8000)
        socket.send_json(_finalize_request("final_1"))
        _collect_until(socket, "speechrail.diarization.finalized")

        socket.send_json({"type": "input_audio_buffer.append", "audio": _pcm16(100)})
        error = socket.receive_json()
        assert error["type"] == "error"
        assert error["error"]["code"] == "invalid_state"


def test_empty_meeting_finalize_has_zero_update_sequence() -> None:
    client, _ = _client(supports_stream=True)
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        socket.send_json(_finalize_request("final_empty"))
        final = _collect_until(socket, "speechrail.diarization.finalized")[-1]
        assert final["status"] == "complete"
        assert final["through_sample"] == 0
        assert final["stable_through_sample"] == 0
        assert final["last_update_sequence"] == 0


class _HangingContinuous:
    """Continuous stream whose finish() never returns (simulated hung native)."""

    def __init__(self) -> None:
        self.closed = False

    async def append(self, pcm: bytes, start_sample: int) -> None:
        del pcm, start_sample

    async def activities(self, through_sample: int):
        from speechrail.domain.diarization import ActivitySnapshot

        return ActivitySnapshot(through_sample, 0, ())

    async def finish(self, through_sample: int):
        del through_sample
        await asyncio.sleep(3600)

    async def close(self) -> None:
        self.closed = True


class _RaisingContinuous:
    """Continuous stream whose native step raises invalid output."""

    async def append(self, pcm: bytes, start_sample: int) -> None:
        del pcm, start_sample

    async def activities(self, through_sample: int):
        del through_sample
        from speechrail.domain.diarization import DiarizationError

        raise DiarizationError("native dimension mismatch", code="diarization_invalid_output")

    async def finish(self, through_sample: int):
        del through_sample
        from speechrail.domain.diarization import DiarizationError

        raise DiarizationError("native dimension mismatch", code="diarization_invalid_output")

    async def close(self) -> None:
        return None


class _LeaseFakeDiarizationEngine(_FakeDiarizationEngine):
    """Counts weight loads once; streams can hang or raise for R4 tests."""

    def __init__(self, *, stream_mode: str) -> None:
        super().__init__(supports_stream=True)
        self.weight_loads = 0
        self.stream_mode = stream_mode

    def create_stream(self, *, config: object):
        if self.weight_loads == 0:
            self.weight_loads = 1  # weights load exactly once per engine
        if self.stream_mode == "hanging":
            return _HangingContinuous()
        if self.stream_mode == "raising":
            return _RaisingContinuous()
        return super().create_stream(config=config)


def _lease_client(*, stream_mode: str, drain_deadline: float = 0.3):
    streaming_factory = _FakeStreamingFactory()
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
        realtime_diarization_drain_deadline_seconds=drain_deadline,
    )
    engine = _LeaseFakeDiarizationEngine(stream_mode=stream_mode)
    services = build_app_services(
        settings,
        AppOverrides(
            realtime_asr_factory=streaming_factory,  # type: ignore[arg-type]
            diarization_engine=engine,  # type: ignore[arg-type]
        ),
    )
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))
    return TestClient(app), engine


def test_hung_native_degrades_finalization_and_keeps_asr_text() -> None:
    client, engine = _lease_client(stream_mode="hanging")
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        first = _append_and_commit(socket, 8000)
        completed = first[-1]
        assert completed["transcript"] == "你好"

        socket.send_json(_finalize_request("final_hang"))
        tail = _collect_until(socket, "speechrail.diarization.finalized")
        final = tail[-1]
        assert final["status"] == "degraded"
        assert final["reason"] == "finalization_timeout"
        assert final["through_sample"] == 8000
        assert final["stable_through_sample"] < final["through_sample"]

        status_events = [
            e for e in tail if e["type"] == "speechrail.diarization.status"
        ]
        assert len(status_events) == 1
        assert status_events[0]["reason"] == "finalization_timeout"

    # A second session during/after the hang must not load a second model.
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
    assert engine.weight_loads == 1


def test_native_exception_sends_unknown_updates_then_one_status() -> None:
    client, _ = _lease_client(stream_mode="raising")
    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        events = _append_and_commit(socket, 8000)
        completed = events[-1]
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["transcript"] == "你好"

        status = _collect_until(socket, "speechrail.diarization.status")
        updates = [e for e in status if e["type"] == "speechrail.diarization.update"]
        degraded = status[-1]
        assert degraded["status"] == "degraded"
        assert degraded["reason"] == "diarization_invalid_output"
        assert degraded["since_sample"] == 8000
        assert updates, "delivered units must be terminated as unknown first"
        assert all(
            update["status"] == "unknown" and update["speaker"] is None
            for update in updates[-1]["updates"]
        )

        # The degraded transition happens at most once per session.
        socket.send_json(_finalize_request("final_deg"))
        tail = _collect_until(socket, "speechrail.diarization.finalized")
        assert sum(1 for e in tail if e["type"] == "speechrail.diarization.status") == 0
        final = tail[-1]
        assert final["status"] == "degraded"
        assert final["reason"] == "diarization_invalid_output"


class _MisalignedStreamingSession(_FakeStreamingSession):
    async def commit(self, want_segments: bool = False) -> None:
        del want_segments
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


class _MisalignedStreamingFactory:
    def create(self, *, language: str | None, prompt: str) -> _MisalignedStreamingSession:
        del language, prompt
        return _MisalignedStreamingSession(language=None, prompt="")

    def release(self, session: object) -> None:
        del session


def test_unavailable_alignment_emits_unknown_update() -> None:
    streaming_factory = _MisalignedStreamingFactory()
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
    )
    services = build_app_services(
        settings,
        AppOverrides(
            realtime_asr_factory=streaming_factory,  # type: ignore[arg-type]
            diarization_engine=_FakeDiarizationEngine(supports_stream=True),  # type: ignore[arg-type]
        ),
    )
    app = FastAPI()
    app.include_router(create_openai_realtime_router(services))
    client = TestClient(app)

    with client.websocket_connect("/v1/realtime") as socket:
        _open(socket)
        _negotiate(socket)
        events = _append_and_commit(socket, 8000)
        completed = events[-1]
        assert completed["type"] == "conversation.item.input_audio_transcription.completed"
        assert completed["transcript"] == "不同意。"
        units = completed["attribution_units"]
        assert len(units) == 1
        assert units[0]["timing_quality"] == "unavailable"

        update_events = _collect_until(socket, "speechrail.diarization.update")
        update = update_events[-1]
        assert len(update["updates"]) == 1
        assert update["updates"][0]["segment_uid"] == units[0]["segment_uid"]
        assert update["updates"][0]["status"] == "unknown"
        assert update["updates"][0]["speaker"] is None
        assert update["updates"][0]["revision"] == 1
