"""Audio transport routes: OpenAI-compatible batch transcription and TTS."""

from __future__ import annotations

import asyncio
import shutil
import struct
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse, Response, StreamingResponse
from pydantic import BaseModel, Field, field_validator

from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import TTSDeliveryError, iter_validated_audio
from speechrail.domain.ports import SpeechRequest
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error, error_response
from speechrail.http.formatters import format_json, format_srt, format_verbose, format_vtt
from speechrail.runtime.admission import QueueFullError

_OPENAI_AUDIO_EXTENSIONS = frozenset(
    {".flac", ".mp3", ".mp4", ".mpeg", ".mpga", ".m4a", ".ogg", ".wav", ".webm"}
)
_AUDIO_CONTAINER_MIME_TYPES = frozenset(
    {"video/mp4", "video/mpeg", "video/webm", "application/ogg", "application/octet-stream"}
)
_FFMPEG_FALLBACKS = (Path("/opt/homebrew/bin/ffmpeg"), Path("/usr/local/bin/ffmpeg"))


class _SpeechHTTPBody(BaseModel):
    """OpenAI-compatible subset for the public sentence TTS endpoint."""

    model: str = Field(min_length=1, max_length=200)
    input: str = Field(min_length=1, max_length=100_000)
    voice: str = Field(min_length=1, max_length=200)
    response_format: Literal["pcm", "wav"] = "wav"
    speed: float = Field(default=1.0, ge=0.25, le=4.0)
    language: str = Field(default="auto", min_length=1, max_length=64)

    @field_validator("input", "voice")
    @classmethod
    def reject_blank_text(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("must not be blank")
        return normalized
    @field_validator("language")
    @classmethod
    def normalize_language(cls, value: str) -> str:
        normalized = value.strip()
        if not normalized:
            raise ValueError("must not be blank")
        return normalized


def _has_supported_audio_hint(file: UploadFile) -> bool:
    """Accept standard audio containers without trusting client metadata as proof."""

    content_type = (file.content_type or "").split(";", 1)[0].strip().lower()
    if content_type.startswith("audio/") or content_type in _AUDIO_CONTAINER_MIME_TYPES:
        return True
    return Path(file.filename or "").suffix.lower() in _OPENAI_AUDIO_EXTENSIONS


async def _read_upload(file: UploadFile, limit: int) -> bytes:
    if not _has_supported_audio_hint(file):
        raise ValueError("unsupported_audio_type")
    content = bytearray()
    while chunk := await file.read(64 * 1024):
        content.extend(chunk)
        if len(content) > limit:
            raise OverflowError
    if not content:
        raise ValueError("empty_audio")
    return bytes(content)


def _resolve_ffmpeg() -> str:
    executable = shutil.which("ffmpeg")
    if executable:
        return executable
    for candidate in _FFMPEG_FALLBACKS:
        if candidate.is_file():
            return str(candidate)
    raise ValueError("audio_decode_failed")


async def _decode_pcm(audio: bytes) -> bytes:
    """Decode any supported local upload with fixed ffmpeg argv, never a shell."""

    process = await asyncio.create_subprocess_exec(
        _resolve_ffmpeg(),
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


def create_audio_router(services: AppServices) -> APIRouter:
    """Batch transcription and sentence TTS; auth at the route boundary."""
    router = APIRouter()
    resolved = services.settings

    @router.post("/v1/audio/transcriptions")
    async def transcription(
        request: Request,
        file: UploadFile = File(...),  # noqa: B008 - FastAPI parameter marker.
        model: str = Form(default=""),
        language: str | None = Form(default=None),
        prompt: str = Form(default=""),
        response_format: str = Form(default="json"),
        temperature: float | None = Form(default=None),
        timestamp_granularities: list[str] = Form(default=[]),  # noqa: B008 - multipart marker.
    ) -> Response:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if model.strip() and model.strip() not in {
            resolved.model_id,
            *resolved.compatibility_model_ids,
        }:
            return error_response(
                400, request_id, "model_not_found", f"Unknown model: {model}", param="model"
            )
        if response_format not in {"json", "verbose_json", "text", "srt", "vtt"}:
            return error_response(
                422,
                request_id,
                "invalid_response_format",
                "Unsupported response format",
                param="response_format",
            )
        if temperature is not None and not 0 <= temperature <= 2:
            return error_response(
                422,
                request_id,
                "invalid_temperature",
                "Temperature must be in [0, 2]",
                param="temperature",
            )
        if timestamp_granularities:
            unknown = set(timestamp_granularities) - {"word", "segment"}
            if unknown:
                return error_response(
                    422,
                    request_id,
                    "invalid_timestamp_granularities",
                    "Only 'word' and 'segment' are supported",
                    param="timestamp_granularities",
                )
            if response_format != "verbose_json":
                return error_response(
                    422,
                    request_id,
                    "timestamp_granularities_requires_verbose_json",
                    "timestamp_granularities requires response_format=verbose_json",
                    param="timestamp_granularities",
                )
        if len(prompt) > 2000:
            return error_response(
                422, request_id, "prompt_too_long", "Prompt is too long", param="prompt"
            )
        try:
            audio = await _read_upload(file, resolved.max_upload_bytes)
            if services.asr_worker is not None:
                audio = await _decode_pcm(audio)
        except OverflowError:
            return error_response(413, request_id, "audio_too_large", "Audio exceeds upload limit")
        except ValueError as exc:
            return error_response(
                422, request_id, str(exc), "Unsupported audio upload", param="file"
            )
        transcribe = services.transcribe
        if transcribe is None:
            return error_response(
                503,
                request_id,
                "backend_not_ready",
                "SpeechRail inference backend is not ready",
                retryable=True,
            )
        try:
            result = await services.admission.run(
                lambda: transcribe(audio, language, prompt),
                deadline=resolved.request_timeout_seconds,
            )
        except QueueFullError:
            return JSONResponse(
                status_code=429,
                content=error(
                    message="Inference queue is full",
                    error_type="server_error",
                    code="queue_full",
                    request_id=request_id,
                    retryable=True,
                ),
                headers={"Retry-After": "1"},
            )
        except TimeoutError:
            return error_response(
                503, request_id, "backend_timeout", "Inference timed out", retryable=True
            )
        if response_format == "json":
            return JSONResponse(format_json(result))
        if response_format == "verbose_json":
            granularities = frozenset(timestamp_granularities) or frozenset({"segment", "word"})
            return JSONResponse(format_verbose(result, granularities=granularities))
        if response_format == "text":
            return PlainTextResponse(result.text)
        if response_format == "srt":
            return PlainTextResponse(format_srt(result), media_type="application/x-subrip")
        return PlainTextResponse(format_vtt(result), media_type="text/vtt")

    @router.post("/v1/audio/speech")
    async def speech(request: Request, body: _SpeechHTTPBody) -> Response:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if body.model != resolved.tts_model_id:
            return error_response(
                400,
                request_id,
                "model_not_found",
                f"Unknown TTS model: {body.model}",
                param="model",
            )
        if body.voice not in resolved.tts_voice_ids:
            return error_response(
                400,
                request_id,
                "voice_not_found",
                f"Unknown preset voice: {body.voice}",
                param="voice",
            )
        synthesizer = services.tts_synthesizer
        if synthesizer is None or not services.tts_ready:
            return error_response(
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
            language=body.language,
        )

        async def audio_stream() -> AsyncIterator[bytes]:
            async for chunk in iter_validated_audio(synthesizer.synthesize(synthesis)):
                yield chunk.audio

        if body.response_format == "wav":
            pcm = bytearray()
            try:
                async for chunk in audio_stream():
                    pcm.extend(chunk)
            except TTSDeliveryError as exc:
                return error_response(
                    502,
                    request_id,
                    exc.code,
                    "TTS backend delivered an invalid audio stream",
                    retryable=True,
                )
            return Response(
                content=_wav_pcm16(bytes(pcm), sample_rate=resolved.tts_sample_rate),
                media_type="audio/wav",
            )
        return StreamingResponse(audio_stream(), media_type="audio/x-pcm")

    return router
