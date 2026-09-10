"""Durable-job processor for owner-scoped local files under the spool directory.

The processor is the only production ``JobProcessor``: it resolves an
``input_ref`` to a regular file inside an allowlisted root, then reuses the
public batch ASR / TTS ports to produce an artifact under
``<spool_dir>/results/<job_id>/``. It never fetches remote references, never
shells out to a model CLI, and returns an opaque repo-relative result
reference instead of an absolute path or raw content.
"""

from __future__ import annotations

import json
import os
from collections.abc import Sequence
from pathlib import Path
from typing import BinaryIO

from fastapi import UploadFile

from speechrail.domain.ports import (
    BatchTranscriber,
    SpeechRequest,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.domain.tts import DEFAULT_VOICE_ID
from speechrail.runtime.job_runner import JobProcessingError
from speechrail.runtime.jobs import JobRecord

RESULTS_SUBDIR = "results"
_TRANSCRIPT_FILENAME = "transcript.json"
_SPEECH_FILENAME = "speech.pcm"
# Mirrors TranscriptionRequest.audio max_length so the decoded payload can
# never exceed the port's own validated bound.
_MAX_BATCH_PCM_BYTES = 40 * 1024 * 1024
# Mirrors SpeechRequest.text max_length.
_MAX_TEXT_CHARS = 100_000
_MAX_ARTIFACT_BYTES = 128 * 1024 * 1024
_CONTENT_TYPES: dict[str, str] = {
    ".json": "application/json",
    ".pcm": "audio/x-pcm",
    ".wav": "audio/wav",
    ".mp3": "audio/mpeg",
}


def resolve_result_artifact(
    *, spool_dir: Path, job_id: str, result_ref: str
) -> tuple[Path, str] | None:
    """Resolve a completed job's relative ref to a streamable artifact.

    Returns ``(path, media_type)`` only when ``result_ref`` is a relative path
    that stays inside ``<spool_dir>/results/<job_id>/`` and points at a regular
    file. Anything else (opaque non-file refs, absolute paths, traversal, a ref
    bound to another job) returns ``None`` so the caller keeps the JSON shape.
    """
    if not result_ref or "/" in job_id or "\\" in job_id or job_id in {"", ".", ".."}:
        return None
    reference = Path(result_ref)
    if reference.is_absolute() or ".." in reference.parts:
        return None
    results_root = (spool_dir / RESULTS_SUBDIR).resolve()
    job_root = results_root / job_id
    candidate = (spool_dir / reference).resolve()
    if candidate.parent != job_root or not candidate.is_file():
        return None
    media_type = _CONTENT_TYPES.get(candidate.suffix.lower(), "application/octet-stream")
    return candidate, media_type


class LocalFileJobProcessor:
    """Resolve local ``input_ref`` files and produce spooled result artifacts."""

    def __init__(
        self,
        *,
        spool_dir: Path,
        batch_transcriber: BatchTranscriber | None = None,
        tts_synthesizer: SpeechSynthesizer | None = None,
        max_upload_bytes: int = 536_870_912,
        max_audio_seconds: int = 3_600,
        tts_sample_rate: int = 24_000,
        ffmpeg_path: Path | None = None,
        allowed_roots: Sequence[Path] | None = None,
    ) -> None:
        if not spool_dir.is_absolute():
            raise ValueError("job spool directory must be absolute")
        self._spool_dir = spool_dir
        self._results_dir = spool_dir / RESULTS_SUBDIR
        roots = tuple(allowed_roots) if allowed_roots is not None else (spool_dir,)
        if not roots:
            raise ValueError("at least one allowed input root is required")
        self._allowed_roots = tuple(root.resolve() for root in roots)
        self._batch_transcriber = batch_transcriber
        self._tts_synthesizer = tts_synthesizer
        self._max_upload_bytes = max_upload_bytes
        self._max_audio_seconds = max_audio_seconds
        self._tts_sample_rate = tts_sample_rate
        self._ffmpeg_path = ffmpeg_path

    async def process(self, job: JobRecord) -> str:
        input_path = self._resolve_input_path(job.request.get("input_ref"))
        params = job.request.get("params")
        if params is None:
            params = {}
        if not isinstance(params, dict):
            raise JobProcessingError("job_input_invalid")
        if job.kind == "transcription":
            return await self._transcribe(job, input_path, params)
        if job.kind == "speech":
            return await self._synthesize(job, input_path, params)
        raise JobProcessingError("job_input_invalid")

    def _resolve_input_path(self, raw: object) -> Path:
        if not isinstance(raw, str):
            raise JobProcessingError("job_input_invalid")
        reference = raw.strip()
        if not reference or "://" in reference or reference.startswith("//"):
            raise JobProcessingError("job_input_not_allowed")
        candidate = Path(reference)
        if not candidate.is_absolute():
            raise JobProcessingError("job_input_not_allowed")
        try:
            resolved = candidate.resolve()
        except (OSError, RuntimeError):
            raise JobProcessingError("job_input_not_allowed") from None
        if not any(root in resolved.parents for root in self._allowed_roots):
            raise JobProcessingError("job_input_not_allowed")
        if not resolved.is_file():
            raise JobProcessingError("job_input_not_found")
        return resolved

    async def _transcribe(
        self, job: JobRecord, input_path: Path, params: dict[str, object]
    ) -> str:
        transcriber = self._batch_transcriber
        if transcriber is None:
            raise JobProcessingError("job_backend_not_ready")
        pcm = await self._decode_audio(input_path)
        try:
            request = TranscriptionRequest(
                request_id=job.id,
                audio=pcm,
                language=_optional_str(params.get("language")),
                prompt=_optional_str(params.get("prompt")) or "",
                include_timestamps=bool(params.get("timestamps", False)),
            )
        except ValueError:
            raise JobProcessingError("job_input_invalid") from None
        result = await transcriber.transcribe(request)
        payload = {
            "text": result.text,
            "language": result.language,
            "duration_ms": result.duration_ms,
            "segments": [
                {
                    "id": segment.id,
                    "start_ms": segment.start_ms,
                    "end_ms": segment.end_ms,
                    "text": segment.text,
                    "language": segment.language,
                    "speaker": segment.speaker,
                }
                for segment in result.segments
            ],
        }
        content = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        return self._write_artifact(job.id, _TRANSCRIPT_FILENAME, content)

    async def _synthesize(
        self, job: JobRecord, input_path: Path, params: dict[str, object]
    ) -> str:
        synthesizer = self._tts_synthesizer
        if synthesizer is None:
            raise JobProcessingError("job_backend_not_ready")
        text = self._read_text(input_path)
        voice = _optional_str(params.get("voice")) or DEFAULT_VOICE_ID
        try:
            request = SpeechRequest(
                text=text,
                voice=voice,
                output_format="pcm16",
                speed=_coerce_speed(params.get("speed")),
                language=_optional_str(params.get("language")) or "auto",
                instruction=_optional_str(params.get("instruction")),
                seed=_coerce_seed(params.get("seed")),
            )
        except ValueError:
            raise JobProcessingError("job_input_invalid") from None
        pcm = bytearray()
        async for chunk in synthesizer.synthesize(request):
            pcm.extend(chunk.audio)
            if len(pcm) > _MAX_ARTIFACT_BYTES:
                raise JobProcessingError("job_input_too_large")
        if not pcm:
            raise JobProcessingError("job_processor_failed")
        return self._write_artifact(job.id, _SPEECH_FILENAME, bytes(pcm))

    async def _decode_audio(self, input_path: Path) -> bytes:
        from speechrail.application.audio_stream import decode_upload

        max_audio_seconds = min(self._max_audio_seconds, _MAX_BATCH_PCM_BYTES // 32_000)
        chunks = bytearray()
        try:
            with input_path.open("rb") as handle:
                upload = _local_upload(handle, input_path)
                async for chunk in decode_upload(
                    upload,
                    max_upload_bytes=self._max_upload_bytes,
                    max_audio_seconds=max_audio_seconds,
                    ffmpeg_path=self._ffmpeg_path,
                ):
                    chunks.extend(chunk)
        except OverflowError:
            raise JobProcessingError("job_input_too_large") from None
        except ValueError as exc:
            code = "job_input_too_large" if str(exc) == "audio_too_long" else "job_decode_failed"
            raise JobProcessingError(code) from None
        if not chunks:
            raise JobProcessingError("job_decode_failed")
        return bytes(chunks)

    def _read_text(self, input_path: Path) -> str:
        try:
            data = input_path.read_bytes()
        except OSError:
            raise JobProcessingError("job_input_not_found") from None
        if len(data) > _MAX_TEXT_CHARS * 4:
            raise JobProcessingError("job_input_too_large")
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            raise JobProcessingError("job_input_invalid") from None
        if not text.strip():
            raise JobProcessingError("job_input_invalid")
        if len(text) > _MAX_TEXT_CHARS:
            raise JobProcessingError("job_input_too_large")
        return text

    def _write_artifact(self, job_id: str, filename: str, content: bytes) -> str:
        target_dir = self._results_dir / job_id
        target_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        target_dir.chmod(0o700)
        target = target_dir / filename
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(descriptor, content)
        finally:
            os.close(descriptor)
        target.chmod(0o600)
        return f"{RESULTS_SUBDIR}/{job_id}/{filename}"


def _local_upload(handle: BinaryIO, input_path: Path) -> UploadFile:
    """Wrap an open binary handle as the Starlette upload type decode_upload expects."""
    return UploadFile(
        file=handle,
        filename=input_path.name,
        size=input_path.stat().st_size,
    )


def _optional_str(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip()
    return normalized or None


def _coerce_speed(value: object) -> float:
    if value is None:
        return 1.0
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise JobProcessingError("job_input_invalid")
    return float(value)


def _coerce_seed(value: object) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise JobProcessingError("job_input_invalid")
    return value


__all__ = ["RESULTS_SUBDIR", "LocalFileJobProcessor", "resolve_result_artifact"]
