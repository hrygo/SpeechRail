from __future__ import annotations

import asyncio
import math
import time
from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.runtime.jobs import JobRepository


def test_jobs_api_creates_reads_and_cancels_owner_scoped_job(tmp_path) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=JobRepository(tmp_path / "speechrail-job-spool"),
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
            job_repository=JobRepository(tmp_path / "speechrail-job-spool"),
        )
    )

    response = client.post("/v1/jobs", json={"kind": "speech", "input_ref": "external/input"})

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_api_key"


def test_jobs_api_delete_releases_a_completed_owner_scoped_result(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
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
    spool_dir = tmp_path / "speechrail-job-spool"
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
                max_job_attempts=1,
                qwen3_model_dir=None,
                qwen3_python=None,
            )
        )
    ) as client:
        response = client.get(f"/v1/jobs/{job.id}")

    assert response.status_code == 200
    assert response.json()["state"] == "failed"
    assert response.json()["error_code"] == "worker_interrupted"
    assert response.json()["attempts"] == 1


def test_configured_job_spool_requeues_interrupted_jobs_under_attempt_budget(
    tmp_path,
) -> None:
    class BlockingProcessor:
        async def process(self, job) -> str:
            del job
            await asyncio.sleep(3600)
            return "result://unreachable"

    spool_dir = tmp_path / "speechrail-job-spool"
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
                max_job_attempts=2,
                job_poll_seconds=0.01,
                qwen3_model_dir=None,
                qwen3_python=None,
            ),
            job_processor=BlockingProcessor(),
        )
    ) as client:
        deadline = time.monotonic() + 1
        while True:
            read = client.get(f"/v1/jobs/{job.id}").json()
            if read["state"] == "running" and read["attempts"] == 2:
                break
            if time.monotonic() >= deadline:
                raise AssertionError(
                    f"interrupted job was not requeued and re-claimed: {read}"
                )
            time.sleep(0.01)

    assert read["state"] == "running"
    assert read["attempts"] == 2


def test_settings_max_job_attempts_defaults_to_two_and_accepts_override() -> None:
    assert Settings(qwen3_model_dir=None, qwen3_python=None).max_job_attempts == 2
    assert (
        Settings(
            qwen3_model_dir=None, qwen3_python=None, max_job_attempts=5
        ).max_job_attempts
        == 5
    )


def test_configured_job_processor_executes_new_jobs_in_the_background(tmp_path) -> None:
    class FakeProcessor:
        async def process(self, job) -> str:
            assert job.request["input_ref"] == "external/input"
            return "result://speech/1"

    spool_dir = tmp_path / "speechrail-job-spool"
    with TestClient(
        create_app(
            Settings(
                job_spool_dir=spool_dir,
                job_poll_seconds=0.01,
                qwen3_model_dir=None,
                qwen3_python=None,
            ),
            job_processor=FakeProcessor(),
        )
    ) as client:
        created = client.post(
            "/v1/jobs",
            json={"kind": "speech", "input_ref": "external/input"},
        )
        job_id = created.json()["id"]
        deadline = time.monotonic() + 1
        while True:
            result = client.get(f"/v1/jobs/{job_id}").json()
            if result["state"] != "queued":
                break
            if time.monotonic() >= deadline:
                raise AssertionError("background job runner did not claim queued work")
            time.sleep(0.01)

    assert result["state"] == "completed"
    assert result["result_ref"] == "result://speech/1"


def test_jobs_api_health_exposes_job_spool_ready(tmp_path) -> None:
    spool_dir = tmp_path / "speechrail-job-spool"
    with TestClient(
        create_app(
            Settings(
                job_spool_dir=spool_dir,
                qwen3_model_dir=None,
                qwen3_python=None,
            )
        )
    ) as client:
        response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["job_spool_ready"] is True


def test_jobs_api_health_no_spool_returns_false(tmp_path) -> None:
    with TestClient(
        create_app(
            Settings(
                qwen3_model_dir=None,
                qwen3_python=None,
            )
        )
    ) as client:
        response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["job_spool_ready"] is False


def test_jobs_api_create_stores_and_returns_params(tmp_path) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=JobRepository(tmp_path / "speechrail-job-spool"),
        )
    )

    created = client.post(
        "/v1/jobs",
        json={
            "kind": "transcription",
            "input_ref": "external/meeting.wav",
            "params": {"language": "zh", "timestamps": True},
        },
    )
    job_id = created.json()["id"]

    assert created.status_code == 202
    assert created.json()["params"] == {"language": "zh", "timestamps": True}

    read = client.get(f"/v1/jobs/{job_id}")
    assert read.json()["params"] == {"language": "zh", "timestamps": True}


def test_jobs_api_create_rejects_non_object_params(tmp_path) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=JobRepository(tmp_path / "speechrail-job-spool"),
        )
    )

    response = client.post(
        "/v1/jobs",
        json={
            "kind": "speech",
            "input_ref": "external/input.wav",
            "params": ["not", "an", "object"],
        },
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_params"


def test_jobs_api_delete_running_job_returns_409(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech",
        owner="loopback",
        request={"input_ref": "external/input"},
    )
    assert repository.claim_next() is not None

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=repository,
        )
    )

    response = client.delete(f"/v1/jobs/{job.id}")

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "job_not_cancellable"


def test_jobs_api_delete_failed_job_returns_409(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech",
        owner="loopback",
        request={"input_ref": "external/input"},
    )
    assert repository.claim_next() is not None
    repository.fail(job.id, error_code="job_processor_failed")

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=repository,
        )
    )

    response = client.delete(f"/v1/jobs/{job.id}")

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "job_not_cancellable"


def test_jobs_api_get_result_completed_returns_200(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech",
        owner="loopback",
        request={"input_ref": "external/input"},
    )
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result://speech/1")

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=repository,
        )
    )

    response = client.get(f"/v1/jobs/{job.id}/result")

    assert response.status_code == 200
    assert response.json()["result_ref"] == "result://speech/1"


def test_jobs_api_get_result_non_completed_returns_409(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech",
        owner="loopback",
        request={"input_ref": "external/input"},
    )

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=repository,
        )
    )

    response = client.get(f"/v1/jobs/{job.id}/result")

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "job_not_ready"


def test_jobs_api_get_result_unknown_id_returns_404(tmp_path) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=JobRepository(tmp_path / "speechrail-job-spool"),
        )
    )

    response = client.get("/v1/jobs/job_00000000000000000000000000000000/result")

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "job_not_found"


def test_jobs_api_get_result_wrong_owner_returns_404(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech",
        owner="owner-a",
        request={"input_ref": "external/input"},
    )
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result://speech/1")

    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=repository,
        )
    )

    response = client.get(
        f"/v1/jobs/{job.id}/result",
        headers={"X-Request-ID": "owner-b"},
    )

    assert response.status_code == 404
    assert response.json()["error"]["code"] == "job_not_found"


def test_jobs_api_expire_completed_job_clears_result(tmp_path) -> None:
    spool_dir = tmp_path / "speechrail-job-spool"
    repository = JobRepository(spool_dir)
    job = repository.create(
        kind="speech",
        owner="loopback",
        request={"input_ref": "external/input"},
    )
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result://speech/1")

    # Manually backdate completed_at so expiry triggers immediately.
    with repository._connect() as connection:
        connection.execute(
            "UPDATE jobs SET completed_at = '2020-01-01T00:00:00+00:00' WHERE id = ?",
            (job.id,),
        )

    repository.expire_completed(before="2025-01-01T00:00:00+00:00")

    client = TestClient(
        create_app(
            Settings(
                job_spool_dir=spool_dir,
                qwen3_model_dir=None,
                qwen3_python=None,
            ),
            job_repository=repository,
        )
    )

    read = client.get(f"/v1/jobs/{job.id}")
    assert read.json()["state"] == "expired"
    assert read.json()["result_ref"] is None


def test_jobs_api_create_503_mentions_spool_dir(tmp_path) -> None:
    client = TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
        )
    )

    response = client.post(
        "/v1/jobs",
        json={"kind": "speech", "input_ref": "external/input"},
    )

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_not_ready"
    assert "SPEECHRAIL_JOB_SPOOL_DIR" in response.json()["error"]["message"]


# ---------------------------------------------------------------------------
# GET /v1/jobs — owner-scoped paginated listing
# ---------------------------------------------------------------------------

_JOB_KEYS = {"id", "kind", "state", "error_code", "result_ref", "params"}


def _set_updated_at(repository: JobRepository, job_id: str, value: str) -> None:
    with repository._connect() as connection:
        connection.execute(
            "UPDATE jobs SET updated_at = ? WHERE id = ?",
            (value, job_id),
        )


def _list_client(repository: JobRepository) -> TestClient:
    return TestClient(
        create_app(
            Settings(qwen3_model_dir=None, qwen3_python=None),
            job_repository=repository,
        )
    )


def test_jobs_api_list_paginates_owner_scoped_jobs_with_cursor(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    oldest = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/1"}
    )
    middle = repository.create(
        kind="transcription",
        owner="loopback",
        request={"input_ref": "external/2", "params": {"language": "en"}},
    )
    newest = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/3"}
    )
    _set_updated_at(repository, oldest.id, "2024-01-01T00:00:00+00:00")
    _set_updated_at(repository, middle.id, "2024-01-02T00:00:00+00:00")
    _set_updated_at(repository, newest.id, "2024-01-03T00:00:00+00:00")
    client = _list_client(repository)

    first = client.get("/v1/jobs", params={"limit": 2})

    assert first.status_code == 200
    first_page = first.json()
    assert first_page["object"] == "list"
    assert first_page["has_more"] is True
    assert isinstance(first_page["next_cursor"], str)
    assert first_page["next_cursor"]
    assert [job["id"] for job in first_page["data"]] == [newest.id, middle.id]
    assert set(first_page["data"][0]) == _JOB_KEYS
    assert first_page["data"][0]["kind"] == "speech"
    assert first_page["data"][1]["params"] == {"language": "en"}

    second = client.get(
        "/v1/jobs", params={"limit": 2, "cursor": first_page["next_cursor"]}
    )

    assert second.status_code == 200
    second_page = second.json()
    assert second_page["object"] == "list"
    assert second_page["has_more"] is False
    assert second_page["next_cursor"] is None
    assert [job["id"] for job in second_page["data"]] == [oldest.id]


def test_jobs_api_list_returns_empty_envelope_for_fresh_owner(tmp_path) -> None:
    client = _list_client(JobRepository(tmp_path / "speechrail-job-spool"))

    response = client.get("/v1/jobs")

    assert response.status_code == 200
    assert response.json() == {
        "object": "list",
        "data": [],
        "next_cursor": None,
        "has_more": False,
    }


def test_jobs_api_list_excludes_other_owner_jobs(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    foreign = repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "external/secret"}
    )
    mine = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/mine"}
    )
    client = _list_client(repository)

    response = client.get("/v1/jobs")

    assert response.status_code == 200
    listed_ids = [job["id"] for job in response.json()["data"]]
    assert listed_ids == [mine.id]
    assert foreign.id not in listed_ids


@pytest.mark.parametrize("limit", [0, 101])
def test_jobs_api_list_rejects_limit_out_of_range(tmp_path, limit: int) -> None:
    client = _list_client(JobRepository(tmp_path / "speechrail-job-spool"))

    response = client.get("/v1/jobs", params={"limit": limit})

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


def test_jobs_api_list_rejects_invalid_cursor(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/1"}
    )
    client = _list_client(repository)

    response = client.get("/v1/jobs", params={"cursor": "not-a-valid-cursor"})

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_cursor"


def test_jobs_api_list_503_when_spool_not_configured(tmp_path) -> None:
    client = TestClient(
        create_app(Settings(qwen3_model_dir=None, qwen3_python=None))
    )

    response = client.get("/v1/jobs")

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_not_ready"
    assert "SPEECHRAIL_JOB_SPOOL_DIR" in response.json()["error"]["message"]


# ---------------------------------------------------------------------------
# GET /v1/jobs/{job_id} — best-effort queue progress
# ---------------------------------------------------------------------------

_PROGRESS_KEYS = {"queue_position", "eta_seconds", "deadline"}


def test_jobs_api_single_read_queued_reports_position_and_bounded_eta(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    first = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/1"}
    )
    second = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/2"}
    )
    _set_updated_at(repository, first.id, "2024-01-01T00:00:00+00:00")
    _set_updated_at(repository, second.id, "2024-01-02T00:00:00+00:00")
    client = _list_client(repository)

    first_read = client.get(f"/v1/jobs/{first.id}").json()
    second_read = client.get(f"/v1/jobs/{second.id}").json()

    assert first_read["state"] == "queued"
    assert first_read["queue_position"] == 1
    assert second_read["state"] == "queued"
    assert second_read["queue_position"] == 2
    assert isinstance(second_read["eta_seconds"], (int, float))
    assert math.isfinite(second_read["eta_seconds"])
    assert second_read["eta_seconds"] >= 0
    assert first_read["deadline"] is None
    assert second_read["deadline"] is None
    assert set(first_read) >= _PROGRESS_KEYS


def test_jobs_api_single_read_running_reports_deadline_and_null_position(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )
    assert repository.claim_next() is not None
    client = _list_client(repository)

    read = client.get(f"/v1/jobs/{job.id}").json()

    assert read["state"] == "running"
    assert read["queue_position"] is None
    assert read["eta_seconds"] is None
    assert isinstance(read["deadline"], str)
    assert datetime.fromisoformat(read["deadline"]).tzinfo is not None


def test_jobs_api_single_read_completed_reports_all_progress_null(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result://speech/1")
    client = _list_client(repository)

    read = client.get(f"/v1/jobs/{job.id}").json()

    assert read["state"] == "completed"
    assert read["queue_position"] is None
    assert read["eta_seconds"] is None
    assert read["deadline"] is None


def test_jobs_api_single_read_unknown_and_wrong_owner_still_404(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    foreign = repository.create(
        kind="speech", owner="owner-a", request={"input_ref": "external/secret"}
    )
    client = _list_client(repository)

    unknown = client.get("/v1/jobs/job_00000000000000000000000000000000")
    wrong_owner = client.get(f"/v1/jobs/{foreign.id}")

    assert unknown.status_code == 404
    assert unknown.json()["error"]["code"] == "job_not_found"
    assert wrong_owner.status_code == 404
    assert wrong_owner.json()["error"]["code"] == "job_not_found"


def test_jobs_api_list_item_keys_stay_exactly_six(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )
    client = _list_client(repository)

    data = client.get("/v1/jobs").json()["data"]

    assert data
    assert set(data[0]) == _JOB_KEYS


def test_jobs_api_single_read_503_when_spool_not_configured(tmp_path) -> None:
    client = TestClient(
        create_app(Settings(qwen3_model_dir=None, qwen3_python=None))
    )

    response = client.get("/v1/jobs/job_00000000000000000000000000000000")

    assert response.status_code == 503
    assert response.json()["error"]["code"] == "backend_not_ready"
    assert "SPEECHRAIL_JOB_SPOOL_DIR" in response.json()["error"]["message"]


# ---------------------------------------------------------------------------
# GET /v1/jobs/{job_id} — sanitized failure detail (error_message)
# ---------------------------------------------------------------------------


def test_jobs_api_single_read_completed_reports_null_error_message(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )
    assert repository.claim_next() is not None
    repository.complete(job.id, result_ref="result://speech/1")
    client = _list_client(repository)

    read = client.get(f"/v1/jobs/{job.id}").json()

    assert read["state"] == "completed"
    assert read["error_message"] is None


def test_jobs_api_single_read_failed_reports_bounded_error_message(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )
    assert repository.claim_next() is not None
    repository.fail(
        job.id,
        error_code="job_input_invalid",
        error_message="failed reading <path>",
    )
    client = _list_client(repository)

    read = client.get(f"/v1/jobs/{job.id}").json()

    assert read["state"] == "failed"
    assert read["error_message"] == "failed reading <path>"
    assert len(read["error_message"]) <= 256
    assert "/Users" not in read["error_message"]


def test_jobs_api_list_never_exposes_error_message(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )
    assert repository.claim_next() is not None
    repository.fail(
        job.id,
        error_code="job_input_invalid",
        error_message="failed reading <path>",
    )
    client = _list_client(repository)

    data = client.get("/v1/jobs").json()["data"]

    assert data
    assert set(data[0]) == _JOB_KEYS
    assert "error_message" not in data[0]
    assert data[0]["error_code"] == "job_input_invalid"


# ---------------------------------------------------------------------------
# attempts — single-read only, bounded restart retries
# ---------------------------------------------------------------------------


def test_jobs_api_single_read_exposes_attempts_after_claim(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )
    assert repository.claim_next() is not None
    client = _list_client(repository)

    read = client.get(f"/v1/jobs/{job.id}").json()

    assert read["state"] == "running"
    assert read["attempts"] == 1


def test_jobs_api_list_item_never_exposes_attempts(tmp_path) -> None:
    repository = JobRepository(tmp_path / "speechrail-job-spool")
    job = repository.create(
        kind="speech", owner="loopback", request={"input_ref": "external/input"}
    )
    assert repository.claim_next() is not None
    client = _list_client(repository)

    data = client.get("/v1/jobs").json()["data"]

    assert data
    assert data[0]["id"] == job.id
    assert set(data[0]) == _JOB_KEYS
    assert "attempts" not in data[0]
