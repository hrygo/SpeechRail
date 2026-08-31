"""Contract-first FastAPI application with bounded ASR execution edges."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, File, Form, Request, UploadFile, WebSocket
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, PlainTextResponse
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response

from speechrail import __version__
from speechrail.compatibility.presenters import legacy_config, legacy_ready_to_stop
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult
from speechrail.http.formatters import format_json, format_srt, format_verbose, format_vtt
from speechrail.realtime.events import RealtimeSession, SessionError
from speechrail.runtime.admission import AdmissionQueue, QueueFullError

Transcribe = Callable[[bytes, str | None, str], Awaitable[TranscriptResult]]


def _error(
    *,
    message: str,
    error_type: str,
    code: str,
    request_id: str,
    retryable: bool,
    param: str | None = None,
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
    return {"error": value}


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


def _error_response(
    status: int,
    request_id: str,
    code: str,
    message: str,
    *,
    retryable: bool = False,
    param: str | None = None,
) -> JSONResponse:
    error_type = "server_error" if retryable else "invalid_request_error"
    return JSONResponse(
        status_code=status,
        content=_error(
            message=message,
            error_type=error_type,
            code=code,
            request_id=request_id,
            retryable=retryable,
            param=param,
        ),
    )


async def _read_upload(file: UploadFile, limit: int) -> bytes:
    if not (file.content_type or "").startswith("audio/"):
        raise ValueError("unsupported_audio_type")
    content = bytearray()
    while chunk := await file.read(64 * 1024):
        content.extend(chunk)
        if len(content) > limit:
            raise OverflowError
    if not content:
        raise ValueError("empty_audio")
    return bytes(content)


def create_app(
    settings: Settings | None = None, *, transcribe: Transcribe | None = None
) -> FastAPI:
    resolved = settings or Settings()
    admission = AdmissionQueue(resolved.max_queue_size)
    app = FastAPI(title="SpeechRail API", version=resolved.version)
    app.state.settings = resolved
    app.add_middleware(RequestIdMiddleware)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        del exc
        return _error_response(
            422,
            getattr(request.state, "request_id", f"req_{uuid4().hex}"),
            "validation_error",
            "Request validation failed",
        )

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "service": resolved.service_name,
            "version": resolved.version,
            "backend": "qwen3-asr-1.7b",
            "ready": transcribe is not None or resolved.backend_ready,
        }

    @app.get("/readyz")
    async def readyz(request: Request) -> JSONResponse:
        if transcribe is not None or resolved.backend_ready:
            return JSONResponse(status_code=200, content={"ready": True})
        return _error_response(
            503,
            request.state.request_id,
            "backend_not_ready",
            "SpeechRail inference backend is not ready",
            retryable=True,
        )

    @app.get("/v1/models")
    async def models() -> dict[str, Any]:
        return {
            "object": "list",
            "data": [
                {"id": item, "object": "model", "owned_by": "speechrail"}
                for item in (resolved.model_id, *resolved.compatibility_model_ids)
            ],
        }

    @app.post("/v1/audio/transcriptions")
    async def transcription(
        request: Request,
        file: UploadFile = File(...),  # noqa: B008 - FastAPI parameter marker.
        model: str = Form(default=""),
        language: str | None = Form(default=None),
        prompt: str = Form(default=""),
        response_format: str = Form(default="json"),
    ) -> Response:
        request_id = request.state.request_id
        if (
            resolved.api_key is not None
            and request.headers.get("Authorization", "") != f"Bearer {resolved.api_key}"
        ):
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
        if model.strip() and model.strip() not in {
            resolved.model_id,
            *resolved.compatibility_model_ids,
        }:
            return _error_response(
                400, request_id, "model_not_found", f"Unknown model: {model}", param="model"
            )
        if response_format not in {"json", "verbose_json", "text", "srt", "vtt"}:
            return _error_response(
                422,
                request_id,
                "invalid_response_format",
                "Unsupported response format",
                param="response_format",
            )
        if len(prompt) > 2000:
            return _error_response(
                422, request_id, "prompt_too_long", "Prompt is too long", param="prompt"
            )
        try:
            audio = await _read_upload(file, resolved.max_upload_bytes)
        except OverflowError:
            return _error_response(413, request_id, "audio_too_large", "Audio exceeds upload limit")
        except ValueError as exc:
            return _error_response(
                422, request_id, str(exc), "Unsupported audio upload", param="file"
            )
        if transcribe is None:
            return _error_response(
                503,
                request_id,
                "backend_not_ready",
                "SpeechRail inference backend is not ready",
                retryable=True,
            )
        try:
            result = await admission.run(
                lambda: transcribe(audio, language, prompt),
                deadline=resolved.request_timeout_seconds,
            )
        except QueueFullError:
            return JSONResponse(
                status_code=429,
                content=_error(
                    message="Inference queue is full",
                    error_type="server_error",
                    code="queue_full",
                    request_id=request_id,
                    retryable=True,
                ),
                headers={"Retry-After": "1"},
            )
        except TimeoutError:
            return _error_response(
                503, request_id, "backend_timeout", "Inference timed out", retryable=True
            )
        if response_format == "json":
            return JSONResponse(format_json(result))
        if response_format == "verbose_json":
            return JSONResponse(format_verbose(result))
        if response_format == "text":
            return PlainTextResponse(result.text)
        if response_format == "srt":
            return PlainTextResponse(format_srt(result), media_type="application/x-subrip")
        return PlainTextResponse(format_vtt(result), media_type="text/vtt")

    @app.websocket("/v1/realtime")
    async def realtime(websocket: WebSocket) -> None:
        if transcribe is None:
            await websocket.close(code=1013, reason="SpeechRail backend is not ready")
            return
        if (
            resolved.api_key is not None
            and websocket.headers.get("Authorization", "") != f"Bearer {resolved.api_key}"
        ):
            await websocket.close(code=1008, reason="Invalid API key")
            return
        await websocket.accept()
        session = RealtimeSession(
            session_id=f"sess_{uuid4().hex}",
            max_frame_bytes=resolved.max_realtime_frame_bytes,
            max_buffer_bytes=resolved.max_realtime_buffer_bytes,
        )
        try:
            while True:
                event = await websocket.receive_json()
                event_type = event.get("type") if isinstance(event, dict) else None
                if event_type == "transcription_session.update":
                    await websocket.send_json(session.update(event.get("session")))
                elif event_type == "input_audio_buffer.append":
                    session.append(event.get("audio"))
                elif event_type == "input_audio_buffer.commit":
                    audio = session.commit()

                    async def operation(
                        audio: bytes = audio,
                        language: str | None = session.language,
                        prompt: str = session.prompt,
                    ) -> TranscriptResult:
                        return await transcribe(audio, language, prompt)

                    result = await admission.run(
                        operation,
                        deadline=resolved.request_timeout_seconds,
                    )
                    await websocket.send_json(session.completed(result))
                    return
                else:
                    raise SessionError("invalid_event")
        except SessionError as exc:
            await websocket.send_json(
                {
                    "type": "error",
                    "error": _error(
                        message="Invalid realtime event",
                        error_type="invalid_request_error",
                        code=exc.code,
                        request_id=f"req_{uuid4().hex}",
                        retryable=False,
                    )["error"],
                }
            )
            await websocket.close(code=1008)
        finally:
            session.close()

    @app.websocket("/asr")
    async def legacy_asr(websocket: WebSocket) -> None:
        if not resolved.legacy_wlk_enabled:
            await websocket.close(code=1008, reason="Legacy endpoint disabled")
            return
        await websocket.accept()
        await websocket.send_json(legacy_config())
        try:
            while True:
                chunk = await websocket.receive_bytes()
                if not chunk:
                    await websocket.send_json(legacy_ready_to_stop())
                    return
        finally:
            await websocket.close()

    return app


app = create_app()

__all__ = ["__version__", "app", "create_app"]
