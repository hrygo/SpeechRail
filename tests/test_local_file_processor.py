from __future__ import annotations

import asyncio
import json
import time
from collections.abc import AsyncIterator
from concurrent.futures import Future
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from speechrail.domain.alignment import (
    AlignmentRequest,
    AlignmentResult,
    AlignmentUnit,
)
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.ports import (
    AudioChunk,
    SpeechRequest,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.domain.tts import VoiceProfile
from speechrail.domain.voice_validation import VoiceValidationArtifact, VoiceValidationRepository
from speechrail.infrastructure.voice_registry import FileVoiceRegistry as VoiceRegistry
from speechrail.runtime.job_artifacts import delete_job_result_artifact
from speechrail.runtime.job_runner import JobProcessingError, JobRunner
from speechrail.runtime.jobs import JobRecord, JobRepository
from speechrail.runtime.local_file_processor import (
    RESULTS_SUBDIR,
    LocalFileJobProcessor,
    resolve_result_artifact,
)
from speechrail.runtime.resource_governor import GovernorLimits, ResourceGovernor


class _NeverCalledProcessor:
    """Protocol-shaped stub whose process() must never run in expiry tests."""

    async def process(self, job: JobRecord) -> str:
        raise AssertionError("expiry tests must not invoke the processor")


# ---------------------------------------------------------------------------
# resolve_result_artifact
# ---------------------------------------------------------------------------


def test_resolve_result_artifact_resolves_relative_path_inside_job_dir(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    job_dir = spool / RESULTS_SUBDIR / "job_abc"
    job_dir.mkdir(parents=True)
    artifact = job_dir / "transcript.json"
    artifact.write_text('{"text": "hi"}')
    ref = f"{RESULTS_SUBDIR}/job_abc/transcript.json"
    result = resolve_result_artifact(spool_dir=spool, job_id="job_abc", result_ref=ref)

    assert result is not None
    path, media_type = result
    assert path == artifact
    assert media_type == "application/json"


def test_resolve_result_artifact_rejects_absolute_path(tmp_path: Path) -> None:
    result = resolve_result_artifact(spool_dir=tmp_path, job_id="job_1", result_ref="/etc/passwd")
    assert result is None


def test_resolve_result_artifact_rejects_traversal(tmp_path: Path) -> None:
    ref = f"{RESULTS_SUBDIR}/../secret"
    assert resolve_result_artifact(spool_dir=tmp_path, job_id="job_1", result_ref=ref) is None


def test_resolve_result_artifact_rejects_missing_file(tmp_path: Path) -> None:
    ref = f"{RESULTS_SUBDIR}/job_1/transcript.json"
    assert resolve_result_artifact(spool_dir=tmp_path, job_id="job_1", result_ref=ref) is None


def test_resolve_result_artifact_rejects_wrong_job_id(tmp_path: Path) -> None:
    other = tmp_path / RESULTS_SUBDIR / "other"
    other.mkdir(parents=True)
    (other / "x.txt").write_text("x")
    ref = f"{RESULTS_SUBDIR}/other/x.txt"
    assert resolve_result_artifact(spool_dir=tmp_path, job_id="job_1", result_ref=ref) is None


def test_resolve_result_artifact_rejects_empty_ref(tmp_path: Path) -> None:
    assert resolve_result_artifact(spool_dir=tmp_path, job_id="job_1", result_ref="") is None


def test_delete_result_artifact_rejects_symlinked_results_root(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    outside = tmp_path / "outside"
    spool.mkdir()
    outside.mkdir()
    (spool / RESULTS_SUBDIR).symlink_to(outside, target_is_directory=True)

    with pytest.raises(OSError, match="symlinked results directory"):
        delete_job_result_artifact(
            spool_dir=spool,
            job_id="job_1",
            result_ref=f"{RESULTS_SUBDIR}/job_1/speech.pcm",
        )

    assert list(outside.iterdir()) == []


def test_delete_result_artifact_rejects_symlinked_job_directory(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    results = spool / RESULTS_SUBDIR
    results.mkdir(parents=True)
    job_root = results / "job_1"
    loop = results / "loop"
    job_root.symlink_to(loop)
    loop.symlink_to(job_root)

    with pytest.raises(OSError, match="symlinked job artifact directory"):
        delete_job_result_artifact(
            spool_dir=spool,
            job_id="job_1",
            result_ref=f"{RESULTS_SUBDIR}/job_1/speech.pcm",
        )


def test_resolve_result_artifact_fallback_octet_stream_unknown_suffix(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    job_dir = spool / RESULTS_SUBDIR / "job_1"
    job_dir.mkdir(parents=True)
    (job_dir / "data.bin").write_bytes(b"\x00\x01")
    ref = f"{RESULTS_SUBDIR}/job_1/data.bin"
    result = resolve_result_artifact(spool_dir=spool, job_id="job_1", result_ref=ref)
    assert result is not None
    _, media_type = result
    assert media_type == "application/octet-stream"


def test_read_text_uses_a_bounded_file_handle(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    spool = tmp_path / "spool"
    processor = LocalFileJobProcessor(spool_dir=spool)
    text_path = tmp_path / "input.txt"
    text_path.write_text("你好", encoding="utf-8")
    real_open = Path.open
    requested_sizes: list[int] = []

    class GuardedFile:
        def __init__(self, handle) -> None:
            self._handle = handle

        def __enter__(self):
            self._handle.__enter__()
            return self

        def __exit__(self, *args: object) -> None:
            self._handle.__exit__(*args)

        def read(self, size: int = -1) -> bytes:
            requested_sizes.append(size)
            if size < 0 or size > 400_001:
                raise AssertionError("text input read must be explicitly bounded")
            return self._handle.read(size)

    monkeypatch.setattr(
        Path,
        "open",
        lambda self, mode: GuardedFile(real_open(self, mode)),
    )
    assert processor._read_text(text_path) == "你好"
    assert requested_sizes == [400_001]


def test_read_text_rejects_oversized_input_after_bounded_read(tmp_path: Path) -> None:
    processor = LocalFileJobProcessor(spool_dir=tmp_path / "spool")
    text_path = tmp_path / "input.txt"
    text_path.write_bytes(b"a" * (100_000 * 4 + 1))

    with pytest.raises(JobProcessingError) as exc_info:
        processor._read_text(text_path)

    assert exc_info.value.error_code == "job_input_too_large"


# ---------------------------------------------------------------------------
# LocalFileJobProcessor — transcription
# ---------------------------------------------------------------------------


class _FakeTranscriber:
    def __init__(self, text: str = "hello world", language: str | None = "en") -> None:
        self.text = text
        self.language = language
        self.calls: list[TranscriptionRequest] = []  # type: ignore[name-defined]

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        self.calls.append(request)
        segments = []
        for i in range(2):
            segments.append(
                TranscriptSegment(
                    id=i,
                    start_ms=i * 500,
                    end_ms=(i + 1) * 500,
                    text=self.text,
                    language=self.language,
                    speaker=None,
                )
            )
        return TranscriptResult(
            text=self.text,
            language=self.language,
            duration_ms=1000,
            segments=tuple(segments),
            request_id=request.request_id,
            model_id="test",
        )


def test_processor_transcription_writes_artifact_and_returns_relative_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    transcriber = _FakeTranscriber(text="transcribed text")
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        batch_transcriber=transcriber,
    )
    job = JobRecord(
        id="job_t1",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": str(audio), "params": {"language": "en"}},
        error_code=None,
        result_ref=None,
    )

    async def _fake_decode(input_path: Path) -> bytes:
        return b"\x00\x01" * 100

    processor._decode_audio = _fake_decode  # type: ignore[method-assign]

    ref = asyncio.run(processor.process(job))

    assert ref == f"{RESULTS_SUBDIR}/job_t1/transcript.json"
    artifact = spool / RESULTS_SUBDIR / "job_t1" / "transcript.json"
    assert artifact.is_file()
    assert artifact.stat().st_mode & 0o777 == 0o600
    payload = json.loads(artifact.read_text())
    assert payload["text"] == "transcribed text"
    assert payload["language"] == "en"


class _FakeAligner:
    """Stand in for the independent fixed-text aligner owner."""

    def __init__(self, *, failure: str | None = None) -> None:
        self.requests: list[AlignmentRequest] = []
        self.failure = failure

    async def align(self, request: AlignmentRequest) -> AlignmentResult:
        self.requests.append(request)
        if self.failure is not None:
            return AlignmentResult(
                task_id=request.task_id,
                epoch=request.epoch,
                utterance_id=request.utterance_id,
                transcript_revision=request.transcript_revision,
                units=(),
                failure=self.failure,
            )
        midpoint = max(1, len(request.text) // 2)
        return AlignmentResult(
            task_id=request.task_id,
            epoch=request.epoch,
            utterance_id=request.utterance_id,
            transcript_revision=request.transcript_revision,
            units=(
                AlignmentUnit(
                    "u-0", 0, midpoint, SampleSpan(0, 16_000), request.granularity
                ),
                AlignmentUnit(
                    "u-1",
                    midpoint,
                    len(request.text),
                    SampleSpan(16_000, 32_000),
                    request.granularity,
                ),
            ),
        )


def _transcription_job(spool: Path, audio: Path, **params: object) -> JobRecord:
    return JobRecord(
        id="job_ts",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": str(audio), "params": params},
        error_code=None,
        result_ref=None,
    )


def _timestamp_processor(
    spool: Path,
    transcriber: _FakeTranscriber,
    aligner: _FakeAligner | None,
) -> LocalFileJobProcessor:
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        batch_transcriber=transcriber,
        text_aligner=aligner,
    )

    async def _fake_decode(input_path: Path) -> bytes:
        return b"\x00\x01" * 100

    processor._decode_audio = _fake_decode  # type: ignore[method-assign]
    return processor


def test_job_timestamps_come_from_the_independent_aligner(tmp_path: Path) -> None:
    """The ASR owner decodes text only; timestamps are a local alignment pass."""

    spool = tmp_path / "spool"
    spool.mkdir()
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    transcriber = _FakeTranscriber(text="hello world")
    aligner = _FakeAligner()
    processor = _timestamp_processor(spool, transcriber, aligner)

    ref = asyncio.run(
        processor.process(_transcription_job(spool, audio, timestamps=True))
    )

    assert [request.include_timestamps for request in transcriber.calls] == [False]
    assert len(aligner.requests) == 1
    assert aligner.requests[0].granularity == "segment"
    assert aligner.requests[0].text == "hello world"
    payload = json.loads((spool / ref).read_text())
    assert payload["text"] == "hello world"
    assert [segment["start_ms"] for segment in payload["segments"]] == [0, 1000]
    assert [segment["text"] for segment in payload["segments"]] == ["hello", "world"]


def test_job_without_timestamps_never_calls_the_aligner(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    transcriber = _FakeTranscriber()
    aligner = _FakeAligner()
    processor = _timestamp_processor(spool, transcriber, aligner)

    asyncio.run(processor.process(_transcription_job(spool, audio)))

    assert aligner.requests == []
    assert [request.include_timestamps for request in transcriber.calls] == [False]


def test_job_timestamps_require_a_configured_aligner(tmp_path: Path) -> None:
    """Fail closed before decoding: no aligner means no truthful timeline."""

    spool = tmp_path / "spool"
    spool.mkdir()
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    transcriber = _FakeTranscriber()
    processor = _timestamp_processor(spool, transcriber, None)

    async def unexpected_decode(input_path: Path) -> bytes:
        raise AssertionError("missing alignment must be refused before decoding")

    processor._decode_audio = unexpected_decode  # type: ignore[method-assign]
    with pytest.raises(JobProcessingError) as failure:
        asyncio.run(processor.process(_transcription_job(spool, audio, timestamps=True)))

    assert failure.value.error_code == "timestamp_alignment_unavailable"
    assert transcriber.calls == []
    assert not (spool / RESULTS_SUBDIR / "job_ts" / "transcript.json").exists()


def test_job_timestamps_fail_the_job_when_alignment_is_unresolved(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    transcriber = _FakeTranscriber()
    processor = _timestamp_processor(spool, transcriber, _FakeAligner(failure="text_mismatch"))

    with pytest.raises(JobProcessingError) as failure:
        asyncio.run(processor.process(_transcription_job(spool, audio, timestamps=True)))

    assert failure.value.error_code == "timestamp_alignment_unavailable"
    assert not (spool / RESULTS_SUBDIR / "job_ts" / "transcript.json").exists()


def test_processor_transcription_rejects_url_input_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=_FakeTranscriber())
    job = JobRecord(
        id="job_x",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": "https://example.com/audio.wav"},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_input_not_allowed"):
        asyncio.run(processor.process(job))


def test_processor_transcription_rejects_traversal_input_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=_FakeTranscriber())
    job = JobRecord(
        id="job_x",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": str(tmp_path / ".." / "etc" / "passwd")},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_input_not_allowed"):
        asyncio.run(processor.process(job))


def test_processor_transcription_rejects_non_file_input_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=_FakeTranscriber())
    job = JobRecord(
        id="job_x",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": str(spool / "missing.wav")},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_input_not_found"):
        asyncio.run(processor.process(job))


def test_processor_transcription_rejects_relative_input_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=_FakeTranscriber())
    job = JobRecord(
        id="job_x",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": "relative/path.wav"},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_input_not_allowed"):
        asyncio.run(processor.process(job))


@pytest.mark.parametrize(
    "input_ref",
    [
        "https://example.com/audio.wav",
        "s3://bucket/audio.wav",
        "//host/share/audio.wav",
    ],
)
def test_processor_transcription_rejects_remote_or_unc_input_refs(
    tmp_path: Path, input_ref: str
) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=_FakeTranscriber())
    job = JobRecord(
        id="job_x",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": input_ref},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_input_not_allowed"):
        asyncio.run(processor.process(job))


def test_processor_transcription_rejects_absolute_path_outside_spool(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    outside = tmp_path / "outside.wav"
    outside.write_bytes(b"RIFF-fake-wav")
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=_FakeTranscriber())
    job = JobRecord(
        id="job_x",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": str(outside)},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_input_not_allowed"):
        asyncio.run(processor.process(job))


def test_processor_transcription_fails_when_no_transcriber(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    processor = LocalFileJobProcessor(spool_dir=spool)
    job = JobRecord(
        id="job_x",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": str(audio)},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_backend_not_ready"):
        asyncio.run(processor.process(job))


# ---------------------------------------------------------------------------
# LocalFileJobProcessor — speech
# ---------------------------------------------------------------------------


class _FakeSynthesizer:
    def __init__(
        self,
        pcm: bytes = b"\x00\x01\x02\x03",
        *,
        runtime_revision: str | None = None,
    ) -> None:
        self._pcm = pcm
        self.runtime_revision = runtime_revision
        self.calls: list[SpeechRequest] = []

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        del voice
        return self.runtime_revision

    async def prepare_voice(
        self,
        voice: str,
        *,
        expected_voice_revision: str | None,
    ) -> str:
        del voice, expected_voice_revision
        if self.runtime_revision is None:
            raise RuntimeError("voice_validation_runtime_unavailable")
        return self.runtime_revision

    async def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        yield AudioChunk(response_id=request.voice, chunk_index=0, audio=self._pcm)


class _ScriptedSynthesizer:
    """Synthesizer that replays an exact, possibly invalid, chunk stream."""

    def __init__(self, chunks: list[AudioChunk]) -> None:
        self._chunks = chunks
        self.runtime_revision = None
        self.closed = False
        self.emitted = 0

    def runtime_revision_for_voice(self, voice: str) -> str | None:
        del voice
        return None

    async def prepare_voice(
        self,
        voice: str,
        *,
        expected_voice_revision: str | None,
    ) -> str:
        del voice, expected_voice_revision
        raise RuntimeError("voice_validation_runtime_unavailable")

    async def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        del request
        try:
            for chunk in self._chunks:
                self.emitted += 1
                yield chunk
        finally:
            self.closed = True


def _speech_job(spool: Path, text_file: Path, **params: object) -> JobRecord:
    return JobRecord(
        id="job_s1",
        kind="speech",
        state="queued",
        owner="loopback",
        request={"input_ref": str(text_file), "params": params},
        error_code=None,
        result_ref=None,
    )


def _speech_processor(spool: Path, synthesizer: SpeechSynthesizer) -> LocalFileJobProcessor:
    return LocalFileJobProcessor(
        spool_dir=spool,
        tts_synthesizer=synthesizer,
        voice_store=VoiceRegistry.open((spool) / "voices.json", (spool) / "voice-audio"),
    )


def test_processor_speech_writes_artifact_and_returns_relative_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input.txt"
    text_file.write_text("hello speech")
    synthesizer = _FakeSynthesizer(pcm=b"\xaa\xbb")
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        tts_synthesizer=synthesizer,
        voice_store=VoiceRegistry.open((spool) / "voices.json", (spool) / "voice-audio"),
    )
    job = JobRecord(
        id="job_s1",
        kind="speech",
        state="queued",
        owner="loopback",
        request={"input_ref": str(text_file), "params": {"voice": "serena"}},
        error_code=None,
        result_ref=None,
    )

    ref = asyncio.run(processor.process(job))

    assert ref == f"{RESULTS_SUBDIR}/job_s1/speech.pcm"
    artifact = spool / RESULTS_SUBDIR / "job_s1" / "speech.pcm"
    assert artifact.is_file()
    assert artifact.stat().st_mode & 0o777 == 0o600
    assert artifact.read_bytes() == b"\xaa\xbb"


@pytest.mark.parametrize(
    ("label", "chunks", "code"),
    [
        (
            "odd_pcm",
            [AudioChunk(response_id="one", chunk_index=0, audio=b"\x01")],
            "job_processor_failed",
        ),
        (
            "first_index_not_zero",
            [AudioChunk(response_id="one", chunk_index=4, audio=b"\x00\x01")],
            "job_processor_failed",
        ),
        (
            "index_gap",
            [
                AudioChunk(response_id="one", chunk_index=0, audio=b"\x00\x01"),
                AudioChunk(response_id="one", chunk_index=2, audio=b"\x00\x01"),
            ],
            "job_processor_failed",
        ),
        (
            "response_id_switch",
            [
                AudioChunk(response_id="one", chunk_index=0, audio=b"\x00\x01"),
                AudioChunk(response_id="two", chunk_index=1, audio=b"\x00\x01"),
            ],
            "job_processor_failed",
        ),
        ("empty_stream", [], "job_processor_failed"),
    ],
)
def test_processor_speech_rejects_malformed_streams_without_an_artifact(
    tmp_path: Path, label: str, chunks: list[AudioChunk], code: str
) -> None:
    del label
    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input.txt"
    text_file.write_text("hello speech")
    synthesizer = _ScriptedSynthesizer(chunks)
    processor = _speech_processor(spool, synthesizer)

    with pytest.raises(JobProcessingError) as failure:
        asyncio.run(processor.process(_speech_job(spool, text_file, voice="serena")))

    assert failure.value.error_code == code
    assert synthesizer.closed, "the backend iterator must be closed"
    assert not (spool / RESULTS_SUBDIR / "job_s1" / "speech.pcm").exists()


def test_processor_speech_accepts_a_valid_multi_chunk_stream(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input.txt"
    text_file.write_text("hello speech")
    synthesizer = _ScriptedSynthesizer(
        [
            AudioChunk(response_id="one", chunk_index=0, audio=b"\xaa\xbb"),
            AudioChunk(response_id="one", chunk_index=1, audio=b"\xcc\xdd"),
        ]
    )
    processor = _speech_processor(spool, synthesizer)

    ref = asyncio.run(processor.process(_speech_job(spool, text_file, voice="serena")))

    assert (spool / ref).read_bytes() == b"\xaa\xbb\xcc\xdd"
    assert synthesizer.closed


def test_processor_accepts_file_uri_for_an_allowlisted_input(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input with spaces.txt"
    text_file.write_text("hello speech")
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        tts_synthesizer=_FakeSynthesizer(pcm=b"\xaa\xbb"),
        voice_store=VoiceRegistry.open((spool) / "voices.json", (spool) / "voice-audio"),
    )
    job = JobRecord(
        id="job_file_uri",
        kind="speech",
        state="queued",
        owner="loopback",
        request={
            "input_ref": text_file.as_uri(),
            "params": {"voice": "serena"},
        },
        error_code=None,
        result_ref=None,
    )

    result = asyncio.run(processor.process(job))

    assert result == f"{RESULTS_SUBDIR}/job_file_uri/speech.pcm"


def test_processor_speech_uses_the_same_strict_validation_gate_as_http(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from speechrail.application.voice_validation_gate import build_validation_binding

    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input.txt"
    text_file.write_text("formal speech")
    runtime_revision = "rt_" + "a" * 64
    synthesizer = _FakeSynthesizer(runtime_revision=runtime_revision)
    profile = VoiceProfile(
        id="clone_job",
        mode="clone",
        revision="vr_" + "b" * 32,
        ref_text="参考文本",
        quality={"status": "pass", "policy_version": "voice_quality_v1"},
    )
    validation_store = VoiceValidationRepository(tmp_path / "voice_validations.json")
    artifact_key = "tts_clone_base"
    catalog_revision = "c" * 40
    binding = build_validation_binding(
        profile,
        VoiceValidationArtifact(artifact_key, catalog_revision),
        synthesizer,
        require_current_binding=True,
    )
    validation_store.put(
        {
            "voice_id": profile.id,
            "voice_revision": profile.revision,
            "status": "pass",
            "run_id": "run_job",
            "model_artifact": artifact_key,
            "model_catalog_revision": catalog_revision,
            "model_runtime_revision": binding.model_runtime_revision,
            "runtime_fingerprint": binding.runtime_fingerprint,
            "preprocess_version": binding.preprocess_version,
            "generation_recipe_revision": binding.generation_recipe_revision,
            "policy_version": binding.policy_version,
            "failure_codes": [],
            "validated_for": ["output"],
        }
    )

    class _Registry:
        def __init__(self, store: VoiceValidationRepository) -> None:
            self.validation_store = store

        def get_profile(self, voice: str) -> VoiceProfile:
            assert voice == profile.id
            return profile

    registry = _Registry(validation_store)
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        tts_synthesizer=synthesizer,
        clone_model_artifact=artifact_key,
        clone_model_catalog_revision=catalog_revision,
        voice_store=registry,
    )
    job = JobRecord(
        id="job_strict",
        kind="speech",
        state="queued",
        owner="loopback",
        request={
            "input_ref": str(text_file),
            "params": {
                "voice": profile.id,
                "validation_policy": "require_output_pass",
            },
        },
        error_code=None,
        result_ref=None,
    )

    result = asyncio.run(processor.process(job))
    assert result == f"{RESULTS_SUBDIR}/job_strict/speech.pcm"


@pytest.mark.parametrize(
    "validated_for",
    [
        pytest.param(["reference"], id="reference-precheck-only"),
        pytest.param([], id="no-dimension"),
    ],
)
def test_processor_speech_strict_rejects_evidence_without_the_output_dimension(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, validated_for: list[str]
) -> None:
    """A reference pre-check must never satisfy strict production admission.

    `validated_for` records *what* was verified and `capability_key` records
    *where*. Only `output` admits a formal render, so a voice whose newest
    evidence covers just the reference pre-check has to be rejected — and
    rejected specifically, so the job surfaces `voice_not_production_ready`
    instead of a generic retryable failure that would loop forever.
    """

    from speechrail.application.voice_validation_gate import build_validation_binding

    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input.txt"
    text_file.write_text("formal speech")
    runtime_revision = "rt_" + "a" * 64
    synthesizer = _FakeSynthesizer(runtime_revision=runtime_revision)
    profile = VoiceProfile(
        id="clone_job_unvalidated",
        mode="clone",
        revision="vr_" + "b" * 32,
        ref_text="参考文本",
        quality={"status": "pass", "policy_version": "voice_quality_v1"},
    )
    validation_store = VoiceValidationRepository(tmp_path / "voice_validations.json")
    artifact_key = "tts_clone_base"
    catalog_revision = "c" * 40
    binding = build_validation_binding(
        profile,
        VoiceValidationArtifact(artifact_key, catalog_revision),
        synthesizer,
        require_current_binding=True,
    )
    validation_store.put(
        {
            "voice_id": profile.id,
            "voice_revision": profile.revision,
            "status": "pass",
            "run_id": "run_job_reference_only",
            "model_artifact": artifact_key,
            "model_catalog_revision": catalog_revision,
            "model_runtime_revision": binding.model_runtime_revision,
            "runtime_fingerprint": binding.runtime_fingerprint,
            "preprocess_version": binding.preprocess_version,
            "generation_recipe_revision": binding.generation_recipe_revision,
            "policy_version": binding.policy_version,
            "failure_codes": [],
            "validated_for": validated_for,
        }
    )

    class _Registry:
        def __init__(self, store: VoiceValidationRepository) -> None:
            self.validation_store = store

        def get_profile(self, voice: str) -> VoiceProfile:
            assert voice == profile.id
            return profile

    registry = _Registry(validation_store)
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        tts_synthesizer=synthesizer,
        clone_model_artifact=artifact_key,
        clone_model_catalog_revision=catalog_revision,
        voice_store=registry,
    )
    job = JobRecord(
        id="job_strict_rejected",
        kind="speech",
        state="queued",
        owner="loopback",
        request={
            "input_ref": str(text_file),
            "params": {
                "voice": profile.id,
                "validation_policy": "require_output_pass",
            },
        },
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError) as exc_info:
        asyncio.run(processor.process(job))
    assert exc_info.value.error_code == "voice_not_production_ready"
    # Nothing may be written for a rejected formal render.
    assert not (spool / RESULTS_SUBDIR / "job_strict_rejected").exists()


def test_processor_speech_rejects_url_input_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        tts_synthesizer=_FakeSynthesizer(),
        voice_store=VoiceRegistry.open((spool) / "voices.json", (spool) / "voice-audio"),
    )
    job = JobRecord(
        id="job_x",
        kind="speech",
        state="queued",
        owner="loopback",
        request={"input_ref": "https://example.com/text.txt"},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_input_not_allowed"):
        asyncio.run(processor.process(job))


def test_processor_speech_fails_when_no_synthesizer(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input.txt"
    text_file.write_text("hi")
    processor = LocalFileJobProcessor(spool_dir=spool)
    job = JobRecord(
        id="job_x",
        kind="speech",
        state="queued",
        owner="loopback",
        request={"input_ref": str(text_file)},
        error_code=None,
        result_ref=None,
    )

    with pytest.raises(JobProcessingError, match="job_backend_not_ready"):
        asyncio.run(processor.process(job))


def test_processor_artifacts_stay_inside_spool(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    transcriber = _FakeTranscriber(text="ok")
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=transcriber)
    job = JobRecord(
        id="job_safe",
        kind="transcription",
        state="queued",
        owner="loopback",
        request={"input_ref": str(audio)},
        error_code=None,
        result_ref=None,
    )

    async def _fake_decode(input_path: Path) -> bytes:
        return b"\x00\x01" * 100

    processor._decode_audio = _fake_decode  # type: ignore[method-assign]
    ref = asyncio.run(processor.process(job))
    assert ref.startswith(f"{RESULTS_SUBDIR}/job_safe/")

    # Verify no artifacts leaked outside spool
    for child in tmp_path.iterdir():
        if child.name == "spool":
            continue
        assert not any(p.name.endswith((".json", ".pcm")) for p in child.rglob("*"))


# ---------------------------------------------------------------------------
# Wiring: auto-assembly and explicit override
# ---------------------------------------------------------------------------


def test_settings_job_spool_dir_auto_builds_runner(tmp_path: Path) -> None:
    from speechrail.application.services import AppOverrides, build_app_services
    from speechrail.config import Settings

    spool = tmp_path / "speechrail-job-spool"
    settings = Settings(
        job_spool_dir=spool,
        qwen3_model_dir=None,
        qwen3_python=None,
        job_poll_seconds=0.01,
    )
    services = build_app_services(settings, AppOverrides())
    assert services.job_repository is not None
    assert services.lifecycle._runner is not None
    assert services.lifecycle._runner._result_ttl_seconds == settings.job_result_ttl_seconds


def test_explicit_job_processor_override_wins(tmp_path: Path) -> None:
    from speechrail.application.services import AppOverrides, build_app_services
    from speechrail.config import Settings
    from speechrail.runtime.jobs import JobRepository

    spool = tmp_path / "speechrail-job-spool"
    repository = JobRepository(spool)

    class OverrideProcessor:
        async def process(self, job: JobRecord) -> str:
            return "override-result"

    settings = Settings(
        job_spool_dir=spool,
        qwen3_model_dir=None,
        qwen3_python=None,
        job_poll_seconds=0.01,
    )
    services = build_app_services(
        settings,
        AppOverrides(job_repository=repository, job_processor=OverrideProcessor()),
    )
    assert services.job_repository is repository
    assert services.lifecycle._runner is not None
    # The runner should use the override, not the auto-built processor
    assert type(services.lifecycle._runner._processor).__name__ == "OverrideProcessor"


def test_auto_built_runner_executes_queued_job_to_completed(tmp_path: Path) -> None:
    from speechrail.application.services import AppOverrides, build_app_services
    from speechrail.config import Settings

    spool = tmp_path / "speechrail-job-spool"

    class FakeProcessor:
        async def process(self, job: JobRecord) -> str:
            assert job.request["input_ref"] == "external/input"
            return "result://auto/1"

    settings = Settings(
        job_spool_dir=spool,
        qwen3_model_dir=None,
        qwen3_python=None,
        job_poll_seconds=0.01,
    )
    services = build_app_services(settings, AppOverrides(job_processor=FakeProcessor()))
    repository = services.job_repository
    assert repository is not None
    runner = services.lifecycle._runner
    assert runner is not None

    job = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )

    assert asyncio.run(runner.run_once()) is True

    record = repository.get(job.id, owner="loopback")
    assert record is not None
    assert record.state == "completed"
    assert record.result_ref == "result://auto/1"


def test_job_runner_expires_completed_results_via_ttl(tmp_path: Path) -> None:
    spool = tmp_path / "speechrail-job-spool"
    repository = JobRepository(spool)
    job = repository.create(
        kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
    )
    assert repository.claim_next() is not None
    artifact_dir = spool / RESULTS_SUBDIR / job.id
    artifact_dir.mkdir(parents=True)
    artifact = artifact_dir / "transcript.json"
    artifact.write_text('{"text": "expired"}', encoding="utf-8")
    repository.complete(
        job.id, result_ref=f"{RESULTS_SUBDIR}/{job.id}/transcript.json"
    )

    # Backdate completed_at so the TTL expiry triggers immediately.
    with repository._connect() as connection:
        connection.execute(
            "UPDATE jobs SET completed_at = '2020-01-01T00:00:00+00:00' WHERE id = ?",
            (job.id,),
        )

    runner = JobRunner(
        repository=repository,
        governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
        processor=_NeverCalledProcessor(),
        deadline_seconds=1,
        result_ttl_seconds=86400,
    )

    # run_once should expire the old result
    asyncio.run(runner.run_once())

    expired = repository.get(job.id, owner="owner-a")
    assert expired is not None
    assert expired.state == "expired"
    assert expired.result_ref is None
    assert not artifact_dir.exists()


def test_job_runner_ttl_does_not_expire_recent_result(tmp_path: Path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(kind="speech", owner="owner-a", request={"input_ref": "opaque"})
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result://speech/1")

    runner = JobRunner(
        repository=repository,
        governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
        processor=_NeverCalledProcessor(),
        deadline_seconds=1,
        result_ttl_seconds=86400,
    )

    asyncio.run(runner.run_once())

    still_completed = repository.get(job.id, owner="owner-a")
    assert still_completed is not None
    assert still_completed.state == "completed"
    assert still_completed.result_ref == "result://speech/1"


def test_job_runner_retries_ttl_release_after_artifact_cleanup_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    spool = tmp_path / "speechrail-job-spool"
    repository = JobRepository(spool)
    job = repository.create(
        kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
    )
    assert repository.claim_next() is not None
    artifact_dir = spool / RESULTS_SUBDIR / job.id
    artifact_dir.mkdir(parents=True)
    artifact = artifact_dir / "transcript.json"
    artifact.write_text('{"text": "retry"}', encoding="utf-8")
    result_ref = f"{RESULTS_SUBDIR}/{job.id}/transcript.json"
    repository.complete(job.id, result_ref=result_ref)
    with repository._connect() as connection:
        connection.execute(
            "UPDATE jobs SET completed_at = '2020-01-01T00:00:00+00:00' WHERE id = ?",
            (job.id,),
        )

    cleanup_calls = 0
    current = [datetime(2026, 1, 2, tzinfo=UTC)]

    def fail_cleanup(**_: object) -> bool:
        nonlocal cleanup_calls
        cleanup_calls += 1
        raise OSError("artifact is temporarily busy")

    monkeypatch.setattr(
        "speechrail.runtime.job_runner.delete_job_result_artifact", fail_cleanup
    )
    runner = JobRunner(
        repository=repository,
        governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
        processor=_NeverCalledProcessor(),
        deadline_seconds=1,
        result_ttl_seconds=86400,
        clock=lambda: current[0],
    )

    asyncio.run(runner.run_once())
    still_completed = repository.get(job.id, owner="owner-a")
    assert still_completed is not None
    assert still_completed.state == "completed"
    assert still_completed.result_ref == result_ref
    assert artifact.exists()
    assert cleanup_calls == 1

    asyncio.run(runner.run_once())
    assert cleanup_calls == 1

    current[0] += timedelta(seconds=5)
    asyncio.run(runner.run_once())
    assert cleanup_calls == 2

    current[0] += timedelta(seconds=10)
    monkeypatch.undo()
    asyncio.run(runner.run_once())

    expired = repository.get(job.id, owner="owner-a")
    assert expired is not None
    assert expired.state == "expired"
    assert expired.result_ref is None
    assert not artifact_dir.exists()


def test_job_runner_claims_work_after_housekeeping_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")

    def fail_cleanup(**_: object) -> bool:
        raise RuntimeError("unexpected path resolution failure")

    monkeypatch.setattr(
        "speechrail.runtime.job_runner.delete_job_result_artifact", fail_cleanup
    )
    expired = repository.create(
        kind="transcription", owner="owner-a", request={"input_ref": "expired"}
    )
    assert repository.claim_next() is not None
    repository.complete(expired.id, result_ref="result://expired")
    with repository._connect() as connection:
        connection.execute(
            "UPDATE jobs SET completed_at = '2020-01-01T00:00:00+00:00' WHERE id = ?",
            (expired.id,),
        )

    class SuccessfulProcessor:
        async def process(self, job: JobRecord) -> str:
            return "result://queued-work"

    queued = repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "queued"}
    )
    runner = JobRunner(
        repository=repository,
        governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
        processor=SuccessfulProcessor(),
        deadline_seconds=1,
        result_ttl_seconds=86400,
        clock=lambda: datetime(2026, 1, 2, tzinfo=UTC),
    )

    assert asyncio.run(runner.run_once()) is True

    completed = repository.get(queued.id, owner="owner-a")
    assert completed is not None
    assert completed.state == "completed"
    assert completed.result_ref == "result://queued-work"


# ---------------------------------------------------------------------------
# E2E: TestClient create -> poll -> completed -> result bytes -> DELETE
# ---------------------------------------------------------------------------


def test_e2e_job_lifecycle_with_artifact_bytes(tmp_path: Path) -> None:
    from fastapi.testclient import TestClient

    from speechrail.app import create_app
    from speechrail.config import Settings
    from speechrail.runtime.jobs import JobRepository

    spool = tmp_path / "speechrail-job-spool"
    repository = JobRepository(spool)
    finish: Future[None] = Future()

    class FakeProcessor:
        async def process(self, job: JobRecord) -> str:
            await asyncio.wrap_future(finish)
            result_dir = spool / RESULTS_SUBDIR / job.id
            result_dir.mkdir(parents=True, exist_ok=True)
            result_dir.chmod(0o700)
            artifact = result_dir / "transcript.json"
            artifact.write_text(json.dumps({"text": "e2e transcript"}))
            artifact.chmod(0o600)
            return f"{RESULTS_SUBDIR}/{job.id}/transcript.json"

    app = create_app(
        Settings(
            job_spool_dir=spool,
            qwen3_model_dir=None,
            qwen3_python=None,
            job_poll_seconds=0.01,
        ),
        job_repository=repository,
        job_processor=FakeProcessor(),
    )

    with TestClient(app) as client:
        created = client.post(
            "/v1/jobs",
            json={"kind": "transcription", "input_ref": "external/input.wav"},
        )
        assert created.status_code == 202
        job_id = created.json()["id"]

        # Poll until completed
        deadline = time.monotonic() + 1.0
        while True:
            status = client.get(f"/v1/jobs/{job_id}").json()
            if status["state"] == "running" and not finish.done():
                finish.set_result(None)
            if status["state"] in {"completed", "failed", "cancelled"}:
                break
            if time.monotonic() >= deadline:
                raise AssertionError("job did not complete in time")
            time.sleep(0.01)

        assert status["state"] == "completed"
        assert status["result_ref"] is not None

        # GET /result should return artifact bytes
        result_resp = client.get(f"/v1/jobs/{job_id}/result")
        assert result_resp.status_code == 200
        assert result_resp.headers["content-type"] == "application/json"
        assert json.loads(result_resp.content) == {"text": "e2e transcript"}

        # DELETE should succeed
        deleted = client.delete(f"/v1/jobs/{job_id}")
        assert deleted.status_code == 200
        assert deleted.json()["state"] == "completed"
        assert deleted.json()["result_ref"] is None
        assert not (spool / RESULTS_SUBDIR / job_id).exists()


def test_e2e_job_lifecycle_speech_artifact(tmp_path: Path) -> None:
    from fastapi.testclient import TestClient

    from speechrail.app import create_app
    from speechrail.config import Settings
    from speechrail.runtime.jobs import JobRepository

    spool = tmp_path / "speechrail-job-spool"
    repository = JobRepository(spool)
    finish: Future[None] = Future()

    class FakeSpeechProcessor:
        async def process(self, job: JobRecord) -> str:
            await asyncio.wrap_future(finish)
            result_dir = spool / RESULTS_SUBDIR / job.id
            result_dir.mkdir(parents=True, exist_ok=True)
            result_dir.chmod(0o700)
            artifact = result_dir / "speech.pcm"
            artifact.write_bytes(b"\x00\x01\x02\x03")
            artifact.chmod(0o600)
            return f"{RESULTS_SUBDIR}/{job.id}/speech.pcm"

    app = create_app(
        Settings(
            job_spool_dir=spool,
            qwen3_model_dir=None,
            qwen3_python=None,
            job_poll_seconds=0.01,
        ),
        job_repository=repository,
        job_processor=FakeSpeechProcessor(),
    )

    with TestClient(app) as client:
        created = client.post(
            "/v1/jobs",
            json={"kind": "speech", "input_ref": "external/input.txt"},
        )
        assert created.status_code == 202
        job_id = created.json()["id"]

        deadline = time.monotonic() + 1.0
        while True:
            status = client.get(f"/v1/jobs/{job_id}").json()
            if status["state"] == "running" and not finish.done():
                finish.set_result(None)
            if status["state"] in {"completed", "failed", "cancelled"}:
                break
            if time.monotonic() >= deadline:
                raise AssertionError("job did not complete in time")
            time.sleep(0.01)

        assert status["state"] == "completed"

        result_resp = client.get(f"/v1/jobs/{job_id}/result")
        assert result_resp.status_code == 200
        assert result_resp.headers["content-type"] == "audio/x-pcm"
        assert result_resp.content == b"\x00\x01\x02\x03"


# ---------------------------------------------------------------------------
# #244: short-write / staging publish regressions (RED first)
# ---------------------------------------------------------------------------


def test_write_artifact_retries_short_write_until_complete(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """os.write may return fewer bytes; the artifact must still be complete."""
    import os as _os

    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool)
    content = b"x" * 16
    real_write = _os.write
    calls = {"n": 0}

    def _short_write(fd: int, data: bytes) -> int:
        calls["n"] += 1
        if calls["n"] == 1:
            return real_write(fd, data[:3])
        return real_write(fd, data)

    monkeypatch.setattr(_os, "write", _short_write)
    ref = processor._write_artifact("job_short", "transcript.json", content)
    artifact = spool / RESULTS_SUBDIR / "job_short" / "transcript.json"
    assert artifact.read_bytes() == content
    assert ref == f"{RESULTS_SUBDIR}/job_short/transcript.json"


def test_write_artifact_fails_without_partial_final_on_stalled_write(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A zero-progress write must fail and leave no visible partial final."""
    import os as _os

    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool)

    monkeypatch.setattr(_os, "write", lambda fd, data: 0)
    with pytest.raises(JobProcessingError, match="job_artifact_incomplete"):
        processor._write_artifact("job_stall", "transcript.json", b"y" * 16)
    assert not (spool / RESULTS_SUBDIR / "job_stall" / "transcript.json").exists()


def test_write_artifact_cleans_staging_on_mid_write_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Mid-write OSError must not leave a partial final or staging file behind."""
    import os as _os

    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool)
    content = b"z" * 16
    real_write = _os.write
    calls = {"n": 0}

    def _flaky_write(fd: int, data: bytes) -> int:
        calls["n"] += 1
        if calls["n"] == 1:
            return real_write(fd, data[:5])
        raise OSError("injected mid-write failure")

    monkeypatch.setattr(_os, "write", _flaky_write)
    with pytest.raises(JobProcessingError, match="job_artifact_incomplete"):
        processor._write_artifact("job_flaky", "transcript.json", content)
    target_dir = spool / RESULTS_SUBDIR / "job_flaky"
    leftovers = list(target_dir.iterdir()) if target_dir.exists() else []
    assert leftovers == []


def test_run_once_short_write_still_publishes_complete_artifact(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """End-to-end: short writes through the runner still yield a full artifact."""
    import os as _os

    spool = tmp_path / "spool"
    spool.mkdir()
    audio = spool / "input.wav"
    audio.write_bytes(b"RIFF-fake-wav")
    real_write = _os.write
    first = {"done": False}

    def _short_once(fd: int, data: bytes) -> int:
        if not first["done"]:
            first["done"] = True
            return real_write(fd, bytes(data[:2]))
        return real_write(fd, data)

    monkeypatch.setattr(_os, "write", _short_once)
    repository = JobRepository(spool)
    transcriber = _FakeTranscriber(text="e2e text")
    processor = LocalFileJobProcessor(spool_dir=spool, batch_transcriber=transcriber)
    processor._decode_audio = (  # type: ignore[method-assign]
        lambda input_path: _coro_bytes()
    )

    async def _coro_bytes() -> bytes:
        return b"\x00\x01" * 50

    governor = ResourceGovernor(GovernorLimits(2, 1, 1))
    runner = JobRunner(
        repository=repository, governor=governor, processor=processor, deadline_seconds=5
    )
    job = repository.create(
        kind="transcription", owner="loopback", request={"input_ref": str(audio)}
    )
    assert asyncio.run(runner.run_once()) is True
    record = repository.get(job.id, owner="loopback")
    assert record is not None and record.state == "completed"
    assert record.result_ref is not None
    resolved = resolve_result_artifact(spool_dir=spool, job_id=job.id, result_ref=record.result_ref)
    assert resolved is not None
    artifact, _media_type = resolved
    assert artifact.stat().st_size > 0
    assert json.loads(artifact.read_text())["text"] == "e2e text"


def test_recover_interrupted_does_not_delete_published_artifact(tmp_path: Path) -> None:
    """A published final survives restart recovery bookkeeping for its job."""
    spool = tmp_path / "spool"
    spool.mkdir()
    repository = JobRepository(spool)
    job = repository.create(kind="transcription", owner="loopback", request={"input_ref": "opaque"})
    processor = LocalFileJobProcessor(spool_dir=spool)
    content = b'{"text": "keep me"}'
    ref = processor._write_artifact(job.id, "transcript.json", content)
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref=ref)
    # Restart recovery only touches rows still marked running; the completed
    # row keeps its ref and the published bytes stay on disk.
    assert repository.recover_interrupted(max_attempts=2) == 0
    record = repository.get(job.id, owner="loopback")
    assert record is not None and record.state == "completed"
    assert record.result_ref == ref
    artifact = spool / RESULTS_SUBDIR / job.id / "transcript.json"
    assert artifact.read_bytes() == content


@pytest.mark.parametrize("operation", ["close", "fsync", "chmod", "replace"])
def test_publish_failure_preserves_previous_artifact_and_cleans_staging(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, operation: str
) -> None:
    import os

    processor = LocalFileJobProcessor(spool_dir=tmp_path)
    processor._write_artifact("job_retry", "speech.pcm", b"\x00\x01" * 8)
    target_dir = tmp_path / RESULTS_SUBDIR / "job_retry"
    target = target_dir / "speech.pcm"
    original = target.read_bytes()

    def fail(*args: object, **kwargs: object) -> None:
        raise OSError("injected publish failure")

    if operation == "close":
        real_close = os.close

        def fail_close(fd: int) -> None:
            real_close(fd)
            fail()

        monkeypatch.setattr(os, "close", fail_close)
    elif operation == "chmod":
        real_chmod = Path.chmod

        def fail_staging_chmod(path: Path, mode: int) -> None:
            if path != target_dir:
                fail()
            real_chmod(path, mode)

        monkeypatch.setattr(Path, "chmod", fail_staging_chmod)
    elif operation == "replace":
        monkeypatch.setattr(Path, "replace", fail)
    else:
        monkeypatch.setattr(os, operation, fail)

    with pytest.raises(JobProcessingError, match="job_artifact_incomplete"):
        processor._write_artifact("job_retry", "speech.pcm", b"\x02\x03" * 8)
    assert target.read_bytes() == original
    assert list(target_dir.iterdir()) == [target]


def test_reentrant_publish_uses_independent_staging(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import os

    processor = LocalFileJobProcessor(spool_dir=tmp_path)
    real_write = os.write
    nested = False

    def reentrant_write(fd: int, content: bytes) -> int:
        nonlocal nested
        if not nested:
            nested = True
            processor._write_artifact("job_shared", "speech.pcm", b"\x02\x03")
        return real_write(fd, content)

    monkeypatch.setattr(os, "write", reentrant_write)
    processor._write_artifact("job_shared", "speech.pcm", b"\x00\x01")
    target_dir = tmp_path / RESULTS_SUBDIR / "job_shared"
    assert (target_dir / "speech.pcm").read_bytes() == b"\x00\x01"
    assert len(list(target_dir.iterdir())) == 1


def test_restart_between_publish_and_database_commit_preserves_complete_file(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path)
    job = repository.create(kind="speech", owner="loopback", request={})
    assert repository.claim_next() is not None
    processor = LocalFileJobProcessor(spool_dir=tmp_path)
    processor._write_artifact(job.id, "speech.pcm", b"\x00\x01" * 8)
    target = tmp_path / RESULTS_SUBDIR / job.id / "speech.pcm"
    assert repository.recover_interrupted(max_attempts=2) == 1
    assert target.read_bytes() == b"\x00\x01" * 8
    recovered = repository.get(job.id, owner="loopback")
    assert recovered is not None and recovered.state == "queued"
    assert recovered.result_ref is None
    assert repository.claim_next() is not None
    ref = processor._write_artifact(job.id, "speech.pcm", b"\x02\x03" * 8)
    repository.complete(job.id, result_ref=ref)
    assert target.read_bytes() == b"\x02\x03" * 8


def test_runner_reads_back_completion_when_database_commit_response_fails(
    tmp_path: Path,
) -> None:
    class Repository(JobRepository):
        def complete(self, job_id: str, *, result_ref: str) -> JobRecord:
            super().complete(job_id, result_ref=result_ref)
            raise RuntimeError("injected error after commit")

    repository = Repository(tmp_path)
    processor = LocalFileJobProcessor(spool_dir=tmp_path)

    class Processor:
        async def process(self, job: JobRecord) -> str:
            return processor._write_artifact(job.id, "speech.pcm", b"\x00\x01" * 8)

    job = repository.create(kind="speech", owner="loopback", request={})
    runner = JobRunner(
        repository=repository,
        governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
        processor=Processor(),
        deadline_seconds=5,
    )
    assert asyncio.run(runner.run_once()) is True
    completed = repository.get(job.id, owner="loopback")
    assert completed is not None and completed.state == "completed"
    assert completed.result_ref is not None
    assert (tmp_path / completed.result_ref).read_bytes() == b"\x00\x01" * 8
