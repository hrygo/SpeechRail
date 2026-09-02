"""Audio transport routes: OpenAI-compatible batch transcription and TTS."""

from __future__ import annotations

import asyncio
import contextlib
import shutil
import struct
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse, Response, StreamingResponse
from pydantic import BaseModel, Field, field_validator

from speechrail.application.diarization import DiarizationCoordinator
from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import TTSDeliveryError, iter_validated_audio
from speechrail.compatibility.openai_realtime import (
    canonical_asr_model,
    canonical_tts_model,
)
from speechrail.domain.diarization import DiarizationConfig, DiarizationError
from speechrail.domain.ports import SpeechRequest
from speechrail.domain.tts import resolve_voice
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
    input: str = Field(min_length=1, max_length=4_096)
    voice: str = Field(min_length=1, max_length=200)
    response_format: Literal["mp3", "opus", "aac", "flac", "wav", "pcm"] = "mp3"
    speed: float = Field(default=1.0, ge=0.25, le=4.0)
    language: str = Field(default="auto", min_length=1, max_length=64)
    instructions: str | None = Field(default=None, max_length=100_000)
    stream_format: str | None = Field(default=None, max_length=16)

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


def _try_fast_decode_wav(audio: bytes) -> bytes | None:
    """Fast-path in-memory decoding for PCM WAV (any sample rate/channels) without subprocess."""
    if len(audio) < 44 or not audio.startswith(b"RIFF") or audio[8:12] != b"WAVE":
        return None
    try:
        offset = 12
        audio_format = None
        num_channels = None
        sample_rate = None
        bits_per_sample = None
        data_bytes: bytes | None = None
        audio_len = len(audio)
        while offset + 8 <= audio_len:
            chunk_id = audio[offset : offset + 4]
            chunk_size = struct.unpack("<I", audio[offset + 4 : offset + 8])[0]
            chunk_data_start = offset + 8
            chunk_data_end = chunk_data_start + chunk_size
            if chunk_data_end > audio_len:
                return None
            if chunk_id == b"fmt " and chunk_size >= 16:
                fmt_tag, channels, rate, _, _, bits = struct.unpack(
                    "<HHIIHH", audio[chunk_data_start : chunk_data_start + 16]
                )
                audio_format = fmt_tag
                num_channels = channels
                sample_rate = rate
                bits_per_sample = bits
            elif chunk_id == b"data":
                data_bytes = audio[chunk_data_start:chunk_data_end]
            offset = chunk_data_end + (chunk_size % 2)

        if (
            audio_format == 1
            and num_channels in (1, 2)
            and bits_per_sample == 16
            and data_bytes is not None
            and len(data_bytes) > 0
            and len(data_bytes) % (2 * num_channels) == 0
        ):
            # Fast path: already 16kHz mono
            if num_channels == 1 and sample_rate == 16_000:
                return data_bytes

            # In-memory NumPy channel mixing and linear resampling
            import numpy as np

            samples = np.frombuffer(data_bytes, dtype="<i2").astype(np.float32)
            if num_channels == 2:
                samples = samples.reshape(-1, 2).mean(axis=1)

            if sample_rate != 16_000 and sample_rate is not None and sample_rate > 0:
                num_out = int(round(len(samples) * 16_000.0 / sample_rate))
                if num_out <= 0:
                    return None
                x_old = np.arange(len(samples), dtype=np.float32)
                x_new = np.linspace(0, len(samples) - 1, num_out, dtype=np.float32)
                samples = np.interp(x_new, x_old, samples)

            return np.clip(samples, -32768.0, 32767.0).astype("<i2").tobytes()
    except Exception:
        return None
    return None


async def _decode_pcm(audio: bytes, max_decompressed_bytes: int = 128 * 1024 * 1024) -> bytes:
    """Decode audio upload with in-memory fastpath and sandboxed ffmpeg fallback."""
    # Level 1 & 2: In-process memory decode
    fast_pcm = _try_fast_decode_wav(audio)
    if fast_pcm is not None:
        if len(fast_pcm) > max_decompressed_bytes:
            raise OverflowError("audio_too_large")
        return fast_pcm

    # Level 3: Sandboxed single-threaded ffmpeg subprocess with timeout & memory limit
    process = await asyncio.create_subprocess_exec(
        _resolve_ffmpeg(),
        "-nostdin",
        "-threads",
        "1",
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
    try:
        async with asyncio.timeout(15.0):
            pcm, _ = await process.communicate(audio)
    except TimeoutError:
        process.kill()
        with contextlib.suppress(Exception):
            await process.communicate()
        raise ValueError("audio_decode_timeout") from None

    if process.returncode != 0 or not pcm or len(pcm) % 2:
        raise ValueError("audio_decode_failed")
    if len(pcm) > max_decompressed_bytes:
        raise OverflowError("audio_too_large")
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


_TTS_CONTAINER_ENCODERS: dict[str, tuple[str, tuple[str, ...]]] = {
    "mp3": ("audio/mpeg", ("-c:a", "libmp3lame", "-b:a", "128k", "-f", "mp3")),
    "opus": ("audio/opus", ("-c:a", "libopus", "-f", "ogg")),
    "aac": ("audio/aac", ("-c:a", "aac", "-f", "adts")),
    "flac": ("audio/flac", ("-c:a", "flac", "-f", "flac")),
}


async def _encode_container(pcm: bytes, *, sample_rate: int, response_format: str) -> bytes:
    """Remux complete PCM16 into an OpenAI container with fixed ffmpeg argv, never a shell."""
    _, args = _TTS_CONTAINER_ENCODERS[response_format]
    process = await asyncio.create_subprocess_exec(
        _resolve_ffmpeg(),
        "-nostdin",
        "-v",
        "error",
        "-f",
        "s16le",
        "-ar",
        str(sample_rate),
        "-ac",
        "1",
        "-i",
        "pipe:0",
        *args,
        "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    encoded, _ = await process.communicate(pcm)
    if process.returncode != 0 or not encoded:
        raise ValueError("audio_encode_failed")
    return encoded


def create_audio_router(services: AppServices) -> APIRouter:
    """Batch transcription and sentence TTS; auth at the route boundary."""
    router = APIRouter()
    resolved = services.settings
    diarization_engine = services.diarization_engine

    @router.post("/v1/audio/transcriptions")
    async def transcription(
        request: Request,
        file: UploadFile = File(...),  # noqa: B008 - FastAPI parameter marker.
        model: str = Form(default=""),
        language: str | None = Form(default=None),
        languages: list[str] = Form(default=[]),  # noqa: B008 - multipart marker.
        prompt: str = Form(default=""),
        response_format: str = Form(default="json"),
        temperature: float | None = Form(default=None),
        timestamp_granularities: list[str] = Form(default=[]),  # noqa: B008 - multipart marker.
        stream: bool = Form(default=False),
        chunking_strategy: str | None = Form(default=None),
        include: list[str] = Form(default=[]),  # noqa: B008 - multipart marker.
        keywords: list[str] = Form(default=[]),  # noqa: B008 - multipart marker.
        known_speaker_names: list[str] = Form(default=[]),  # noqa: B008 - multipart marker.
        known_speaker_references: list[str] = Form(default=[]),  # noqa: B008 - multipart marker.
    ) -> Response:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        if model.strip():
            registered = frozenset({resolved.model_id, *resolved.compatibility_model_ids})
            if canonical_asr_model(model.strip(), registered=registered) is None:
                return error_response(
                    400, request_id, "model_not_found", f"Unknown model: {model}", param="model"
                )
        diarization_requested = (
            model.strip() == "gpt-4o-transcribe-diarize" or response_format == "diarized_json"
        )
        if response_format not in {
            "json",
            "verbose_json",
            "diarized_json",
            "text",
            "srt",
            "vtt",
        }:
            return error_response(
                422,
                request_id,
                "invalid_response_format",
                "Unsupported response format",
                param="response_format",
            )
        if diarization_requested and not services.diarization_ready:
            return error_response(
                503,
                request_id,
                "diarization_not_available",
                "diarization profile is not available",
                retryable=False,
            )
        if stream:
            return error_response(
                422,
                request_id,
                "stream_unsupported",
                "SpeechRail does not support streaming file transcription",
                param="stream",
            )
        if chunking_strategy is not None:
            return error_response(
                422,
                request_id,
                "chunking_strategy_unsupported",
                "SpeechRail transcribes whole files without chunking",
                param="chunking_strategy",
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
        if language is None and languages:
            language = languages[0]
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
        from speechrail.domain.itn import apply_light_itn, compose_hotword_prompt

        effective_prompt = compose_hotword_prompt(prompt, keywords)
        try:
            want_timestamps = response_format in {"verbose_json", "diarized_json", "srt", "vtt"}
            result = await services.admission.run(
                lambda: transcribe(audio, language, effective_prompt, want_timestamps),
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
        if diarization_requested:
            assert diarization_engine is not None
            coordinator = DiarizationCoordinator(
                diarization_engine.create(config=DiarizationConfig(enabled=True))
            )
            try:
                await coordinator.append_audio(audio)
                segments = await coordinator.annotate(result.segments)
                result = result.model_copy(update={"segments": segments})
            except DiarizationError as exc:
                return error_response(
                    502,
                    request_id,
                    exc.code,
                    "Diarization backend returned an invalid result",
                    retryable=True,
                )
            finally:
                await coordinator.close()

        # Apply Light ITN to output text and segments
        result = result.model_copy(
            update={
                "text": apply_light_itn(result.text),
                "segments": [
                    s.model_copy(update={"text": apply_light_itn(s.text)})
                    for s in result.segments
                ],
            }
        )
        if response_format == "json":
            return JSONResponse(format_json(result))
        if response_format in {"verbose_json", "diarized_json"}:
            granularities = frozenset(timestamp_granularities) or frozenset({"segment", "word"})
            if response_format == "diarized_json":
                granularities = frozenset({"segment"})
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
        if canonical_tts_model(
            body.model, registered=frozenset({resolved.tts_model_id})
        ) is None:
            return error_response(
                400,
                request_id,
                "model_not_found",
                f"Unknown TTS model: {body.model}",
                param="model",
            )
        preset_voice = resolve_voice(body.voice)
        if preset_voice not in resolved.tts_voice_ids:
            return error_response(
                400,
                request_id,
                "voice_not_found",
                f"Unknown preset voice: {body.voice}",
                param="voice",
            )
        if body.stream_format not in (None, "audio"):
            return error_response(
                422,
                request_id,
                "stream_format_unsupported",
                "SpeechRail returns a complete audio body; stream_format is not supported",
                param="stream_format",
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
            voice=preset_voice,
            output_format="pcm16",
            speed=body.speed,
            language=body.language,
        )

        async def audio_stream() -> AsyncIterator[bytes]:
            async for chunk in iter_validated_audio(synthesizer.synthesize(synthesis)):
                yield chunk.audio

        if body.response_format == "pcm":
            pcm_stream = audio_stream()
            try:
                first = await anext(pcm_stream, b"")
            except TTSDeliveryError as exc:
                return error_response(
                    502,
                    request_id,
                    exc.code,
                    "TTS backend delivered an invalid audio stream",
                    retryable=True,
                )
            if not first:
                return error_response(
                    502,
                    request_id,
                    "audio_encode_failed",
                    "Failed to encode the synthesized audio",
                    retryable=True,
                )

            async def streamed_pcm() -> AsyncIterator[bytes]:
                yield first
                async for chunk in pcm_stream:
                    yield chunk

            return StreamingResponse(streamed_pcm(), media_type="audio/x-pcm")
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
        if not pcm:
            return error_response(
                502,
                request_id,
                "audio_encode_failed",
                "Failed to encode the synthesized audio",
                retryable=True,
            )
        try:
            if body.response_format == "wav":
                content = _wav_pcm16(bytes(pcm), sample_rate=resolved.tts_sample_rate)
                media_type = "audio/wav"
            else:
                media_type, _ = _TTS_CONTAINER_ENCODERS[body.response_format]
                content = await _encode_container(
                    bytes(pcm),
                    sample_rate=resolved.tts_sample_rate,
                    response_format=body.response_format,
                )
        except ValueError:
            return error_response(
                502,
                request_id,
                "audio_encode_failed",
                "Failed to encode the synthesized audio",
                retryable=True,
            )
        return Response(content=content, media_type=media_type)

    return router
