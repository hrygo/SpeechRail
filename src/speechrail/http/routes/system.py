"""Read-only system endpoints: process health, readiness and model identity."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from fastapi import APIRouter, File, Form, Request, Response, UploadFile
from fastapi.responses import JSONResponse

from speechrail.application.services import AppServices
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.compatibility.openai_realtime import (
    asr_model_aliases,
    diarization_model_aliases,
    tts_model_aliases,
)
from speechrail.config.model_catalog import ModelArtifact
from speechrail.config.selection import ActiveModelCatalog, active_model_catalog
from speechrail.domain.tts import VOICE_ALIASES, VoiceProfile, get_voice_registry
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error_response

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
    {"cooperative_cancel_supported", "fallback_abort_count", "reload_count"}
)


def _tts_lifecycle_diagnostics(services: AppServices) -> dict[str, int | bool] | None:
    """Return safe TTS lifecycle counters when this backend exposes them."""

    stats = getattr(services.tts_synthesizer, "lifecycle_stats", None)
    if not isinstance(stats, dict):
        return None
    return {
        name: value
        for name, value in stats.items()
        if name in _TTS_LIFECYCLE_FIELDS and isinstance(value, (bool, int))
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
            entry["capabilities"] = {
                "supports_preview": supports_voice_design,
                "supports_clone": supports_voice_design,
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
    if variant in {"voice_design", "custom_voice"}:
        try:
            binding = resolve_binding(variant, profile.id)
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
        "variant": variant,
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
    return entry


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
            "diarization_ready": services.diarization_ready,
            "diarization": services.diarization_status,
            "asr_state": states.get("asr", "unconfigured"),
            "tts_state": states.get("tts", "unconfigured"),
            "tts_lifecycle": _tts_lifecycle_diagnostics(services),
            "streaming_state": states.get("streaming", "unconfigured"),
            "realtime_vad": {
                "configured_engine": resolved.realtime_vad_engine,
                "resolved_engine": "silero" if resolved.resolves_to_silero_vad else "legacy",
                "speech_admission_enabled": resolved.realtime_speech_admission_enabled,
            },
            "ready": services.asr_ready or services.tts_ready,
        }

    @router.get("/readyz")
    async def readyz(request: Request) -> JSONResponse:
        if services.asr_ready or services.tts_ready:
            return JSONResponse(
                status_code=200,
                content={"ready": True, "diarization": services.diarization_status},
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
                        "supports_clone": active.tts is not None
                        and active.tts.variant == "voice_design",
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

    @router.get("/v1/voices")
    async def voices() -> dict[str, Any]:
        """List system preset voices and custom user-designed voices."""
        registry = get_voice_registry()
        profiles = registry.list_profiles()
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
        variant = active.tts.variant if active.tts is not None else None
        if variant != "voice_design":
            tier_name = active.profile or "custom"
            return error_response(
                400,
                request_id,
                "voice_cloning_unsupported",
                (
                    f"Active TTS tier ({tier_name}) variant '{variant}' "
                    "does not support voice cloning; switch to quality profile"
                ),
            )

        if not name or not name.strip():
            return error_response(400, request_id, "invalid_name", "Voice name is required")
        if not ref_text or not ref_text.strip():
            return error_response(
                400, request_id, "invalid_ref_text", "Reference text (ref_text) is required"
            )

        audio_content = bytearray()
        max_limit = 15 * 1024 * 1024
        while chunk := await audio.read(64 * 1024):
            audio_content.extend(chunk)
            if len(audio_content) > max_limit:
                return error_response(
                    413, request_id, "audio_too_large", "Audio file exceeds 15MB limit"
                )

        if len(audio_content) < 1024:
            return error_response(
                400, request_id, "audio_too_short", "Audio content is empty or too short"
            )

        ffmpeg_cmd = str(resolved.ffmpeg_path) if resolved.ffmpeg_path else "ffmpeg"
        try:
            from speechrail.domain.tts import transcode_and_validate_clone_audio

            wav_bytes, duration = transcode_and_validate_clone_audio(
                bytes(audio_content),
                ffmpeg_path=ffmpeg_cmd,
                min_duration=2.0,
                max_duration=45.0,
                target_sample_rate=24_000,
            )
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

        vid_str = (
            voice_id.strip().lower()
            if isinstance(voice_id, str) and voice_id.strip()
            else None
        )
        try:
            profile = get_voice_registry().create_cloned_profile(
                name=name.strip(),
                ref_text=ref_text.strip(),
                audio_bytes=wav_bytes,
                voice_id=vid_str,
                duration_seconds=duration,
            )
            return JSONResponse(
                status_code=201,
                content=_voice_entry(profile, active, services.tts_ready),
            )
        except ValueError as exc:
            return error_response(400, request_id, "voice_creation_failed", str(exc))

    @router.delete("/v1/voices/{voice_id}")
    async def delete_voice(voice_id: str, request: Request) -> JSONResponse:
        """Delete a persistent custom voice; system preset voices are protected."""
        request_id: str = getattr(request.state, "request_id", "") or "req_voices"
        if (auth_error := http_auth_error(request, resolved)) is not None:
            return auth_error
        try:
            get_voice_registry().delete_custom_profile(voice_id)
            return JSONResponse(status_code=200, content={"status": "deleted", "id": voice_id})
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
