from __future__ import annotations

import sqlite3
from pathlib import Path

from speechrail.runtime.jobs import _INTERRUPTED_EXHAUSTED_MESSAGE, JobRepository


def test_job_repository_scopes_records_to_owner_and_cancels_queued_work(tmp_path: Path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(kind="speech", owner="owner-a", request={"input_ref": "opaque"})

    assert repository.get(job.id, owner="owner-b") is None
    cancelled = repository.cancel(job.id, owner="owner-a")

    assert cancelled is not None
    assert cancelled.state == "cancelled"
    assert repository.claim_next() is None


def test_job_repository_claim_is_atomic_and_restart_marks_running_work_failed(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(kind="transcription", owner="owner-a", request={"input_ref": "opaque"})

    assert repository.claim_next() is not None
    assert repository.claim_next() is None

    assert repository.recover_interrupted(max_attempts=1) == 1
    recovered = repository.get(job.id, owner="owner-a")
    assert recovered is not None
    assert recovered.state == "failed"
    assert recovered.error_code == "worker_interrupted"
    assert recovered.error_message == _INTERRUPTED_EXHAUSTED_MESSAGE


def test_job_repository_completes_deletes_result_and_expires_by_completion_time(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(kind="speech", owner="owner-a", request={"input_ref": "opaque"})
    claimed = repository.claim_next()
    assert claimed is not None

    completed = repository.complete(job.id, result_ref="result.wav")
    assert completed.state == "completed"
    assert completed.result_ref == "result.wav"

    deleted = repository.delete_result(job.id, owner="owner-a")
    assert deleted is not None
    assert deleted.result_ref is None

    assert repository.expire_completed(before="9999-01-01T00:00:00+00:00") == 1
    expired = repository.get(job.id, owner="owner-a")
    assert expired is not None
    assert expired.state == "expired"


def test_cancelling_a_completed_job_releases_its_result_without_rewriting_state(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(kind="speech", owner="owner-a", request={"input_ref": "opaque"})
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result.wav")

    deleted = repository.cancel(job.id, owner="owner-a")

    assert deleted is not None
    assert deleted.state == "completed"
    assert deleted.result_ref is None


def test_job_repository_claim_increments_attempts_and_bounds_restart_retries(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
    )

    first = repository.claim_next()
    assert first is not None
    assert first.attempts == 1
    assert repository.claim_next() is None

    # First restart: still under budget, so it is requeued with the counted attempt.
    assert repository.recover_interrupted(max_attempts=2) == 1
    requeued = repository.get(job.id, owner="owner-a")
    assert requeued is not None
    assert requeued.state == "queued"
    assert requeued.attempts == 1
    assert requeued.error_message is None

    second = repository.claim_next()
    assert second is not None
    assert second.attempts == 2

    # Second restart: attempts are exhausted, so it fails terminally.
    assert repository.recover_interrupted(max_attempts=2) == 1
    failed = repository.get(job.id, owner="owner-a")
    assert failed is not None
    assert failed.state == "failed"
    assert failed.error_code == "worker_interrupted"
    assert failed.error_message == _INTERRUPTED_EXHAUSTED_MESSAGE
    assert failed.attempts == 2


def test_job_repository_records_a_bounded_failure_code(tmp_path: Path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(kind="transcription", owner="owner-a", request={"input_ref": "opaque"})
    assert repository.claim_next() is not None

    failed = repository.fail(job.id, error_code="backend_timeout")

    assert failed.state == "failed"
    assert failed.error_code == "backend_timeout"


def test_job_repository_adds_error_message_column_to_existing_spool(tmp_path: Path) -> None:
    spool_dir = tmp_path / "speechrail-job-spool"
    spool_dir.mkdir(mode=0o700)
    database = spool_dir / "jobs.sqlite3"
    legacy = sqlite3.connect(database)
    legacy.execute(
        """
        CREATE TABLE jobs (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            owner TEXT NOT NULL,
            request_json TEXT NOT NULL,
            error_code TEXT,
            result_ref TEXT,
            completed_at TEXT,
            updated_at TEXT NOT NULL
        )
        """
    )
    legacy.commit()
    legacy.close()

    repository = JobRepository(spool_dir)
    with repository._connect() as connection:
        columns = {row["name"] for row in connection.execute("PRAGMA table_info(jobs)")}

    assert "error_message" in columns

    job = repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "opaque"}
    )
    assert repository.claim_next() is not None
    failed = repository.fail(
        job.id, error_code="job_processor_failed", error_message="safe detail"
    )

    assert failed.state == "failed"
    assert failed.error_message == "safe detail"


def test_job_repository_adds_attempts_column_to_existing_spool(tmp_path: Path) -> None:
    spool_dir = tmp_path / "speechrail-job-spool"
    spool_dir.mkdir(mode=0o700)
    database = spool_dir / "jobs.sqlite3"
    legacy = sqlite3.connect(database)
    legacy.execute(
        """
        CREATE TABLE jobs (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            owner TEXT NOT NULL,
            request_json TEXT NOT NULL,
            error_code TEXT,
            result_ref TEXT,
            completed_at TEXT,
            error_message TEXT,
            updated_at TEXT NOT NULL
        )
        """
    )
    legacy.commit()
    legacy.close()

    repository = JobRepository(spool_dir)
    with repository._connect() as connection:
        columns = {row["name"] for row in connection.execute("PRAGMA table_info(jobs)")}

    assert "attempts" in columns

    job = repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "opaque"}
    )
    claimed = repository.claim_next()
    assert claimed is not None
    assert claimed.id == job.id
    assert claimed.attempts == 1


def test_claim_next_prefers_the_requested_kind_over_an_older_other_kind(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    older_speech = repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "opaque"}
    )
    oldest_transcription = repository.create(
        kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
    )
    repository.create(
        kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
    )

    claimed = repository.claim_next(prefer_kind="transcription")

    assert claimed is not None
    assert claimed.id == oldest_transcription.id
    assert claimed.id != older_speech.id
    assert claimed.kind == "transcription"
    assert claimed.state == "running"
    assert claimed.attempts == 1


def test_claim_next_without_preference_keeps_overall_fifo_order(tmp_path: Path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    oldest = repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "opaque"}
    )
    repository.create(
        kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
    )

    claimed = repository.claim_next()

    assert claimed is not None
    assert claimed.id == oldest.id


def test_claim_next_falls_back_to_available_kind_when_preference_is_empty(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    oldest_speech = repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "opaque"}
    )
    repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "opaque"}
    )

    claimed = repository.claim_next(prefer_kind="transcription")

    assert claimed is not None
    assert claimed.id == oldest_speech.id
    assert claimed.kind == "speech"


def test_claim_next_with_a_preference_remains_single_claim(tmp_path: Path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    repository.create(
        kind="transcription", owner="owner-a", request={"input_ref": "opaque"}
    )

    assert repository.claim_next(prefer_kind="transcription") is not None
    assert repository.claim_next(prefer_kind="transcription") is None


def test_job_repository_creates_claim_and_list_indexes_idempotently(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")

    JobRepository(repository.spool_dir)

    with repository._connect() as connection:
        names = {
            str(row["name"])
            for row in connection.execute("PRAGMA index_list(jobs)").fetchall()
        }

    assert {"idx_jobs_state_updated", "idx_jobs_owner_updated"} <= names
