"""Cross-entry checks for the ASR-TTS workflow the eight fixes touched.

Each defect is covered by its own regression.  What those cannot show is that
two entry points still agree once they share one backend: the REST batch route
and the durable job processor both derive timestamps from the independent
aligner over the same frozen transcript, and both must reject a TTS stream that
breaks the delivery contract.  A per-entry test would still pass if one of them
drifted back to asking the ASR owner for native timings, or started trusting the
backend's chunk stream again.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.domain.alignment import (
    AlignmentRequest,
    AlignmentResult,
    AlignmentUnit,
)
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import (
    AudioChunk,
    SpeechRequest,
    TranscriptionRequest,
)
from speechrail.http.errors import RequestIdMiddleware
from speechrail.http.routes.audio import create_audio_router
from speechrail.infrastructure.voice_registry import FileVoiceRegistry
from speechrail.runtime.job_artifacts import RESULTS_SUBDIR
from speechrail.runtime.job_runner import JobProcessingError
from speechrail.runtime.jobs import JobRecord
from speechrail.runtime.local_file_processor import LocalFileJobProcessor

_FROZEN_TEXT = "Do not pay 500 dollars."
_PCM = b"\x00\x01" * 16_000


class _FrozenAligner:
    """Split the frozen transcript in half, or fail the way a lossy one does."""

    def __init__(self, *, tokens: tuple[str, ...] | None = None) -> None:
        self.requests: list[AlignmentRequest] = []
        self._tokens = tokens

    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        self.requests.append(request)
        if self._tokens is not None:
            # The vendor dropped a word: the validator must refuse it, and both
            # entry points must refuse it identically.
            return AlignmentResult(
                task_id=request.task_id,
                epoch=request.epoch,
                utterance_id=request.utterance_id,
                transcript_revision=request.transcript_revision,
                units=(),
                failure="text_mismatch",
            )
        midpoint = len(request.text) // 2
        return AlignmentResult(
            task_id=request.task_id,
            epoch=request.epoch,
            utterance_id=request.utterance_id,
            transcript_revision=request.transcript_revision,
            units=(
                AlignmentUnit("u-0", 0, midpoint, SampleSpan(0, 16_000), "segment"),
                AlignmentUnit(
                    "u-1", midpoint, len(request.text), SampleSpan(16_000, 32_000), "segment"
                ),
            ),
        )


class _FrozenTranscriber:
    """Text-only ASR owner, as Qwen3-ASR has to be in this environment."""

    def __init__(self) -> None:
        self.requests: list[TranscriptionRequest] = []

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        self.requests.append(request)
        return TranscriptResult(
            request_id=request.request_id,
            model_id="speechrail/qwen3-asr-1.7b",
            text=_FROZEN_TEXT,
            language="en",
            duration_ms=1000,
        )


class _MisbehavingSynthesizer:
    """Emits a stream the delivery contract forbids."""

    def __init__(self) -> None:
        self.closed = 0

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        del voice
        return None

    async def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        del request
        try:
            yield AudioChunk(response_id="one", chunk_index=4, audio=b"\x00")
        finally:
            self.closed += 1


def _rest_client(aligner: _FrozenAligner, transcriber: _FrozenTranscriber) -> TestClient:
    services = build_app_services(
        Settings(qwen3_model_dir=None, qwen3_python=None),
        AppOverrides(text_aligner=aligner, batch_transcriber=transcriber),
    )
    app = FastAPI()
    app.add_middleware(RequestIdMiddleware)
    app.include_router(create_audio_router(services))
    return TestClient(app)


def _job_processor(spool: Path, aligner: _FrozenAligner) -> LocalFileJobProcessor:
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        batch_transcriber=_FrozenTranscriber(),
        text_aligner=aligner,
    )

    async def _decode(input_path: Path) -> bytes:
        del input_path
        return _PCM

    processor._decode_audio = _decode  # type: ignore[method-assign]
    return processor


def _job(spool: Path, **params: object) -> JobRecord:
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    return JobRecord(
        id="job_it",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": str(audio), "params": params},
        error_code=None,
        result_ref=None,
    )


def test_rest_and_job_derive_the_same_timeline_from_one_aligner(tmp_path: Path) -> None:
    aligner = _FrozenAligner()
    transcriber = _FrozenTranscriber()
    spool = tmp_path / "spool"
    spool.mkdir()

    rest = _rest_client(aligner, transcriber).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", b"1234", "audio/wav")},
        data={"response_format": "verbose_json", "timestamp_granularities[]": "segment"},
    )
    assert rest.status_code == 200, rest.text
    rest_body = rest.json()

    ref = asyncio.run(_job_processor(spool, aligner).process(_job(spool, timestamps=True)))
    job_body = json.loads((spool / ref).read_text())

    # Neither entry point asked the ASR owner for native timings.
    assert [request.include_timestamps for request in transcriber.requests] == [False]
    # Same frozen text, same aligner, same boundaries.
    assert [request.text for request in aligner.requests] == [_FROZEN_TEXT] * 2
    assert [segment["text"] for segment in rest_body["segments"]] == [
        segment["text"] for segment in job_body["segments"]
    ]
    # REST renders OpenAI's second-based `start`; the durable artifact keeps
    # integer milliseconds. Same boundaries, different spelling.
    assert [segment["start"] for segment in rest_body["segments"]] == [
        segment["start_ms"] / 1000 for segment in job_body["segments"]
    ]
    assert job_body["segments"]


def test_an_untruthful_alignment_is_refused_by_both_entry_points(tmp_path: Path) -> None:
    """A dropped word must not become a plausible timeline on either path."""

    lossy = _FrozenAligner(tokens=("Do", "pay", "dollars"))
    spool = tmp_path / "spool"
    spool.mkdir()

    rest = _rest_client(lossy, _FrozenTranscriber()).post(
        "/v1/audio/transcriptions",
        files={"file": ("clip.wav", b"1234", "audio/wav")},
        data={"response_format": "verbose_json", "timestamp_granularities[]": "segment"},
    )

    assert rest.status_code == 502
    assert rest.json()["error"]["code"] == "timestamp_alignment_unavailable"

    with pytest.raises(JobProcessingError) as failure:
        asyncio.run(_job_processor(spool, lossy).process(_job(spool, timestamps=True)))

    assert failure.value.error_code == "timestamp_alignment_unavailable"
    assert not (spool / RESULTS_SUBDIR / "job_it" / "transcript.json").exists()


def test_the_job_refuses_a_tts_stream_the_delivery_contract_forbids(
    tmp_path: Path,
) -> None:
    """The durable path must not be the one place a broken stream gets through."""

    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input.txt"
    text_file.write_text("hello speech")
    synthesizer = _MisbehavingSynthesizer()
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        tts_synthesizer=synthesizer,
        voice_store=FileVoiceRegistry.open(tmp_path / "voices.json", tmp_path / "voices"),
    )
    job = JobRecord(
        id="job_bad_tts",
        kind="speech",
        state="queued",
        owner="loopback",
        request={"input_ref": str(text_file), "params": {"voice": "serena"}},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError) as failure:
        asyncio.run(processor.process(job))

    assert failure.value.error_code == "job_processor_failed"
    assert synthesizer.closed == 1, "the backend iterator must be closed"
    assert not (spool / RESULTS_SUBDIR / "job_bad_tts" / "speech.pcm").exists()


def test_a_plain_transcription_needs_no_aligner_at_all(tmp_path: Path) -> None:
    """Adding the alignment gate must not tax requests that ask for no timeline."""

    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=_FrozenTranscriber())

    async def _decode(input_path: Path) -> bytes:
        del input_path
        return _PCM

    processor._decode_audio = _decode  # type: ignore[method-assign]

    ref = asyncio.run(processor.process(_job(spool)))

    body = json.loads((spool / ref).read_text())
    assert body["text"] == _FROZEN_TEXT
    assert body["segments"] == []
