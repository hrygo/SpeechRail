"""Contract-first FastAPI application with bounded ASR execution edges."""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import math
from collections.abc import AsyncIterator
from typing import Any, Literal
from uuid import uuid4

from fastapi import FastAPI, Request, WebSocket
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.responses import Response
from starlette.websockets import WebSocketDisconnect

from speechrail import __version__
from speechrail.application.services import (
    AppOverrides,
    Transcribe,
    build_app_services,
)
from speechrail.compatibility.presenters import legacy_config, legacy_ready_to_stop
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.ports import (
    BatchTranscriber,
    DiarizationEngine,
    RealtimeAsrFactory,
    RealtimeAsrSession,
    SpeechRequest,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.domain.realtime_v2 import RealtimeV2Error
from speechrail.http.errors import (
    RequestIdMiddleware,
    install_error_handlers,
)
from speechrail.http.errors import error as _error
from speechrail.http.errors import error_response as _error_response
from speechrail.http.routes.audio import create_audio_router
from speechrail.http.routes.system import create_system_router
from speechrail.realtime.events import RealtimeSession, SessionError
from speechrail.realtime.outbound import BoundedOutboundEventPump, SlowConsumerError
from speechrail.realtime.v2_session import SpeechSession, TranscriptionSession
from speechrail.runtime.diarization import DiarizationCoordinator
from speechrail.runtime.job_runner import JobProcessor
from speechrail.runtime.jobs import JobRecord, JobRepository
from speechrail.runtime.resource_governor import GovernorQueueFullError, WorkClass


def _speech_speed(event: dict[str, Any]) -> float:
    """Validate the optional realtime speed field at the protocol boundary."""
    value = event.get("speed", 1.0)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RealtimeV2Error("invalid speech speed", code="invalid_speed")
    speed = float(value)
    if not math.isfinite(speed) or not 0.25 <= speed <= 4.0:
        raise RealtimeV2Error("invalid speech speed", code="invalid_speed")
    return speed


class _JobHTTPBody(BaseModel):
    kind: Literal["speech", "transcription"]
    input_ref: str = Field(min_length=1, max_length=1_000)


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
    transcribe = services.transcribe
    tts_synthesizer = services.tts_synthesizer
    job_repository = services.job_repository
    admission = services.admission
    governor = services.governor
    resolved_v2_transcriber = services.v2_transcriber
    realtime_asr_factory = services.realtime_asr_factory
    diarization_engine = services.diarization_engine

    @contextlib.asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        await services.lifecycle.start()
        try:
            yield
        finally:
            await services.lifecycle.close()

    app = FastAPI(title="SpeechRail API", version=resolved.version, lifespan=lifespan)
    app.state.settings = resolved
    app.add_middleware(RequestIdMiddleware)

    def job_owner(request: Request) -> str:
        if resolved.api_key is None:
            return "loopback"
        return hashlib.sha256(resolved.api_key.encode()).hexdigest()

    def job_auth_error(request: Request) -> JSONResponse | None:
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
                    request_id=request.state.request_id,
                    retryable=False,
                ),
                headers={"WWW-Authenticate": "Bearer"},
            )
        return None

    def job_response(job: JobRecord) -> dict[str, object]:
        return {
            "id": job.id,
            "kind": job.kind,
            "state": job.state,
            "error_code": job.error_code,
            "result_ref": job.result_ref,
        }

    install_error_handlers(app)
    app.include_router(create_system_router(services))
    app.include_router(create_audio_router(services))

    @app.post("/v1/jobs", status_code=202)
    async def create_job(request: Request, body: _JobHTTPBody) -> Response:
        if error := job_auth_error(request):
            return error
        if job_repository is None:
            return _error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                "SpeechRail job spool is not ready",
                retryable=True,
            )
        job = job_repository.create(
            kind=body.kind, owner=job_owner(request), request={"input_ref": body.input_ref}
        )
        return JSONResponse(status_code=202, content=job_response(job))

    @app.get("/v1/jobs/{job_id}")
    async def get_job(request: Request, job_id: str) -> Response:
        if error := job_auth_error(request):
            return error
        if job_repository is None:
            return _error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                "SpeechRail job spool is not ready",
                retryable=True,
            )
        job = job_repository.get(job_id, owner=job_owner(request))
        if job is None:
            return _error_response(404, request.state.request_id, "job_not_found", "Unknown job")
        return JSONResponse(job_response(job))

    @app.delete("/v1/jobs/{job_id}")
    async def delete_job(request: Request, job_id: str) -> Response:
        if error := job_auth_error(request):
            return error
        if job_repository is None:
            return _error_response(
                503,
                request.state.request_id,
                "backend_not_ready",
                "SpeechRail job spool is not ready",
                retryable=True,
            )
        job = job_repository.cancel(job_id, owner=job_owner(request))
        if job is None:
            return _error_response(404, request.state.request_id, "job_not_found", "Unknown job")
        return JSONResponse(job_response(job))

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

    @app.websocket("/v2/realtime")
    async def realtime_v2(websocket: WebSocket) -> None:
        if (
            resolved_v2_transcriber is None
            and realtime_asr_factory is None
            and not services.tts_ready
        ):
            await websocket.close(code=1013, reason="SpeechRail inference backend is not ready")
            return
        if (
            resolved.api_key is not None
            and websocket.headers.get("Authorization", "") != f"Bearer {resolved.api_key}"
        ):
            await websocket.close(code=1008, reason="Invalid API key")
            return
        await websocket.accept()
        session: TranscriptionSession | SpeechSession = TranscriptionSession(
            max_audio_bytes=resolved.max_realtime_buffer_bytes,
            max_frame_bytes=resolved.max_realtime_frame_bytes,
        )
        active_synthesis: asyncio.Task[None] | None = None
        active_streaming_asr: RealtimeAsrSession | None = None
        streaming_reader: asyncio.Task[None] | None = None
        active_diarization: DiarizationCoordinator | None = None
        streaming_item_id: str | None = None
        streaming_revision = 0

        async def consume_streaming_asr_events() -> None:
            nonlocal streaming_item_id, streaming_revision
            if active_streaming_asr is None:
                return
            async for event in active_streaming_asr.events():
                if not isinstance(session, TranscriptionSession):
                    return
                if event.kind == "partial":
                    if not event.text.strip():
                        continue
                    streaming_item_id = streaming_item_id or f"item_{uuid4().hex}"
                    streaming_revision += 1
                    await websocket.send_json(
                        session.transcription_delta(
                            item_id=streaming_item_id,
                            revision=streaming_revision,
                            text=event.text,
                            start_ms=0,
                            end_ms=0,
                        )
                    )
                elif event.kind == "completed":
                    if not event.text.strip():
                        continue
                    item_id = streaming_item_id or f"item_{uuid4().hex}"
                    segments = event.segments or (
                        TranscriptSegment(
                            id=f"seg_{uuid4().hex}", start_ms=0, end_ms=0, text=event.text
                        ),
                    )
                    if active_diarization is not None:
                        segments = await active_diarization.annotate(segments)
                    await websocket.send_json(
                        session.transcription_completed(
                            item_id=item_id,
                            text=event.text,
                            language=event.language,
                            segments=[segment.model_dump(mode="json") for segment in segments],
                        )
                    )
                    streaming_item_id = None
                    streaming_revision = 0
                else:
                    await websocket.send_json(
                        session.protocol_error(
                            code=event.error_code or "backend_error",
                            message="ASR backend reported an error",
                            retryable=True,
                        )
                    )
                    await websocket.close(code=1013)
                    return

        async def transcribe_item(audio: bytes) -> None:
            if not audio:
                return
            if not isinstance(session, TranscriptionSession) or resolved_v2_transcriber is None:
                raise RealtimeV2Error("ASR backend is not ready", code="backend_not_ready")
            request = TranscriptionRequest(
                request_id=session.request_id,
                audio=audio,
                language=session.language,
                prompt=session.prompt,
            )
            result = await governor.run(
                lambda: resolved_v2_transcriber.transcribe(request),
                WorkClass.REALTIME_ASR,
                deadline=resolved.request_timeout_seconds,
            )
            segments = result.segments
            if active_diarization is not None:
                segments = await active_diarization.annotate(segments)
            await websocket.send_json(
                session.transcription_completed(
                    item_id=f"item_{uuid4().hex}",
                    text=result.text,
                    language=result.language,
                    segments=[segment.model_dump(mode="json") for segment in segments],
                )
            )

        async def synthesize_text(text: str, *, speed: float = 1.0) -> None:
            if not text:
                return
            synthesizer = tts_synthesizer
            if (
                not isinstance(session, SpeechSession)
                or synthesizer is None
                or not services.tts_ready
            ):
                raise RealtimeV2Error("TTS backend is not ready", code="backend_not_ready")
            created = session.response_created()
            response_id = str(created["response_id"])
            await websocket.send_json(created)
            request = SpeechRequest(
                text=text,
                voice=session.voice,
                output_format="pcm16",
                sample_rate=24_000,
                speed=speed,
                language=session.language,
            )
            output = BoundedOutboundEventPump(
                max_events=resolved.realtime_outbound_max_events,
                send=websocket.send_json,
            )
            await output.start()
            finished = False
            try:
                async with governor.reserve(
                    WorkClass.REALTIME_TTS, deadline=resolved.request_timeout_seconds
                ):
                    async for chunk in synthesizer.synthesize(request):
                        await output.publish(
                            session.audio_delta(
                                response_id=response_id,
                                chunk_index=chunk.chunk_index,
                                audio=chunk.audio,
                            )
                        )
                await output.publish(session.response_completed(response_id=response_id))
                completed = session.complete_if_input_committed()
                if completed is not None:
                    await output.publish(completed)
                await output.finish()
                finished = True
            except SlowConsumerError:
                await websocket.send_json(
                    session.protocol_error(
                        code="slow_consumer",
                        message="Realtime client cannot consume audio fast enough",
                        retryable=False,
                    )
                )
                await websocket.close(code=1013)
            finally:
                if not finished:
                    await output.abort()

        try:
            while True:
                event = await websocket.receive_json()
                event_type = event.get("type") if isinstance(event, dict) else None
                if event_type == "session.update":
                    configured = event.get("session")
                    if not isinstance(configured, dict):
                        raise RealtimeV2Error(
                            "session must be an object", code="invalid_session"
                        )
                    if configured.get("type") == "transcription":
                        if resolved_v2_transcriber is None and realtime_asr_factory is None:
                            raise RealtimeV2Error(
                                "ASR backend is not ready", code="backend_not_ready"
                            )
                        model = configured.get("model", resolved.model_id)
                        if model not in {resolved.model_id, *resolved.compatibility_model_ids}:
                            raise RealtimeV2Error("unknown model", code="model_not_found")
                        if not isinstance(session, TranscriptionSession):
                            raise RealtimeV2Error(
                                "session type cannot change", code="invalid_session"
                            )
                        created = session.configure(configured)
                        if session.diarization.enabled:
                            if diarization_engine is None:
                                raise RealtimeV2Error(
                                    "diarization profile is not available",
                                    code="diarization_not_available",
                                )
                            active_diarization = DiarizationCoordinator(
                                diarization_engine.create(config=session.diarization)
                            )
                        await websocket.send_json(created)
                        if realtime_asr_factory is not None:
                            active_streaming_asr = realtime_asr_factory.create(
                                language=session.language, prompt=session.prompt
                            )
                            await active_streaming_asr.connect()
                            streaming_reader = asyncio.create_task(consume_streaming_asr_events())
                    elif configured.get("type") == "speech":
                        if not services.tts_ready:
                            raise RealtimeV2Error(
                                "TTS backend is not ready", code="backend_not_ready"
                            )
                        model = configured.get("model", resolved.tts_model_id)
                        if model != resolved.tts_model_id:
                            raise RealtimeV2Error("unknown model", code="model_not_found")
                        session = SpeechSession(
                            max_text_chars=100_000,
                            allowed_voices=resolved.tts_voice_ids,
                            request_id=session.request_id,
                        )
                        await websocket.send_json(session.configure(configured))
                    else:
                        raise RealtimeV2Error(
                            "unsupported session type", code="capability_not_supported"
                        )
                elif event_type == "input_audio_buffer.append":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    audio = session.append_audio(event.get("audio"))
                    if active_diarization is not None:
                        await active_diarization.append_audio(audio)
                    if active_streaming_asr is not None:
                        await active_streaming_asr.append_audio(audio)
                    await websocket.send_json(session.audio_ack())
                elif event_type == "input_audio_buffer.flush":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    audio = session.flush_audio()
                    if active_streaming_asr is not None:
                        await active_streaming_asr.flush()
                    else:
                        await transcribe_item(audio)
                elif event_type == "input_audio_buffer.commit":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    audio = session.commit_audio()
                    if active_streaming_asr is not None:
                        await active_streaming_asr.commit()
                        if streaming_reader is not None:
                            await streaming_reader
                    else:
                        await transcribe_item(audio)
                    if active_diarization is not None and session.diarization.finalize:
                        await websocket.send_json(
                            session.diarization_completed(await active_diarization.finalize())
                        )
                    await websocket.send_json(session.session_completed())
                    await websocket.close()
                    return
                elif event_type == "speech_input.append":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    text = event.get("text")
                    if not isinstance(text, str):
                        raise RealtimeV2Error("text is required", code="invalid_event")
                    session.append_text(text)
                elif event_type == "speech_input.flush":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    if active_synthesis is not None and not active_synthesis.done():
                        raise RealtimeV2Error(
                            "a response is already active", code="response_in_progress"
                        )
                    speed = _speech_speed(event)
                    text = session.flush_text()
                    if text:
                        active_synthesis = asyncio.create_task(
                            synthesize_text(text, speed=speed)
                        )
                elif event_type == "speech_input.commit":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    if active_synthesis is not None and not active_synthesis.done():
                        raise RealtimeV2Error(
                            "a response is already active", code="response_in_progress"
                        )
                    speed = _speech_speed(event)
                    text = session.commit_text()
                    if text:
                        active_synthesis = asyncio.create_task(
                            synthesize_text(text, speed=speed)
                        )
                    else:
                        completed = session.complete_if_input_committed()
                        if completed is not None:
                            await websocket.send_json(completed)
                            await websocket.close()
                            return
                elif event_type == "response.cancel":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    response_id = event.get("response_id")
                    if not isinstance(response_id, str):
                        raise RealtimeV2Error("response_id is required", code="invalid_event")
                    if active_synthesis is not None and not active_synthesis.done():
                        active_synthesis.cancel()
                        with contextlib.suppress(asyncio.CancelledError):
                            await active_synthesis
                    await websocket.send_json(session.response_cancel(response_id=response_id))
                    active_synthesis = None
                    completed = session.complete_if_input_committed()
                    if completed is not None:
                        await websocket.send_json(completed)
                        await websocket.close()
                        return
                elif event_type == "session.cancel":
                    if active_synthesis is not None and not active_synthesis.done():
                        active_synthesis.cancel()
                        with contextlib.suppress(asyncio.CancelledError):
                            await active_synthesis
                        active_synthesis = None
                    await websocket.send_json(session.cancel())
                    await websocket.close()
                    return
                else:
                    raise RealtimeV2Error("unsupported realtime v2 event", code="invalid_event")
        except RealtimeV2Error as exc:
            await websocket.send_json(
                session.protocol_error(code=exc.code, message=str(exc), retryable=False)
            )
            await websocket.close(code=1008)
        except GovernorQueueFullError:
            await websocket.send_json(
                session.protocol_error(
                    code="queue_full", message="Realtime inference queue is full", retryable=True
                )
            )
            await websocket.close(code=1013)
        except TimeoutError:
            await websocket.send_json(
                session.protocol_error(
                    code="backend_timeout", message="Realtime inference timed out", retryable=True
                )
            )
            await websocket.close(code=1013)
        except WebSocketDisconnect:
            pass
        finally:
            if active_synthesis is not None and not active_synthesis.done():
                active_synthesis.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await active_synthesis
            if streaming_reader is not None and not streaming_reader.done():
                streaming_reader.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await streaming_reader
            if active_streaming_asr is not None:
                await active_streaming_asr.close()
            if active_diarization is not None:
                await active_diarization.close()

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
