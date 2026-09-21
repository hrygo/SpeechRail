"""Explicit prompt-to-reference registration; existing voices are never migrated."""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import io
import json
import wave
from dataclasses import replace
from functools import partial
from pathlib import Path
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
from speechrail.config.model_catalog import ModelArtifact
from speechrail.config.selection import active_model_catalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.idempotency import (
    DurableIdempotencyJournal,
    IdempotencyConflictError,
    IdempotencyStoreUnavailableError,
)
from speechrail.domain.ports import SpeechRequest, SpeechSynthesizer, TranscriptionRequest
from speechrail.domain.tts import (
    DEFAULT_VOICE_ID,
    SYSTEM_VOICE_PROFILES,
    VOICE_ALIASES,
    VoiceAlreadyExistsError,
    VoiceProfile,
    VoiceStoreUnavailableError,
    canonicalize_clone_reference_audio,
    get_voice_registry,
    normalize_tts_text,
)
from speechrail.domain.tts_errors import TTS_PARAMETER_ERROR_CODES, TtsBackendError
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
from speechrail.runtime.resource_governor import (
    GovernorQueueFullError,
    WorkClass,
    WorkPurpose,
)

_SAMPLE_RATE = 24_000
_MAX_REFERENCE_PCM_BYTES = 30 * _SAMPLE_RATE * 2
_DESIGN_IDEMPOTENCY_OWNER = "speechrail-local"
_DESIGN_IDEMPOTENCY_OPERATION = "voice.design"
_design_idempotency_journal = DurableIdempotencyJournal(
    Path.home() / ".speechrail" / "voice_design_idempotency.json",
    max_entries=128,
)


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


def _design_payload_fingerprint(body: VoiceDesignRegistrationRequest) -> str:
    payload = json.dumps(
        body.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(payload).hexdigest()


def _design_result_matches(
    profile: VoiceProfile,
    body: VoiceDesignRegistrationRequest,
    normalized_reference_text: str,
    artifact: ModelArtifact,
) -> bool:
    """Prove a recovered profile belongs to this idempotent design request."""

    creation = profile.creation
    return (
        profile.id == body.id
        and profile.mode == "clone"
        and profile.name == body.name.strip()
        and profile.ref_text == normalized_reference_text
        and creation is not None
        and creation.model_artifact == artifact.key
        and creation.model_revision == artifact.revision
        and creation.seed == body.seed
        and creation.instruction_sha256
        == hashlib.sha256(body.instruction.encode("utf-8")).hexdigest()
        and creation.reference_text_sha256
        == hashlib.sha256(normalized_reference_text.encode("utf-8")).hexdigest()
    )


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
        text = normalize_tts_text(body.reference_text)
        if not 20 <= len(text) <= 240:
            return error_response(
                422,
                request_id,
                "invalid_ref_text",
                "Normalized reference text must contain 20 to 240 characters",
            )

        idempotency_key = request.headers.get("Idempotency-Key")
        fingerprint = _design_payload_fingerprint(body) if idempotency_key else None
        journal_started = False
        if idempotency_key and fingerprint is not None:
            try:
                decision = _design_idempotency_journal.begin(
                    owner=_DESIGN_IDEMPOTENCY_OWNER,
                    operation=_DESIGN_IDEMPOTENCY_OPERATION,
                    key=idempotency_key,
                    fingerprint=fingerprint,
                    provisional_result_id=body.id,
                )
            except IdempotencyConflictError:
                return error_response(
                    409,
                    request_id,
                    "idempotency_conflict",
                    "Idempotency-Key was already used with a different voice-design payload",
                )
            except IdempotencyStoreUnavailableError:
                return error_response(
                    503,
                    request_id,
                    "idempotency_store_unavailable",
                    "Durable idempotency state is unavailable",
                    retryable=True,
                )
            journal_started = decision.state == "new"
            if decision.state in {"pending", "completed"}:
                result_id = decision.result_id
                if result_id is None:
                    return error_response(
                        409,
                        request_id,
                        "idempotency_pending",
                        "Previous voice-design operation has no recoverable result identity",
                        retryable=True,
                    )
                try:
                    recovered = registry.get_profile(result_id)
                except VoiceStoreUnavailableError:
                    return error_response(
                        503,
                        request_id,
                        "voice_store_unavailable",
                        "Voice store is unavailable",
                        retryable=True,
                    )
                except ValueError:
                    recovered = None
                if recovered is not None:
                    if not _design_result_matches(
                        recovered,
                        body,
                        text,
                        design,
                    ):
                        return error_response(
                            409,
                            request_id,
                            "voice_already_exists",
                            "Target voice ID is owned by a different design payload",
                        )
                    if decision.state == "pending":
                        try:
                            _design_idempotency_journal.complete(
                                owner=_DESIGN_IDEMPOTENCY_OWNER,
                                operation=_DESIGN_IDEMPOTENCY_OPERATION,
                                key=idempotency_key,
                                fingerprint=fingerprint,
                                result_id=recovered.id,
                            )
                        except IdempotencyStoreUnavailableError:
                            return error_response(
                                503,
                                request_id,
                                "idempotency_store_unavailable",
                                "Recovered voice exists but completion state could not be recorded",
                                retryable=True,
                            )
                    return JSONResponse(
                        status_code=201,
                        content={
                            "voice": _voice_entry(recovered, active, services.tts_ready),
                            "synthesis_validation": "unevaluated",
                        },
                    )
                if decision.state == "completed":
                    return error_response(
                        409,
                        request_id,
                        "idempotency_result_unavailable",
                        "The original idempotent voice-design result is no longer available",
                    )
                return error_response(
                    409,
                    request_id,
                    "idempotency_pending",
                    "Previous voice-design operation may have started but no result is visible yet",
                    retryable=True,
                )

        expires_at = asyncio.get_running_loop().time() + services.settings.request_timeout_seconds
        stage = "generation"
        publication_started = False
        try:
            try:
                registry.get_profile(body.id)
            except ValueError:
                pass
            else:
                raise VoiceAlreadyExistsError("target voice already exists")
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
                purpose=WorkPurpose.VOICE_CREATION,
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
            # Eviction is a group-level maintenance handoff: acquire the
            # governor's wildcard TTS lane so no keyed capability worker is
            # still active while the router closes its workers.
            async with services.governor.reserve(
                WorkClass.BATCH_TTS,
                expires_at=expires_at,
                purpose=WorkPurpose.VOICE_CREATION,
            ):
                await _evict_quality_tts_if_supported(
                    synthesizer,
                    expires_at=expires_at,
                )
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
            async with services.governor.reserve(
                WorkClass.BATCH_ASR,
                expires_at=expires_at,
                purpose=WorkPurpose.VOICE_CREATION,
            ):
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
            publication_started = True
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
            if idempotency_key and fingerprint is not None:
                try:
                    _design_idempotency_journal.complete(
                        owner=_DESIGN_IDEMPOTENCY_OWNER,
                        operation=_DESIGN_IDEMPOTENCY_OPERATION,
                        key=idempotency_key,
                        fingerprint=fingerprint,
                        result_id=profile.id,
                    )
                except IdempotencyStoreUnavailableError:
                    return error_response(
                        503,
                        request_id,
                        "idempotency_store_unavailable",
                        "Voice was published but durable completion state could not be recorded",
                        retryable=True,
                    )
            return JSONResponse(
                status_code=201,
                content={
                    "voice": _voice_entry(profile, active, services.tts_ready),
                    "synthesis_validation": "unevaluated",
                },
            )
        except VoiceAlreadyExistsError:
            if journal_started and idempotency_key and fingerprint is not None:
                with contextlib.suppress(IdempotencyStoreUnavailableError):
                    _design_idempotency_journal.abort(
                        owner=_DESIGN_IDEMPOTENCY_OWNER,
                        operation=_DESIGN_IDEMPOTENCY_OPERATION,
                        key=idempotency_key,
                        fingerprint=fingerprint,
                    )
                journal_started = False
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
        except TtsBackendError as exc:
            if exc.code in TTS_PARAMETER_ERROR_CODES:
                status_code = 400
            elif exc.public_code == "tts_initialization_failed":
                status_code = 503
            else:
                status_code = 502
            return error_response(
                status_code,
                request_id,
                exc.public_code,
                "TTS backend failed during voice reference generation",
                retryable=exc.retryable,
                diagnostic_class=exc.diagnostic_class,
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
        finally:
            if (
                journal_started
                and not publication_started
                and idempotency_key
                and fingerprint is not None
            ):
                with contextlib.suppress(IdempotencyStoreUnavailableError):
                    _design_idempotency_journal.abort(
                        owner=_DESIGN_IDEMPOTENCY_OWNER,
                        operation=_DESIGN_IDEMPOTENCY_OPERATION,
                        key=idempotency_key,
                        fingerprint=fingerprint,
                    )

    return router
