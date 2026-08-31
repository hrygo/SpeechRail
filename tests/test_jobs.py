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
