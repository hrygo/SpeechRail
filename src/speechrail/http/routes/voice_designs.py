"""Voice-design candidate lifecycle; publication always follows Base validation."""

from __future__ import annotations

import asyncio
import hashlib
import io
import json
import time
import uuid
import wave
from contextlib import suppress
from dataclasses import replace
from datetime import UTC, datetime
from functools import lru_cache, partial
from pathlib import Path
from typing import Any, Literal

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field, StrictInt, field_validator

from speechrail.application.render_receipts import observed_runtime_revision_for_synthesizer
from speechrail.application.services import AppServices
from speechrail.application.tts_admission import tts_resource_key
from speechrail.application.tts_delivery import (
    PcmOutputCounter,
    TTSDeliveryError,
    iter_until,
    iter_validated_audio,
)
from speechrail.application.voice_design import (
    VoiceDesignActionError,
    VoiceDesignCandidate,
    VoiceDesignConflictError,
    VoiceDesignNotFoundError,
    VoiceDesignRepository,
    VoiceDesignReview,
    VoiceDesignStoreUnavailableError,
    VoiceDesignValidation,
)
from speechrail.application.voice_validation_gate import build_validation_binding
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
    TranscriptionRequest,
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
    use_voice_profile,
    voice_revision_for_clone,
)
from speechrail.domain.tts_errors import TTS_PARAMETER_ERROR_CODES, TtsBackendError
from speechrail.domain.tts_routing import TtsExecutionMode, tts_capability_key
from speechrail.domain.voice_creation import VoiceCreation
from speechrail.domain.voice_validation import VoiceValidationStoreUnavailableError
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
_MAX_VALIDATION_PCM_BYTES = 30 * _SAMPLE_RATE * 2
# Server-controlled audition texts. Clients may always pass their own test_text,
# but a simple client cannot silently re-use the reference text as its own
# evidence: the server substitutes a distinct controlled text when it is absent.
_CONTROLLED_TEST_TEXTS = (
    "今天的天气很适合在公园里慢慢散步，听听周围自然的声音。",
    "请用平稳自然的语气朗读这句话，注意每个字的清晰程度。",
    "生活里的小事往往最值得记录，比如清晨第一缕阳光照进房间。",
)
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
    return _journal_for_path(
        registry.storage_path.with_name("voice_design_idempotency.json")
    )


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
) -> bytes:
    counter = PcmOutputCounter(max_bytes)
    pcm = bytearray()
    if design:
        method = getattr(synthesizer, "synthesize_design", None)
        source = method(synthesis) if callable(method) else synthesizer.synthesize(synthesis)
    else:
        source = synthesizer.synthesize(synthesis)
    stream = iter_until(iter_validated_audio(source), expires_at)
    try:
        async for chunk in stream:
            counter.accept(len(chunk.audio))
            pcm.extend(chunk.audio)
    finally:
        close = getattr(stream, "aclose", None)
        if close is not None:
            await close()
    return bytes(pcm)


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
    request = TranscriptionRequest(
        request_id=f"req_design_{uuid.uuid4().hex}",
        audio=_resample_quality_pcm_24k_to_16k(pcm),
        language=language,
        prompt="",
        include_timestamps=False,
    )
    try:
        async with services.governor.reserve(
            WorkClass.BATCH_ASR,
            expires_at=expires_at,
            purpose=WorkPurpose.VOICE_CREATION,
        ):
            remaining = expires_at - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError
            result = await services.admission.run(
                partial(transcriber.transcribe, request),
                deadline=remaining,
            )
    except (GovernorQueueFullError, QueueFullError, AsrModeBusy, TimeoutError):
        raise
    except Exception as exc:
        # Never surface vendor text: a local ASR failure is reported as one
        # stable, retryable unavailability code.
        raise VoiceDesignActionError(
            "transcription_unavailable",
            "Local Batch ASR failed while checking the reference",
            status_code=503,
            retryable=True,
        ) from exc
    return result.text


def _quality_error(request_id: str, report: vq.VoiceQualityReport) -> JSONResponse:
    return _quality_reject_response(request_id, report)


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


def _selected_capability_key(services: AppServices) -> str:
    tier = services.settings.selection_tts_spec or "quality"
    return tts_capability_key(tier, TtsExecutionMode.RENDER)


def _hash_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _validation_id(
    *,
    candidate_revision: str,
    capability_key: str,
    test_text_sha256: str,
) -> str:
    digest = hashlib.sha256(
        json.dumps(
            {
                "candidate_revision": candidate_revision,
                "capability_key": capability_key,
                "test_text_sha256": test_text_sha256,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    return f"vv_{digest[:24]}"


def _candidate_validation(
    *,
    candidate: VoiceDesignCandidate,
    capability_key: str,
    test_text: str,
    output_pcm: bytes,
    quality: vq.VoiceQualityReport,
    transcript: str | None,
    transcript_match: float | None,
    model_artifact: str,
    model_catalog_revision: str,
    model_runtime_revision: str | None,
    runtime_fingerprint: str | None,
    preprocess_version: str,
    generation_recipe_revision: str,
    policy_version: str,
) -> VoiceDesignValidation:
    test_text_sha256 = _hash_text(test_text)
    validation_id = _validation_id(
        candidate_revision=candidate.revision,
        capability_key=capability_key,
        test_text_sha256=test_text_sha256,
    )
    failures: list[str] = []
    machine_status: Literal["pass", "warn", "reject"]
    if quality.status == vq.VoiceQualityStatus.REJECT.value:
        machine_status = "reject"
        failures.append("output_invalid")
    elif transcript_match is None:
        machine_status = "warn"
        failures.append("transcription_unavailable")
    elif transcript_match >= _TRANSCRIPT_PASS_SCORE:
        machine_status = "pass"
    elif transcript_match >= 0.80:
        machine_status = "warn"
        failures.append("transcript_warn")
    else:
        machine_status = "reject"
        failures.append("transcript_mismatch")
    if model_runtime_revision is None or runtime_fingerprint is None:
        machine_status = "warn" if machine_status != "reject" else machine_status
        failures.append("model_runtime_identity_unknown")
    now = time.time()
    return VoiceDesignValidation(
        validation_id=validation_id,
        candidate_revision=candidate.revision,
        status="warn",
        machine_status=machine_status,
        failure_codes=failures,
        capability_key=capability_key,
        model_artifact=model_artifact,
        model_catalog_revision=model_catalog_revision,
        model_runtime_revision=model_runtime_revision,
        runtime_fingerprint=runtime_fingerprint,
        preprocess_version=preprocess_version,
        generation_recipe_revision=generation_recipe_revision,
        policy_version=policy_version,
        test_text_sha256=test_text_sha256,
        output_audio_sha256=hashlib.sha256(output_pcm).hexdigest(),
        transcript_text_sha256=(
            _hash_text(transcript) if transcript is not None else None
        ),
        transcript_match=transcript_match,
        created_at=now,
        updated_at=now,
    )


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

    @router.post("", status_code=201)
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
                (
                    f"Active TTS selection ({tier_name}) does not provide the "
                    "VoiceDesign capability"
                ),
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
                        content={
                            "candidate": _safe_candidate(repository, existing_candidate)
                        },
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
            if (
                existing.target_voice_id == body.voice_id
                and existing.state not in {"cancelled", "failed", "published"}
            ):
                return error_response(
                    409,
                    request_id,
                    "voice_design_target_in_use",
                    "Target voice ID is already reserved by another candidate",
                )

        expires_at = (
            asyncio.get_running_loop().time()
            + services.settings.request_timeout_seconds
        )
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
                resource_key="tts",
                purpose=WorkPurpose.VOICE_CREATION,
            ):
                raw_pcm = await _collect_audio(
                    synthesizer,
                    synthesis,
                    expires_at=expires_at,
                    design=True,
                    max_bytes=_MAX_REFERENCE_PCM_BYTES,
                )
            if len(raw_pcm) < 2 * _SAMPLE_RATE * 2:
                raise TTSDeliveryError("voice_reference_too_short")
            raw_wav = _wav_from_pcm(raw_pcm)
            raw_report = _grade_clone_audio(raw_wav)
            if raw_report.status == vq.VoiceQualityStatus.REJECT.value:
                return _quality_error(request_id, raw_report)
            wav_bytes, duration = canonicalize_clone_reference_audio(raw_wav)
            report = _grade_clone_audio(wav_bytes)
            if report.status == vq.VoiceQualityStatus.REJECT.value:
                return _quality_error(request_id, report)

            with wave.open(io.BytesIO(wav_bytes), "rb") as wav:
                canonical_pcm = wav.readframes(wav.getnframes())
            async with services.governor.reserve(
                WorkClass.BATCH_TTS,
                expires_at=expires_at,
                purpose=WorkPurpose.VOICE_CREATION,
            ):
                await _evict_quality_tts_if_supported(
                    synthesizer,
                    expires_at=expires_at,
                )
            transcript = await _transcribe_pcm(
                services,
                canonical_pcm,
                language=body.language,
                expires_at=expires_at,
            )
            score = (
                vq.transcript_match_score(reference_text, transcript)
                if transcript
                else None
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
                _empty_synthesis(),
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
                except (VoiceDesignNotFoundError, VoiceDesignStoreUnavailableError):
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
            status_code = 400 if exc.code in TTS_PARAMETER_ERROR_CODES else 502
            if exc.public_code == "tts_initialization_failed":
                status_code = 503
            return error_response(
                status_code,
                request_id,
                exc.public_code,
                "TTS backend failed during candidate generation",
                retryable=exc.retryable,
                diagnostic_class=exc.diagnostic_class,
            )
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
        except (TTSDeliveryError, OverflowError, ValueError):
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
                except (VoiceDesignNotFoundError, VoiceDesignStoreUnavailableError):
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
                "data": [
                    _safe_candidate(repository, candidate)
                    for candidate in repository.list()
                ],
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
            audio_bytes = await asyncio.to_thread(
                Path(candidate.reference_audio_path).read_bytes
            )
            with wave.open(io.BytesIO(audio_bytes), "rb") as wav:
                pcm = wav.readframes(wav.getnframes())
            expires_at = (
                asyncio.get_running_loop().time()
                + services.settings.request_timeout_seconds
            )
            transcript = await _transcribe_pcm(
                services,
                pcm,
                language=candidate.language,
                expires_at=expires_at,
            )
            score = vq.transcript_match_score(text, transcript)
            if score < _TRANSCRIPT_PASS_SCORE:
                return error_response(
                    400,
                    request_id,
                    "transcript_mismatch",
                    "Candidate reference did not meet the transcript-match threshold",
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
                if current.revision != candidate.revision:
                    raise VoiceDesignConflictError("candidate revision changed")
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
        except VoiceDesignStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_design_store_unavailable",
                "Voice design store is unavailable",
                retryable=True,
            )
        except (GovernorQueueFullError, QueueFullError, AsrModeBusy):
            return error_response(
                429,
                request_id,
                "backend_busy",
                "Speech resources are busy",
                retryable=True,
            )
        except (OSError, ValueError, TTSDeliveryError):
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
            candidate = repository.get(candidate_id)
            if candidate.state == "published":
                return _invalid_state(request_id, candidate)
            if candidate.state in {"generated", "cancelled", "failed"}:
                return _invalid_state(request_id, candidate)
            capability_key = body.capability_key or _selected_capability_key(services)
            now = time.time()
            if body.human_review is not None:
                review = body.human_review
                current_validation = next(
                    (
                        item
                        for item in candidate.validations
                        if item.validation_id == review.validation_id
                    ),
                    None,
                )
                if current_validation is None:
                    return error_response(
                        404,
                        request_id,
                        "voice_design_validation_not_found",
                        "Validation result was not found for this candidate",
                    )
                if current_validation.candidate_revision != candidate.revision:
                    return error_response(
                        409,
                        request_id,
                        "voice_design_revision_conflict",
                        "Validation belongs to an older candidate revision",
                    )
                if current_validation.machine_status != "pass":
                    return error_response(
                        409,
                        request_id,
                        "voice_design_machine_validation_required",
                        (
                            "Human review can only follow a passing Base "
                            "validation for this candidate revision"
                        ),
                    )
                status: Literal["pass", "warn", "reject"]
                if "reject" in {review.identity, review.naturalness}:
                    status = "reject"
                elif (
                    review.identity == "pass"
                    and review.naturalness == "pass"
                    and current_validation.runtime_fingerprint is not None
                ):
                    status = "pass"
                else:
                    status = "warn"
                reviewed = current_validation.model_copy(
                    update={
                        "identity_status": review.identity,
                        "naturalness_status": review.naturalness,
                        "status": status,
                        "updated_at": now,
                    }
                )
                validations = [
                    reviewed if item.validation_id == reviewed.validation_id else item
                    for item in candidate.validations
                ]
                state = "publishable" if status == "pass" else (
                    "failed" if status == "reject" else "validating"
                )

                def apply_review(current: VoiceDesignCandidate) -> VoiceDesignCandidate:
                    if current.revision != candidate.revision:
                        raise VoiceDesignConflictError("candidate revision changed")
                    return current.model_copy(
                        update={
                            "validations": validations,
                            "state": state,
                            "updated_at": now,
                        }
                    )

                updated = repository.update(
                    candidate_id,
                    apply_review,
                )
                return JSONResponse(
                    status_code=200,
                    content={"candidate": _safe_candidate(repository, updated)},
                )

            test_text = (
                normalize_tts_text(body.test_text)
                if body.test_text is not None
                else next(
                    (
                        candidate_text
                        for candidate_text in _CONTROLLED_TEST_TEXTS
                        if normalize_tts_text(candidate_text)
                        != candidate.reference_text
                    ),
                    None,
                )
            )
            if test_text is None:
                return error_response(
                    422,
                    request_id,
                    "controlled_test_text_conflict",
                    (
                        "No controlled test text differs from the candidate "
                        "reference text; pass an explicit test_text"
                    ),
                )
            if not 20 <= len(test_text) <= 240:
                return error_response(
                    422,
                    request_id,
                    "invalid_test_text",
                    "Normalized test text must contain 20 to 240 characters",
                )
            if test_text == candidate.reference_text:
                return error_response(
                    422,
                    request_id,
                    "test_text_matches_reference",
                    "Base validation requires a different test text",
                )
            base = active.tts_clone
            synthesizer = services.tts_synthesizer
            if base is None or base.variant != "base" or synthesizer is None:
                return error_response(
                    503,
                    request_id,
                    "voice_design_base_unavailable",
                    "Base validation requires an active Base capability",
                    retryable=True,
                )

            def mark_validating(current: VoiceDesignCandidate) -> VoiceDesignCandidate:
                if current.revision != candidate.revision:
                    raise VoiceDesignConflictError("candidate revision changed")
                return current.model_copy(
                    update={"state": "validating", "updated_at": now}
                )

            repository.update(candidate_id, mark_validating)
            expires_at = (
                asyncio.get_running_loop().time()
                + services.settings.request_timeout_seconds
            )
            synthesis = SpeechRequest(
                text=test_text,
                voice=candidate.target_voice_id,
                language=candidate.language,
                sample_rate=_SAMPLE_RATE,
                expected_voice_revision=candidate.revision,
            )
            profile = candidate.profile()
            with use_voice_profile(profile):
                async with services.governor.reserve(
                    WorkClass.BATCH_TTS,
                    expires_at=expires_at,
                    resource_key=tts_resource_key(
                        synthesizer, candidate.target_voice_id
                    ),
                    purpose=WorkPurpose.VOICE_CREATION,
                ):
                    output_pcm = await _collect_audio(
                        synthesizer,
                        synthesis,
                        expires_at=expires_at,
                        design=False,
                        max_bytes=_MAX_VALIDATION_PCM_BYTES,
                    )
                runtime_revision = observed_runtime_revision_for_synthesizer(
                    synthesizer,
                    candidate.target_voice_id,
                )
            if not output_pcm:
                raise TTSDeliveryError("voice_validation_output_empty")
            output_wav = _wav_from_pcm(output_pcm)
            quality = _grade_clone_audio(output_wav)
            async with services.governor.reserve(
                WorkClass.BATCH_TTS,
                expires_at=expires_at,
                purpose=WorkPurpose.VOICE_CREATION,
            ):
                await _evict_quality_tts_if_supported(
                    synthesizer,
                    expires_at=expires_at,
                )
            transcript: str | None = None
            transcript_match: float | None = None
            try:
                transcript = await _transcribe_pcm(
                    services,
                    output_pcm,
                    language=candidate.language,
                    expires_at=expires_at,
                )
                transcript_match = vq.transcript_match_score(test_text, transcript)
            except VoiceDesignActionError as exc:
                if exc.code != "transcription_unavailable":
                    raise

            binding = build_validation_binding(
                profile,
                base,
                synthesizer,
                require_current_binding=True,
                observed_runtime_revision=runtime_revision,
                capability_key=capability_key,
            )
            validation = _candidate_validation(
                candidate=candidate,
                capability_key=capability_key,
                test_text=test_text,
                output_pcm=output_pcm,
                quality=quality,
                transcript=transcript,
                transcript_match=transcript_match,
                model_artifact=base.key,
                model_catalog_revision=base.revision,
                model_runtime_revision=binding.model_runtime_revision,
                runtime_fingerprint=binding.runtime_fingerprint,
                preprocess_version=binding.preprocess_version,
                generation_recipe_revision=binding.generation_recipe_revision,
                policy_version=binding.policy_version,
            )
            state = (
                "failed"
                if validation.machine_status == "reject"
                else "validating"
            )
            validations = [
                item
                for item in candidate.validations
                if item.validation_id != validation.validation_id
            ]
            validations.append(validation)

            def store_validation(
                current: VoiceDesignCandidate,
            ) -> VoiceDesignCandidate:
                if current.revision != candidate.revision:
                    raise VoiceDesignConflictError("candidate revision changed")
                return current.model_copy(
                    update={
                        "validations": validations,
                        "state": state,
                        "updated_at": validation.updated_at,
                    }
                )

            updated = repository.update(
                candidate_id,
                store_validation,
            )
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
                "Candidate changed while validation was running",
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
        except (GovernorQueueFullError, QueueFullError, AsrModeBusy):
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
            return error_response(
                502,
                request_id,
                exc.public_code,
                "TTS backend failed during Base validation",
                retryable=exc.retryable,
                diagnostic_class=exc.diagnostic_class,
            )
        except (OSError, ValueError, TTSDeliveryError, OverflowError):
            return error_response(
                502,
                request_id,
                "output_invalid",
                "Base validation output was invalid",
            )

    @router.post("/{candidate_id}/publish")
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
                        "voice": _voice_entry(profile, active, services.tts_ready),
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
                "probe_set": "voice_design_base_v1",
                "repetitions": 1,
                "failure_codes": [],
                "validated_for": [validation.capability_key],
            }
            registry.validation_store.put(validation_record)
            audio_bytes = await asyncio.to_thread(
                Path(candidate.reference_audio_path).read_bytes
            )
            profile_holder: list[Any] = []

            def publish(current: VoiceDesignCandidate) -> VoiceDesignCandidate:
                if current.revision != candidate.revision:
                    raise VoiceDesignConflictError("candidate revision changed")
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
                    "voice": _voice_entry(profile, active, services.tts_ready),
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
        except (OSError, ValueError):
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
