from __future__ import annotations

import asyncio
import json
import time
from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.ports import (
    AudioChunk,
    SpeechRequest,
    TranscriptionRequest,
)
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
    def __init__(self, pcm: bytes = b"\x00\x01\x02\x03") -> None:
        self._pcm = pcm
        self.calls: list[SpeechRequest] = []

    async def synthesize(self, request: SpeechRequest) -> AsyncIterator[AudioChunk]:
        yield AudioChunk(response_id=request.voice, chunk_index=0, audio=self._pcm)


def test_processor_speech_writes_artifact_and_returns_relative_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    text_file = spool / "input.txt"
    text_file.write_text("hello speech")
    synthesizer = _FakeSynthesizer(pcm=b"\xaa\xbb")
    processor = LocalFileJobProcessor(
        spool_dir=spool,
        tts_synthesizer=synthesizer,
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


def test_processor_speech_rejects_url_input_ref(tmp_path: Path) -> None:
    spool = tmp_path / "spool"
    spool.mkdir()
    processor = LocalFileJobProcessor(spool_dir=spool, tts_synthesizer=_FakeSynthesizer())
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
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(kind="speech", owner="owner-a", request={"input_ref": "opaque"})
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result://speech/1")

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

    class FakeProcessor:
        async def process(self, job: JobRecord) -> str:
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
            if status["state"] != "queued":
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


def test_e2e_job_lifecycle_speech_artifact(tmp_path: Path) -> None:
    from fastapi.testclient import TestClient

    from speechrail.app import create_app
    from speechrail.config import Settings
    from speechrail.runtime.jobs import JobRepository

    spool = tmp_path / "speechrail-job-spool"
    repository = JobRepository(spool)

    class FakeSpeechProcessor:
        async def process(self, job: JobRecord) -> str:
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
            if status["state"] != "queued":
                break
            if time.monotonic() >= deadline:
                raise AssertionError("job did not complete in time")
            time.sleep(0.01)

        assert status["state"] == "completed"

        result_resp = client.get(f"/v1/jobs/{job_id}/result")
        assert result_resp.status_code == 200
        assert result_resp.headers["content-type"] == "audio/x-pcm"
        assert result_resp.content == b"\x00\x01\x02\x03"
