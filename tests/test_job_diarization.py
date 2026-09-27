from __future__ import annotations

import asyncio
import json
import struct
from pathlib import Path

import pytest

from speechrail.domain.alignment import AlignmentRequest, AlignmentResult, AlignmentUnit
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.diarization import (
    ActivityFrame,
    ActivityUpdate,
    SampleSpan,
)
from speechrail.runtime.job_runner import JobProcessingError
from speechrail.runtime.jobs import JobRepository
from speechrail.runtime.local_file_processor import LocalFileJobProcessor


class _BatchTranscriber:
    async def transcribe(self, request):  # type: ignore[no-untyped-def]
        return TranscriptResult(
            request_id=request.request_id,
            model_id="speechrail/qwen3-asr-1.7b",
            text="你好世界",
            language="zh",
            duration_ms=2000,
        )


class _Aligner:
    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        half = len(request.pcm16) // 4
        return AlignmentResult(
            task_id=request.task_id,
            epoch=request.epoch,
            utterance_id=request.utterance_id,
            transcript_revision=request.transcript_revision,
            units=(
                AlignmentUnit("unit-0", 0, 2, SampleSpan(0, half), "segment"),
                AlignmentUnit(
                    "unit-1", 2, len(request.text), SampleSpan(half, half * 2), "segment"
                ),
            ),
        )


class _ActivitySession:
    def __init__(self, epoch: str) -> None:
        self._epoch = epoch
        self._samples = 0
        self._updates: asyncio.Queue[ActivityUpdate | None] = asyncio.Queue()

    async def append(self, *, start_sample: int, pcm16: bytes) -> None:
        assert start_sample == self._samples
        self._samples += len(pcm16) // 2

    async def updates(self):  # type: ignore[no-untyped-def]
        while (update := await self._updates.get()) is not None:
            yield update

    async def finish(self, *, through_sample: int) -> None:
        halfway = through_sample // 2
        await self._updates.put(
            ActivityUpdate(
                epoch=self._epoch,
                step_id=0,
                replace_span=SampleSpan(0, through_sample),
                frames=(
                    ActivityFrame(
                        SampleSpan(0, halfway),
                        (0.9, 0.0, 0.0, 0.0),
                        frozenset({0}),
                    ),
                    ActivityFrame(
                        SampleSpan(halfway, through_sample),
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


class _DiarizationEngine:
    def open(self, *, epoch: str) -> _ActivitySession:
        return _ActivitySession(epoch)


def _wav(seconds: int) -> bytes:
    payload = b"\x00\x00" * seconds * 16_000
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


def _job(tmp_path: Path):
    spool = tmp_path / "spool"
    repository = JobRepository(spool)
    audio = spool / "meeting.wav"
    audio.write_bytes(_wav(2))
    job = repository.create(
        kind="transcription",
        owner="owner",
        request={"input_ref": str(audio), "params": {"diarize": True}},
    )
    return spool, repository, job


def test_transcription_job_runs_the_requested_diarization(tmp_path: Path) -> None:
    spool, repository, job = _job(tmp_path)
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        batch_transcriber=_BatchTranscriber(),
        diarization_engine=_DiarizationEngine(),
        text_aligner=_Aligner(),
    )

    result_ref = asyncio.run(processor.process(job))
    artifact = spool / result_ref
    payload = json.loads(artifact.read_text(encoding="utf-8"))

    assert repository.get(job.id, owner="owner") is not None
    assert payload["text"] == "你好世界"
    assert [segment["speaker"] for segment in payload["segments"]] == ["A", "B"]


def test_transcription_job_rejects_diarize_when_capability_is_missing(
    tmp_path: Path,
) -> None:
    spool, _repository, job = _job(tmp_path)
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        batch_transcriber=_BatchTranscriber(),
    )

    with pytest.raises(JobProcessingError, match="diarization_not_available"):
        asyncio.run(processor.process(job))
