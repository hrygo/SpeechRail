from __future__ import annotations

import asyncio
import struct
from collections.abc import AsyncIterator, Awaitable
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

from speechrail.application.services import AppOverrides, build_app_services
from speechrail.backends.diarization.coreml import CoreMLSortformerEngine
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization import (
    ActivityFrame,
    ActivityUpdate,
    AlignmentRequest,
    AlignmentResult,
    DiarizationError,
    Span,
    TextUnit,
)
from speechrail.http.errors import RequestIdMiddleware
from speechrail.http.routes.audio import create_audio_router
from speechrail.http.routes.system import create_system_router


def _backend(
    _: bytes, __: str | None, ___: str, ____: bool = False
) -> Awaitable[TranscriptResult]:
    async def result() -> TranscriptResult:
        return TranscriptResult(
            request_id="backend",
            model_id="speechrail/qwen3-asr-1.7b",
            text="你好 世界",
            language="zh",
            duration_ms=1600,
            segments=(
                TranscriptSegment(id=0, start_ms=0, end_ms=800, text="你好"),
                TranscriptSegment(id=1, start_ms=800, end_ms=1600, text="世界"),
            ),
        )

    return result()


def _pcm16_wav(seconds: int) -> bytes:
    frames = seconds * 16_000
    payload = b"\x00\x00" * frames
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(payload),
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        16_000,
        32_000,
        2,
        16,
        b"data",
        len(payload),
    )
    return header + payload


class FakeActivitySession:
    def __init__(self, appended_audio: list[bytes], epoch: str) -> None:
        self._appended_audio = appended_audio
        self._epoch = epoch
        self._updates: asyncio.Queue[ActivityUpdate | None] = asyncio.Queue()

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        assert start_sample == sum(len(audio) // 2 for audio in self._appended_audio)
        assert pcm16
        self._appended_audio.append(pcm16)

    async def updates(self):
        while update := await self._updates.get():
            yield update

    async def finish(self, *, through_sample: int) -> None:
        halfway = through_sample // 2
        await self._updates.put(
            ActivityUpdate(
                epoch=self._epoch,
                step_id=0,
                replace_span=Span(0, through_sample),
                frames=(
                    ActivityFrame(Span(0, halfway), (0.9, 0.0, 0.0, 0.0), frozenset({0})),
                    ActivityFrame(
                        Span(halfway, through_sample),
                        (0.0, 0.9, 0.0, 0.0),
                        frozenset({1}),
                    ),
                ),
                processed_through=through_sample,
                stable_through=through_sample,
            )
        )
        await self._updates.put(None)

    async def cancel(self) -> None:
        await self._updates.put(None)


class FakeDiarizationEngine:
    def __init__(self) -> None:
        self.appended_audio: list[bytes] = []

    def open(self, *, epoch: str):
        return FakeActivitySession(self.appended_audio, epoch)


class FailingActivitySession(FakeActivitySession):
    async def finish(self, *, through_sample: int) -> None:
        del through_sample
        raise DiarizationError("invalid diarization output", code="diarization_invalid_output")


class FailingDiarizationEngine(FakeDiarizationEngine):
    def open(self, *, epoch: str):
        return FailingActivitySession(self.appended_audio, epoch)


class FakeFixedTextAligner:
    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        return AlignmentResult(
            request.epoch,
            request.item_id,
            (
                TextUnit("batch-0", 0, 2, Span(0, 12_800)),
                TextUnit("batch-1", 2, len(request.text), Span(12_800, 25_600)),
            ),
        )


def _client(
    *,
    diarization_engine=None,
    include_system: bool = False,
    transcribe=_backend,
    batch_transcriber=None,
) -> TestClient:
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        diarization_model_path=None,
        diarization_embedding_model_path=None,
    )
    services = build_app_services(
        settings,
        AppOverrides(
            transcribe=transcribe,
            batch_transcriber=batch_transcriber,
            diarization_engine=diarization_engine,
            text_aligner=FakeFixedTextAligner() if diarization_engine is not None else None,
        ),
    )
    app = FastAPI()
    app.add_middleware(RequestIdMiddleware)
    app.include_router(create_audio_router(services))
    if include_system:
        app.include_router(create_system_router(services))
    return TestClient(app)


class RecordingStreamingBatch:
    def __init__(self) -> None:
        self.received = b""
        self.language: str | None = None

    async def transcribe_stream(
        self,
        request_id: str,
        audio: AsyncIterator[bytes],
        language: str | None = None,
        prompt: str | None = None,
        include_timestamps: bool = True,
    ) -> TranscriptResult:
        del prompt, include_timestamps
        self.received = b"".join([chunk async for chunk in audio])
        self.language = language
        return (await _backend(self.received, language, "", True)).model_copy(
            update={"request_id": request_id}
        )


def test_batch_diarized_json_emits_anonymous_speakers() -> None:
    response = _client(diarization_engine=FakeDiarizationEngine()).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", _pcm16_wav(2), "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 200
    payload = response.json()
    assert [segment["speaker"] for segment in payload["segments"]] == ["A", "B"]
    assert [segment["id"] for segment in payload["segments"]] == ["seg_0", "seg_1"]
    assert all(segment["type"] == "transcript.text.segment" for segment in payload["segments"])
    assert "words" not in payload


def test_batch_diarized_json_fails_closed_without_profile() -> None:
    response = _client().post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", _pcm16_wav(2), "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "diarization_not_available"


def test_batch_diarized_json_accepts_openai_bracketed_chunking_strategy() -> None:
    response = _client(diarization_engine=FakeDiarizationEngine()).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", _pcm16_wav(2), "audio/wav")},
        data={
            "model": "gpt-4o-transcribe-diarize",
            "response_format": "diarized_json",
            "chunking_strategy[type]": "auto",
        },
    )

    assert response.status_code == 200


def test_diarized_multipart_rejects_conflicting_chunking_before_activity_engine() -> None:
    engine = FakeDiarizationEngine()
    response = _client(diarization_engine=engine).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", _pcm16_wav(2), "audio/wav")},
        data={
            "model": "gpt-4o-transcribe-diarize",
            "response_format": "diarized_json",
            "chunking_strategy": "auto",
            "chunking_strategy[type]": "server_vad",
        },
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_chunking_strategy"
    assert engine.appended_audio == []


def test_diarized_multipart_rejects_bracketed_known_speaker_reference() -> None:
    engine = FakeDiarizationEngine()
    response = _client(diarization_engine=engine).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", _pcm16_wav(2), "audio/wav")},
        data={
            "model": "gpt-4o-transcribe-diarize",
            "response_format": "diarized_json",
            "known_speaker_references[]": "opaque-local-reference",
        },
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "unsupported_parameter"
    assert response.json()["error"]["param"] == "known_speaker_references"
    assert engine.appended_audio == []


def test_diarized_multipart_rejects_missing_diarization_model_before_activity_engine() -> None:
    engine = FakeDiarizationEngine()
    response = _client(diarization_engine=engine).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", _pcm16_wav(2), "audio/wav")},
        data={"response_format": "diarized_json"},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_diarization_model"
    assert engine.appended_audio == []


def test_diarized_multipart_rejects_empty_audio_before_activity_engine() -> None:
    engine = FakeDiarizationEngine()
    response = _client(diarization_engine=engine).post(
        "/v1/audio/transcriptions",
        files={"file": ("empty.wav", b"", "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "empty_audio"
    assert engine.appended_audio == []


def test_diarized_silence_with_an_empty_transcript_succeeds_without_starting_activity() -> None:
    async def silence_backend(
        _: bytes, __: str | None, ___: str, ____: bool = False
    ) -> TranscriptResult:
        return TranscriptResult(
            request_id="backend",
            model_id="speechrail/qwen3-asr-1.7b",
            text="",
            language="zh",
            duration_ms=1600,
        )

    engine = FakeDiarizationEngine()
    response = _client(diarization_engine=engine, transcribe=silence_backend).post(
        "/v1/audio/transcriptions",
        files={"file": ("silence.wav", _pcm16_wav(2), "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 200
    assert response.json()["text"] == ""
    assert response.json()["segments"] == []
    assert engine.appended_audio == []


def test_diarized_audio_over_30_seconds_requires_chunking_before_model_use() -> None:
    engine = FakeDiarizationEngine()
    response = _client(diarization_engine=engine).post(
        "/v1/audio/transcriptions",
        files={"file": ("long.wav", _pcm16_wav(31), "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "diarization_chunking_required"
    assert response.json()["error"]["param"] == "chunking_strategy"
    assert engine.appended_audio == []


def test_diarized_audio_over_30_seconds_accepts_explicit_auto_chunking() -> None:
    engine = FakeDiarizationEngine()
    response = _client(diarization_engine=engine).post(
        "/v1/audio/transcriptions",
        files={"file": ("long.wav", _pcm16_wav(31), "audio/wav")},
        data={
            "model": "gpt-4o-transcribe-diarize",
            "response_format": "diarized_json",
            "chunking_strategy": "auto",
        },
    )

    assert response.status_code == 200
    assert engine.appended_audio


def test_diarized_server_vad_preserves_streamed_pcm_tail_and_language(monkeypatch) -> None:
    """The accepted OpenAI chunking variant cannot alter source audio timing."""
    import speechrail.http.routes.audio as audio_routes

    chunks = (b"\x01\x00" * 16_000, b"\x02\x00" * 10_000, b"\x03\x00" * 11)

    async def decoded_pcm(*_args, **_kwargs):
        for chunk in chunks:
            yield chunk

    monkeypatch.setattr(audio_routes, "decode_upload", decoded_pcm)
    engine = FakeDiarizationEngine()
    streaming = RecordingStreamingBatch()
    response = _client(
        diarization_engine=engine, batch_transcriber=streaming
    ).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.webm", b"container", "video/webm")},
        data={
            "model": "gpt-4o-transcribe-diarize",
            "response_format": "diarized_json",
            "chunking_strategy": "server_vad",
            "language": "ja",
        },
    )

    assert response.status_code == 200
    assert streaming.language == "ja"
    assert streaming.received == b"".join(chunks)
    assert engine.appended_audio == [b"".join(chunks)]


def test_batch_diarization_failure_uses_stable_error_envelope() -> None:
    response = _client(diarization_engine=FailingDiarizationEngine()).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", _pcm16_wav(2), "audio/wav")},
        data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
    )

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "diarization_unresolved"


def test_streamed_diarization_failure_is_json_before_any_sse_bytes() -> None:
    response = _client(diarization_engine=FailingDiarizationEngine()).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", _pcm16_wav(2), "audio/wav")},
        data={
            "model": "gpt-4o-transcribe-diarize",
            "response_format": "diarized_json",
            "stream": "true",
        },
    )

    assert response.status_code == 502
    assert response.headers["content-type"].startswith("application/json")
    assert response.json()["error"]["code"] == "diarization_unresolved"


def test_models_advertise_diarized_alias_only_with_profile() -> None:
    available = _client(diarization_engine=FakeDiarizationEngine(), include_system=True)
    unavailable = _client(include_system=True)

    available_ids = {item["id"] for item in available.get("/v1/models").json()["data"]}
    unavailable_ids = {item["id"] for item in unavailable.get("/v1/models").json()["data"]}

    assert "gpt-4o-transcribe-diarize" in available_ids
    assert "gpt-4o-transcribe-diarize" not in unavailable_ids


def test_models_hide_diarized_alias_when_runtime_preflight_fails(tmp_path: Path) -> None:
    engine = CoreMLSortformerEngine(
        model_path=tmp_path / "missing.mlmodelc", executable=tmp_path / "missing-worker"
    )
    client = _client(diarization_engine=engine, include_system=True)

    response = client.get("/v1/models")

    assert response.status_code == 200
    assert "gpt-4o-transcribe-diarize" not in {
        item["id"] for item in response.json()["data"]
    }
