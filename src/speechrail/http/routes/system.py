"""Read-only system endpoints: process health, readiness and model identity."""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from fastapi import APIRouter, File, Form, Request, Response, UploadFile
from fastapi.responses import JSONResponse

from speechrail.application.services import AppServices
from speechrail.application.tts_stream import TtsStreamService
from speechrail.application.tts_stream_capability import (
    tts_stream_model_payload,
)
from speechrail.application.voice_quality_run import run_voice_quality as execute_voice_quality_run
from speechrail.application.voice_validation_execution import (
    ValidationRuntime,
    VoiceValidationExecutionError,
)
from speechrail.application.voice_validation_execution import (
    empty_synthesis as _shared_empty_synthesis,
)
from speechrail.application.voice_validation_execution import (
    grade_clone_audio as _shared_grade_clone_audio,
)
from speechrail.compatibility.openai_realtime import (
    asr_model_aliases,
    diarization_model_aliases,
    tts_model_aliases,
)
from speechrail.config.model_catalog import ModelArtifact
from speechrail.config.selection import ActiveModelCatalog, active_model_catalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.idempotency import (
    DurableIdempotencyJournal,
    IdempotencyConflictError,
    IdempotencyStoreUnavailableError,
)
from speechrail.domain.ports import SpeechSynthesizer
from speechrail.domain.tts import (
    SYSTEM_VOICE_PROFILES,
    VOICE_ALIASES,
    VOICE_ID_RE,
    VoiceAlreadyExistsError,
    VoiceInUseError,
    VoiceProfile,
    VoiceRevisionConflictError,
    VoiceRevokedError,
    VoiceStoreUnavailableError,
    VoiceUpdateUnsupportedError,
    canonicalize_clone_reference_audio,
)
from speechrail.domain.tts_execution import EMPTY_TTS_EXECUTION, TtsExecutionPorts
from speechrail.domain.tts_pronunciation import (
    PronunciationConflictError,
    PronunciationEntry,
    PronunciationRevokedError,
    PronunciationStoreUnavailableError,
    get_pronunciation_registry,
)
from speechrail.domain.voice_ports import ValidatedVoiceDirectory
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import backend_reclamation_error_response, error, error_response
from speechrail.http.voice_projection import quality_reject_content, voice_entry
from speechrail.runtime.admission import QueueFullError
from speechrail.runtime.resource_governor import (
    GovernorLaneIsolatedError,
    GovernorQueueFullError,
)

_CLONE_PROMPTS_ASSET = (
    Path(__file__).resolve().parent.parent.parent / "assets" / "clone_prompts.json"
)


def _load_clone_prompts() -> list[dict[str, Any]]:
    if _CLONE_PROMPTS_ASSET.is_file():
        try:
            loaded = json.loads(_CLONE_PROMPTS_ASSET.read_text(encoding="utf-8"))
            if isinstance(loaded, list):
                return loaded
        except Exception:
            return []
    return []


_CACHED_CLONE_PROMPTS: list[dict[str, Any]] = _load_clone_prompts()
_MAX_VOICE_SEED = 2**32 - 1
_TTS_LIFECYCLE_FIELDS = frozenset(
    {
        "cooperative_cancel_supported",
        "fallback_abort_count",
        "reload_count",
        "reload_count_by_role",
        "warm_capability",
        "warm_capabilities",
    }
)
_LOGGER = logging.getLogger(__name__)

# Clone publication is single-owner local state. The journal stores only hashes,
# operation metadata and the resulting profile ID; raw audio/text/API keys are never persisted.
_CLONE_IDEMPOTENCY_OWNER = "speechrail-local"
_CLONE_IDEMPOTENCY_OPERATION = "voice.clone"


def _clone_payload_fingerprint(
    audio_content: bytes,
    ref_text: str,
    *,
    name: str,
    voice_id: str | None,
) -> str:
    payload = {
        "audio_sha256": hashlib.sha256(audio_content).hexdigest(),
        "ref_text_sha256": hashlib.sha256(ref_text.strip().encode("utf-8")).hexdigest(),
        "name": name.strip(),
        "voice_id": (
            voice_id.strip().lower() if isinstance(voice_id, str) and voice_id.strip() else None
        ),
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


def _clone_result_matches(
    profile: VoiceProfile,
    *,
    name: str,
    ref_text: str,
    canonical_wav: bytes,
) -> bool:
    """Prove a recovered clone belongs to the idempotent request payload."""

    if (
        profile.mode != "clone"
        or profile.name != name.strip()
        or profile.ref_text != ref_text.strip()
        or profile.audio_path is None
    ):
        return False
    try:
        stored_digest = hashlib.sha256(Path(profile.audio_path).read_bytes()).hexdigest()
    except OSError:
        return False
    return stored_digest == hashlib.sha256(canonical_wav).hexdigest()


def _tts_lifecycle_diagnostics(
    services: AppServices,
) -> dict[str, object] | None:
    """Return safe TTS lifecycle counters when this backend exposes them."""

    stats = getattr(services.tts_synthesizer, "lifecycle_stats", None)
    if not isinstance(stats, dict):
        return None
    return {
        name: value
        for name, value in stats.items()
        if name in _TTS_LIFECYCLE_FIELDS
        and (
            value is None
            or isinstance(value, (bool, int, str))
            or (isinstance(value, list) and all(isinstance(item, str) for item in value))
        )
    }


def _tts_design_diagnostics(services: AppServices) -> dict[str, object]:
    """Read optional design-lane diagnostics; discovery never starts a worker."""
    synthesizer = services.tts_synthesizer
    status = getattr(synthesizer, "design_status", None)
    if isinstance(status, dict):
        return {key: status[key] for key in ("configured", "ready", "state", "last_error")}
    configured = active_model_catalog(services.settings).voice_design is not None and callable(
        getattr(synthesizer, "synthesize_design", None)
    )
    return {
        "configured": configured,
        "ready": None if configured else False,
        "state": "unknown" if configured else "unconfigured",
        "last_error": None,
    }


def _model_entry(
    model_id: str,
    active: ActiveModelCatalog,
    artifact: ModelArtifact | None,
    *,
    streaming_input: dict[str, object] | None = None,
) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "id": model_id,
        "object": "model",
        "owned_by": "speechrail",
        "created": 0,
    }
    if artifact is not None:
        entry.update(
            {
                "profile": active.profile,
                "artifact": artifact.key,
                "source_model": artifact.model_id,
                "family": artifact.family,
                "variant": artifact.variant,
                "quantization": artifact.quantization.model_dump(mode="json"),
            }
        )
        if artifact.family == "qwen3_tts":
            # Preview and instruction are served by the VoiceDesign lane, which is
            # a separate artifact from whichever tier produced this entry. Deriving
            # them from `artifact.variant` reports `false` for every real deployment
            # (a TTS entry is only ever custom_voice or base) and contradicts the
            # capability snapshot, which resolves the same facts correctly.
            supports_voice_design = (
                active.voice_design is not None and active.voice_design.variant == "voice_design"
            )
            supports_clone = active.tts_clone is not None and active.tts_clone.variant == "base"
            entry["capabilities"] = {
                "supports_preview": supports_voice_design,
                "supports_clone": supports_clone,
                "supports_instruction": supports_voice_design,
            }
            if streaming_input is not None:
                entry["capabilities"]["streaming_input"] = streaming_input
    return entry


def _voice_entry(
    profile: VoiceProfile,
    active: ActiveModelCatalog,
    tts_ready: bool,
    *,
    voice_store: ValidatedVoiceDirectory,
    enabled: bool = True,
    synthesizer: SpeechSynthesizer | None = None,
    tts_execution: TtsExecutionPorts = EMPTY_TTS_EXECUTION,
    strict_validation: bool = False,
    include_streaming: bool = False,
    stream_service: TtsStreamService | None = None,
) -> dict[str, Any]:
    return voice_entry(
        profile,
        active,
        tts_ready,
        voice_store=voice_store,
        enabled=enabled,
        synthesizer=synthesizer,
        tts_execution=tts_execution,
        strict_validation=strict_validation,
        include_streaming=include_streaming,
        stream_service=stream_service,
    )


def _voice_list_entry(
    profile: VoiceProfile,
    active: ActiveModelCatalog,
    tts_ready: bool,
    *,
    voice_store: ValidatedVoiceDirectory,
    enabled: bool = True,
    synthesizer: SpeechSynthesizer | None = None,
    tts_execution: TtsExecutionPorts = EMPTY_TTS_EXECUTION,
    strict_validation: bool = False,
    include_streaming: bool = False,
    stream_service: TtsStreamService | None = None,
) -> dict[str, Any]:
    """Project only routing-safe discovery fields for the public voice list."""

    detailed = _voice_entry(
        profile,
        active,
        tts_ready,
        voice_store=voice_store,
        enabled=enabled,
        synthesizer=synthesizer,
        tts_execution=tts_execution,
        strict_validation=strict_validation,
        include_streaming=include_streaming,
        stream_service=stream_service,
    )
    safe_fields = (
        "id",
        "name",
        "aliases",
        "is_default",
        "is_system",
        "created_at",
        "available",
        "variant",
        "capabilities",
        "mode",
        "preview",
        "revision",
        "revoked",
        "availability_reason",
        "validation_state",
        "validated_for",
        "production_ready",
        "production_ready_reason",
        "streaming",
    )
    return {key: detailed[key] for key in safe_fields if key in detailed}


def _safe_revision_entry(
    profile: VoiceProfile,
    *,
    current_revision: str | None,
) -> dict[str, object]:
    return {
        "revision": profile.revision,
        "current": profile.revision == current_revision,
        "mode": profile.mode,
        "revoked": profile.revoked,
        "created_at": profile.created_at,
    }


def _empty_synthesis() -> vq.VoiceQualitySynthesis:
    return _shared_empty_synthesis()


def _grade_clone_audio(wav_bytes: bytes) -> vq.VoiceQualityReport:
    return _shared_grade_clone_audio(wav_bytes)


@dataclass(frozen=True)
class _CloneQualityEvaluation:
    canonical_wav: bytes | None
    canonical_duration: float
    report: vq.VoiceQualityReport


def _evaluate_clone_reference_audio(wav_bytes: bytes) -> _CloneQualityEvaluation:
    """Grade the raw gate and, when allowed, the canonical persisted reference."""
    raw_report = _grade_clone_audio(wav_bytes)
    if raw_report.status == vq.VoiceQualityStatus.REJECT.value:
        return _CloneQualityEvaluation(None, 0.0, raw_report)

    canonical_wav, canonical_duration = canonicalize_clone_reference_audio(
        wav_bytes, target_sample_rate=24_000
    )
    canonical_report = _grade_clone_audio(canonical_wav)
    if canonical_report.status == vq.VoiceQualityStatus.REJECT.value:
        return _CloneQualityEvaluation(None, 0.0, canonical_report)
    return _CloneQualityEvaluation(canonical_wav, canonical_duration, canonical_report)


def _quality_reject_response(request_id: str, report: vq.VoiceQualityReport) -> JSONResponse:
    status, content, headers = quality_reject_content(request_id, report)
    return JSONResponse(
        status_code=status,
        content=content,
        headers=headers,
    )


async def _read_uploaded_audio(
    audio: UploadFile, request_id: str
) -> tuple[bytes, JSONResponse | None]:
    content = bytearray()
    while chunk := await audio.read(64 * 1024):
        content.extend(chunk)
        if len(content) > 15 * 1024 * 1024:
            return b"", error_response(
                413, request_id, "audio_too_large", "Audio file exceeds 15MB limit"
            )
    if len(content) < 1024:
        return b"", error_response(
            400, request_id, "audio_too_short", "Audio content is empty or too short"
        )
    return bytes(content), None


async def _transcode_clone_audio(audio_content: bytes, ffmpeg_cmd: str) -> tuple[bytes, float]:
    """Transcode reference audio without blocking the ASGI event loop.

    The child stdout is read through the shared bounded executor so a long or
    malformed reference can never grow the process heap, and cancellation or a
    timeout reaps the exact child instead of leaking it into the worker.
    """
    from speechrail.application.ffmpeg import run_ffmpeg_subprocess
    from speechrail.domain.tts import validate_transcoded_clone_wav

    if not audio_content:
        raise ValueError("audio content must not be empty")
    if len(audio_content) > 15 * 1024 * 1024:
        raise ValueError("audio file exceeds 15MB limit")

    target_sample_rate = 24_000
    max_duration = 45.0
    # 45s of 24kHz mono PCM16 plus a generous WAV header margin. Exceeding this
    # is rejected outright; we never silently truncate with -t.
    max_output_bytes = int(max_duration * target_sample_rate * 2) + 64 * 1024
    try:
        wav_bytes = await run_ffmpeg_subprocess(
            (
                ffmpeg_cmd,
                "-nostdin",
                "-threads",
                "1",
                "-v",
                "error",
                "-i",
                "pipe:0",
                "-ac",
                "1",
                "-ar",
                str(target_sample_rate),
                "-f",
                "wav",
                "pipe:1",
            ),
            audio_content,
            max_output_bytes=max_output_bytes,
            output_limit_error=ValueError(
                f"audio exceeds maximum allowed size for {max_duration}s duration (too long)"
            ),
            timeout_error=ValueError("audio transcoding timed out"),
            failure_error=ValueError("audio transcoding failed"),
            timeout_seconds=10.0,
        )
    except FileNotFoundError as exc:
        # The bounded executor surfaces a missing binary as FileNotFoundError;
        # keep the historical 500 dependency_missing contract for this route.
        raise RuntimeError("ffmpeg_not_found") from exc
    duration = validate_transcoded_clone_wav(
        wav_bytes,
        min_duration=2.0,
        max_duration=max_duration,
        target_sample_rate=target_sample_rate,
        skip_signal_validation=True,
    )
    return wav_bytes, duration


_CLONE_NAME_MAX_LENGTH = 32
_CLONE_REF_TEXT_MAX_LENGTH = 2_000


def _normalized_clone_voice_id(voice_id: object) -> tuple[str | None, str | None]:
    """Normalize an optional requested clone voice id and reject reserved ids.

    ``POST /v1/voices/clone/validate`` runs the same pipeline as
    ``POST /v1/voices/clone`` without persisting anything, so both routes must
    accept exactly the same ids. Sharing this check keeps a dry run from
    reporting "参考音频合格" for an id that registration then rejects.
    """

    if not isinstance(voice_id, str) or not voice_id.strip():
        return None, None
    normalized = voice_id.strip().lower()
    if (
        VOICE_ID_RE.fullmatch(normalized) is None
        or normalized in SYSTEM_VOICE_PROFILES
        or normalized in VOICE_ALIASES
    ):
        return None, ("Voice id must match ^[a-zA-Z0-9_-]{1,64}$ and must not be reserved")
    return normalized, None


def create_system_router(services: AppServices) -> APIRouter:
    """Four read-only endpoints; no auth by design (loopback-first service)."""
    router = APIRouter()
    resolved = services.settings
    active = active_model_catalog(resolved)

    @router.get("/health")
    async def health() -> dict[str, Any]:
        states = services.subsystem_states
        return {
            "status": "ok",
            "service": resolved.service_name,
            "version": resolved.version,
            "backend": active.asr.key if active.asr is not None else resolved.model_id,
            "profile": active.profile,
            "asr_ready": services.asr_ready,
            "asr_runtime_revision": services.asr_runtime_revision,
            "tts_ready": services.tts_ready,
            "tts_warm": services.tts_warm,
            "diarization_ready": services.diarization_ready,
            "diarization": services.diarization_status,
            "asr_state": states.get("asr", "unconfigured"),
            "tts_state": states.get("tts", "unconfigured"),
            "tts_lifecycle": _tts_lifecycle_diagnostics(services),
            "tts_design": _tts_design_diagnostics(services),
            "streaming_state": states.get("streaming", "unconfigured"),
            "realtime_vad": services.realtime_vad_status,
            "job_spool_ready": services.job_repository is not None,
            "ready": services.asr_ready or services.tts_ready,
        }

    @router.get("/readyz")
    async def readyz(request: Request) -> JSONResponse:
        if services.asr_ready or services.tts_ready:
            return JSONResponse(
                status_code=200,
                content={
                    "ready": True,
                    "diarization": services.diarization_status,
                    "realtime_vad": services.realtime_vad_status,
                },
            )
        return error_response(
            503,
            request.state.request_id,
            "backend_not_ready",
            "SpeechRail inference backend is not ready",
            retryable=True,
        )

    @router.get("/v1/models")
    async def models() -> dict[str, Any]:
        asr_target = resolved.model_id
        tts_target = resolved.tts_model_id
        data: list[dict[str, Any]] = [
            _model_entry(asr_target, active, active.asr),
            _model_entry(
                tts_target,
                active,
                active.tts,
                streaming_input=tts_stream_model_payload(services.tts_execution),
            ),
        ]
        for alias, target in sorted(asr_model_aliases().items()):
            if alias in diarization_model_aliases() and not services.diarization_ready:
                continue
            data.append(
                {
                    "id": alias,
                    "object": "model",
                    "owned_by": "speechrail",
                    "created": 0,
                    "resolves_to": target,
                }
            )
        for alias, target in sorted(tts_model_aliases().items()):
            data.append(
                {
                    "id": alias,
                    "object": "model",
                    "owned_by": "speechrail",
                    "created": 0,
                    "resolves_to": target,
                    "capabilities": {
                        "supports_preview": active.voice_design is not None
                        and active.voice_design.variant == "voice_design",
                        "supports_clone": active.tts_clone is not None
                        and active.tts_clone.variant == "base",
                        "supports_instruction": active.voice_design is not None
                        and active.voice_design.variant == "voice_design",
                        "streaming_input": tts_stream_model_payload(services.tts_execution),
                    },
                }
            )
        for compat in resolved.compatibility_model_ids:
            if compat in diarization_model_aliases() and not services.diarization_ready:
                continue
            if compat in {asr_target, tts_target} or any(d["id"] == compat for d in data):
                continue
            data.append(
                {
                    "id": compat,
                    "object": "model",
                    "owned_by": "speechrail",
                    "created": 0,
                    "resolves_to": asr_target,
                }
            )
        return {"object": "list", "data": data}

    @router.get("/v1/voices", response_model=None)
    async def voices(request: Request) -> dict[str, Any] | Response:
        """List system preset voices and custom user-designed voices."""
        registry = services.voice_store
        try:
            profiles = registry.list_profiles()
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request.state.request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        return {
            "object": "list",
            "data": [
                _voice_list_entry(
                    profile,
                    active,
                    services.tts_ready,
                    enabled=not profile.is_system or profile.id in resolved.tts_voice_ids,
                    synthesizer=services.tts_synthesizer,
                    tts_execution=services.tts_execution,
                    strict_validation=True,
                    include_streaming=True,
                    stream_service=services.tts_streams,
                    voice_store=services.voice_store,
                )
                for profile in profiles
            ],
        }

    @router.get("/v1/voices/{voice_id}")
    async def voice_detail(voice_id: str, request: Request) -> JSONResponse:
        """Return one system or custom voice profile."""
        request_id: str = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            profile = services.voice_store.get_profile(voice_id)
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except ValueError:
            return error_response(
                404,
                request_id,
                "voice_not_found",
                "Voice not found",
            )
        return JSONResponse(
            status_code=200,
            content=_voice_entry(
                profile,
                active,
                services.tts_ready,
                enabled=not profile.is_system or profile.id in resolved.tts_voice_ids,
                synthesizer=services.tts_synthesizer,
                tts_execution=services.tts_execution,
                strict_validation=True,
                include_streaming=True,
                stream_service=services.tts_streams,
                voice_store=services.voice_store,
            ),
        )

    @router.patch("/v1/voices/{voice_id}")
    async def update_voice(voice_id: str, request: Request) -> JSONResponse:
        """Atomically update mutable metadata for a custom voice."""
        request_id: str = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            body = await request.json()
        except Exception:
            return error_response(
                400,
                request_id,
                "invalid_json",
                "Invalid JSON payload",
            )
        if not isinstance(body, dict):
            return error_response(
                400,
                request_id,
                "invalid_payload",
                "JSON object expected",
            )
        allowed = {"name", "instruction", "seed"}
        if set(body) - allowed or not any(key in body and body[key] is not None for key in allowed):
            return error_response(
                400,
                request_id,
                "invalid_payload",
                "At least one mutable voice field is required",
            )
        name = body.get("name")
        instruction = body.get("instruction")
        seed = body.get("seed")
        if name is not None and (not isinstance(name, str) or not name.strip()):
            return error_response(
                400,
                request_id,
                "invalid_name",
                "Voice name must not be empty",
            )
        if instruction is not None and (
            not isinstance(instruction, str) or not instruction.strip()
        ):
            return error_response(
                400,
                request_id,
                "invalid_instruction",
                "Voice instruction must not be empty",
            )
        if instruction is not None and len(instruction.strip()) > 10_000:
            return error_response(
                400,
                request_id,
                "invalid_instruction",
                "Voice instruction exceeds the 10000 character limit",
            )
        if seed is not None and (type(seed) is not int or seed < 0 or seed > _MAX_VOICE_SEED):
            return error_response(
                400,
                request_id,
                "invalid_seed",
                f"Voice seed must be an integer between 0 and {_MAX_VOICE_SEED}",
            )
        try:
            profile = services.voice_store.update_custom_profile(
                voice_id,
                name=name,
                instruction=instruction,
                seed=seed,
            )
        except VoiceUpdateUnsupportedError as exc:
            return error_response(
                403,
                request_id,
                "voice_update_unsupported",
                str(exc),
            )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except KeyError:
            return error_response(
                404,
                request_id,
                "voice_not_found",
                f"Voice {voice_id} not found",
            )
        except ValueError as exc:
            return error_response(
                400,
                request_id,
                "voice_update_failed",
                str(exc),
            )
        return JSONResponse(
            status_code=200,
            content=_voice_entry(
                profile,
                active,
                services.tts_ready,
                synthesizer=services.tts_synthesizer,
                tts_execution=services.tts_execution,
                strict_validation=True,
                voice_store=services.voice_store,
            ),
        )

    @router.get("/v1/speechrail/pronunciation-sets")
    async def list_pronunciation_sets(request: Request) -> JSONResponse:
        """Enumerate safe set identity only; entries remain management data."""

        request_id = getattr(request.state, "request_id", "") or "req_pronunciation"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            values = get_pronunciation_registry().list_sets()
        except PronunciationStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "pronunciation_store_unavailable",
                "Pronunciation registry is unavailable",
                retryable=True,
            )
        return JSONResponse(
            status_code=200,
            content={
                "object": "list",
                "data": [
                    {
                        "id": value.id,
                        "revision": value.revision,
                        "revoked": value.revoked,
                        "entry_count": len(value.entries),
                    }
                    for value in values
                ],
            },
        )

    @router.get("/v1/speechrail/pronunciation-sets/{set_id}/revisions/{revision}")
    async def get_pronunciation_revision(
        set_id: str,
        revision: str,
        request: Request,
    ) -> JSONResponse:
        """Read one explicit management revision including its local entries."""

        request_id = getattr(request.state, "request_id", "") or "req_pronunciation"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            value = get_pronunciation_registry().get(
                set_id,
                revision=revision,
            )
        except PronunciationRevokedError:
            return error_response(
                409,
                request_id,
                "pronunciation_revoked",
                "Pronunciation revision is revoked",
            )
        except PronunciationStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "pronunciation_store_unavailable",
                "Pronunciation registry is unavailable",
                retryable=True,
            )
        except KeyError:
            return error_response(
                404,
                request_id,
                "pronunciation_revision_not_found",
                "Pronunciation set or revision not found",
            )
        return JSONResponse(status_code=200, content=value.to_dict())

    @router.put("/v1/speechrail/pronunciation-sets/{set_id}")
    async def put_pronunciation_set(
        set_id: str,
        request: Request,
    ) -> JSONResponse:
        """Create or CAS-update a pronunciation set as a new immutable revision."""

        request_id = getattr(request.state, "request_id", "") or "req_pronunciation"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            body = await request.json()
        except Exception:
            return error_response(
                400,
                request_id,
                "invalid_json",
                "Invalid JSON payload",
            )
        if not isinstance(body, dict) or set(body) != {
            "expected_revision",
            "entries",
        }:
            return error_response(
                400,
                request_id,
                "invalid_payload",
                "expected_revision and entries are required",
            )
        expected_revision = body.get("expected_revision")
        if expected_revision is not None and not isinstance(expected_revision, str):
            return error_response(
                400,
                request_id,
                "invalid_expected_revision",
                "expected_revision must be a string or null",
            )
        raw_entries = body.get("entries")
        if not isinstance(raw_entries, list):
            return error_response(
                400,
                request_id,
                "invalid_entries",
                "entries must be an array",
            )
        try:
            entries = tuple(
                PronunciationEntry(**entry) for entry in raw_entries if isinstance(entry, dict)
            )
            if len(entries) != len(raw_entries):
                raise ValueError("every pronunciation entry must be an object")
            value = get_pronunciation_registry().put(
                set_id,
                entries,
                expected_revision=expected_revision,
            )
        except PronunciationConflictError as exc:
            return error_response(
                409,
                request_id,
                "pronunciation_conflict",
                str(exc),
            )
        except PronunciationStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "pronunciation_store_unavailable",
                "Pronunciation registry is unavailable",
                retryable=True,
            )
        except (TypeError, ValueError) as exc:
            return error_response(
                400,
                request_id,
                "invalid_pronunciation_set",
                str(exc),
            )
        return JSONResponse(
            status_code=200,
            content={
                "id": value.id,
                "revision": value.revision,
                "revoked": value.revoked,
                "entry_count": len(value.entries),
            },
        )

    @router.post("/v1/speechrail/pronunciation-sets/{set_id}/revisions/{revision}/revoke")
    async def revoke_pronunciation_revision(
        set_id: str,
        revision: str,
        request: Request,
    ) -> JSONResponse:
        request_id = getattr(request.state, "request_id", "") or "req_pronunciation"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            value = get_pronunciation_registry().revoke(set_id, revision)
        except PronunciationStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "pronunciation_store_unavailable",
                "Pronunciation registry is unavailable",
                retryable=True,
            )
        except KeyError:
            return error_response(
                404,
                request_id,
                "pronunciation_revision_not_found",
                "Pronunciation set or revision not found",
            )
        return JSONResponse(
            status_code=200,
            content={
                "id": value.id,
                "revision": value.revision,
                "revoked": True,
            },
        )

    @router.delete("/v1/speechrail/pronunciation-sets/{set_id}")
    async def delete_pronunciation_set(
        set_id: str,
        request: Request,
    ) -> JSONResponse:
        request_id = getattr(request.state, "request_id", "") or "req_pronunciation"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            get_pronunciation_registry().delete(set_id)
        except PronunciationStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "pronunciation_store_unavailable",
                "Pronunciation registry is unavailable",
                retryable=True,
            )
        except KeyError:
            return error_response(
                404,
                request_id,
                "pronunciation_set_not_found",
                "Pronunciation set not found",
            )
        return JSONResponse(
            status_code=200,
            content={"status": "deleted", "id": set_id},
        )

    @router.patch("/v1/speechrail/voices/{voice_id}")
    async def update_voice_v2(voice_id: str, request: Request) -> JSONResponse:
        """CAS-update a custom voice without changing the strict v1 request shape."""

        request_id = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            body = await request.json()
        except Exception:
            return error_response(400, request_id, "invalid_json", "Invalid JSON payload")
        if not isinstance(body, dict):
            return error_response(400, request_id, "invalid_payload", "JSON object expected")
        allowed = {"name", "instruction", "seed", "expected_revision"}
        if set(body) - allowed:
            return error_response(400, request_id, "invalid_payload", "Unknown voice field")
        expected_revision = body.get("expected_revision")
        if not isinstance(expected_revision, str):
            return error_response(
                400,
                request_id,
                "expected_revision_required",
                "expected_revision is required for v2 voice updates",
            )
        name = body.get("name")
        instruction = body.get("instruction")
        seed = body.get("seed")
        if name is None and instruction is None and seed is None:
            return error_response(
                400,
                request_id,
                "invalid_payload",
                "At least one mutable voice field is required",
            )
        try:
            profile = services.voice_store.update_custom_profile(
                voice_id,
                name=name,
                instruction=instruction,
                seed=seed,
                expected_revision=expected_revision,
            )
        except VoiceRevisionConflictError:
            return error_response(
                409,
                request_id,
                "voice_revision_conflict",
                "Voice alias no longer points at expected_revision",
            )
        except VoiceUpdateUnsupportedError as exc:
            return error_response(
                403,
                request_id,
                "voice_update_unsupported",
                str(exc),
            )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except KeyError:
            return error_response(404, request_id, "voice_not_found", "Voice not found")
        except ValueError as exc:
            return error_response(400, request_id, "voice_update_failed", str(exc))
        return JSONResponse(
            status_code=200,
            content={
                "id": profile.id,
                "name": profile.name or profile.id,
                "voice_revision": profile.revision,
                "mode": profile.mode,
                "revoked": profile.revoked,
            },
        )

    @router.get("/v1/speechrail/voices/{voice_id}/revisions")
    async def list_voice_revisions(voice_id: str, request: Request) -> JSONResponse:
        """List safe immutable revision metadata without private recipes or paths."""

        request_id = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        registry = services.voice_store
        try:
            current = registry.get_profile(voice_id)
            revisions = registry.list_revisions(voice_id)
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except KeyError, ValueError:
            return error_response(404, request_id, "voice_not_found", "Voice not found")
        return JSONResponse(
            status_code=200,
            content={
                "object": "list",
                "data": [
                    _safe_revision_entry(
                        item,
                        current_revision=current.revision,
                    )
                    for item in revisions
                ],
            },
        )

    @router.post("/v1/speechrail/voices/{voice_id}/rollback")
    async def rollback_voice_revision(voice_id: str, request: Request) -> JSONResponse:
        """Atomically point a friendly voice ID back to a non-revoked revision."""

        request_id = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            body = await request.json()
        except Exception:
            return error_response(400, request_id, "invalid_json", "Invalid JSON payload")
        if not isinstance(body, dict) or set(body) != {
            "target_revision",
            "expected_revision",
        }:
            return error_response(
                400,
                request_id,
                "invalid_payload",
                "target_revision and expected_revision are required",
            )
        target = body.get("target_revision")
        expected = body.get("expected_revision")
        if not isinstance(target, str) or not isinstance(expected, str):
            return error_response(
                400,
                request_id,
                "invalid_payload",
                "Voice revisions must be strings",
            )
        try:
            profile = services.voice_store.rollback_custom_profile(
                voice_id,
                target_revision=target,
                expected_revision=expected,
            )
        except VoiceRevisionConflictError:
            return error_response(
                409,
                request_id,
                "voice_revision_conflict",
                "Voice alias no longer points at expected_revision",
            )
        except VoiceRevokedError:
            return error_response(
                409,
                request_id,
                "voice_revoked",
                "Target voice revision is revoked",
            )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except KeyError:
            return error_response(
                404,
                request_id,
                "voice_revision_not_found",
                "Voice or target revision not found",
            )
        except ValueError as exc:
            return error_response(400, request_id, "invalid_voice_revision", str(exc))
        return JSONResponse(
            status_code=200,
            content={
                "id": profile.id,
                "voice_revision": profile.revision,
                "mode": profile.mode,
                "revoked": profile.revoked,
            },
        )

    @router.post("/v1/speechrail/voices/{voice_id}/revisions/{revision}/revoke")
    async def revoke_voice_revision(
        voice_id: str,
        revision: str,
        request: Request,
    ) -> JSONResponse:
        """Revoke one exact revision for future synthesis without killing active leases."""

        request_id = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            profile = services.voice_store.revoke_revision(
                voice_id,
                revision=revision,
            )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except KeyError:
            return error_response(
                404,
                request_id,
                "voice_revision_not_found",
                "Voice revision not found",
            )
        except ValueError as exc:
            return error_response(400, request_id, "invalid_voice_revision", str(exc))
        return JSONResponse(
            status_code=200,
            content={
                "id": profile.id,
                "voice_revision": profile.revision,
                "revoked": True,
            },
        )

    @router.post("/v1/voices", status_code=201)
    async def create_voice(request: Request) -> JSONResponse:
        """Create a persistent custom voice using natural language instruction."""
        request_id: str = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            body = await request.json()
        except Exception:
            return error_response(
                400,
                request_id,
                "invalid_json",
                "Invalid JSON payload",
            )
        if not isinstance(body, dict):
            return error_response(
                400,
                request_id,
                "invalid_payload",
                "JSON object expected",
            )
        name = body.get("name")
        instruction = body.get("instruction")
        voice_id = body.get("id")
        seed = body.get("seed")
        if not isinstance(name, str) or not name.strip():
            return error_response(
                400,
                request_id,
                "invalid_name",
                "Voice name is required",
            )
        if not isinstance(instruction, str) or not instruction.strip():
            return error_response(
                400,
                request_id,
                "invalid_instruction",
                "Voice instruction is required",
            )
        if len(instruction.strip()) > 10_000:
            return error_response(
                400,
                request_id,
                "invalid_instruction",
                "Voice instruction exceeds the 10000 character limit",
            )
        if seed is not None and (type(seed) is not int or seed < 0 or seed > _MAX_VOICE_SEED):
            return error_response(
                400,
                request_id,
                "invalid_seed",
                f"Voice seed must be an integer between 0 and {_MAX_VOICE_SEED}",
            )
        vid_str = (
            voice_id.strip().lower() if isinstance(voice_id, str) and voice_id.strip() else None
        )
        try:
            profile = services.voice_store.create_custom_profile(
                name=name.strip(),
                instruction=instruction.strip(),
                voice_id=vid_str,
                seed=seed,
            )
            return JSONResponse(
                status_code=201,
                content=_voice_entry(
                    profile,
                    active,
                    services.tts_ready,
                    synthesizer=services.tts_synthesizer,
                    tts_execution=services.tts_execution,
                    strict_validation=True,
                    voice_store=services.voice_store,
                ),
            )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except ValueError as exc:
            return error_response(
                400,
                request_id,
                "voice_creation_failed",
                str(exc),
            )

    @router.get("/v1/voices/clone/prompts")
    async def clone_prompts() -> dict[str, Any]:
        """List official curated scripts for zero-shot voice cloning."""
        return {"object": "list", "data": _CACHED_CLONE_PROMPTS}

    @router.post("/v1/voices/clone", status_code=201)
    async def clone_voice(
        request: Request,
        audio: UploadFile = File(...),  # noqa: B008 - FastAPI parameter marker.
        ref_text: str = Form(...),
        name: str = Form(...),
        voice_id: str | None = Form(default=None, alias="id"),
    ) -> JSONResponse:
        """Clone and register a custom voice using a reference audio and prompt text."""
        request_id: str = getattr(request.state, "request_id", "") or "req_clone"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        variant = active.tts_clone.variant if active.tts_clone is not None else None
        if variant != "base":
            tier_name = active.profile or "custom"
            return error_response(
                400,
                request_id,
                "voice_cloning_unsupported",
                (
                    f"Active TTS tier ({tier_name}) variant '{variant}' "
                    "does not provide the Base clone capability"
                ),
            )

        if not name or not name.strip():
            return error_response(400, request_id, "invalid_name", "Voice name is required")
        if len(name) > _CLONE_NAME_MAX_LENGTH:
            return error_response(
                400,
                request_id,
                "invalid_name",
                f"Voice name must not exceed {_CLONE_NAME_MAX_LENGTH} characters",
            )
        if not ref_text or not ref_text.strip():
            return error_response(
                400, request_id, "invalid_ref_text", "Reference text (ref_text) is required"
            )
        if len(ref_text) > _CLONE_REF_TEXT_MAX_LENGTH:
            return error_response(
                400,
                request_id,
                "invalid_ref_text",
                (f"Reference text must not exceed {_CLONE_REF_TEXT_MAX_LENGTH} characters"),
            )
        requested_voice_id, voice_id_error = _normalized_clone_voice_id(voice_id)
        if voice_id_error is not None:
            return error_response(
                400,
                request_id,
                "invalid_voice_id",
                voice_id_error,
                param="id",
            )

        audio_content, read_error = await _read_uploaded_audio(audio, request_id)
        if read_error is not None:
            return read_error

        idempotency_key = request.headers.get("Idempotency-Key")

        ffmpeg_cmd = str(resolved.ffmpeg_path) if resolved.ffmpeg_path else "ffmpeg"
        try:
            wav_bytes, _duration = await _transcode_clone_audio(audio_content, ffmpeg_cmd)
        except RuntimeError as exc:
            return error_response(500, request_id, "dependency_missing", str(exc))
        except ValueError as exc:
            err_str = str(exc)
            if "too short" in err_str:
                code = "audio_too_short"
            elif "too long" in err_str:
                code = "audio_too_long"
            else:
                code = "invalid_audio"
            return error_response(400, request_id, code, err_str)

        try:
            evaluation = _evaluate_clone_reference_audio(wav_bytes)
        except ValueError as exc:
            return error_response(400, request_id, "invalid_audio", str(exc))
        if evaluation.canonical_wav is None:
            return _quality_reject_response(request_id, evaluation.report)
        canonical_wav = evaluation.canonical_wav
        canonical_duration = evaluation.canonical_duration
        report = evaluation.report

        vid_str = requested_voice_id
        if idempotency_key and vid_str is None:
            key_hash = DurableIdempotencyJournal.key_hash(idempotency_key)
            vid_str = f"clone_idem_{key_hash[:24]}"

        fingerprint: str | None = None
        if idempotency_key:
            fingerprint = _clone_payload_fingerprint(
                audio_content,
                ref_text,
                name=name,
                voice_id=vid_str,
            )
            try:
                decision = services.voice_clone_journal.begin(
                    owner=_CLONE_IDEMPOTENCY_OWNER,
                    operation=_CLONE_IDEMPOTENCY_OPERATION,
                    key=idempotency_key,
                    fingerprint=fingerprint,
                    provisional_result_id=vid_str,
                )
            except IdempotencyConflictError:
                return error_response(
                    409,
                    request_id,
                    "idempotency_conflict",
                    "Idempotency-Key was already used with a different clone payload",
                )
            except IdempotencyStoreUnavailableError:
                return error_response(
                    503,
                    request_id,
                    "idempotency_store_unavailable",
                    "Durable idempotency state is unavailable",
                    retryable=True,
                )
            if decision.state == "pending":
                if decision.result_id is None:
                    return error_response(
                        409,
                        request_id,
                        "idempotency_pending",
                        "Previous operation predates recoverable result identity",
                        retryable=True,
                    )
                vid_str = decision.result_id
                try:
                    profile = services.voice_store.get_profile(decision.result_id)
                except VoiceStoreUnavailableError:
                    return error_response(
                        503,
                        request_id,
                        "voice_store_unavailable",
                        "Custom voice storage is unavailable",
                        retryable=True,
                    )
                except ValueError:
                    profile = None
                if profile is not None:
                    if not _clone_result_matches(
                        profile,
                        name=name,
                        ref_text=ref_text,
                        canonical_wav=canonical_wav,
                    ):
                        return error_response(
                            409,
                            request_id,
                            "voice_already_exists",
                            "Target voice ID is owned by a different clone payload",
                        )
                    try:
                        services.voice_clone_journal.complete(
                            owner=_CLONE_IDEMPOTENCY_OWNER,
                            operation=_CLONE_IDEMPOTENCY_OPERATION,
                            key=idempotency_key,
                            fingerprint=fingerprint,
                            result_id=profile.id,
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
                        content=_voice_entry(
                            profile,
                            active,
                            services.tts_ready,
                            synthesizer=services.tts_synthesizer,
                            tts_execution=services.tts_execution,
                            strict_validation=True,
                            voice_store=services.voice_store,
                        ),
                    )
            if decision.state == "completed":
                if decision.result_id is None:
                    return error_response(
                        503,
                        request_id,
                        "idempotency_store_unavailable",
                        "Completed idempotency record is missing its result",
                        retryable=True,
                    )
                try:
                    profile = services.voice_store.get_profile(decision.result_id)
                except ValueError, VoiceStoreUnavailableError:
                    return error_response(
                        409,
                        request_id,
                        "idempotency_result_unavailable",
                        "The original idempotent clone result is no longer available",
                    )
                if not _clone_result_matches(
                    profile,
                    name=name,
                    ref_text=ref_text,
                    canonical_wav=canonical_wav,
                ):
                    return error_response(
                        409,
                        request_id,
                        "voice_already_exists",
                        "Idempotency result does not match the clone payload",
                    )
                return JSONResponse(
                    status_code=201,
                    content=_voice_entry(
                        profile,
                        active,
                        services.tts_ready,
                        synthesizer=services.tts_synthesizer,
                        tts_execution=services.tts_execution,
                        strict_validation=True,
                        voice_store=services.voice_store,
                    ),
                )

        try:
            profile = services.voice_store.create_cloned_profile(
                name=name.strip(),
                ref_text=ref_text.strip(),
                audio_bytes=canonical_wav,
                voice_id=vid_str,
                duration_seconds=canonical_duration,
                quality=report.to_dict(),
                # A caller may omit Idempotency-Key, but an explicit voice id
                # must still be create-only. The conflict handler below
                # reconciles keyed retries; unkeyed collisions return 409.
                create_only=True,
            )
            if idempotency_key and fingerprint is not None:
                result_id = services.voice_clone_journal.complete(
                    owner=_CLONE_IDEMPOTENCY_OWNER,
                    operation=_CLONE_IDEMPOTENCY_OPERATION,
                    key=idempotency_key,
                    fingerprint=fingerprint,
                    result_id=profile.id,
                )
                if result_id != profile.id:
                    return error_response(
                        409,
                        request_id,
                        "idempotency_conflict",
                        "Another completed result already owns this Idempotency-Key",
                    )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except IdempotencyStoreUnavailableError:
            # If publication already happened, preserve pending state. Retrying must
            # not create a second voice until an operator resolves the unknown state.
            return error_response(
                503,
                request_id,
                "idempotency_store_unavailable",
                "Voice may have been created but durable completion could not be recorded",
                retryable=True,
            )
        except VoiceAlreadyExistsError:
            if idempotency_key is None or fingerprint is None or vid_str is None:
                return error_response(
                    409,
                    request_id,
                    "voice_already_exists",
                    "Target voice already exists",
                )
            try:
                profile = services.voice_store.get_profile(vid_str)
                if not _clone_result_matches(
                    profile,
                    name=name,
                    ref_text=ref_text,
                    canonical_wav=canonical_wav,
                ):
                    return error_response(
                        409,
                        request_id,
                        "voice_already_exists",
                        "Target voice ID is owned by a different clone payload",
                    )
                services.voice_clone_journal.complete(
                    owner=_CLONE_IDEMPOTENCY_OWNER,
                    operation=_CLONE_IDEMPOTENCY_OPERATION,
                    key=idempotency_key,
                    fingerprint=fingerprint,
                    result_id=profile.id,
                )
            except ValueError, IdempotencyStoreUnavailableError:
                return error_response(
                    503,
                    request_id,
                    "idempotency_store_unavailable",
                    "Concurrent clone result could not be reconciled",
                    retryable=True,
                )
        except ValueError as exc:
            return error_response(400, request_id, "voice_creation_failed", str(exc))

        return JSONResponse(
            status_code=201,
            content=_voice_entry(
                profile,
                active,
                services.tts_ready,
                synthesizer=services.tts_synthesizer,
                tts_execution=services.tts_execution,
                strict_validation=True,
                voice_store=services.voice_store,
            ),
        )

    @router.get("/v1/speechrail/voices/clone/idempotency")
    async def clone_idempotency_status(request: Request) -> JSONResponse:
        """Read durable clone operation state by proving possession of its key."""

        request_id = getattr(request.state, "request_id", "") or "req_clone"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        idempotency_key = request.headers.get("Idempotency-Key")
        if not idempotency_key:
            return error_response(
                400,
                request_id,
                "idempotency_key_required",
                "Idempotency-Key header is required",
            )
        try:
            decision = services.voice_clone_journal.lookup(
                owner=_CLONE_IDEMPOTENCY_OWNER,
                operation=_CLONE_IDEMPOTENCY_OPERATION,
                key=idempotency_key,
            )
        except IdempotencyStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "idempotency_store_unavailable",
                "Durable idempotency state is unavailable",
                retryable=True,
            )
        if decision is None:
            return error_response(
                404,
                request_id,
                "idempotency_not_found",
                "No clone operation is recorded for this key",
            )
        return JSONResponse(
            status_code=200,
            content={
                "state": decision.state,
                "result_id": decision.result_id,
            },
        )

    @router.post("/v1/voices/clone/validate")
    async def validate_voice_clone(
        request: Request,
        audio: UploadFile = File(...),  # noqa: B008 - FastAPI parameter marker.
        ref_text: str = Form(...),
        name: str = Form(...),
        voice_id: str | None = Form(default=None, alias="id"),
    ) -> JSONResponse:
        """Validate clone input quality without creating a profile."""
        request_id: str = getattr(request.state, "request_id", "") or "req_validate"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        variant = active.tts_clone.variant if active.tts_clone is not None else None
        if variant != "base":
            tier_name = active.profile or "custom"
            return error_response(
                400,
                request_id,
                "voice_cloning_unsupported",
                (
                    f"Active TTS tier ({tier_name}) variant '{variant}' "
                    "does not provide the Base clone capability"
                ),
            )
        if not name or not name.strip():
            return error_response(400, request_id, "invalid_name", "Voice name is required")
        if len(name) > _CLONE_NAME_MAX_LENGTH:
            return error_response(
                400,
                request_id,
                "invalid_name",
                f"Voice name must not exceed {_CLONE_NAME_MAX_LENGTH} characters",
            )
        if not ref_text or not ref_text.strip():
            return error_response(
                400, request_id, "invalid_ref_text", "Reference text (ref_text) is required"
            )
        if len(ref_text) > _CLONE_REF_TEXT_MAX_LENGTH:
            return error_response(
                400,
                request_id,
                "invalid_ref_text",
                (f"Reference text must not exceed {_CLONE_REF_TEXT_MAX_LENGTH} characters"),
            )

        _requested_voice_id, voice_id_error = _normalized_clone_voice_id(voice_id)
        if voice_id_error is not None:
            return error_response(
                400,
                request_id,
                "invalid_voice_id",
                voice_id_error,
                param="id",
            )

        audio_content, read_error = await _read_uploaded_audio(audio, request_id)
        if read_error is not None:
            return read_error

        ffmpeg_cmd = str(resolved.ffmpeg_path) if resolved.ffmpeg_path else "ffmpeg"
        try:
            wav_bytes, _duration = await _transcode_clone_audio(audio_content, ffmpeg_cmd)
        except RuntimeError as exc:
            return error_response(500, request_id, "dependency_missing", str(exc))
        except ValueError as exc:
            err_str = str(exc)
            if "too short" in err_str:
                code = "audio_too_short"
            elif "too long" in err_str:
                code = "audio_too_long"
            else:
                code = "invalid_audio"
            return error_response(400, request_id, code, err_str)

        try:
            evaluation = _evaluate_clone_reference_audio(wav_bytes)
        except ValueError as exc:
            err_str = str(exc)
            if "too short" in err_str:
                code = "audio_too_short"
            elif "too long" in err_str:
                code = "audio_too_long"
            else:
                code = "invalid_audio"
            return error_response(400, request_id, code, err_str)
        return JSONResponse(status_code=200, content=evaluation.report.to_dict())

    @router.post("/v1/speechrail/voices/{voice_id}/quality-runs")
    @router.post("/v1/voices/{voice_id}/quality-runs")
    async def run_voice_quality(voice_id: str, request: Request) -> JSONResponse:
        """Run bounded quality probes against a voice profile."""
        request_id: str = getattr(request.state, "request_id", "") or "req_quality"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            body = await request.json()
        except Exception:
            return error_response(400, request_id, "invalid_json", "Invalid JSON payload")
        if not isinstance(body, dict):
            return error_response(400, request_id, "invalid_payload", "JSON object expected")

        probe_set = body.get("probe_set", "voice_quality_v1_zh")
        if probe_set != "voice_quality_v1_zh":
            return error_response(
                422,
                request_id,
                "validation_error",
                "Unknown probe_set; expected voice_quality_v1_zh",
            )
        runs = body.get("runs", 3)
        if type(runs) is not int or not 1 <= runs <= 3:
            return error_response(
                422, request_id, "validation_error", "runs must be an integer between 1 and 3"
            )

        if body.get("include_audio"):
            return error_response(
                422,
                request_id,
                "include_audio_unsupported",
                "include_audio is not supported; probe audio is not returned",
            )

        try:
            result = await execute_voice_quality_run(
                voice_id=voice_id,
                registry=services.voice_store,
                active=active,
                runtime=ValidationRuntime(
                    synthesizer=services.tts_synthesizer,
                    tts_execution=services.tts_execution,
                    transcriber=services.batch_transcriber,
                    governor=services.governor,
                    admission=services.admission,
                    tts_ready=services.tts_ready,
                    asr_ready=services.asr_ready,
                ),
                runs=runs,
                probe_set=str(probe_set),
                request_id=request_id,
                expires_at=asyncio.get_running_loop().time() + resolved.request_timeout_seconds,
            )
        except GovernorLaneIsolatedError:
            return backend_reclamation_error_response(request_id)
        except GovernorQueueFullError, QueueFullError:
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
        except VoiceValidationExecutionError as exc:
            return error_response(
                503,
                request_id,
                exc.code,
                str(exc),
                retryable=exc.retryable,
            )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except ValueError:
            return error_response(
                404,
                request_id,
                "voice_not_found",
                f"Voice {voice_id} not found",
            )
        report = result.report
        _LOGGER.info(
            "voice quality run: policy=%s status=%s probes=%d/%d model=%s variant=%s service=%s",
            report.policy_version,
            report.status,
            report.synthesis.successful_probe_count,
            report.synthesis.probe_count,
            resolved.tts_model_id,
            active.tts.variant if active.tts is not None else None,
            resolved.version,
        )
        if request.url.path.startswith("/v1/speechrail/"):
            content = {
                "legacy_report": report.to_dict(),
                "evidence": result.evidence,
                "validation_persisted": result.validation_persisted,
            }
        else:
            content = {**report.to_dict(), "validation_persisted": result.validation_persisted}
        return JSONResponse(status_code=200, content=content)

    @router.delete("/v1/voices/{voice_id}")
    async def delete_voice(voice_id: str, request: Request) -> JSONResponse:
        """Delete a persistent custom voice; system preset voices are protected."""
        request_id: str = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            services.voice_store.delete_custom_profile(voice_id)
            return JSONResponse(status_code=200, content={"status": "deleted", "id": voice_id})
        except VoiceInUseError:
            response = error_response(
                409,
                request_id,
                "voice_in_use",
                "Custom voice is currently in use",
                retryable=True,
            )
            response.headers["Retry-After"] = "1"
            return response
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except ValueError as exc:
            return error_response(
                403,
                request_id,
                "voice_deletion_failed",
                str(exc),
            )
        except KeyError:
            return error_response(
                404,
                request_id,
                "voice_not_found",
                f"Voice {voice_id} not found",
            )

    @router.get("/metrics")
    async def metrics(request: Request) -> Response:
        """Expose Prometheus / JSON metrics via the unified Metrics engine."""
        gov_snap = services.governor.snapshot()
        worker_states = services.lifecycle.worker_states()
        resource_status = services.runtime_resource_status(gov_snap)
        readiness = {
            "asr": services.asr_ready,
            "tts": services.tts_ready,
            "diarization": services.diarization_ready,
            "realtime_vad": bool(services.realtime_vad_status["ready"]),
        }

        accept = request.headers.get("accept", "")
        if "application/json" in accept and "text/plain" not in accept:
            return JSONResponse(
                content=services.metrics.render_json(
                    governor_snapshot=gov_snap,
                    worker_states=worker_states,
                    readiness=readiness,
                    resources=resource_status,
                )
            )

        return Response(
            content=services.metrics.render_prometheus(
                governor_snapshot=gov_snap,
                worker_states=worker_states,
                readiness=readiness,
                resources=resource_status,
            ),
            media_type="text/plain; version=0.0.4; charset=utf-8",
        )

    return router
