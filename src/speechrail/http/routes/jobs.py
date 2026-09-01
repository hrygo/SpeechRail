"""Durable job lifecycle routes; owner-scoped metadata spool access."""

from __future__ import annotations

import hashlib
from typing import Literal

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from speechrail.application.services import AppServices
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error_response
from speechrail.runtime.jobs import JobRecord


class _JobHTTPBody(BaseModel):
    kind: Literal["speech", "transcription"]
    input_ref: str = Field(min_length=1, max_length=1_000)


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
    }


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
        if job_repository is None:
            return error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                "SpeechRail job spool is not ready",
                retryable=True,
            )
        job = job_repository.create(
            kind=body.kind, owner=job_owner(request), request={"input_ref": body.input_ref}
        )
        return JSONResponse(status_code=202, content=_job_response(job))

    @router.get("/v1/jobs/{job_id}")
    async def get_job(request: Request, job_id: str) -> Response:
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if job_repository is None:
            return error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                "SpeechRail job spool is not ready",
                retryable=True,
            )
        job = job_repository.get(job_id, owner=job_owner(request))
        if job is None:
            return error_response(404, request.state.request_id, "job_not_found", "Unknown job")
        return JSONResponse(_job_response(job))

    @router.delete("/v1/jobs/{job_id}")
    async def delete_job(request: Request, job_id: str) -> Response:
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if job_repository is None:
            return error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                "SpeechRail job spool is not ready",
                retryable=True,
            )
        job = job_repository.cancel(job_id, owner=job_owner(request))
        if job is None:
            return error_response(404, request.state.request_id, "job_not_found", "Unknown job")
        return JSONResponse(_job_response(job))

    return router
