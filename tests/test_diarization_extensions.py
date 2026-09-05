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
    return socket.receive_json()


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
        committed2 = second[0]
        completed2 = second[-1]
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
