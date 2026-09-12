"""Explicit prompt-to-reference registration; existing voices are never migrated."""

from __future__ import annotations

import asyncio
import hashlib
import io
import wave
from dataclasses import replace
from functools import partial
from typing import Literal

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator

from speechrail.application.services import AppServices
from speechrail.application.tts_admission import tts_resource_key
from speechrail.application.tts_delivery import (
    PcmOutputCounter,
    TTSDeliveryError,
    iter_until,
    iter_validated_audio,
)
from speechrail.config.selection import active_model_catalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.ports import SpeechRequest, SpeechSynthesizer, TranscriptionRequest
from speechrail.domain.tts import (
    DEFAULT_VOICE_ID,
    SYSTEM_VOICE_PROFILES,
    VOICE_ALIASES,
    VoiceAlreadyExistsError,
    VoiceStoreUnavailableError,
    canonicalize_clone_reference_audio,
    get_voice_registry,
    normalize_tts_text,
)
from speechrail.domain.voice_creation import VoiceCreation
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error_response
from speechrail.http.routes.system import (
    _TRANSCRIPT_PASS_SCORE,
    _empty_synthesis,
    _evict_quality_tts_if_supported,
    _grade_clone_audio,
    _quality_reject_response,
    _resample_quality_pcm_24k_to_16k,
    _voice_entry,
)
from speechrail.runtime.admission import QueueFullError
from speechrail.runtime.asr_mode import AsrModeBusy
from speechrail.runtime.resource_governor import GovernorQueueFullError, WorkClass

_SAMPLE_RATE = 24_000
_MAX_REFERENCE_PCM_BYTES = 30 * _SAMPLE_RATE * 2


class VoiceDesignRegistrationRequest(BaseModel):
    """A new Base-bound voice ID, never an in-place conversion of an old voice."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    id: str = Field(pattern=r"^[a-z0-9_-]{1,64}$")
    name: str = Field(min_length=1, max_length=64)
    instruction: str = Field(min_length=1, max_length=10_000)
    reference_text: str = Field(min_length=20, max_length=240)
    seed: StrictInt = Field(default=42, ge=0, le=2**32 - 1)
    # The first registration gate is calibrated only as a Chinese experiment.
    language: Literal["zh"] = "zh"

    @field_validator("id")
    @classmethod
    def reject_reserved_id(cls, value: str) -> str:
        if value in SYSTEM_VOICE_PROFILES or value in VOICE_ALIASES:
            raise ValueError("reserved voice ID")
        return value


async def _generate_reference(
    synthesizer: SpeechSynthesizer,
    synthesis: SpeechRequest,
    *,
    expires_at: float,
) -> bytes:
    counter = PcmOutputCounter(_MAX_REFERENCE_PCM_BYTES)
    pcm = bytearray()
    stream = iter_until(iter_validated_audio(synthesizer.synthesize(synthesis)), expires_at)
    try:
        async for chunk in stream:
            counter.accept(len(chunk.audio))
            pcm.extend(chunk.audio)
    finally:
        close = getattr(stream, "aclose", None)
        if close is not None:
            await close()
    if len(pcm) < 2 * _SAMPLE_RATE * 2:
        raise TTSDeliveryError("voice_reference_too_short")
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(_SAMPLE_RATE)
        wav.writeframes(pcm)
    return output.getvalue()


def create_voice_design_router(services: AppServices) -> APIRouter:
    router = APIRouter()
    active = active_model_catalog(services.settings)

    @router.post("/v1/voices/designs", status_code=201)
    async def register_design(
        request: Request, body: VoiceDesignRegistrationRequest
    ) -> JSONResponse:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        design, clone = active.tts, active.tts_clone
        if (
            active.profile != "quality"
            or design is None
            or design.variant != "voice_design"
            or clone is None
            or clone.variant != "base"
        ):
            return error_response(
                400,
                request_id,
                "voice_design_registration_unsupported",
                "Generated-reference registration requires the quality VoiceDesign/Base profile",
            )
        synthesizer, transcriber = services.tts_synthesizer, services.batch_transcriber
        if synthesizer is None:
            return error_response(
                503,
                request_id,
                "backend_not_ready",
                "TTS is not configured",
                retryable=True,
            )
        if transcriber is None:
            return error_response(
                503,
                request_id,
                "transcription_unavailable",
                "Reference registration requires local Batch ASR validation",
                retryable=True,
            )
        registry = get_voice_registry()
        expires_at = asyncio.get_running_loop().time() + services.settings.request_timeout_seconds
        stage = "generation"
        try:
            try:
                registry.get_profile(body.id)
            except ValueError:
                pass
            else:
                raise VoiceAlreadyExistsError("target voice already exists")
            text = normalize_tts_text(body.reference_text)
            if not 20 <= len(text) <= 240:
                return error_response(
                    422,
                    request_id,
                    "invalid_ref_text",
                    "Normalized reference text must contain 20 to 240 characters",
                )
            synthesis = SpeechRequest(
                text=text,
                voice=DEFAULT_VOICE_ID,
                instruction=body.instruction,
                seed=body.seed,
                language=body.language,
                sample_rate=_SAMPLE_RATE,
            )
            async with services.governor.reserve(
                WorkClass.BATCH_TTS,
                expires_at=expires_at,
                resource_key=tts_resource_key(synthesizer, synthesis.voice),
            ):
                raw_wav = await _generate_reference(synthesizer, synthesis, expires_at=expires_at)
            raw_report = _grade_clone_audio(raw_wav)
            if raw_report.status == "reject":
                return _quality_reject_response(request_id, raw_report)
            # Validate before gain adjustment so clipping cannot be hidden by normalization.
            wav_bytes, duration = canonicalize_clone_reference_audio(raw_wav)
            report = _grade_clone_audio(wav_bytes)
            if report.status == "reject":
                return _quality_reject_response(request_id, report)
            await _evict_quality_tts_if_supported(synthesizer, expires_at=expires_at)
            stage = "transcription"
            with wave.open(io.BytesIO(wav_bytes), "rb") as wav:
                pcm = wav.readframes(wav.getnframes())
            asr_request = TranscriptionRequest(
                request_id=request_id,
                audio=_resample_quality_pcm_24k_to_16k(pcm),
                language=body.language,
                prompt="",
                include_timestamps=False,
            )
            async with services.governor.reserve(WorkClass.BATCH_ASR, expires_at=expires_at):
                remaining = expires_at - asyncio.get_running_loop().time()
                if remaining <= 0:
                    raise TimeoutError
                transcript = await services.admission.run(
                    partial(transcriber.transcribe, asr_request),
                    deadline=remaining,
                )
            score = vq.transcript_match_score(text, transcript.text)
            if score < _TRANSCRIPT_PASS_SCORE:
                return error_response(
                    400,
                    request_id,
                    "transcript_mismatch",
                    "Generated reference did not meet the transcript-match threshold",
                )
            report = vq.make_quality_report(
                replace(report.reference, transcript_match=score),
                _empty_synthesis(),
                transcript_match=score,
            )
            if asyncio.get_running_loop().time() >= expires_at:
                raise TimeoutError
            stage = "persistence"
            creation = VoiceCreation(
                model_artifact=design.key,
                model_revision=design.revision,
                seed=body.seed,
                instruction_sha256=hashlib.sha256(body.instruction.encode()).hexdigest(),
                reference_text_sha256=hashlib.sha256(text.encode()).hexdigest(),
                reference_audio_sha256=hashlib.sha256(wav_bytes).hexdigest(),
            )
            # Publication is the last step. No temporary custom profile or WAV is
            # exposed while TTS/ASR is running; create_only checks under the store lock.
            profile = registry.create_cloned_profile(
                name=body.name,
                ref_text=text,
                audio_bytes=wav_bytes,
                voice_id=body.id,
                duration_seconds=duration,
                quality=report.to_dict(),
                creation=creation,
                create_only=True,
            )
            return JSONResponse(
                status_code=201,
                content={
                    "voice": _voice_entry(profile, active, services.tts_ready),
                    "synthesis_validation": "unevaluated",
                },
            )
        except VoiceAlreadyExistsError:
            return error_response(
                409,
                request_id,
                "voice_already_exists",
                "Use a new target voice ID",
            )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Voice store is unavailable",
                retryable=True,
            )
        except (GovernorQueueFullError, QueueFullError, AsrModeBusy) as exc:
            response = error_response(
                429,
                request_id,
                "backend_busy" if isinstance(exc, AsrModeBusy) else "queue_full",
                "Speech resources are busy",
                retryable=True,
            )
            response.headers["Retry-After"] = "1"
            return response
        except TimeoutError:
            return error_response(
                503,
                request_id,
                "backend_timeout",
                "Voice registration timed out",
                retryable=True,
            )
        except (TTSDeliveryError, OverflowError):
            return error_response(
                502,
                request_id,
                "output_invalid",
                "Invalid or oversized reference audio",
            )
        except Exception:
            # Do not disclose vendor exception text, audio, prompts or private paths.
            code = {
                "generation": "backend_error",
                "transcription": "transcription_unavailable",
                "persistence": "voice_store_unavailable",
            }[stage]
            return error_response(
                502 if stage == "generation" else 503,
                request_id,
                code,
                "Voice registration could not complete",
                retryable=True,
            )

    return router
