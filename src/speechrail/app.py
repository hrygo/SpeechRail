"""SpeechRail composition root: overrides → services → FastAPI app."""

from __future__ import annotations

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
from speechrail.http.routes.realtime_v2 import create_realtime_v2_router
from speechrail.http.routes.system import create_system_router
from speechrail.runtime.job_runner import JobProcessor
from speechrail.runtime.jobs import JobRepository


def create_app(
    settings: Settings | None = None,
    *,
    transcribe: Transcribe | None = None,
    v2_transcriber: BatchTranscriber | None = None,
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
        v2_transcriber=v2_transcriber,
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
        await services.lifecycle.start()
        try:
            yield
        finally:
            await services.lifecycle.close()

    app = FastAPI(title="SpeechRail API", version=resolved.version, lifespan=lifespan)
    app.state.settings = resolved
    app.add_middleware(RequestIdMiddleware)
    install_error_handlers(app)
    app.include_router(create_system_router(services))
    app.include_router(create_audio_router(services))
    app.include_router(create_jobs_router(services))
    app.include_router(create_realtime_v2_router(services))
    app.include_router(create_openai_realtime_router(services))
    return app


app = create_app()

__all__ = ["__version__", "app", "create_app"]
