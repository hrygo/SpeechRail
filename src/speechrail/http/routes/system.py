"""Read-only system endpoints: process health, readiness and model identity."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from speechrail.application.services import AppServices
from speechrail.compatibility.openai_realtime import (
    asr_model_aliases,
    diarization_model_aliases,
    tts_model_aliases,
)
from speechrail.domain.tts import VOICE_PROFILES
from speechrail.http.errors import error_response


def create_system_router(services: AppServices) -> APIRouter:
    """Four read-only endpoints; no auth by design (loopback-first service)."""
    router = APIRouter()
    resolved = services.settings

    @router.get("/health")
    async def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "service": resolved.service_name,
            "version": resolved.version,
            "backend": "qwen3-asr-1.7b",
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
            {"id": asr_target, "object": "model", "owned_by": "speechrail"},
            {"id": tts_target, "object": "model", "owned_by": "speechrail"},
        ]
        for alias, target in sorted(asr_model_aliases().items()):
            if alias in diarization_model_aliases() and not services.diarization_ready:
                continue
            data.append(
                {"id": alias, "object": "model", "owned_by": "speechrail", "resolves_to": target}
            )
        for alias, target in sorted(tts_model_aliases().items()):
            data.append(
                {"id": alias, "object": "model", "owned_by": "speechrail", "resolves_to": target}
            )
        for compat in resolved.compatibility_model_ids:
            if compat in {asr_target, tts_target} or any(
                d["id"] == compat for d in data
            ):
                continue
            data.append(
                {
                    "id": compat,
                    "object": "model",
                    "owned_by": "speechrail",
                    "resolves_to": asr_target,
                }
            )
        return {"object": "list", "data": data}

    @router.get("/v1/voices")
    async def voices() -> dict[str, Any]:
        """List the server-owned preset voices without exposing model internals."""
        return {
            "object": "list",
            "data": [
                {
                    "id": voice_id,
                    "description": VOICE_PROFILES[voice_id].description,
                    "is_default": VOICE_PROFILES[voice_id].is_default,
                    "available": services.tts_ready,
                }
                for voice_id in resolved.tts_voice_ids
            ],
        }

    return router
