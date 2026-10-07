"""Voice-design candidate lifecycle; publication always follows Base validation."""

from __future__ import annotations

import asyncio
import hashlib
import io
import json
import logging
import time
import uuid
import wave
from collections.abc import Callable
from contextlib import suppress
from dataclasses import replace
from datetime import UTC, datetime
from functools import lru_cache
from pathlib import Path
from typing import Any, Literal

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator

from speechrail.application.candidate_validation import CandidateHumanReview
from speechrail.application.candidate_validation import (
    validate_candidate as run_candidate_validation,
)
from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import (
    TTSDeliveryError,
)
from speechrail.application.voice_design import (
    VoiceDesignActionError,
    VoiceDesignAssetUnavailableError,
    VoiceDesignCandidate,
    VoiceDesignCandidateUnavailableError,
    VoiceDesignConflictError,
    VoiceDesignNotFoundError,
    VoiceDesignRepository,
    VoiceDesignReview,
    VoiceDesignStoreUnavailableError,
    VoiceDesignValidationLimitError,
)
from speechrail.application.voice_validation_execution import (
    TRANSCRIPT_PASS_SCORE,
    ValidationRuntime,
    VoiceValidationExecutionError,
    empty_synthesis,
    grade_clone_audio,
)
from speechrail.application.voice_validation_execution import (
    collect_audio as _collect_audio_execution,
)
from speechrail.application.voice_validation_execution import (
    transcribe_pcm as _transcribe_pcm_execution,
)
from speechrail.config.selection import active_model_catalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.idempotency import (
    DurableIdempotencyJournal,
    IdempotencyConflictError,
    IdempotencyStoreUnavailableError,
)
from speechrail.domain.ports import (
    SpeechRequest,
    SpeechSynthesizer,
)
from speechrail.domain.tts import (
    DEFAULT_VOICE_ID,
    SYSTEM_VOICE_PROFILES,
    VOICE_ALIASES,
    VoiceAlreadyExistsError,
    VoiceStoreUnavailableError,
    canonicalize_clone_reference_audio,
    get_voice_registry,
    normalize_tts_text,
    voice_revision_for_clone,
)
from speechrail.domain.tts_errors import TtsBackendError
from speechrail.domain.tts_routing import TtsExecutionMode, tts_capability_key
from speechrail.domain.voice_creation import VoiceCreation
from speechrail.domain.voice_validation import (
    OUTPUT_VALIDATION_SCOPE,
    VOICE_DESIGN_OUTPUT_PROBE_SET,
    VoiceValidationStoreUnavailableError,
)
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import backend_reclamation_error_response, error_response
from speechrail.http.tts_errors import tts_backend_error_response
from speechrail.http.voice_projection import quality_reject_content, voice_entry
from speechrail.runtime.admission import QueueFullError
from speechrail.runtime.asr_mode import AsrModeBusy
from speechrail.runtime.resource_governor import (
    GovernorLaneIsolatedError,
    GovernorQueueFullError,
    WorkClass,
    WorkPurpose,
)

logger = logging.getLogger(__name__)

_SAMPLE_RATE = 24_000
_MAX_REFERENCE_PCM_BYTES = 30 * _SAMPLE_RATE * 2
_MAX_VALIDATION_PCM_BYTES = 30 * _SAMPLE_RATE * 2
_MAX_REFERENCE_WAV_BYTES = _MAX_REFERENCE_PCM_BYTES + 44
_MAX_VALIDATION_WAV_BYTES = _MAX_VALIDATION_PCM_BYTES + 44
_DESIGN_IDEMPOTENCY_OWNER = "speechrail-local"
_DESIGN_IDEMPOTENCY_OPERATION = "voice.design.candidate"


@lru_cache(maxsize=8)
def _journal_for_path(path: Path) -> DurableIdempotencyJournal:
    """Return the durable idempotency journal that owns one voice store."""

    return DurableIdempotencyJournal(path, max_entries=128)


def _design_idempotency_journal() -> DurableIdempotencyJournal:
    """Derive durable replay state beside the active voice registry.

    Deriving from the registry keeps tests and alternate app homes isolated
    instead of writing candidate replay state into the developer's real
    ``~/.speechrail`` directory.
    """

    registry = get_voice_registry()
    return _journal_for_path(registry.storage_path.with_name("voice_design_idempotency.json"))


class VoiceDesignCreateRequest(BaseModel):
    """Create one private candidate; no production voice is registered."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    voice_id: str = Field(pattern=r"^[a-z0-9_-]{1,64}$")
    name: str = Field(min_length=1, max_length=64)
    instruction: str = Field(min_length=1, max_length=10_000)
    reference_text: str = Field(min_length=20, max_length=240)
    seed: StrictInt = Field(default=42, ge=0, le=2**32 - 1)
    language: Literal["zh"] = "zh"

    @field_validator("voice_id")
    @classmethod
    def reject_reserved_id(cls, value: str) -> str:
        if value in SYSTEM_VOICE_PROFILES or value in VOICE_ALIASES:
            raise ValueError("reserved voice ID")
        return value


class VoiceDesignConfirmRequest(BaseModel):
    """Confirm or edit the reference text for the current audio."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    reference_text: str | None = Field(default=None, min_length=20, max_length=240)


class VoiceDesignHumanReview(BaseModel):
    """Explicit human audition result; machine metrics never fill this in."""

    model_config = ConfigDict(extra="forbid")

    validation_id: str = Field(pattern=r"^vv_[0-9a-f]{24}$")
    identity: VoiceDesignReview
    naturalness: VoiceDesignReview


class VoiceDesignValidateRequest(BaseModel):
    """Run Base new-text validation or attach a human review to its result."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    test_text: str | None = Field(default=None, min_length=20, max_length=240)
    capability_key: str | None = Field(
        default=None,
        pattern=r"^(fast|quality|reference)\.render$",
    )
    human_review: VoiceDesignHumanReview | None = None


class VoiceDesignPublishRequest(BaseModel):
    """Publish one exact candidate revision after validation."""

    model_config = ConfigDict(extra="forbid")

    expected_candidate_revision: str | None = Field(
        default=None,
        pattern=r"^vr_[0-9a-f]{32}$",
    )


def _candidate_id_for_key(key: str) -> str:
    digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
    return f"vd_{digest[:24]}"


def _payload_fingerprint(body: BaseModel) -> str:
    payload = json.dumps(
        body.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _repository() -> VoiceDesignRepository:
    registry = get_voice_registry()
    return VoiceDesignRepository(
        registry.storage_path.with_name("voice_design_candidates.json"),
        registry.storage_path.with_name("voice_design_candidates"),
    )


def _wav_from_pcm(pcm: bytes, *, sample_rate: int = _SAMPLE_RATE) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm)
    return output.getvalue()


async def _collect_audio(
    synthesizer: SpeechSynthesizer,
    synthesis: SpeechRequest,
    *,
    expires_at: float,
    design: bool,
    max_bytes: int,
    on_close_failure: Callable[[], None] | None = None,
) -> bytes:
    try:
        return await _collect_audio_execution(
            synthesizer,
            synthesis,
            expires_at=expires_at,
            design=design,
            max_bytes=max_bytes,
            on_close_failure=on_close_failure,
        )
    except VoiceValidationExecutionError as exc:
        raise VoiceDesignActionError(
            exc.code,
            str(exc),
            status_code=503,
            retryable=exc.retryable,
        ) from None


async def _transcribe_pcm(
    services: AppServices,
    pcm: bytes,
    *,
    language: str,
    expires_at: float,
) -> str:
    transcriber = services.batch_transcriber
    if transcriber is None:
        raise VoiceDesignActionError(
            "transcription_unavailable",
            "Voice design confirmation requires local Batch ASR",
            status_code=503,
            retryable=True,
        )
    try:
        return await _transcribe_pcm_execution(
            transcriber=transcriber,
            governor=services.governor,
            admission=services.admission,
            pcm=pcm,
            language=language,
            expires_at=expires_at,
            request_id_prefix="req_design",
            purpose=WorkPurpose.VOICE_CREATION,
        )
    except VoiceValidationExecutionError as exc:
        if exc.code != "transcription_unavailable":
            raise
        # Never surface vendor text: a local ASR failure is reported as one
        # stable, retryable unavailability code.
        raise VoiceDesignActionError(
            "transcription_unavailable",
            "Local Batch ASR failed while checking the reference",
            status_code=503,
            retryable=True,
        ) from exc


def _quality_error(request_id: str, report: vq.VoiceQualityReport) -> JSONResponse:
    status, content, headers = quality_reject_content(request_id, report)
    return JSONResponse(status_code=status, content=content, headers=headers)


def _safe_candidate(
    repository: VoiceDesignRepository,
    candidate: VoiceDesignCandidate,
) -> dict[str, Any]:
    return repository.safe_projection(candidate)


def _not_found(request_id: str, candidate_id: str) -> JSONResponse:
    return error_response(
        404,
        request_id,
        "voice_design_candidate_not_found",
        f"Voice design candidate {candidate_id!r} was not found",
    )


def _invalid_state(request_id: str, candidate: VoiceDesignCandidate) -> JSONResponse:
    return error_response(
        409,
        request_id,
        "voice_design_state_conflict",
        f"Candidate {candidate.candidate_id!r} is in state {candidate.state!r}",
    )


def _action_error(request_id: str, exc: VoiceDesignActionError) -> JSONResponse:
    return error_response(
        exc.status_code,
        request_id,
        exc.code,
        exc.message,
        retryable=exc.retryable,
    )


def _required_candidate_revision(
    request: Request,
    request_id: str,
) -> str | JSONResponse:
    revision = request.headers.get("SpeechRail-Expected-Candidate-Revision")
    if revision is None or not revision.strip():
        return error_response(
            428,
            request_id,
            "expected_candidate_revision_required",
            "SpeechRail-Expected-Candidate-Revision is required",
        )
    return revision


def _selected_capability_key(services: AppServices) -> str:
    tier = services.settings.selection_tts_spec or "quality"
    return tts_capability_key(tier, TtsExecutionMode.RENDER)


def _hash_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _candidate_for_request(
    body: VoiceDesignCreateRequest,
    *,
    candidate_id: str,
    reference_text: str,
    transcript: str,
    wav_bytes: bytes,
    duration_seconds: float,
    quality: dict[str, Any],
    design_artifact_key: str,
    design_revision: str,
    request_fingerprint: str,
    repository: VoiceDesignRepository,
) -> VoiceDesignCandidate:
    creation = VoiceCreation(
        model_artifact=design_artifact_key,
        model_revision=design_revision,
        seed=body.seed,
        instruction_sha256=_hash_text(body.instruction),
        reference_text_sha256=_hash_text(reference_text),
        reference_audio_sha256=hashlib.sha256(wav_bytes).hexdigest(),
    )
    revision = voice_revision_for_clone(
        ref_text=reference_text,
        audio_bytes=wav_bytes,
        creation=creation,
    )
    audio_path = repository.assets_dir / f"{candidate_id}.wav"
    now = time.time()
    return VoiceDesignCandidate(
        candidate_id=candidate_id,
        target_voice_id=body.voice_id,
        name=body.name,
        language=body.language,
        seed=body.seed,
        instruction_sha256=creation.instruction_sha256,
        reference_text=reference_text,
        reference_text_sha256=creation.reference_text_sha256,
        transcript=transcript,
        transcript_sha256=_hash_text(transcript),
        reference_audio_path=str(audio_path.resolve()),
        reference_audio_sha256=creation.reference_audio_sha256,
        duration_seconds=duration_seconds,
        quality=quality,
        source_model_artifact=design_artifact_key,
        source_model_revision=design_revision,
        creation=creation,
        revision=revision,
        request_fingerprint=request_fingerprint,
        state="generated",
        created_at=now,
        updated_at=now,
    )


def create_voice_design_router(services: AppServices) -> APIRouter:
    router = APIRouter(prefix="/v1/voice-designs", tags=["voice-design"])
    active = active_model_catalog(services.settings)

    @router.post(
        "",
        status_code=201,
        responses={200: {"description": ("Idempotent replay of an already created candidate")}},
    )
    async def create_candidate(
        request: Request,
        body: VoiceDesignCreateRequest,
    ) -> JSONResponse:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        design = active.voice_design
        if design is None or design.variant != "voice_design":
            tier_name = active.profile or "custom"
            return error_response(
                400,
                request_id,
                "voice_design_unsupported",
                (f"Active TTS selection ({tier_name}) does not provide the VoiceDesign capability"),
            )
        synthesizer = services.tts_synthesizer
        if synthesizer is None:
            return error_response(
                503,
                request_id,
                "voice_design_unavailable",
                "VoiceDesign worker is not available",
                retryable=True,
            )
        if services.batch_transcriber is None:
            return error_response(
                503,
                request_id,
                "transcription_unavailable",
                "Voice design confirmation requires local Batch ASR",
                retryable=True,
            )
        reference_text = normalize_tts_text(body.reference_text)
        if not 20 <= len(reference_text) <= 240:
            return error_response(
                422,
                request_id,
                "invalid_ref_text",
                "Normalized reference text must contain 20 to 240 characters",
            )
        registry = get_voice_registry()
        try:
            registry.get_profile(body.voice_id)
        except ValueError:
            pass
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Voice store is unavailable",
                retryable=True,
            )
        else:
            return error_response(
                409,
                request_id,
                "voice_already_exists",
                "Target voice ID already exists",
            )

        repository = _repository()
        journal = _design_idempotency_journal()
        idempotency_key = request.headers.get("Idempotency-Key")
        fingerprint = _payload_fingerprint(body)
        journal_started = False
        candidate_id = (
            _candidate_id_for_key(idempotency_key)
            if idempotency_key
            else f"vd_{uuid.uuid4().hex[:24]}"
        )
        if idempotency_key:
            try:
                decision = journal.begin(
                    owner=_DESIGN_IDEMPOTENCY_OWNER,
                    operation=_DESIGN_IDEMPOTENCY_OPERATION,
                    key=idempotency_key,
                    fingerprint=fingerprint,
                    provisional_result_id=candidate_id,
                )
            except IdempotencyConflictError:
                return error_response(
                    409,
                    request_id,
                    "idempotency_conflict",
                    "Idempotency-Key was already used with a different payload",
                )
            except IdempotencyStoreUnavailableError:
                return error_response(
                    503,
                    request_id,
                    "idempotency_store_unavailable",
                    "Durable idempotency state is unavailable",
                    retryable=True,
                )
            candidate_id = decision.result_id or candidate_id
            journal_started = decision.state == "new"
            if decision.state in {"pending", "completed"}:
                try:
                    existing_candidate = repository.get(candidate_id)
                except VoiceDesignNotFoundError:
                    existing_candidate = None
                if existing_candidate is not None:
                    if existing_candidate.request_fingerprint != fingerprint:
                        return error_response(
                            409,
                            request_id,
                            "idempotency_conflict",
                            "Candidate belongs to a different request payload",
                        )
                    return JSONResponse(
                        status_code=200,
                        content={"candidate": _safe_candidate(repository, existing_candidate)},
                    )
                if decision.state == "completed":
                    return error_response(
                        409,
                        request_id,
                        "idempotency_result_unavailable",
                        "The original candidate is no longer available",
                    )

        # A replay above returns the original candidate; only a genuinely new
        # request must prove the target voice ID is still unreserved.
        for existing in repository.list():
            if existing.target_voice_id == body.voice_id and existing.state not in {
                "cancelled",
                "failed",
                "published",
            }:
                return error_response(
                    409,
                    request_id,
                    "voice_design_target_in_use",
                    "Target voice ID is already reserved by another candidate",
                )

        expires_at = asyncio.get_running_loop().time() + services.settings.request_timeout_seconds
        try:
            synthesis = SpeechRequest(
                text=reference_text,
                voice=DEFAULT_VOICE_ID,
                instruction=body.instruction,
                seed=body.seed,
                language=body.language,
                sample_rate=_SAMPLE_RATE,
            )
            async with services.governor.reserve(
                WorkClass.BATCH_TTS,
                expires_at=expires_at,
                # The design lane owns its worker; a wildcard key would
                # serialize design behind every production render (#135).
                resource_key="voice_design",
                purpose=WorkPurpose.VOICE_CREATION,
            ):
                raw_pcm = await _collect_audio(
                    synthesizer,
                    synthesis,
                    expires_at=expires_at,
                    design=True,
                    max_bytes=_MAX_REFERENCE_PCM_BYTES,
                    on_close_failure=lambda: services.governor.quarantine_tts_lane("voice_design"),
                )
            if len(raw_pcm) < 2 * _SAMPLE_RATE * 2:
                raise TTSDeliveryError("voice_reference_too_short")
            raw_wav = _wav_from_pcm(raw_pcm)
            raw_report = grade_clone_audio(raw_wav)
            if raw_report.status == vq.VoiceQualityStatus.REJECT.value:
                return _quality_error(request_id, raw_report)
            wav_bytes, duration = canonicalize_clone_reference_audio(raw_wav)
            report = grade_clone_audio(wav_bytes)
            if report.status == vq.VoiceQualityStatus.REJECT.value:
                return _quality_error(request_id, report)

            with wave.open(io.BytesIO(wav_bytes), "rb") as wav:
                canonical_pcm = wav.readframes(wav.getnframes())
            # Production workers stay resident across design work: the design
            # lane idles out on its own TTL instead of evicting them (#135).
            transcript = await _transcribe_pcm(
                services,
                canonical_pcm,
                language=body.language,
                expires_at=expires_at,
            )
            score = vq.transcript_match_score(reference_text, transcript) if transcript else None
            if report.reference is None:
                # `grade_clone_audio` always grades against a real reference
                # block; a missing one is an internal invariant violation, not
                # a licence to synthesize placeholder metrics.
                return error_response(
                    502,
                    request_id,
                    "quality_reference_missing",
                    "Voice quality grading produced no reference block",
                    retryable=True,
                )
            reference = (
                report.reference
                if score is None
                else replace(
                    report.reference,
                    transcript_match=score,
                )
            )
            quality = vq.make_quality_report(
                reference,
                empty_synthesis(),
                transcript_match=score,
            ).to_dict()
            candidate = _candidate_for_request(
                body,
                candidate_id=candidate_id,
                reference_text=reference_text,
                transcript=transcript,
                wav_bytes=wav_bytes,
                duration_seconds=duration,
                quality=quality,
                design_artifact_key=design.key,
                design_revision=design.revision,
                request_fingerprint=fingerprint,
                repository=repository,
            )
            stored = repository.create(candidate, wav_bytes)
            if idempotency_key:
                journal.complete(
                    owner=_DESIGN_IDEMPOTENCY_OWNER,
                    operation=_DESIGN_IDEMPOTENCY_OPERATION,
                    key=idempotency_key,
                    fingerprint=fingerprint,
                    result_id=stored.candidate_id,
                )
            return JSONResponse(
                status_code=201,
                content={"candidate": _safe_candidate(repository, stored)},
            )
        except VoiceDesignConflictError:
            if idempotency_key:
                try:
                    stored = repository.get(candidate_id)
                except VoiceDesignNotFoundError, VoiceDesignStoreUnavailableError:
                    stored = None
                if stored is not None and stored.request_fingerprint == fingerprint:
                    return JSONResponse(
                        status_code=200,
                        content={"candidate": _safe_candidate(repository, stored)},
                    )
            return error_response(
                409,
                request_id,
                "voice_design_candidate_conflict",
                "Candidate identity is already in use",
            )
        except GovernorLaneIsolatedError:
            return backend_reclamation_error_response(request_id)
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
                "VoiceDesign candidate generation timed out",
                retryable=True,
            )
        except TtsBackendError as exc:
            backend_response = tts_backend_error_response(
                request_id, exc, worker_role="voice_design"
            )
            assert backend_response is not None
            return backend_response
        except VoiceDesignActionError as exc:
            return _action_error(request_id, exc)
        except IdempotencyStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "idempotency_store_unavailable",
                "Durable idempotency state is unavailable",
                retryable=True,
            )
        except TTSDeliveryError, OverflowError, ValueError:
            logger.exception(
                "voice design candidate generation produced invalid output",
                extra={"speechrail": {"request_id": request_id}},
            )
            return error_response(
                502,
                request_id,
                "output_invalid",
                "Invalid or oversized candidate audio",
            )
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )
        finally:
            if journal_started and idempotency_key:
                try:
                    repository.get(candidate_id)
                except VoiceDesignNotFoundError, VoiceDesignStoreUnavailableError:
                    with suppress(IdempotencyStoreUnavailableError):
                        journal.abort(
                            owner=_DESIGN_IDEMPOTENCY_OWNER,
                            operation=_DESIGN_IDEMPOTENCY_OPERATION,
                            key=idempotency_key,
                            fingerprint=fingerprint,
                        )

    @router.get("", response_model=None)
    async def list_candidates(request: Request) -> dict[str, Any] | JSONResponse:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        try:
            repository = _repository()
            return {
                "object": "list",
                "data": [_safe_candidate(repository, candidate) for candidate in repository.list()],
            }
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )

    @router.get("/{candidate_id}")
    async def get_candidate(candidate_id: str, request: Request) -> JSONResponse:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        try:
            repository = _repository()
            candidate = repository.get(candidate_id)
        except VoiceDesignNotFoundError:
            return _not_found(request_id, candidate_id)
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )
        return JSONResponse(
            status_code=200,
            content={"candidate": _safe_candidate(repository, candidate)},
        )

    @router.get("/{candidate_id}/audio")
    async def get_candidate_reference_audio(
        candidate_id: str,
        request: Request,
    ) -> Response:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        expected_revision = _required_candidate_revision(request, request_id)
        if isinstance(expected_revision, JSONResponse):
            return expected_revision
        try:
            _candidate, audio_bytes = _repository().read_reference_audio(
                candidate_id,
                expected_revision=expected_revision,
                max_bytes=_MAX_REFERENCE_WAV_BYTES,
            )
            return Response(
                content=audio_bytes,
                media_type="audio/wav",
                headers={"Cache-Control": "no-store"},
            )
        except VoiceDesignNotFoundError:
            return _not_found(request_id, candidate_id)
        except VoiceDesignCandidateUnavailableError:
            return error_response(
                409,
                request_id,
                "voice_design_candidate_unavailable",
                "Candidate is cancelled or invalid and can no longer be reviewed",
            )
        except VoiceDesignConflictError:
            return error_response(
                409,
                request_id,
                "voice_design_revision_conflict",
                "Candidate revision changed or its reference is no longer available",
            )
        except VoiceDesignAssetUnavailableError:
            return error_response(
                409,
                request_id,
                "reference_audio_unavailable",
                "The candidate reference audio is unavailable or does not match its record",
            )
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )

    @router.get("/{candidate_id}/validations/{validation_id}/audio")
    async def get_candidate_validation_audio(
        candidate_id: str,
        validation_id: str,
        request: Request,
    ) -> Response:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        expected_revision = _required_candidate_revision(request, request_id)
        if isinstance(expected_revision, JSONResponse):
            return expected_revision
        try:
            _candidate, audio_bytes = _repository().read_validation_audio(
                candidate_id,
                validation_id,
                expected_revision=expected_revision,
                max_bytes=_MAX_VALIDATION_WAV_BYTES,
            )
            return Response(
                content=audio_bytes,
                media_type="audio/wav",
                headers={"Cache-Control": "no-store"},
            )
        except VoiceDesignNotFoundError as exc:
            if str(exc) == candidate_id:
                return _not_found(request_id, candidate_id)
            return error_response(
                404,
                request_id,
                "voice_design_validation_not_found",
                "Validation result was not found for this candidate",
            )
        except VoiceDesignCandidateUnavailableError:
            return error_response(
                409,
                request_id,
                "voice_design_candidate_unavailable",
                "Candidate is cancelled or invalid and can no longer be reviewed",
            )
        except VoiceDesignConflictError:
            return error_response(
                409,
                request_id,
                "voice_design_revision_conflict",
                "Candidate revision changed",
            )
        except VoiceDesignAssetUnavailableError:
            return error_response(
                409,
                request_id,
                "validation_audio_unavailable",
                "This validation WAV is unavailable or does not match its record",
            )
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )

    @router.post("/{candidate_id}/confirm")
    async def confirm_candidate(
        candidate_id: str,
        request: Request,
        body: VoiceDesignConfirmRequest,
    ) -> JSONResponse:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        try:
            repository = _repository()
            candidate = repository.get(candidate_id)
            if candidate.state == "published":
                return JSONResponse(
                    status_code=200,
                    content={"candidate": _safe_candidate(repository, candidate)},
                )
            if candidate.state in {"cancelled", "failed"}:
                return _invalid_state(request_id, candidate)
            text = (
                normalize_tts_text(body.reference_text)
                if body.reference_text is not None
                else candidate.reference_text
            )
            if not 20 <= len(text) <= 240:
                return error_response(
                    422,
                    request_id,
                    "invalid_ref_text",
                    "Normalized reference text must contain 20 to 240 characters",
                )
            expected_state = candidate.state
            candidate, audio_bytes = await asyncio.to_thread(
                repository.read_reference_audio,
                candidate_id,
                expected_revision=candidate.revision,
                max_bytes=_MAX_REFERENCE_WAV_BYTES,
            )
            if candidate.state != expected_state:
                raise VoiceDesignConflictError("candidate state changed")
            with wave.open(io.BytesIO(audio_bytes), "rb") as wav:
                pcm = wav.readframes(wav.getnframes())
            expires_at = (
                asyncio.get_running_loop().time() + services.settings.request_timeout_seconds
            )
            transcript = await _transcribe_pcm(
                services,
                pcm,
                language=candidate.language,
                expires_at=expires_at,
            )
            score = vq.transcript_match_score(text, transcript)
            if score < TRANSCRIPT_PASS_SCORE or not vq.transcript_numbers_match(text, transcript):
                return error_response(
                    400,
                    request_id,
                    "transcript_mismatch",
                    "Candidate reference did not meet the text-fidelity requirements",
                )
            changed = text != candidate.reference_text
            if changed:
                # An edited transcript is a new acoustic identity: the
                # provenance hash must move with the text or publication would
                # (correctly) refuse the mismatch later.
                creation = candidate.creation.model_copy(
                    update={"reference_text_sha256": _hash_text(text)}
                )
                revision = voice_revision_for_clone(
                    ref_text=text,
                    audio_bytes=audio_bytes,
                    creation=creation,
                )
            else:
                creation = candidate.creation
                revision = candidate.revision
            now = time.time()

            def confirm(current: VoiceDesignCandidate) -> VoiceDesignCandidate:
                if current.revision != candidate.revision or current.state != candidate.state:
                    raise VoiceDesignConflictError("candidate revision or state changed")
                return current.model_copy(
                    update={
                        "reference_text": text,
                        "reference_text_sha256": _hash_text(text),
                        "transcript": transcript,
                        "transcript_sha256": _hash_text(transcript),
                        "creation": creation,
                        "revision": revision,
                        "validations": [] if changed else current.validations,
                        "state": "confirmed",
                        "confirmed_at": now,
                        "updated_at": now,
                    }
                )

            updated = repository.update(candidate.candidate_id, confirm)
            return JSONResponse(
                status_code=200,
                content={"candidate": _safe_candidate(repository, updated)},
            )
        except VoiceDesignNotFoundError:
            return _not_found(request_id, candidate_id)
        except VoiceDesignConflictError:
            return error_response(
                409,
                request_id,
                "voice_design_revision_conflict",
                "Candidate changed while it was being confirmed",
            )
        except VoiceDesignActionError as exc:
            return _action_error(request_id, exc)
        except VoiceDesignAssetUnavailableError:
            return error_response(
                409,
                request_id,
                "reference_audio_unavailable",
                "The candidate reference audio is unavailable or does not match its record",
            )
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )
        except GovernorLaneIsolatedError:
            return backend_reclamation_error_response(request_id)
        except GovernorQueueFullError, QueueFullError, AsrModeBusy:
            return error_response(
                429,
                request_id,
                "backend_busy",
                "Speech resources are busy",
                retryable=True,
            )
        except TimeoutError:
            # TimeoutError is an OSError subclass, so it has to be classified
            # before the data-error branch below: a worker exchange that ran out
            # of time is retryable, not an invalid candidate.
            return error_response(
                503,
                request_id,
                "backend_timeout",
                "Candidate confirmation timed out",
                retryable=True,
            )
        except OSError, ValueError, TTSDeliveryError:
            logger.exception(
                "voice design candidate confirmation failed",
                extra={"speechrail": {"request_id": request_id}},
            )
            return error_response(
                422,
                request_id,
                "voice_design_candidate_invalid",
                "Candidate reference could not be confirmed",
            )

    @router.post("/{candidate_id}/validate")
    async def validate_candidate(
        candidate_id: str,
        request: Request,
        body: VoiceDesignValidateRequest,
    ) -> JSONResponse:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        try:
            repository = _repository()
            updated = await run_candidate_validation(
                repository=repository,
                candidate_id=candidate_id,
                active=active,
                runtime=ValidationRuntime(
                    synthesizer=services.tts_synthesizer,
                    transcriber=services.batch_transcriber,
                    governor=services.governor,
                    admission=services.admission,
                    tts_ready=services.tts_ready,
                    asr_ready=services.asr_ready,
                ),
                selected_capability_key=_selected_capability_key(services),
                requested_capability_key=body.capability_key,
                test_text=body.test_text,
                human_review=(
                    CandidateHumanReview(
                        validation_id=body.human_review.validation_id,
                        identity=body.human_review.identity,
                        naturalness=body.human_review.naturalness,
                    )
                    if body.human_review is not None
                    else None
                ),
                expires_at=asyncio.get_running_loop().time()
                + services.settings.request_timeout_seconds,
            )
            return JSONResponse(
                status_code=200,
                content={"candidate": _safe_candidate(repository, updated)},
            )
        except VoiceDesignNotFoundError:
            return _not_found(request_id, candidate_id)
        except VoiceDesignValidationLimitError:
            return error_response(
                409,
                request_id,
                "voice_design_validation_limit_reached",
                ("This candidate already retains the maximum number of validation results"),
            )
        except VoiceDesignConflictError:
            return error_response(
                409,
                request_id,
                "voice_design_revision_conflict",
                "Candidate changed while validation was running",
            )
        except VoiceDesignAssetUnavailableError:
            return error_response(
                409,
                request_id,
                "validation_audio_unavailable",
                "Validation audio is unavailable or conflicts with its stored identity",
            )
        except VoiceDesignActionError as exc:
            return _action_error(request_id, exc)
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )
        except VoiceValidationExecutionError as exc:
            return error_response(
                503,
                request_id,
                exc.code,
                str(exc),
                retryable=exc.retryable,
            )
        except GovernorLaneIsolatedError:
            return backend_reclamation_error_response(request_id)
        except GovernorQueueFullError, QueueFullError, AsrModeBusy:
            return error_response(
                429,
                request_id,
                "backend_busy",
                "Speech resources are busy",
                retryable=True,
            )
        except TimeoutError:
            return error_response(
                503,
                request_id,
                "backend_timeout",
                "VoiceDesign validation timed out",
                retryable=True,
            )
        except TtsBackendError as exc:
            response = tts_backend_error_response(request_id, exc, worker_role="tts_base")
            assert response is not None
            return response
        except (OSError, ValueError, TTSDeliveryError, OverflowError) as exc:
            logger.warning(
                "voice design Base validation failed: code=output_invalid "
                "request_id=%s exception_type=%s",
                request_id,
                type(exc).__name__,
            )
            return error_response(
                502,
                request_id,
                "output_invalid",
                "Base validation output was invalid",
            )

    @router.post(
        "/{candidate_id}/publish",
        status_code=201,
        responses={200: {"description": "The candidate was already published"}},
    )
    async def publish_candidate(
        candidate_id: str,
        request: Request,
        body: VoiceDesignPublishRequest,
    ) -> JSONResponse:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        try:
            repository = _repository()
            candidate = repository.get(candidate_id)
            if body.expected_candidate_revision is not None and (
                body.expected_candidate_revision != candidate.revision
            ):
                return error_response(
                    409,
                    request_id,
                    "voice_design_revision_conflict",
                    "Candidate revision changed before publication",
                )
            if candidate.state == "published":
                profile = get_voice_registry().get_profile(candidate.target_voice_id)
                return JSONResponse(
                    status_code=200,
                    content={
                        "candidate": _safe_candidate(repository, candidate),
                        "voice": voice_entry(
                            profile,
                            active,
                            services.tts_ready,
                            synthesizer=services.tts_synthesizer,
                            strict_validation=True,
                        ),
                    },
                )
            if candidate.state != "validating" and candidate.state != "publishable":
                return _invalid_state(request_id, candidate)
            validation = candidate.passing_validation()
            if validation is None:
                return error_response(
                    409,
                    request_id,
                    "voice_design_validation_required",
                    "Publication requires a complete Base and human validation pass",
                )

            expected_state = candidate.state
            candidate, audio_bytes = await asyncio.to_thread(
                repository.read_reference_audio,
                candidate_id,
                expected_revision=candidate.revision,
                max_bytes=_MAX_REFERENCE_WAV_BYTES,
            )
            if candidate.state == "published":
                profile = get_voice_registry().get_profile(candidate.target_voice_id)
                return JSONResponse(
                    status_code=200,
                    content={
                        "candidate": _safe_candidate(repository, candidate),
                        "voice": voice_entry(
                            profile,
                            active,
                            services.tts_ready,
                            synthesizer=services.tts_synthesizer,
                            strict_validation=True,
                        ),
                    },
                )
            current_validation = candidate.passing_validation()
            if (
                candidate.state != expected_state
                or current_validation is None
                or current_validation.validation_id != validation.validation_id
            ):
                raise VoiceDesignConflictError("candidate state or validation changed")

            registry = get_voice_registry()
            validation_record = {
                "voice_id": candidate.target_voice_id,
                "voice_revision": candidate.revision,
                "status": "pass",
                "identity_status": validation.identity_status,
                "run_id": validation.validation_id,
                "tested_at": datetime.now(UTC).isoformat(),
                "policy_version": validation.policy_version,
                "model_artifact": validation.model_artifact,
                "model_variant": "base",
                "model_catalog_revision": validation.model_catalog_revision,
                "model_runtime_revision": validation.model_runtime_revision,
                "runtime_fingerprint": validation.runtime_fingerprint,
                "preprocess_version": validation.preprocess_version,
                "generation_recipe_revision": validation.generation_recipe_revision,
                "capability_key": validation.capability_key,
                "probe_set": VOICE_DESIGN_OUTPUT_PROBE_SET,
                "repetitions": 1,
                "failure_codes": [],
                "validated_for": [OUTPUT_VALIDATION_SCOPE],
            }
            registry.validation_store.put(validation_record)
            profile_holder: list[Any] = []

            def publish(current: VoiceDesignCandidate) -> VoiceDesignCandidate:
                current_validation = current.passing_validation()
                if (
                    current.revision != candidate.revision
                    or current.state != candidate.state
                    or current_validation is None
                    or current_validation.validation_id != validation.validation_id
                ):
                    raise VoiceDesignConflictError(
                        "candidate revision, state, or validation changed"
                    )
                try:
                    profile = registry.create_cloned_profile(
                        name=current.name,
                        ref_text=current.reference_text,
                        audio_bytes=audio_bytes,
                        voice_id=current.target_voice_id,
                        duration_seconds=current.duration_seconds,
                        quality=current.quality,
                        creation=current.creation,
                        create_only=True,
                    )
                except VoiceAlreadyExistsError:
                    profile = registry.get_profile(current.target_voice_id)
                    if profile.revision != current.revision:
                        raise VoiceDesignConflictError(
                            "target voice exists with a different revision"
                        ) from None
                if profile.revision != current.revision:
                    raise VoiceDesignConflictError(
                        "published voice revision does not match candidate"
                    )
                profile_holder.append(profile)
                now = time.time()
                return current.model_copy(
                    update={
                        "state": "published",
                        "published_at": now,
                        "published_voice_revision": profile.revision,
                        "updated_at": now,
                    }
                )

            published = repository.update(candidate_id, publish)
            profile = profile_holder[-1]
            return JSONResponse(
                status_code=201,
                content={
                    "candidate": _safe_candidate(repository, published),
                    "voice": voice_entry(
                        profile,
                        active,
                        services.tts_ready,
                        synthesizer=services.tts_synthesizer,
                        strict_validation=True,
                    ),
                },
            )
        except VoiceDesignNotFoundError:
            return _not_found(request_id, candidate_id)
        except VoiceDesignConflictError:
            return error_response(
                409,
                request_id,
                "voice_design_publish_conflict",
                "Candidate or target voice changed before publication",
            )
        except VoiceDesignAssetUnavailableError:
            return error_response(
                409,
                request_id,
                "reference_audio_unavailable",
                "The candidate reference audio is unavailable or does not match its record",
            )
        except (
            VoiceStoreUnavailableError,
            VoiceValidationStoreUnavailableError,
            VoiceDesignStoreUnavailableError,
        ):
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice publication store is unavailable",
                retryable=True,
            )
        except OSError, ValueError:
            logger.exception(
                "voice design candidate publication failed",
                extra={"speechrail": {"request_id": request_id}},
            )
            return error_response(
                422,
                request_id,
                "voice_design_publish_invalid",
                "Candidate assets could not be published",
            )

    @router.post("/{candidate_id}/cancel")
    async def cancel_candidate(candidate_id: str, request: Request) -> JSONResponse:
        request_id = request.state.request_id
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        try:
            repository = _repository()
            candidate = repository.get(candidate_id)
            if candidate.state == "published":
                return _invalid_state(request_id, candidate)
            now = time.time()
            cancelled = repository.update(
                candidate_id,
                lambda current: current.model_copy(
                    update={"state": "cancelled", "updated_at": now}
                ),
            )
        except VoiceDesignNotFoundError:
            return _not_found(request_id, candidate_id)
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )
        return JSONResponse(
            status_code=200,
            content={"candidate": _safe_candidate(repository, cancelled)},
        )

    return router


__all__ = [
    "VoiceDesignConfirmRequest",
    "VoiceDesignCreateRequest",
    "VoiceDesignPublishRequest",
    "VoiceDesignValidateRequest",
    "create_voice_design_router",
]
