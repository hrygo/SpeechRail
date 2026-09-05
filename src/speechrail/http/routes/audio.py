"""Audio transport routes: OpenAI-compatible batch transcription and TTS."""

from __future__ import annotations

import asyncio
import contextlib
import shutil
import struct
import time as _time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Literal, cast

from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse, Response, StreamingResponse
from pydantic import BaseModel, Field, field_validator

from speechrail.application.audio_stream import decode_upload
from speechrail.application.diarization import DiarizationCoordinator
from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import TTSDeliveryError, iter_validated_audio
from speechrail.compatibility.openai_realtime import (
    canonical_asr_model,
    canonical_tts_model,
)
from speechrail.domain.contracts import TranscriptResult
from speechrail.domain.diarization import DiarizationConfig, DiarizationError
from speechrail.domain.ports import (
    SpeechRequest,
    StreamingBatchTranscriber,
    TranscriptionRequest,
)
from speechrail.domain.tts import resolve_voice
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error, error_response
from speechrail.http.formatters import format_json, format_srt, format_verbose, format_vtt
from speechrail.runtime.admission import QueueFullError
from speechrail.runtime.resource_governor import GovernorQueueFullError, WorkClass

_OPENAI_AUDIO_EXTENSIONS = frozenset(
    {".flac", ".mp3", ".mp4", ".mpeg", ".mpga", ".m4a", ".ogg", ".wav", ".webm"}
)
_AUDIO_CONTAINER_MIME_TYPES = frozenset(
    {"video/mp4", "video/mpeg", "video/webm", "application/ogg", "application/octet-stream"}
)
_FFMPEG_FALLBACKS = (Path("/opt/homebrew/bin/ffmpeg"), Path("/usr/local/bin/ffmpeg"))
_FFMPEG_IO_CHUNK_BYTES = 64 * 1024
_FFMPEG_TIMEOUT_SECONDS = 15.0
_MAX_ENCODED_AUDIO_BYTES = 128 * 1024 * 1024


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


def _try_fast_decode_wav(
    audio: bytes,
    max_decompressed_bytes: int = 128 * 1024 * 1024,
    max_audio_seconds: int | None = None,
) -> bytes | None:
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
    except Exception:
        return None

    if (
        audio_format != 1
        or num_channels not in (1, 2)
        or sample_rate is None
        or sample_rate <= 0
        or bits_per_sample != 16
        or data_bytes is None
        or len(data_bytes) == 0
        or len(data_bytes) % (2 * num_channels) != 0
    ):
        return None

    input_frames = len(data_bytes) // (2 * num_channels)
    if sample_rate == 16_000:
        num_out = input_frames
    else:
        num_out = round(input_frames * 16_000.0 / sample_rate)
        if num_out <= 0:
            return None
    output_bytes = num_out * 2
    if output_bytes > max_decompressed_bytes:
        raise OverflowError("audio_too_large")
    if max_audio_seconds is not None and output_bytes > max_audio_seconds * 32_000:
        raise ValueError("audio_too_long")

    # Fast path: already 16kHz mono
    if num_channels == 1 and sample_rate == 16_000:
        return data_bytes

    # In-memory NumPy channel mixing and linear resampling
    try:
        import numpy as np

        samples = np.frombuffer(data_bytes, dtype="<i2").astype(np.float32)
        if num_channels == 2:
            samples = samples.reshape(-1, 2).mean(axis=1)

        if sample_rate != 16_000:
            x_old = np.arange(len(samples), dtype=np.float32)
            x_new = np.linspace(0, len(samples) - 1, num_out, dtype=np.float32)
            samples = np.interp(x_new, x_old, samples).astype(np.float32)

        return np.clip(samples, -32768.0, 32767.0).astype("<i2").tobytes()
    except Exception:
        return None


class _FFmpegOutputLimitError(Exception):
    """Internal marker carrying the public error for a bounded stdout overflow."""

    def __init__(self, error: ValueError | OverflowError) -> None:
        super().__init__(str(error))
        self.error = error


async def _write_ffmpeg_stdin(stdin: asyncio.StreamWriter, payload: bytes) -> None:
    """Feed ffmpeg in bounded chunks and close stdin so it can finish."""
    try:
        for offset in range(0, len(payload), _FFMPEG_IO_CHUNK_BYTES):
            stdin.write(payload[offset : offset + _FFMPEG_IO_CHUNK_BYTES])
            await stdin.drain()
    finally:
        stdin.close()


async def _read_ffmpeg_stdout(
    stdout: asyncio.StreamReader,
    *,
    max_bytes: int,
    limit_error: ValueError | OverflowError,
) -> bytes:
    """Read at most max_bytes plus one probe byte from ffmpeg stdout."""
    output = bytearray()
    max_bytes = max(0, max_bytes)
    while True:
        read_size = min(_FFMPEG_IO_CHUNK_BYTES, max_bytes + 1 - len(output))
        chunk = await stdout.read(read_size)
        if not chunk:
            return bytes(output)
        if len(output) + len(chunk) > max_bytes:
            raise _FFmpegOutputLimitError(limit_error)
        output.extend(chunk)


async def _cleanup_ffmpeg_process(
    process: asyncio.subprocess.Process,
    tasks: tuple[asyncio.Task[object], ...],
) -> None:
    """Stop ffmpeg and drain its pipes so cancellation cannot leak a child."""
    if process.stdin is not None:
        with contextlib.suppress(Exception):
            process.stdin.close()
    for task in tasks:
        if not task.done():
            task.cancel()
    if tasks:
        with contextlib.suppress(BaseException):
            await asyncio.gather(*tasks, return_exceptions=True)
    if process.returncode is None:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
    # communicate() is used only after termination to drain/discard buffered output and reap.
    with contextlib.suppress(BaseException):
        await process.communicate()


async def _run_ffmpeg_subprocess(
    command: tuple[str, ...],
    payload: bytes,
    *,
    max_output_bytes: int,
    output_limit_error: ValueError | OverflowError,
    timeout_error: ValueError,
    failure_error: ValueError,
) -> bytes:
    """Run fixed-argv ffmpeg with bounded concurrent stdin/stdout tasks."""
    process = await asyncio.create_subprocess_exec(
        *command,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    if process.stdin is None or process.stdout is None:
        await _cleanup_ffmpeg_process(process, ())
        raise failure_error

    writer_task = asyncio.create_task(_write_ffmpeg_stdin(process.stdin, payload))
    reader_task = asyncio.create_task(
        _read_ffmpeg_stdout(
            process.stdout,
            max_bytes=max_output_bytes,
            limit_error=output_limit_error,
        )
    )
    tasks: tuple[asyncio.Task[object], ...] = (writer_task, reader_task)
    try:
        async with asyncio.timeout(_FFMPEG_TIMEOUT_SECONDS):
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
            # FIRST_EXCEPTION returns all tasks when neither task raises. When a task
            # fails, inspect the reader first so the earliest output limit wins over
            # a simultaneous BrokenPipeError from the input writer.
            for task in (reader_task, writer_task):
                if task in done:
                    task.result()
            await process.wait()
            output = reader_task.result()
            if process.returncode != 0 or not output:
                raise RuntimeError("ffmpeg exited without a valid output")
    except _FFmpegOutputLimitError as exc:
        await _cleanup_ffmpeg_process(process, tasks)
        raise exc.error from None
    except TimeoutError:
        await _cleanup_ffmpeg_process(process, tasks)
        raise timeout_error from None
    except asyncio.CancelledError:
        await _cleanup_ffmpeg_process(process, tasks)
        raise
    except Exception as exc:
        await _cleanup_ffmpeg_process(process, tasks)
        raise failure_error from exc
    return output


async def _decode_pcm(
    audio: bytes,
    max_decompressed_bytes: int = 128 * 1024 * 1024,
    max_audio_seconds: int | None = None,
) -> bytes:
    """Decode audio upload with in-memory fastpath and bounded ffmpeg fallback."""
    # Level 1 & 2: In-process memory decode
    fast_pcm = _try_fast_decode_wav(
        audio,
        max_decompressed_bytes=max_decompressed_bytes,
        max_audio_seconds=max_audio_seconds,
    )
    if fast_pcm is not None:
        if len(fast_pcm) > max_decompressed_bytes:
            raise OverflowError("audio_too_large")
        if max_audio_seconds is not None and len(fast_pcm) > max_audio_seconds * 32_000:
            raise ValueError("audio_too_long")
        return fast_pcm

    # Level 3: bounded stdout and a cancellable single-threaded ffmpeg subprocess.
    output_limit = max(0, max_decompressed_bytes)
    output_limit_error: ValueError | OverflowError = OverflowError("audio_too_large")
    if max_audio_seconds is not None:
        duration_limit = max(0, max_audio_seconds * 32_000)
        if duration_limit < output_limit:
            output_limit = duration_limit
            output_limit_error = ValueError("audio_too_long")
    pcm = await _run_ffmpeg_subprocess(
        (
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
        ),
        audio,
        max_output_bytes=output_limit,
        output_limit_error=output_limit_error,
        timeout_error=ValueError("audio_decode_timeout"),
        failure_error=ValueError("audio_decode_failed"),
    )

    if not pcm or len(pcm) % 2:
        raise ValueError("audio_decode_failed")
    if len(pcm) > max_decompressed_bytes:
        raise OverflowError("audio_too_large")
    if max_audio_seconds is not None and len(pcm) > max_audio_seconds * 32_000:
        raise ValueError("audio_too_long")
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
    return await _run_ffmpeg_subprocess(
        (
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
        ),
        pcm,
        max_output_bytes=_MAX_ENCODED_AUDIO_BYTES,
        output_limit_error=ValueError("audio_encode_failed"),
        timeout_error=ValueError("audio_encode_failed"),
        failure_error=ValueError("audio_encode_failed"),
    )


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
        timestamp_granularities_bracketed: list[str] = Form(  # noqa: B008 - multipart marker.
            default=[], alias="timestamp_granularities[]"
        ),
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
        timestamp_granularities = [
            *timestamp_granularities,
            *timestamp_granularities_bracketed,
        ]
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
        batch_transcriber = services.batch_transcriber
        transcribe_stream = getattr(batch_transcriber, "transcribe_stream", None)
        streaming_batch = (
            cast(StreamingBatchTranscriber, batch_transcriber)
            if callable(transcribe_stream)
            else None
        )
        transcribe = services.transcribe
        if streaming_batch is None and transcribe is None and batch_transcriber is None:
            return error_response(
                503,
                request_id,
                "backend_not_ready",
                "SpeechRail inference backend is not ready",
                retryable=True,
            )
        if not _has_supported_audio_hint(file):
            return error_response(
                422,
                request_id,
                "unsupported_audio_type",
                "Unsupported audio upload",
                param="file",
            )
        from speechrail.domain.itn import apply_light_itn, compose_hotword_prompt

        effective_prompt = compose_hotword_prompt(prompt, keywords)
        want_timestamps = response_format in {"verbose_json", "diarized_json", "srt", "vtt"}
        coordinator: DiarizationCoordinator | None = None
        if diarization_requested:
            assert diarization_engine is not None
            coordinator = DiarizationCoordinator(
                diarization_engine.create(config=DiarizationConfig(enabled=True))
            )
        audio_bytes = 0

        async def close_coordinator() -> None:
            nonlocal coordinator
            if coordinator is not None:
                current, coordinator = coordinator, None
                await current.close()

        async def run_inference() -> TranscriptResult:
            nonlocal audio_bytes
            try:
                if streaming_batch is not None:
                    decoded = decode_upload(
                        file,
                        max_upload_bytes=resolved.max_upload_bytes,
                        max_audio_seconds=resolved.max_audio_seconds,
                    )

                    async def observed_audio() -> AsyncIterator[bytes]:
                        nonlocal audio_bytes
                        async for chunk in decoded:
                            audio_bytes += len(chunk)
                            if coordinator is not None:
                                await coordinator.append_audio(chunk)
                            yield chunk

                    async with contextlib.aclosing(decoded):
                        return await streaming_batch.transcribe_stream(
                            request_id,
                            observed_audio(),
                            language,
                            effective_prompt,
                            want_timestamps,
                        )

                audio = await _read_upload(file, resolved.max_upload_bytes)
                if services.asr_worker is not None:
                    audio = await _decode_pcm(
                        audio,
                        max_audio_seconds=resolved.max_audio_seconds,
                    )
                else:
                    fast_pcm = _try_fast_decode_wav(
                        audio,
                        max_decompressed_bytes=128 * 1024 * 1024,
                        max_audio_seconds=resolved.max_audio_seconds,
                    )
                    if fast_pcm is not None:
                        audio = fast_pcm
                audio_bytes = len(audio)
                if coordinator is not None:
                    await coordinator.append_audio(audio)
                if batch_transcriber is not None:
                    return await batch_transcriber.transcribe(
                        TranscriptionRequest(
                            request_id=request_id,
                            audio=audio,
                            language=language,
                            prompt=effective_prompt,
                            include_timestamps=want_timestamps,
                        )
                    )
                assert transcribe is not None
                return await transcribe(audio, language, effective_prompt, want_timestamps)
            except BaseException:
                await close_coordinator()
                raise

        try:
            _t0 = _time.monotonic()
            # Batch REST work flows through the governor so the realtime
            # reservation cannot be starved by concurrent uploads.
            result = await services.governor.run(
                lambda: services.admission.run(
                    run_inference,
                    deadline=resolved.request_timeout_seconds,
                ),
                WorkClass.BATCH_ASR,
                deadline=resolved.request_timeout_seconds,
            )
            _inference_sec = _time.monotonic() - _t0
            # Audio duration from PCM16 @ 16kHz mono = len / 2 / 16000
            _audio_sec = audio_bytes / 32_000
            services.metrics.record_asr(_audio_sec, _inference_sec)
        except OverflowError:
            return error_response(413, request_id, "audio_too_large", "Audio exceeds upload limit")
        except ValueError as exc:
            if str(exc) == "audio_too_long":
                return error_response(
                    400,
                    request_id,
                    "audio_too_long",
                    f"Audio duration exceeds maximum limit of {resolved.max_audio_seconds} seconds",
                    param="file",
                )
            return error_response(
                422, request_id, str(exc), "Unsupported audio upload", param="file"
            )
        except QueueFullError:
            await close_coordinator()
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
        except GovernorQueueFullError:
            await close_coordinator()
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
            await close_coordinator()
            return error_response(
                503, request_id, "backend_timeout", "Inference timed out", retryable=True
            )
        except DiarizationError as exc:
            await close_coordinator()
            return error_response(
                502,
                request_id,
                exc.code,
                "Diarization backend returned an invalid result",
                retryable=True,
            )
        if coordinator is not None:
            try:
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
                await close_coordinator()

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
        from speechrail.domain.tts import get_voice_profile
        try:
            profile = get_voice_profile(preset_voice)
            if profile.is_system and preset_voice not in resolved.tts_voice_ids:
                raise ValueError(f"voice {preset_voice} not configured")
        except ValueError:
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
            # Batch TTS flows through the governor so it cannot consume the
            # reserved realtime TTS lane; the reserve is held while the stream
            # is consumed and released as soon as the generator closes.
            async with services.governor.reserve(
                WorkClass.BATCH_TTS, deadline=resolved.request_timeout_seconds
            ):
                async for chunk in iter_validated_audio(synthesizer.synthesize(synthesis)):
                    yield chunk.audio

        if body.response_format == "pcm":
            pcm_stream = audio_stream()
            _tts_t0 = _time.monotonic()
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
            except GovernorQueueFullError:
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
            if not first:
                return error_response(
                    502,
                    request_id,
                    "audio_encode_failed",
                    "Failed to encode the synthesized audio",
                    retryable=True,
                )

            async def streamed_pcm() -> AsyncIterator[bytes]:
                nonlocal _tts_t0
                _emitted_bytes = 0
                async def _record_if_complete() -> None:
                    audio_sec = _emitted_bytes / 2 / resolved.tts_sample_rate
                    services.metrics.record_tts(
                        voice=preset_voice,
                        char_count=len(body.input),
                        audio_duration_sec=audio_sec,
                        inference_duration_sec=_time.monotonic() - _tts_t0,
                    )

                yield first
                _emitted_bytes += len(first)
                async for chunk in pcm_stream:
                    _emitted_bytes += len(chunk)
                    yield chunk
                await _record_if_complete()

            return StreamingResponse(streamed_pcm(), media_type="audio/x-pcm")
        pcm = bytearray()
        _tts_t0 = _time.monotonic()
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
        except GovernorQueueFullError:
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
        _tts_inference_sec = _time.monotonic() - _tts_t0
        if not pcm:
            return error_response(
                502,
                request_id,
                "audio_encode_failed",
                "Failed to encode the synthesized audio",
                retryable=True,
            )
        # Record TTS metrics: audio_sec = pcm_bytes / 2 / sample_rate
        _tts_audio_sec = len(pcm) / 2 / resolved.tts_sample_rate
        services.metrics.record_tts(
            voice=preset_voice,
            char_count=len(body.input),
            audio_duration_sec=_tts_audio_sec,
            inference_duration_sec=_tts_inference_sec,
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
