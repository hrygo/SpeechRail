from __future__ import annotations

import asyncio
import itertools
from pathlib import Path

from speechrail.runtime.job_runner import (
    JobProcessingError,
    JobRunner,
    sanitize_error_message,
)
from speechrail.runtime.jobs import JobRecord, JobRepository
from speechrail.runtime.resource_governor import GovernorLimits, ResourceGovernor


def test_job_runner_completes_claimed_work_in_the_matching_batch_lane(tmp_path: Path) -> None:
    class FakeProcessor:
        async def process(self, job: JobRecord) -> str:
            assert job.kind == "speech"
            assert job.request == {"input_ref": "opaque"}
            return "result://speech/job-1"

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        job = repository.create(kind="speech", owner="owner-a", request={"input_ref": "opaque"})
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=FakeProcessor(),
            deadline_seconds=1,
        )

        assert await runner.run_once()
        completed = repository.get(job.id, owner="owner-a")
        assert completed is not None
        assert completed.state == "completed"
        assert completed.result_ref == "result://speech/job-1"
        assert not await runner.run_once()

    asyncio.run(scenario())


def test_job_runner_records_a_bounded_processor_failure(tmp_path: Path) -> None:
    class FailingProcessor:
        async def process(self, job: JobRecord) -> str:
            del job
            raise RuntimeError("untrusted detail")

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        job = repository.create(
            kind="transcription",
            owner="owner-a",
            request={"input_ref": "opaque"},
        )
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=FailingProcessor(),
            deadline_seconds=1,
        )

        assert await runner.run_once()
        failed = repository.get(job.id, owner="owner-a")
        assert failed is not None
        assert failed.state == "failed"
        assert failed.error_code == "job_processor_failed"

    asyncio.run(scenario())


def test_sanitize_error_message_redacts_paths_urls_and_emails() -> None:
    raw = (
        "failed reading /Users/secret/models/x.bin from "
        "https://example.com/audio?token=1 via a@b.co"
    )

    cleaned = sanitize_error_message(raw)

    assert "/Users" not in cleaned
    assert "https://" not in cleaned
    assert "a@b.co" not in cleaned
    assert "<path>" in cleaned
    assert "<url>" in cleaned
    assert "<email>" in cleaned


def test_sanitize_error_message_strips_control_chars_and_collapses_whitespace() -> None:
    cleaned = sanitize_error_message("bad\x00thing\n\tnext\r\nline")

    assert "\x00" not in cleaned
    assert "\n" not in cleaned
    assert "\t" not in cleaned
    assert cleaned == "bad thing next line"


def test_sanitize_error_message_truncates_a_long_transcript() -> None:
    cleaned = sanitize_error_message("x" * 4000)

    assert 0 < len(cleaned) <= 256


def test_sanitize_error_message_handles_empty_input() -> None:
    assert sanitize_error_message("") == ""


def test_job_runner_stores_sanitized_curated_processing_message(tmp_path: Path) -> None:
    class FailingProcessor:
        async def process(self, job: JobRecord) -> str:
            del job
            raise JobProcessingError(
                "job_input_invalid",
                message="failed reading /Users/secret/models/x.bin",
            )

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        job = repository.create(
            kind="transcription",
            owner="owner-a",
            request={"input_ref": "opaque"},
        )
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=FailingProcessor(),
            deadline_seconds=1,
        )

        assert await runner.run_once()
        failed = repository.get(job.id, owner="owner-a")
        assert failed is not None
        assert failed.state == "failed"
        assert failed.error_code == "job_input_invalid"
        assert failed.error_message is not None
        assert "/Users" not in failed.error_message
        assert len(failed.error_message) <= 256

    asyncio.run(scenario())


def test_job_runner_hides_unexpected_exception_detail(tmp_path: Path) -> None:
    class FailingProcessor:
        async def process(self, job: JobRecord) -> str:
            del job
            raise RuntimeError("SECRET raw text /etc/passwd")

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        job = repository.create(
            kind="transcription",
            owner="owner-a",
            request={"input_ref": "opaque"},
        )
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=FailingProcessor(),
            deadline_seconds=1,
        )

        assert await runner.run_once()
        failed = repository.get(job.id, owner="owner-a")
        assert failed is not None
        assert failed.state == "failed"
        assert failed.error_code == "job_processor_failed"
        assert failed.error_message is not None
        assert "SECRET" not in failed.error_message
        assert "/etc/passwd" not in failed.error_message
        assert len(failed.error_message) <= 256

    asyncio.run(scenario())


def test_job_runner_interleaves_kinds_so_neither_kind_starves(tmp_path: Path) -> None:
    claimed_kinds: list[str] = []

    class RecordingProcessor:
        async def process(self, job: JobRecord) -> str:
            claimed_kinds.append(job.kind)
            return f"result://{job.id}"

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        jobs = [
            repository.create(
                kind="speech", owner="owner-a", request={"input_ref": "opaque"}
            ),
            repository.create(
                kind="speech", owner="owner-a", request={"input_ref": "opaque"}
            ),
            repository.create(
                kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
            ),
            repository.create(
                kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
            ),
        ]
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=RecordingProcessor(),
            deadline_seconds=1,
        )

        while await runner.run_once():
            pass

        # Both kinds were queued up front; a burst of one kind must not run
        # entirely before the other, so claims alternate.
        assert claimed_kinds.count("speech") == 2
        assert claimed_kinds.count("transcription") == 2
        assert all(
            first != second for first, second in itertools.pairwise(claimed_kinds)
        )
        for job in jobs:
            stored = repository.get(job.id, owner="owner-a")
            assert stored is not None
            assert stored.state == "completed"

    asyncio.run(scenario())


def test_job_runner_single_kind_queue_drains_in_fifo_order(tmp_path: Path) -> None:
    claimed_ids: list[str] = []

    class RecordingProcessor:
        async def process(self, job: JobRecord) -> str:
            claimed_ids.append(job.id)
            return f"result://{job.id}"

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        jobs = [
            repository.create(
                kind="speech", owner="owner-a", request={"input_ref": "opaque"}
            ),
            repository.create(
                kind="speech", owner="owner-a", request={"input_ref": "opaque"}
            ),
            repository.create(
                kind="speech", owner="owner-a", request={"input_ref": "opaque"}
            ),
        ]
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=RecordingProcessor(),
            deadline_seconds=1,
        )

        while await runner.run_once():
            pass

        assert claimed_ids == [job.id for job in jobs]
        for job in jobs:
            stored = repository.get(job.id, owner="owner-a")
            assert stored is not None
            assert stored.state == "completed"

    asyncio.run(scenario())


def test_job_runner_falls_back_to_available_kind_when_preferred_is_empty(
    tmp_path: Path,
) -> None:
    claimed: list[tuple[str, str]] = []

    class RecordingProcessor:
        async def process(self, job: JobRecord) -> str:
            claimed.append((job.kind, job.id))
            return f"result://{job.id}"

    async def scenario() -> None:
        repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
        transcription = repository.create(
            kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
        )
        first_speech = repository.create(
            kind="speech", owner="owner-a", request={"input_ref": "opaque"}
        )
        second_speech = repository.create(
            kind="speech", owner="owner-a", request={"input_ref": "opaque"}
        )
        runner = JobRunner(
            repository=repository,
            governor=ResourceGovernor(GovernorLimits(2, 1, 1)),
            processor=RecordingProcessor(),
            deadline_seconds=1,
        )

        while await runner.run_once():
            pass

        # The oldest job is transcription; after it the runner prefers speech,
        # and once only speech remains it falls back to that kind instead of
        # idling on an empty preference.
        assert [kind for kind, _ in claimed] == [
            "transcription",
            "speech",
            "speech",
        ]
        assert [job_id for _, job_id in claimed] == [
            transcription.id,
            first_speech.id,
            second_speech.id,
        ]

    asyncio.run(scenario())
