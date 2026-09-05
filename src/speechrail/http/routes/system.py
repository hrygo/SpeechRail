"""Read-only system endpoints: process health, readiness and model identity."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse

from speechrail.application.services import AppServices
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.compatibility.openai_realtime import (
    asr_model_aliases,
    diarization_model_aliases,
    tts_model_aliases,
)
from speechrail.config import Settings
from speechrail.config.model_catalog import ModelArtifact, load_catalog
from speechrail.domain.tts import VOICE_ALIASES, VoiceProfile, get_voice_registry
from speechrail.http.errors import error_response


@dataclass(frozen=True, slots=True)
class _ActiveCatalog:
    profile: str | None
    asr: ModelArtifact | None
    tts: ModelArtifact | None


def _active_catalog(settings: Settings) -> _ActiveCatalog:
    """Match resolved managed model directories to the packaged immutable catalog."""

    catalog = load_catalog()
    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}
    asr_key = settings.qwen3_model_dir.name if settings.qwen3_model_dir else None
    tts_key = settings.qwen3_tts_model_dir.name if settings.qwen3_tts_model_dir else None
    asr = artifacts.get(asr_key) if asr_key else None
    tts = artifacts.get(tts_key) if tts_key else None
    profile = next(
        (
            preset.id
            for preset in catalog.presets
            if preset.asr == asr_key and preset.tts == tts_key
        ),
        None,
    )
    return _ActiveCatalog(profile=profile, asr=asr, tts=tts)


def _model_entry(
    model_id: str,
    active: _ActiveCatalog,
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
    return entry


def _voice_entry(
    profile: VoiceProfile,
    active: _ActiveCatalog,
    tts_ready: bool,
) -> dict[str, Any]:
    variant = active.tts.variant if active.tts is not None else None
    available = tts_ready
    supports_speaker = False
    supports_instruction = False
    if variant in {"voice_design", "custom_voice"}:
        try:
            binding = resolve_binding(variant, profile.id)
        except ValueError:
            available = False
        else:
            capabilities = binding.capabilities
            supports_speaker = capabilities.supports_speaker
            supports_instruction = capabilities.supports_instruction

    return {
        "id": profile.id,
        "name": profile.name or profile.id,
        "description": profile.description,
        "instruction": profile.instruction,
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
        },
    }


def create_system_router(services: AppServices) -> APIRouter:
    """Four read-only endpoints; no auth by design (loopback-first service)."""
    router = APIRouter()
    resolved = services.settings
    active = _active_catalog(resolved)

    @router.get("/health")
    async def health() -> dict[str, Any]:
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
            "data": [_voice_entry(p, active, services.tts_ready) for p in profiles],
        }

    @router.post("/v1/voices")
    async def create_voice(request: Request) -> JSONResponse:
        """Create a persistent custom voice using natural language instruction."""
        request_id: str = getattr(request.state, "request_id", "") or "req_voices"
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

    @router.delete("/v1/voices/{voice_id}")
    async def delete_voice(voice_id: str, request: Request) -> JSONResponse:
        """Delete a persistent custom voice; system preset voices are protected."""
        request_id: str = getattr(request.state, "request_id", "") or "req_voices"
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
