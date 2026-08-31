from __future__ import annotations

from pathlib import Path

from speechrail.runtime.jobs import JobRepository


def test_job_repository_scopes_records_to_owner_and_cancels_queued_work(tmp_path: Path) -> None:
    repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
    job = repository.create(kind="speech", owner="owner-a", request={"input_ref": "opaque"})

    assert repository.get(job.id, owner="owner-b") is None
    cancelled = repository.cancel(job.id, owner="owner-a")

    assert cancelled is not None
    assert cancelled.state == "cancelled"
    assert repository.claim_next() is None


def test_job_repository_claim_is_atomic_and_restart_marks_running_work_failed(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
    job = repository.create(kind="transcription", owner="owner-a", request={"input_ref": "opaque"})

    assert repository.claim_next() is not None
    assert repository.claim_next() is None

    assert repository.recover_interrupted() == 1
    recovered = repository.get(job.id, owner="owner-a")
    assert recovered is not None
    assert recovered.state == "failed"
    assert recovered.error_code == "worker_interrupted"


def test_job_repository_completes_deletes_result_and_expires_by_completion_time(
    tmp_path: Path,
) -> None:
    repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
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
