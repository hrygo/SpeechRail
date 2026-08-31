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
