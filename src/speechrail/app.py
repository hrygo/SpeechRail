"""SpeechRail composition root: overrides → services → FastAPI app."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from datetime import UTC, datetime

from fastapi import FastAPI

from speechrail import __version__
from speechrail.application.services import (
    AppOverrides,
    Transcribe,
    build_app_services,
)
from speechrail.config import Settings
from speechrail.domain.ports import (
    BatchTranscriber,
    DiarizationEngine,
    RealtimeAsrFactory,
    SpeechSynthesizer,
)
from speechrail.http.errors import RequestIdMiddleware, install_error_handlers
from speechrail.http.routes.audio import create_audio_router
from speechrail.http.routes.jobs import create_jobs_router
from speechrail.http.routes.realtime_openai import create_openai_realtime_router
from speechrail.http.routes.system import create_system_router
from speechrail.observability.logging import access
from speechrail.runtime.job_runner import JobProcessor
from speechrail.runtime.jobs import JobRepository

logger = logging.getLogger(__name__)


def create_app(
    settings: Settings | None = None,
    *,
    transcribe: Transcribe | None = None,
    batch_transcriber: BatchTranscriber | None = None,
    realtime_asr_factory: RealtimeAsrFactory | None = None,
    diarization_engine: DiarizationEngine | None = None,
    tts_synthesizer: SpeechSynthesizer | None = None,
    job_repository: JobRepository | None = None,
    job_processor: JobProcessor | None = None,
) -> FastAPI:
    """Compose the FastAPI app from settings, explicit overrides and routers."""
    resolved_settings = settings or Settings()
    overrides = AppOverrides(
        transcribe=transcribe,
        batch_transcriber=batch_transcriber,
        realtime_asr_factory=realtime_asr_factory,
        diarization_engine=diarization_engine,
        tts_synthesizer=tts_synthesizer,
        job_repository=job_repository,
        job_processor=job_processor,
    )
    services = build_app_services(resolved_settings, overrides)
    resolved = services.settings

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        try:
            await services.lifecycle.start()
        except BaseException:
            logger.exception(
                "SpeechRail startup failed while starting local worker backends; "
                "the exception chain carries the worker error code and stderr tail"
            )
            raise
        try:
            yield
        finally:
            await services.lifecycle.close()

    app = FastAPI(title="SpeechRail API", version=resolved.version, lifespan=lifespan)
    app.state.settings = resolved
    app.add_middleware(RequestIdMiddleware)

    # Lightweight HTTP metrics middleware.  A pure ASGI wrapper measures from
    # request start to the final response-body send, so a StreamingResponse is
    # timed to its last byte instead of the instant it was handed off.
    import time as _time
    from collections.abc import MutableMapping
    from typing import Any

    from starlette.types import ASGIApp, Receive, Scope, Send

    class _MetricsMiddleware:
        def __init__(self, app: ASGIApp) -> None:
            self._app = app

        async def __call__(
            self, scope: Scope, receive: Receive, send: Send
        ) -> None:
            if scope["type"] != "http":
                await self._app(scope, receive, send)
                return
            start = _time.monotonic()
            status = 0
            endpoint = "<unmatched>"
            outcome = "completed"
            error_code: str | None = None
            final_body_sent = False

            state = scope.get("state")
            request_id = state.get("request_id") if isinstance(state, dict) else None
            if not isinstance(request_id, str) or not request_id:
                request_id = None
                for name, value in scope.get("headers", []):
                    if name.lower() == b"x-request-id" and isinstance(value, bytes):
                        request_id = value.decode("utf-8", errors="ignore")[:128]
                        break
                request_id = request_id or "req_unknown"

            async def send_wrapper(message: MutableMapping[str, Any]) -> None:
                nonlocal status, endpoint, error_code, final_body_sent, outcome, request_id
                if message.get("type") == "http.response.start":
                    status_raw = message.get("status", 0)
                    status = status_raw if isinstance(status_raw, int) else 0
                    route = scope.get("route")
                    route_path = getattr(route, "path", None)
                    if isinstance(route_path, str) and route_path:
                        endpoint = route_path
                    raw_headers = message.get("headers", [])
                    if isinstance(raw_headers, list):
                        headers: list[Any] = []
                        for header in raw_headers:
                            if not isinstance(header, (tuple, list)) or len(header) != 2:
                                headers.append(header)
                                continue
                            name, value = header
                            normalized_name = name.lower() if isinstance(name, bytes) else name
                            if normalized_name == b"x-speechrail-error-code":
                                if isinstance(value, bytes):
                                    error_code = value.decode("ascii", errors="ignore")[:128]
                                elif isinstance(value, str):
                                    error_code = value[:128]
                                continue
                            if normalized_name == b"x-request-id" and isinstance(value, bytes):
                                request_id = value.decode("utf-8", errors="ignore")[:128]
                            headers.append(header)
                        message["headers"] = headers
                elif message.get("type") == "http.response.body":
                    final_body_sent = not bool(message.get("more_body", False))
                await send(message)

            try:
                await self._app(scope, receive, send_wrapper)
            except asyncio.CancelledError:
                outcome = "cancelled"
                raise
            except BaseException as exc:
                outcome = (
                    "disconnected"
                    if isinstance(exc, (ConnectionError, BrokenPipeError))
                    or "disconnect" in type(exc).__name__.lower()
                    else "error"
                )
                raise
            finally:
                if outcome == "completed" and status and not final_body_sent:
                    outcome = "error"
                duration_sec = _time.monotonic() - start
                services.metrics.record_http_request(
                    endpoint=endpoint,
                    method=scope["method"],
                    status=status,
                    duration_sec=duration_sec,
                )
                access(
                    logger,
                    timestamp=datetime.now(UTC).isoformat(),
                    request_id=request_id,
                    route=endpoint,
                    status=status if status else None,
                    outcome=outcome,
                    duration_ms=duration_sec * 1000.0,
                    error_code=error_code,
                    tts_warm=services.tts_warm,
                    worker_state=services.subsystem_states.get("tts"),
                )

    app.add_middleware(_MetricsMiddleware)

    install_error_handlers(app)
    app.include_router(create_system_router(services))
    app.include_router(create_audio_router(services))
    app.include_router(create_jobs_router(services))
    app.include_router(create_openai_realtime_router(services))
    return app


app = create_app()

__all__ = ["__version__", "app", "create_app"]
