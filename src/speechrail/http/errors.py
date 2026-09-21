"""Unified HTTP error envelope, request-ID middleware and validation handler."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response


def error(
    *,
    message: str,
    error_type: str,
    code: str,
    request_id: str,
    retryable: bool,
    param: str | None = None,
    diagnostic_class: str | None = None,
) -> dict[str, Any]:
    value: dict[str, Any] = {
        "message": message,
        "type": error_type,
        "code": code,
        "request_id": request_id,
        "retryable": retryable,
    }
    if param is not None:
        value["param"] = param
    if diagnostic_class is not None:
        value["diagnostic_class"] = diagnostic_class
    return {"error": value}


def error_response(
    status: int,
    request_id: str,
    code: str,
    message: str,
    *,
    retryable: bool = False,
    param: str | None = None,
    diagnostic_class: str | None = None,
) -> JSONResponse:
    error_type = "server_error" if retryable else "invalid_request_error"
    return JSONResponse(
        status_code=status,
        content=error(
            message=message,
            error_type=error_type,
            code=code,
            request_id=request_id,
            retryable=retryable,
            param=param,
            diagnostic_class=diagnostic_class,
        ),
        headers={"X-SpeechRail-Error-Code": code},
    )


def _single_validation_param(exc: RequestValidationError) -> str | None:
    """Return one safe top-level field name without exposing submitted values."""

    fields: set[str] = set()
    for issue in exc.errors():
        location = issue.get("loc")
        if not isinstance(location, (tuple, list)) or len(location) < 2:
            continue
        if location[0] not in {"body", "path", "query", "header", "cookie"}:
            continue
        field = location[1]
        if isinstance(field, str) and field:
            fields.add(field)
    return next(iter(fields)) if len(fields) == 1 else None


class RequestIdMiddleware(BaseHTTPMiddleware):
    async def dispatch(
        self, request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        request_id = request.headers.get("X-Request-ID") or f"req_{uuid4().hex}"
        request.state.request_id = request_id
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        response.headers["Cache-Control"] = "no-store"
        return response


def install_error_handlers(app: FastAPI) -> None:
    """Register the shared validation exception handler on the app."""

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        return error_response(
            422,
            getattr(request.state, "request_id", f"req_{uuid4().hex}"),
            "validation_error",
            "Request validation failed",
            param=_single_validation_param(exc),
        )
