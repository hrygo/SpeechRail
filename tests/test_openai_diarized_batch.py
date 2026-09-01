from __future__ import annotations

from collections.abc import Awaitable

from fastapi import FastAPI
from fastapi.testclient import TestClient

from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization import (
    DiarizationAssignment,
    DiarizationError,
    DiarizationSpeaker,
    DiarizationUpdate,
)
from speechrail.http.errors import RequestIdMiddleware
from speechrail.http.routes.audio import create_audio_router
from speechrail.http.routes.system import create_system_router


def _backend(_: bytes, __: str | None, ___: str) -> Awaitable[TranscriptResult]:
    async def result() -> TranscriptResult:
        return TranscriptResult(
            request_id="backend",
            model_id="speechrail/qwen3-asr-1.7b",
            text="你好 世界",
            language="zh",
            duration_ms=1600,
            segments=(
                TranscriptSegment(id="seg_1", start_ms=0, end_ms=800, text="你好"),
                TranscriptSegment(id="seg_2", start_ms=800, end_ms=1600, text="世界"),
            ),
        )

    return result()


class FakeDiarizationSession:
    async def append_audio(self, audio: bytes) -> None:
        assert audio

    async def annotate(self, segments):
        return DiarizationUpdate(
            assignments=tuple(
                DiarizationAssignment(
                    segment_id=segment.id,
                    speakers=(
                        DiarizationSpeaker(id=f"spk_{index + 1:02d}", confidence=0.9),
                    ),
                )
                for index, segment in enumerate(segments)
            )
        )

    async def finalize(self) -> DiarizationUpdate:
        return DiarizationUpdate()

    async def close(self) -> None:
        return None


class FakeDiarizationEngine:
    def create(self, *, config):
        return FakeDiarizationSession()


class FailingDiarizationSession(FakeDiarizationSession):
    async def annotate(self, segments):
        raise DiarizationError("invalid diarization output", code="diarization_invalid_output")


class FailingDiarizationEngine(FakeDiarizationEngine):
    def create(self, *, config):
        return FailingDiarizationSession()


def _client(*, diarization_engine=None, include_system: bool = False) -> TestClient:
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
    )
    services = build_app_services(
        settings,
        AppOverrides(
            transcribe=_backend,
            diarization_engine=diarization_engine,
        ),
    )
    app = FastAPI()
    app.add_middleware(RequestIdMiddleware)
    app.include_router(create_audio_router(services))
    if include_system:
        app.include_router(create_system_router(services))
    return TestClient(app)


def test_batch_diarized_json_emits_anonymous_speakers() -> None:
    response = _client(diarization_engine=FakeDiarizationEngine()).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", b"1234", "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 200
    assert [segment["speaker"] for segment in response.json()["segments"]] == [
        "spk_01",
        "spk_02",
    ]


def test_batch_diarized_json_fails_closed_without_profile() -> None:
    response = _client().post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", b"1234", "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "diarization_not_available"


def test_batch_diarization_backend_output_uses_stable_error_envelope() -> None:
    response = _client(diarization_engine=FailingDiarizationEngine()).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", b"1234", "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "diarization_invalid_output"


def test_models_advertise_diarized_alias_only_with_profile() -> None:
    available = _client(diarization_engine=FakeDiarizationEngine(), include_system=True)
    unavailable = _client(include_system=True)

    available_ids = {item["id"] for item in available.get("/v1/models").json()["data"]}
    unavailable_ids = {item["id"] for item in unavailable.get("/v1/models").json()["data"]}

    assert "gpt-4o-transcribe-diarize" in available_ids
    assert "gpt-4o-transcribe-diarize" not in unavailable_ids
