from __future__ import annotations

from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.runtime.jobs import JobRepository


def test_jobs_api_creates_reads_and_cancels_owner_scoped_job(tmp_path) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=JobRepository(tmp_path.parent / "speechrail-job-spool"),
        )
    )

    created = client.post(
        "/v1/jobs",
        json={"kind": "speech", "input_ref": "external/input.txt"},
        headers={"X-Request-ID": "owner-a"},
    )
    job_id = created.json()["id"]
    read = client.get(f"/v1/jobs/{job_id}", headers={"X-Request-ID": "owner-a"})
    cancelled = client.delete(f"/v1/jobs/{job_id}", headers={"X-Request-ID": "owner-a"})

    assert created.status_code == 202
    assert read.json()["state"] == "queued"
    assert cancelled.json()["state"] == "cancelled"


def test_jobs_api_requires_bearer_key_when_configured(tmp_path) -> None:
    client = TestClient(
        create_app(
            Settings(api_key="secret", qwen3_model_dir=None, qwen3_python=None),
            job_repository=JobRepository(tmp_path.parent / "speechrail-job-spool"),
        )
    )

    response = client.post("/v1/jobs", json={"kind": "speech", "input_ref": "external/input"})

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_api_key"


def test_jobs_api_delete_releases_a_completed_owner_scoped_result(tmp_path) -> None:
    repository = JobRepository(tmp_path.parent / "speechrail-job-spool")
    job = repository.create(
        kind="speech",
        owner="loopback",
        request={"input_ref": "external/input"},
    )
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result.wav")
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=repository,
        )
    )

    response = client.delete(f"/v1/jobs/{job.id}")

    assert response.status_code == 200
    assert response.json()["state"] == "completed"
    assert response.json()["result_ref"] is None


def test_configured_job_spool_recovers_interrupted_jobs_on_startup(tmp_path) -> None:
    spool_dir = tmp_path.parent / "speechrail-job-spool"
    repository = JobRepository(spool_dir)
    job = repository.create(
        kind="speech",
        owner="loopback",
        request={"input_ref": "external/input"},
    )
    assert repository.claim_next() is not None

    with TestClient(
        create_app(
            Settings(
                job_spool_dir=spool_dir,
                qwen3_model_dir=None,
                qwen3_python=None,
            )
        )
    ) as client:
        response = client.get(f"/v1/jobs/{job.id}")

    assert response.status_code == 200
    assert response.json()["state"] == "failed"
    assert response.json()["error_code"] == "worker_interrupted"
