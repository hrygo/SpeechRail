"""Contract-first FastAPI application for SpeechRail.

The current release exposes the public surface and safe failure semantics.
Inference adapters are deliberately not bundled into this foundation commit;
the implementation plan describes the Qwen3-ASR and WhisperLiveKit ports.
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, File, Form, Request, UploadFile, WebSocket
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response

from speechrail import __version__
from speechrail.config import Settings


def _error(
    *,
    message: str,
    error_type: str,
    code: str,
    request_id: str,
    retryable: bool,
    param: str | None = None,
) -> dict[str, Any]:
    """Build the single OpenAI-compatible error envelope."""

    payload: dict[str, Any] = {
        "message": message,
        "type": error_type,
        "code": code,
        "request_id": request_id,
        "retryable": retryable,
    }
    if param is not None:
        payload["param"] = param
    return {"error": payload}


class RequestIdMiddleware(BaseHTTPMiddleware):
    """Attach a request ID without logging request bodies or credentials."""

    async def dispatch(
        self,
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        request_id = request.headers.get("X-Request-ID") or f"req_{uuid4().hex}"
        request.state.request_id = request_id
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        response.headers["Cache-Control"] = "no-store"
        return response


def _authorized(request: Request, settings: Settings) -> bool:
    """Validate an optional Bearer key; loopback defaults remain keyless."""

    if settings.api_key is None:
        return True
    authorization = request.headers.get("Authorization", "")
    return authorization == f"Bearer {settings.api_key}"


def _model_known(model: str, settings: Settings) -> bool:
    """Accept the canonical model and explicit compatibility aliases."""

    requested = model.strip()
    return not requested or requested in {settings.model_id, *settings.compatibility_model_ids}


def create_app(settings: Settings | None = None) -> FastAPI:
    """Create an isolated SpeechRail ASGI application."""

    resolved = settings or Settings()
    app = FastAPI(
        title="SpeechRail API",
        version=resolved.version,
        description=(
            "Local-first shared speech recognition API. The foundation release "
            "publishes the stable contract before inference adapters are enabled."
        ),
    )
    app.state.settings = resolved
    app.add_middleware(RequestIdMiddleware)

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request,
        exc: RequestValidationError,
    ) -> JSONResponse:
        del exc
        request_id = getattr(request.state, "request_id", f"req_{uuid4().hex}")
        return JSONResponse(
            status_code=422,
            content=_error(
                message="Request validation failed",
                error_type="invalid_request_error",
                code="validation_error",
                request_id=request_id,
                retryable=False,
            ),
        )

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "service": resolved.service_name,
            "version": resolved.version,
            "backend": "qwen3-asr-1.7b",
            "ready": resolved.backend_ready,
        }

    @app.get("/readyz")
    async def readyz(request: Request) -> JSONResponse:
        request_id = getattr(request.state, "request_id", f"req_{uuid4().hex}")
        if resolved.backend_ready:
            return JSONResponse(status_code=200, content={"ready": True})
        return JSONResponse(
            status_code=503,
            content=_error(
                message="SpeechRail inference backend is not ready",
                error_type="server_error",
                code="backend_not_ready",
                request_id=request_id,
                retryable=True,
            ),
        )

    @app.get("/v1/models")
    async def list_models() -> dict[str, Any]:
        ids = [resolved.model_id, *resolved.compatibility_model_ids]
        return {
            "object": "list",
            "data": [
                {
                    "id": model_id,
                    "object": "model",
                    "owned_by": "speechrail",
                }
                for model_id in ids
            ],
        }

    @app.post("/v1/audio/transcriptions")
    async def create_transcription(
        request: Request,
        file: UploadFile = File(...),  # noqa: B008 - FastAPI requires a parameter marker here.
        model: str = Form(default=""),
        language: str | None = Form(default=None),
        prompt: str = Form(default=""),
        response_format: str = Form(default="json"),
    ) -> JSONResponse:
        del file, language, prompt, response_format
        request_id = getattr(request.state, "request_id", f"req_{uuid4().hex}")
        if not _authorized(request, resolved):
            return JSONResponse(
                status_code=401,
                content=_error(
                    message="Invalid or missing API key",
                    error_type="authentication_error",
                    code="invalid_api_key",
                    request_id=request_id,
                    retryable=False,
                ),
                headers={"WWW-Authenticate": "Bearer"},
            )
        if not _model_known(model, resolved):
            return JSONResponse(
                status_code=400,
                content=_error(
                    message=f"Unknown model: {model}",
                    error_type="invalid_request_error",
                    code="model_not_found",
                    request_id=request_id,
                    retryable=False,
                    param="model",
                ),
            )
        return JSONResponse(
            status_code=503,
            content=_error(
                message="SpeechRail inference backend is not ready",
                error_type="server_error",
                code="backend_not_ready",
                request_id=request_id,
                retryable=True,
            ),
        )

    @app.websocket("/v1/realtime")
    async def realtime(websocket: WebSocket) -> None:
        await websocket.close(code=1013, reason="SpeechRail backend is not ready")

    @app.websocket("/asr")
    async def legacy_asr(websocket: WebSocket) -> None:
        await websocket.close(code=1013, reason="SpeechRail backend is not ready")

    return app


app = create_app()

__all__ = ["__version__", "app", "create_app"]
