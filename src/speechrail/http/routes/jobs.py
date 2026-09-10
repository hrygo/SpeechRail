"""Durable job lifecycle routes; owner-scoped metadata spool access."""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Query, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel, Field

from speechrail.application.services import AppServices
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error_response
from speechrail.runtime.jobs import JobRecord, JobRepository
from speechrail.runtime.local_file_processor import resolve_result_artifact

_JOB_SPOOL_HINT = "SpeechRail job spool is not ready; configure SPEECHRAIL_JOB_SPOOL_DIR"
_JOB_NOT_FOUND_MESSAGE = "Unknown job; jobs are owner-scoped and may have expired"


class _JobHTTPBody(BaseModel):
    kind: Literal["speech", "transcription"]
    input_ref: str = Field(min_length=1, max_length=1_000)
    params: Any = None


def _job_owner(api_key: str | None) -> str:
    if api_key is None:
        return "loopback"
    return hashlib.sha256(api_key.encode()).hexdigest()


def _job_response(job: JobRecord) -> dict[str, object]:
    return {
        "id": job.id,
        "kind": job.kind,
        "state": job.state,
        "error_code": job.error_code,
        "result_ref": job.result_ref,
        "params": job.request.get("params"),
    }


def _running_deadline(
    repository: JobRepository, job_id: str, *, owner: str, timeout_seconds: float
) -> str | None:
    updated_at = repository.timing(job_id, owner=owner)
    if updated_at is None:
        return None
    try:
        started = datetime.fromisoformat(updated_at)
    except ValueError:
        return None
    if started.tzinfo is None:
        started = started.replace(tzinfo=UTC)
    return (started + timedelta(seconds=timeout_seconds)).astimezone(UTC).isoformat()


def _single_job_response(
    job: JobRecord,
    *,
    repository: JobRepository,
    owner: str,
    estimate_seconds: float,
    timeout_seconds: float,
) -> dict[str, object]:
    content = _job_response(job)
    content["error_message"] = job.error_message
    content["attempts"] = job.attempts
    if job.state == "queued":
        position = repository.queue_position(job.id, owner=owner)
        content["queue_position"] = position
        content["eta_seconds"] = (
            position * estimate_seconds if position is not None else None
        )
        content["deadline"] = None
    elif job.state == "running":
        content["queue_position"] = None
        content["eta_seconds"] = None
        content["deadline"] = _running_deadline(
            repository, job.id, owner=owner, timeout_seconds=timeout_seconds
        )
    else:
        content["queue_position"] = None
        content["eta_seconds"] = None
        content["deadline"] = None
    return content


def create_jobs_router(services: AppServices) -> APIRouter:
    """Owner-scoped durable job endpoints; runner lifecycle stays in lifecycle."""
    router = APIRouter()
    resolved = services.settings
    job_repository = services.job_repository

    def job_owner(request: Request) -> str:
        del request
        return _job_owner(resolved.api_key)

    @router.post("/v1/jobs", status_code=202)
    async def create_job(request: Request, body: _JobHTTPBody) -> Response:
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if body.params is not None and not isinstance(body.params, dict):
            return error_response(
                400,
                request.state.request_id,
                "invalid_params",
                "params must be a JSON object",
            )
        if job_repository is None:
            return error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                _JOB_SPOOL_HINT,
                retryable=True,
            )
        job_request: dict[str, Any] = {"input_ref": body.input_ref}
        if body.params is not None:
            job_request["params"] = body.params
        job = job_repository.create(
            kind=body.kind, owner=job_owner(request), request=job_request
        )
        return JSONResponse(status_code=202, content=_job_response(job))

    @router.get("/v1/jobs")
    async def list_jobs(
        request: Request,
        limit: Annotated[int, Query(ge=1, le=100)] = 20,
        cursor: Annotated[str | None, Query()] = None,
    ) -> Response:
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if job_repository is None:
            return error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                _JOB_SPOOL_HINT,
                retryable=True,
            )
        try:
            jobs, next_cursor = job_repository.list_page(
                owner=job_owner(request), limit=limit, cursor=cursor
            )
        except ValueError:
            return error_response(
                400,
                request.state.request_id,
                "invalid_cursor",
                "cursor is not a valid pagination cursor",
            )
        return JSONResponse(
            {
                "object": "list",
                "data": [_job_response(job) for job in jobs],
                "next_cursor": next_cursor,
                "has_more": next_cursor is not None,
            }
        )

    @router.get("/v1/jobs/{job_id}")
    async def get_job(request: Request, job_id: str) -> Response:
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if job_repository is None:
            return error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                _JOB_SPOOL_HINT,
                retryable=True,
            )
        job = job_repository.get(job_id, owner=job_owner(request))
        if job is None:
            return error_response(
                404, request.state.request_id, "job_not_found", _JOB_NOT_FOUND_MESSAGE
            )
        return JSONResponse(
            _single_job_response(
                job,
                repository=job_repository,
                owner=job_owner(request),
                estimate_seconds=resolved.job_estimate_seconds,
                timeout_seconds=resolved.request_timeout_seconds,
            )
        )

    @router.delete("/v1/jobs/{job_id}")
    async def delete_job(request: Request, job_id: str) -> Response:
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if job_repository is None:
            return error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                _JOB_SPOOL_HINT,
                retryable=True,
            )
        job = job_repository.cancel(job_id, owner=job_owner(request))
        if job is None:
            return error_response(
                404, request.state.request_id, "job_not_found", _JOB_NOT_FOUND_MESSAGE
            )
        if job.state in {"running", "failed", "expired"}:
            return error_response(
                409,
                request.state.request_id,
                "job_not_cancellable",
                "Job is not in a cancellable state",
            )
        return JSONResponse(_job_response(job))

    @router.get("/v1/jobs/{job_id}/result")
    async def get_job_result(request: Request, job_id: str) -> Response:
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if job_repository is None:
            return error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                _JOB_SPOOL_HINT,
                retryable=True,
            )
        job = job_repository.get(job_id, owner=job_owner(request))
        if job is None:
            return error_response(
                404, request.state.request_id, "job_not_found", _JOB_NOT_FOUND_MESSAGE
            )
        if job.state != "completed":
            return error_response(
                409,
                request.state.request_id,
                "job_not_ready",
                "Job result is not ready",
            )
        if job_repository is not None and job.result_ref is not None:
            artifact = resolve_result_artifact(
                spool_dir=job_repository.spool_dir,
                job_id=job_id,
                result_ref=job.result_ref,
            )
            if artifact is not None:
                path, media_type = artifact
                return FileResponse(path, media_type=media_type, filename=path.name)
        return JSONResponse({"result_ref": job.result_ref})

    return router
