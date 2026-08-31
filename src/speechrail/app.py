"""Contract-first FastAPI application with bounded ASR execution edges."""

from __future__ import annotations

import asyncio
import hashlib
import struct
from collections.abc import AsyncIterator, Awaitable, Callable
from pathlib import Path
from typing import Any, Literal
from uuid import uuid4

from fastapi import FastAPI, File, Form, Request, UploadFile, WebSocket
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse
from pydantic import BaseModel, Field, field_validator
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response

from speechrail import __version__
from speechrail.backends.qwen3_native import (
    Qwen3BackendConfig,
    Qwen3BatchTranscriber,
    Qwen3Worker,
)
from speechrail.compatibility.presenters import legacy_config, legacy_ready_to_stop
from speechrail.config import Settings
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.ports import (
    BatchTranscriber,
    SpeechRequest,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.domain.realtime_v2 import RealtimeV2Error
from speechrail.http.formatters import format_json, format_srt, format_verbose, format_vtt
from speechrail.realtime.events import RealtimeSession, SessionError
from speechrail.realtime.v2_session import SpeechSession, TranscriptionSession
from speechrail.runtime.admission import AdmissionQueue, QueueFullError
from speechrail.runtime.jobs import JobRecord, JobRepository
from speechrail.runtime.resource_governor import GovernorQueueFullError, ResourceGovernor, WorkClass

Transcribe = Callable[[bytes, str | None, str], Awaitable[TranscriptResult]]


class _CallableBatchTranscriber(BatchTranscriber):
    """Bridge the v1 callable seam while v2 adopts typed backend ports."""

    def __init__(self, transcribe: Transcribe, model_id: str) -> None:
        self._transcribe = transcribe
        self._model_id = model_id

    async def transcribe(self, request: TranscriptionRequest) -> TranscriptResult:
        result = await self._transcribe(request.audio, request.language, request.prompt)
        return result.model_copy(
            update={"request_id": request.request_id, "model_id": self._model_id}
        )


class _SpeechHTTPBody(BaseModel):
    """OpenAI-compatible subset for the public sentence TTS endpoint."""

    model: str = Field(min_length=1, max_length=200)
    input: str = Field(min_length=1, max_length=100_000)
    voice: str = Field(min_length=1, max_length=200)
    response_format: Literal["pcm", "wav"] = "wav"
    speed: float = Field(default=1.0, ge=0.25, le=4.0)

    @field_validator("input", "voice")
    @classmethod
    def reject_blank_text(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("must not be blank")
        return normalized


class _JobHTTPBody(BaseModel):
    kind: Literal["speech", "transcription"]
    input_ref: str = Field(min_length=1, max_length=1_000)


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


async def _decode_pcm(audio: bytes) -> bytes:
    """Decode any supported local upload with fixed ffmpeg argv, never a shell."""

    process = await asyncio.create_subprocess_exec(
        "ffmpeg",
        "-nostdin",
        "-v",
        "error",
        "-i",
        "pipe:0",
        "-f",
        "s16le",
        "-ar",
        "16000",
        "-ac",
        "1",
        "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    pcm, _ = await process.communicate(audio)
    if process.returncode != 0 or not pcm or len(pcm) % 2:
        raise ValueError("audio_decode_failed")
    return pcm


def create_app(
    settings: Settings | None = None,
    *,
    transcribe: Transcribe | None = None,
    v2_transcriber: BatchTranscriber | None = None,
    tts_synthesizer: SpeechSynthesizer | None = None,
    job_repository: JobRepository | None = None,
) -> FastAPI:
    resolved = settings or Settings()
    worker: Qwen3Worker | None = None
    if (
        transcribe is None
        and resolved.qwen3_model_dir is not None
        and resolved.qwen3_python is not None
    ):
        worker = Qwen3Worker(
            Qwen3BackendConfig(
                repository_root=Path(__file__).parents[2],
                python_executable=resolved.qwen3_python,
                model_dir=resolved.qwen3_model_dir,
                device=resolved.device,
                dtype=resolved.dtype,
                timeout_seconds=resolved.request_timeout_seconds,
            )
        )
        transcribe = worker.transcribe
        v2_transcriber = Qwen3BatchTranscriber(worker=worker, model_id=resolved.model_id)
    admission = AdmissionQueue(resolved.max_queue_size)
    governor = ResourceGovernor(resolved.governor_limits)
    resolved_v2_transcriber = v2_transcriber
    if resolved_v2_transcriber is None and transcribe is not None:
        resolved_v2_transcriber = _CallableBatchTranscriber(transcribe, resolved.model_id)
    app = FastAPI(title="SpeechRail API", version=resolved.version)
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

    if worker is not None:

        @app.on_event("startup")
        async def start_worker() -> None:
            await worker.start()

        @app.on_event("shutdown")
        async def stop_worker() -> None:
            await worker.close()

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
                for item in (
                    resolved.model_id,
                    resolved.tts_model_id,
                    *resolved.compatibility_model_ids,
                )
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
            if worker is not None:
                audio = await _decode_pcm(audio)
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

    @app.post("/v1/audio/speech")
    async def speech(request: Request, body: _SpeechHTTPBody) -> Response:
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
        if body.model != resolved.tts_model_id:
            return _error_response(
                400,
                request_id,
                "model_not_found",
                f"Unknown TTS model: {body.model}",
                param="model",
            )
        if body.voice not in resolved.tts_voice_ids:
            return _error_response(
                400,
                request_id,
                "voice_not_found",
                f"Unknown preset voice: {body.voice}",
                param="voice",
            )
        if tts_synthesizer is None:
            return _error_response(
                503,
                request_id,
                "backend_not_ready",
                "SpeechRail TTS backend is not ready",
                retryable=True,
            )
        synthesis = SpeechRequest(
            text=body.input,
            voice=body.voice,
            output_format="pcm16" if body.response_format == "pcm" else "wav",
            speed=body.speed,
        )

        async def audio_stream() -> AsyncIterator[bytes]:
            expected_chunk = 0
            async for chunk in tts_synthesizer.synthesize(synthesis):
                if chunk.chunk_index != expected_chunk:
                    raise RuntimeError("tts_chunk_order_invalid")
                expected_chunk += 1
                yield chunk.audio

        if body.response_format == "wav":
            pcm = bytearray()
            async for chunk in audio_stream():
                pcm.extend(chunk)
            return Response(
                content=_wav_pcm16(bytes(pcm), sample_rate=resolved.tts_sample_rate),
                media_type="audio/wav",
            )
        return StreamingResponse(audio_stream(), media_type="audio/x-pcm")

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
        if resolved_v2_transcriber is None and tts_synthesizer is None:
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
            await websocket.send_json(
                session.transcription_completed(
                    item_id=f"item_{uuid4().hex}",
                    text=result.text,
                    language=result.language,
                    segments=[segment.model_dump(mode="json") for segment in result.segments],
                )
            )

        async def synthesize_text(text: str) -> None:
            if not text:
                return
            if not isinstance(session, SpeechSession) or tts_synthesizer is None:
                raise RealtimeV2Error("TTS backend is not ready", code="backend_not_ready")
            created = session.response_created()
            response_id = str(created["response_id"])
            await websocket.send_json(created)
            request = SpeechRequest(
                text=text,
                voice=session.voice,
                output_format="pcm16",
                sample_rate=24_000,
            )
            async with governor.reserve(
                WorkClass.REALTIME_TTS, deadline=resolved.request_timeout_seconds
            ):
                async for chunk in tts_synthesizer.synthesize(request):
                    await websocket.send_json(
                        session.audio_delta(
                            response_id=response_id,
                            chunk_index=chunk.chunk_index,
                            audio=chunk.audio,
                        )
                    )
            await websocket.send_json(session.response_completed(response_id=response_id))
            completed = session.complete_if_input_committed()
            if completed is not None:
                await websocket.send_json(completed)

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
                        if resolved_v2_transcriber is None:
                            raise RealtimeV2Error(
                                "ASR backend is not ready", code="backend_not_ready"
                            )
                        model = configured.get("model", resolved.model_id)
                        if model not in {resolved.model_id, *resolved.compatibility_model_ids}:
                            raise RealtimeV2Error("unknown model", code="model_not_found")
                        await websocket.send_json(session.configure(configured))
                    elif configured.get("type") == "speech":
                        if tts_synthesizer is None:
                            raise RealtimeV2Error(
                                "TTS backend is not ready", code="backend_not_ready"
                            )
                        model = configured.get("model", resolved.tts_model_id)
                        if model != resolved.tts_model_id:
                            raise RealtimeV2Error("unknown model", code="model_not_found")
                        session = SpeechSession(
                            max_text_chars=100_000, request_id=session.request_id
                        )
                        await websocket.send_json(session.configure(configured))
                    else:
                        raise RealtimeV2Error(
                            "unsupported session type", code="capability_not_supported"
                        )
                elif event_type == "input_audio_buffer.append":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    session.append_audio(event.get("audio"))
                    await websocket.send_json(session.audio_ack())
                elif event_type == "input_audio_buffer.flush":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    await transcribe_item(session.flush_audio())
                elif event_type == "input_audio_buffer.commit":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    await transcribe_item(session.commit_audio())
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
                    await synthesize_text(session.flush_text())
                elif event_type == "speech_input.commit":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    await synthesize_text(session.commit_text())
                    if session.state == "committed":
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
                    await websocket.send_json(session.response_cancel(response_id=response_id))
                elif event_type == "session.cancel":
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


def _wav_pcm16(pcm: bytes, *, sample_rate: int) -> bytes:
    """Wrap a complete mono PCM16 payload in a standard WAV container."""
    if len(pcm) % 2:
        raise ValueError("PCM16 payload must have an even byte length")
    byte_rate = sample_rate * 2
    header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + len(pcm),
        b"WAVE",
        b"fmt ",
        16,
        1,
        1,
        sample_rate,
        byte_rate,
        2,
        16,
        b"data",
        len(pcm),
    )
    return header + pcm


app = create_app()

__all__ = ["__version__", "app", "create_app"]
