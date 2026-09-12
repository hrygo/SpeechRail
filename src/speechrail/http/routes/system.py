"""Read-only system endpoints: process health, readiness and model identity."""

from __future__ import annotations

import asyncio
import hashlib
import io
import json
import logging
import struct
import threading
import wave
from collections import OrderedDict
from pathlib import Path
from typing import Any, cast

from fastapi import APIRouter, File, Form, Request, Response, UploadFile
from fastapi.responses import JSONResponse

from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import (
    TTSDeliveryError,
    iter_until,
    iter_validated_audio,
)
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.compatibility.openai_realtime import (
    asr_model_aliases,
    diarization_model_aliases,
    tts_model_aliases,
)
from speechrail.config.model_catalog import ModelArtifact
from speechrail.config.selection import ActiveModelCatalog, active_model_catalog
from speechrail.domain import voice_quality as vq
from speechrail.domain.ports import (
    BatchTranscriber,
    SpeechRequest,
    SpeechSynthesizer,
    TranscriptionRequest,
)
from speechrail.domain.tts import (
    VOICE_ALIASES,
    VoiceInUseError,
    VoiceProfile,
    VoiceStoreUnavailableError,
    canonicalize_clone_reference_audio,
    get_voice_registry,
)
from speechrail.domain.voice_quality_metrics import compute_output_quality_metrics
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error, error_response
from speechrail.runtime.admission import QueueFullError
from speechrail.runtime.resource_governor import GovernorQueueFullError, WorkClass

_CLONE_PROMPTS_ASSET = (
    Path(__file__).resolve().parent.parent.parent
    / "assets"
    / "clone_prompts.json"
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
        "warm_capability",
    }
)
_LOGGER = logging.getLogger(__name__)

# Bounded idempotency store keyed by (Idempotency-Key, audio sha256, sha256 of
# ref_text). It retains only the created profile id — never the raw ref_text or
# the full VoiceProfile — and evicts the oldest entry past 128 keys.
_CLONE_IDEMPOTENCY_MAX_ENTRIES = 128
_clone_idempotency: OrderedDict[tuple[str, str, str], str] = OrderedDict()
_clone_idempotency_lock = threading.Lock()


def _clone_idempotency_key(
    idempotency_key: str, audio_content: bytes, ref_text: str
) -> tuple[str, str, str]:
    audio_hash = hashlib.sha256(audio_content).hexdigest()
    ref_hash = hashlib.sha256(ref_text.strip().encode("utf-8")).hexdigest()
    return (idempotency_key, audio_hash, ref_hash)


def _store_clone_idempotency_locked(
    cache_key: tuple[str, str, str], profile_id: str
) -> None:
    _clone_idempotency[cache_key] = profile_id
    _clone_idempotency.move_to_end(cache_key)
    while len(_clone_idempotency) > _CLONE_IDEMPOTENCY_MAX_ENTRIES:
        _clone_idempotency.popitem(last=False)


def _tts_lifecycle_diagnostics(
    services: AppServices,
) -> dict[str, int | bool | str | None] | None:
    """Return safe TTS lifecycle counters when this backend exposes them."""

    stats = getattr(services.tts_synthesizer, "lifecycle_stats", None)
    if not isinstance(stats, dict):
        return None
    return {
        name: value
        for name, value in stats.items()
        if name in _TTS_LIFECYCLE_FIELDS
        and (value is None or isinstance(value, (bool, int, str)))
    }


def _model_entry(
    model_id: str,
    active: ActiveModelCatalog,
    artifact: ModelArtifact | None,
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
            supports_voice_design = artifact.variant == "voice_design"
            supports_clone = (
                active.tts_clone is not None and active.tts_clone.variant == "base"
            )
            entry["capabilities"] = {
                "supports_preview": supports_voice_design,
                "supports_clone": supports_clone,
                "supports_instruction": supports_voice_design,
            }
    return entry


def _voice_entry(
    profile: VoiceProfile,
    active: ActiveModelCatalog,
    tts_ready: bool,
    *,
    enabled: bool = True,
) -> dict[str, Any]:
    variant = active.tts.variant if active.tts is not None else None
    available = tts_ready and enabled
    supports_speaker = False
    supports_instruction = False
    supports_clone = False
    binding_variant = (
        active.tts_clone.variant
        if profile.mode == "clone" and active.tts_clone is not None
        else variant
    )
    if binding_variant in {"voice_design", "custom_voice", "base"}:
        try:
            binding = resolve_binding(binding_variant, profile.id)
        except ValueError:
            available = False
        else:
            capabilities = binding.capabilities
            supports_speaker = capabilities.supports_speaker
            supports_instruction = capabilities.supports_instruction
            supports_clone = capabilities.supports_clone

    entry: dict[str, Any] = {
        "id": profile.id,
        "name": profile.name or profile.id,
        "description": profile.description,
        "instruction": profile.instruction,
        "seed": profile.seed,
        "aliases": sorted(
            alias for alias, preset in VOICE_ALIASES.items() if preset == profile.id
        ),
        "is_default": profile.is_default,
        "is_system": profile.is_system,
        "created_at": profile.created_at,
        "available": available,
        "variant": binding_variant,
        "capabilities": {
            "supports_speaker": supports_speaker,
            "supports_instruction": supports_instruction,
            "supports_clone": supports_clone,
        },
        "mode": profile.mode,
    }
    if profile.ref_text is not None:
        entry["ref_text"] = profile.ref_text
    if profile.duration_seconds > 0:
        entry["duration_seconds"] = profile.duration_seconds
    if profile.quality is not None:
        entry["quality"] = profile.quality
    return entry


def _empty_reference() -> vq.VoiceQualityReference:
    return vq.VoiceQualityReference(
        duration_seconds=0.0,
        sample_rate=24_000,
        channels=1,
        speech_active_ratio=0.0,
        noise_floor_dbfs=0.0,
        estimated_snr_db=0.0,
        clipping_ratio=0.0,
        leading_silence_seconds=0.0,
        trailing_silence_seconds=0.0,
        transcript_match=None,
    )


def _empty_synthesis() -> vq.VoiceQualitySynthesis:
    return vq.VoiceQualitySynthesis(
        probe_count=0,
        successful_probe_count=0,
        active_rms_dbfs=0.0,
        peak_dbfs=0.0,
        chunk_jump_p95_db=0.0,
        clipping_ratio=0.0,
        deterministic=False,
    )


def _grade_clone_audio(wav_bytes: bytes) -> vq.VoiceQualityReport:
    with wave.open(io.BytesIO(wav_bytes), "rb") as wf:
        sample_rate = wf.getframerate()
        channels = wf.getnchannels()
        pcm = wf.readframes(wf.getnframes())
    leading, trailing = vq.leading_trailing_silence_seconds(pcm, sample_rate)
    reference = vq.VoiceQualityReference(
        duration_seconds=vq.duration_seconds(pcm, sample_rate),
        sample_rate=sample_rate,
        channels=channels,
        speech_active_ratio=vq.speech_active_ratio(pcm, sample_rate),
        noise_floor_dbfs=vq.noise_floor_dbfs(pcm),
        estimated_snr_db=vq.estimated_snr_db(pcm, sample_rate),
        clipping_ratio=vq.clipping_ratio(pcm),
        leading_silence_seconds=leading,
        trailing_silence_seconds=trailing,
        transcript_match=None,
    )
    return vq.make_quality_report(reference, _empty_synthesis())


def _quality_reject_response(
    request_id: str, report: vq.VoiceQualityReport
) -> JSONResponse:
    content = error(
        message="Reference audio failed the voice quality gate",
        error_type="invalid_request_error",
        code="voice_quality_reject",
        request_id=request_id,
        retryable=False,
    )
    content["quality_report"] = report.to_dict()
    return JSONResponse(
        status_code=400,
        content=content,
        headers={"X-SpeechRail-Error-Code": "voice_quality_reject"},
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


def _transcode_clone_audio(audio_content: bytes, ffmpeg_cmd: str) -> tuple[bytes, float]:
    from speechrail.domain.tts import transcode_and_validate_clone_audio

    return transcode_and_validate_clone_audio(
        audio_content,
        ffmpeg_path=ffmpeg_cmd,
        min_duration=2.0,
        max_duration=45.0,
        target_sample_rate=24_000,
        skip_signal_validation=True,
    )


_CLONE_SPEED_UNSUPPORTED_CODE = vq.VoiceQualityFailureCode.CLONE_SPEED_UNSUPPORTED.value
_OUTPUT_INVALID_CODE = vq.VoiceQualityFailureCode.OUTPUT_INVALID.value
_TRANSCRIPTION_UNAVAILABLE_CODE = (
    vq.VoiceQualityFailureCode.TRANSCRIPTION_UNAVAILABLE.value
)
_TRANSCRIPT_PASS_SCORE = 0.92
_TRANSCRIPT_WARN_SCORE = 0.80
_MAX_QUALITY_PROBE_PCM_BYTES = 30 * 24_000 * 2


def _classify_probe_failure(exc: BaseException) -> str:
    if isinstance(exc, RuntimeError) and "speed" in str(exc).lower():
        return _CLONE_SPEED_UNSUPPORTED_CODE
    if isinstance(exc, (TTSDeliveryError, ValueError, TypeError)):
        return _OUTPUT_INVALID_CODE
    return vq.VoiceQualityFailureCode.PROBE_FAILED.value


async def _synthesize_probes(
    synthesizer: SpeechSynthesizer,
    voice_id: str,
    repetitions: int,
    *,
    expires_at: float | None = None,
) -> tuple[bytes, int, int, list[str], bool, dict[str, bytes]]:
    pcm = bytearray()
    ok = 0
    failure_codes: list[str] = []
    probes = vq.VOICE_QUALITY_V1_ZH_PROBES
    digests_by_probe: dict[str, list[bytes]] = {probe["id"]: [] for probe in probes}
    representative_pcm: dict[str, bytes] = {}

    for probe in probes:
        for _ in range(repetitions):
            synthesis = SpeechRequest(
                text=probe["text"],
                voice=voice_id,
                output_format="pcm16",
                sample_rate=24_000,
            )
            probe_pcm = bytearray()
            try:
                source = iter_validated_audio(synthesizer.synthesize(synthesis))
                bounded = (
                    iter_until(source, expires_at) if expires_at is not None else source
                )
                async for chunk in bounded:
                    if len(probe_pcm) + len(chunk.audio) > _MAX_QUALITY_PROBE_PCM_BYTES:
                        raise ValueError("quality probe audio exceeds 30 seconds")
                    probe_pcm.extend(chunk.audio)
            except TimeoutError:
                raise
            except Exception as exc:
                failure_codes.append(_classify_probe_failure(exc))
                continue
            if not probe_pcm or len(probe_pcm) % 2 != 0:
                failure_codes.append(_OUTPUT_INVALID_CODE)
                continue

            try:
                probe_metrics = compute_output_quality_metrics(
                    bytes(probe_pcm),
                    sample_rate=24_000,
                    probe_count=1,
                    successful_probe_count=1,
                    deterministic=True,
                )
            except (ValueError, TypeError):
                failure_codes.append(_OUTPUT_INVALID_CODE)
                continue

            if cast(float, probe_metrics["active_rms_dbfs"]) <= -45.0:
                failure_codes.append(_OUTPUT_INVALID_CODE)
                continue
            if cast(float, probe_metrics["clipping_ratio"]) > 0.0:
                failure_codes.append(vq.VoiceQualityFailureCode.OUTPUT_PEAK_EXCEEDED.value)
                continue

            payload = bytes(probe_pcm)
            digests_by_probe[probe["id"]].append(hashlib.sha256(payload).digest())
            representative_pcm.setdefault(probe["id"], payload)
            pcm.extend(payload)
            ok += 1

    attempted = len(probes) * repetitions
    deterministic = repetitions >= 2 and all(
        len(digests) == repetitions and len(set(digests)) == 1
        for digests in digests_by_probe.values()
    )
    if repetitions >= 2 and ok == attempted and not deterministic:
        failure_codes.append(vq.VoiceQualityFailureCode.OUTPUT_NONDETERMINISTIC.value)

    return (
        bytes(pcm),
        attempted,
        ok,
        failure_codes,
        deterministic,
        representative_pcm,
    )


def _synthesis_report(
    pcm: bytes,
    attempted: int,
    ok: int,
    *,
    deterministic: bool,
    transcript_match: float | None = None,
    intelligibility_evaluated: bool = False,
) -> vq.VoiceQualitySynthesis:
    if not pcm or ok == 0:
        return vq.VoiceQualitySynthesis(
            probe_count=attempted,
            successful_probe_count=0,
            active_rms_dbfs=-240.0,
            peak_dbfs=-240.0,
            chunk_jump_p95_db=0.0,
            clipping_ratio=0.0,
            deterministic=False,
            transcript_match=transcript_match,
            intelligibility_evaluated=intelligibility_evaluated,
        )
    metrics = compute_output_quality_metrics(
        pcm,
        sample_rate=24_000,
        probe_count=attempted,
        successful_probe_count=ok,
        deterministic=deterministic,
    )
    return vq.VoiceQualitySynthesis(
        probe_count=cast(int, metrics["probe_count"]),
        successful_probe_count=cast(int, metrics["successful_probe_count"]),
        active_rms_dbfs=cast(float, metrics["active_rms_dbfs"]),
        peak_dbfs=cast(float, metrics["peak_dbfs"]),
        chunk_jump_p95_db=cast(float, metrics["chunk_jump_p95_db"]),
        clipping_ratio=cast(float, metrics["clipping_ratio"]),
        deterministic=cast(bool, metrics["deterministic"]),
        transcript_match=transcript_match,
        intelligibility_evaluated=intelligibility_evaluated,
    )


def _resample_quality_pcm_24k_to_16k(pcm: bytes) -> bytes:
    """Linearly resample mono PCM16 from the TTS 24 kHz rate to ASR 16 kHz."""
    if not pcm or len(pcm) % 2 != 0:
        raise ValueError("invalid PCM16 payload")
    count = len(pcm) // 2
    samples = struct.unpack(f"<{count}h", pcm)
    output_count = count * 2 // 3
    if output_count <= 0:
        raise ValueError("PCM16 payload is too short")
    output = bytearray(output_count * 2)
    for index in range(output_count):
        source_numerator = index * 3
        left = source_numerator // 2
        half_step = source_numerator % 2
        if left >= count - 1:
            value = samples[-1]
        elif half_step:
            value = round((samples[left] + samples[left + 1]) / 2.0)
        else:
            value = samples[left]
        struct.pack_into("<h", output, index * 2, max(-32768, min(32767, value)))
    return bytes(output)


async def _evict_quality_tts_if_supported(synthesizer: SpeechSynthesizer) -> None:
    evict = getattr(synthesizer, "evict_warm_capability", None)
    if callable(evict):
        await evict()


async def _evaluate_probe_intelligibility(
    services: AppServices,
    transcriber: BatchTranscriber,
    representative_pcm: dict[str, bytes],
    *,
    request_id: str,
    expires_at: float,
) -> float:
    """Transcribe one valid sample per fixed probe after the TTS phase completes."""
    scores: list[float] = []
    async with services.governor.reserve(WorkClass.BATCH_ASR, expires_at=expires_at):
        for probe in vq.VOICE_QUALITY_V1_ZH_PROBES:
            pcm = representative_pcm.get(probe["id"])
            if pcm is None:
                raise ValueError("missing representative quality probe audio")
            remaining = expires_at - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise TimeoutError
            request = TranscriptionRequest(
                request_id=f"{request_id}:intelligibility:{probe['id']}",
                audio=_resample_quality_pcm_24k_to_16k(pcm),
                language="zh",
                prompt="",
                include_timestamps=False,
            )
            result = await services.admission.run(
                lambda request=request: transcriber.transcribe(request),
                deadline=remaining,
            )
            scores.append(vq.transcript_match_score(probe["text"], result.text))
    return min(scores) if scores else 0.0


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
            "tts_ready": services.tts_ready,
            "tts_warm": services.tts_warm,
            "diarization_ready": services.diarization_ready,
            "diarization": services.diarization_status,
            "asr_state": states.get("asr", "unconfigured"),
            "tts_state": states.get("tts", "unconfigured"),
            "tts_lifecycle": _tts_lifecycle_diagnostics(services),
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
            _model_entry(tts_target, active, active.tts),
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
                        "supports_preview": active.tts is not None
                        and active.tts.variant == "voice_design",
                        "supports_clone": active.tts_clone is not None
                        and active.tts_clone.variant == "base",
                        "supports_instruction": active.tts is not None
                        and active.tts.variant == "voice_design",
                    },
                }
            )
        for compat in resolved.compatibility_model_ids:
            if compat in diarization_model_aliases() and not services.diarization_ready:
                continue
            if compat in {asr_target, tts_target} or any(
                d["id"] == compat for d in data
            ):
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
        registry = get_voice_registry()
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
                _voice_entry(
                    profile,
                    active,
                    services.tts_ready,
                    enabled=not profile.is_system or profile.id in resolved.tts_voice_ids,
                )
                for profile in profiles
            ],
        }

    @router.post("/v1/voices")
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
        if seed is not None and (
            type(seed) is not int or seed < 0 or seed > _MAX_VOICE_SEED
        ):
            return error_response(
                400,
                request_id,
                "invalid_seed",
                f"Voice seed must be an integer between 0 and {_MAX_VOICE_SEED}",
            )
        vid_str = (
            voice_id.strip().lower()
            if isinstance(voice_id, str) and voice_id.strip()
            else None
        )
        try:
            profile = get_voice_registry().create_custom_profile(
                name=name.strip(),
                instruction=instruction.strip(),
                voice_id=vid_str,
                seed=seed,
            )
            return JSONResponse(
                status_code=201,
                content=_voice_entry(profile, active, services.tts_ready),
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

    @router.post("/v1/voices/clone")
    async def clone_voice(
        request: Request,
        audio: UploadFile = File(...),  # noqa: B008 - FastAPI parameter marker.
        ref_text: str = Form(...),
        name: str = Form(...),
        voice_id: str | None = Form(
            default=None, alias="id"
        ),
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
                    "does not provide the Base clone capability; switch to quality profile"
                ),
            )

        if not name or not name.strip():
            return error_response(400, request_id, "invalid_name", "Voice name is required")
        if not ref_text or not ref_text.strip():
            return error_response(
                400, request_id, "invalid_ref_text", "Reference text (ref_text) is required"
            )

        audio_content, read_error = await _read_uploaded_audio(audio, request_id)
        if read_error is not None:
            return read_error

        idempotency_key = request.headers.get("Idempotency-Key")
        cache_key: tuple[str, str, str] | None = None
        if idempotency_key:
            cache_key = _clone_idempotency_key(idempotency_key, audio_content, ref_text)
            cached_id = _clone_idempotency.get(cache_key)
            if cached_id is not None:
                try:
                    profile = get_voice_registry().get_profile(cached_id)
                except ValueError:
                    # Stale idempotency entry: the cached profile was deleted after
                    # the original clone. Drop the key and fall through to normal
                    # creation instead of leaking a bare 500.
                    with _clone_idempotency_lock:
                        _clone_idempotency.pop(cache_key, None)
                else:
                    return JSONResponse(
                        status_code=201,
                        content=_voice_entry(profile, active, services.tts_ready),
                    )

        ffmpeg_cmd = str(resolved.ffmpeg_path) if resolved.ffmpeg_path else "ffmpeg"
        try:
            wav_bytes, duration = _transcode_clone_audio(audio_content, ffmpeg_cmd)
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

        report = _grade_clone_audio(wav_bytes)
        if report.status == vq.VoiceQualityStatus.REJECT.value:
            return _quality_reject_response(request_id, report)
        try:
            canonical_wav, canonical_duration = canonicalize_clone_reference_audio(
                wav_bytes, target_sample_rate=24_000
            )
        except ValueError as exc:
            return error_response(400, request_id, "invalid_audio", str(exc))

        vid_str = (
            voice_id.strip().lower()
            if isinstance(voice_id, str) and voice_id.strip()
            else None
        )

        def _build_profile() -> VoiceProfile:
            return get_voice_registry().create_cloned_profile(
                name=name.strip(),
                ref_text=ref_text.strip(),
                audio_bytes=canonical_wav,
                voice_id=vid_str,
                duration_seconds=canonical_duration,
                quality=report.to_dict(),
            )

        def _create_or_reuse() -> VoiceProfile:
            if cache_key is None:
                return _build_profile()
            with _clone_idempotency_lock:
                existing_id = _clone_idempotency.get(cache_key)
                if existing_id is not None:
                    try:
                        return get_voice_registry().get_profile(existing_id)
                    except ValueError:
                        # Stale idempotency entry: the cached profile was deleted.
                        # Drop the key and re-create instead of failing the request.
                        _clone_idempotency.pop(cache_key, None)
                profile = _build_profile()
                _store_clone_idempotency_locked(cache_key, profile.id)
                return profile

        try:
            profile = _create_or_reuse()
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        except ValueError as exc:
            return error_response(400, request_id, "voice_creation_failed", str(exc))

        return JSONResponse(
            status_code=201,
            content=_voice_entry(profile, active, services.tts_ready),
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
                    "does not provide the Base clone capability; switch to quality profile"
                ),
            )
        if not name or not name.strip():
            return error_response(400, request_id, "invalid_name", "Voice name is required")
        if not ref_text or not ref_text.strip():
            return error_response(
                400, request_id, "invalid_ref_text", "Reference text (ref_text) is required"
            )

        audio_content, read_error = await _read_uploaded_audio(audio, request_id)
        if read_error is not None:
            return read_error

        ffmpeg_cmd = str(resolved.ffmpeg_path) if resolved.ffmpeg_path else "ffmpeg"
        try:
            wav_bytes, _duration = _transcode_clone_audio(audio_content, ffmpeg_cmd)
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

        report = _grade_clone_audio(wav_bytes)
        return JSONResponse(status_code=200, content=report.to_dict())

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

        synthesizer = services.tts_synthesizer
        if synthesizer is None or not services.tts_ready:
            return error_response(
                503,
                request_id,
                "backend_not_ready",
                "SpeechRail TTS backend is not ready",
                retryable=True,
            )

        registry = get_voice_registry()
        expires_at = asyncio.get_running_loop().time() + resolved.request_timeout_seconds
        try:
            async with services.governor.reserve(
                WorkClass.BATCH_TTS, expires_at=expires_at
            ):
                with registry.lease_profile(voice_id) as profile:
                    (
                        pcm,
                        attempted,
                        ok,
                        probe_failure_codes,
                        deterministic,
                        representative_pcm,
                    ) = await _synthesize_probes(
                        synthesizer,
                        profile.id,
                        runs,
                        expires_at=expires_at,
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
                503,
                request_id,
                "backend_timeout",
                "Voice quality run timed out",
                retryable=True,
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
                404, request_id, "voice_not_found", f"Voice {voice_id} not found"
            )

        transcript_match: float | None = None
        intelligibility_evaluated = False
        intelligibility_unavailable = False
        if ok == attempted and not probe_failure_codes:
            transcriber = services.batch_transcriber
            if transcriber is None or not services.asr_ready:
                intelligibility_unavailable = True
            else:
                try:
                    await _evict_quality_tts_if_supported(synthesizer)
                    transcript_match = await _evaluate_probe_intelligibility(
                        services,
                        transcriber,
                        representative_pcm,
                        request_id=request_id,
                        expires_at=expires_at,
                    )
                    intelligibility_evaluated = True
                except (GovernorQueueFullError, QueueFullError):
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
                        503,
                        request_id,
                        "backend_timeout",
                        "Voice intelligibility validation timed out",
                        retryable=True,
                    )
                except Exception:
                    _LOGGER.exception(
                        "voice intelligibility validation unavailable: request_id=%s",
                        request_id,
                    )
                    intelligibility_unavailable = True

        output_invalid = False
        try:
            synthesis = _synthesis_report(
                pcm,
                attempted,
                ok,
                deterministic=deterministic,
                transcript_match=transcript_match,
                intelligibility_evaluated=intelligibility_evaluated,
            )
        except (ValueError, TypeError):
            synthesis = vq.VoiceQualitySynthesis(
                probe_count=attempted,
                successful_probe_count=ok,
                active_rms_dbfs=-240.0,
                peak_dbfs=-240.0,
                chunk_jump_p95_db=0.0,
                clipping_ratio=0.0,
                deterministic=False,
                transcript_match=transcript_match,
                intelligibility_evaluated=intelligibility_evaluated,
            )
            output_invalid = True

        failure_codes = list(dict.fromkeys(probe_failure_codes))
        if output_invalid and _OUTPUT_INVALID_CODE not in failure_codes:
            failure_codes.append(_OUTPUT_INVALID_CODE)

        if intelligibility_unavailable:
            failure_codes.append(_TRANSCRIPTION_UNAVAILABLE_CODE)

        if ok != attempted or output_invalid or any(
            code != _TRANSCRIPTION_UNAVAILABLE_CODE for code in failure_codes
        ):
            status = vq.VoiceQualityStatus.REJECT.value
        elif not intelligibility_evaluated or transcript_match is None:
            status = vq.VoiceQualityStatus.UNEVALUATED.value
        elif transcript_match < _TRANSCRIPT_WARN_SCORE:
            status = vq.VoiceQualityStatus.REJECT.value
            failure_codes.append(vq.VoiceQualityFailureCode.TRANSCRIPT_MISMATCH.value)
        elif transcript_match < _TRANSCRIPT_PASS_SCORE:
            status = vq.VoiceQualityStatus.WARN.value
            failure_codes.append(vq.VoiceQualityFailureCode.TRANSCRIPT_MISMATCH.value)
        else:
            status = vq.VoiceQualityStatus.PASS.value
        failure_codes = list(dict.fromkeys(failure_codes))
        report = vq.VoiceQualityReport(
            policy_version=vq.POLICY_VERSION,
            status=status,
            run_id=vq.new_run_id(),
            tested_at=vq.now_iso8601_z(),
            reference=_empty_reference(),
            synthesis=synthesis,
            failure_codes=failure_codes,
        )
        variant_name = active.tts.variant if active.tts is not None else None
        _LOGGER.info(
            "voice quality run: policy=%s status=%s probes=%d/%d model=%s variant=%s service=%s",
            vq.POLICY_VERSION,
            status,
            ok,
            attempted,
            resolved.tts_model_id,
            variant_name,
            resolved.version,
        )
        return JSONResponse(status_code=200, content=report.to_dict())

    @router.delete("/v1/voices/{voice_id}")
    async def delete_voice(voice_id: str, request: Request) -> JSONResponse:
        """Delete a persistent custom voice; system preset voices are protected."""
        request_id: str = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            get_voice_registry().delete_custom_profile(voice_id)
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
                )
            )

        return Response(
            content=services.metrics.render_prometheus(
                governor_snapshot=gov_snap,
                worker_states=worker_states,
                readiness=readiness,
            ),
            media_type="text/plain; version=0.0.4; charset=utf-8",
        )

    return router
