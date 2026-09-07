"""SpeechRail composition root: overrides → services → FastAPI app."""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

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

            async def send_wrapper(message: MutableMapping[str, Any]) -> None:
                nonlocal status, endpoint
                if message.get("type") == "http.response.start":
                    status_raw = message.get("status", 0)
                    status = status_raw if isinstance(status_raw, int) else 0
                    route = scope.get("route")
                    route_path = getattr(route, "path", None)
                    if isinstance(route_path, str) and route_path:
                        endpoint = route_path
                await send(message)

            await self._app(scope, receive, send_wrapper)
            services.metrics.record_http_request(
                endpoint=endpoint,
                method=scope["method"],
                status=status,
                duration_sec=_time.monotonic() - start,
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
