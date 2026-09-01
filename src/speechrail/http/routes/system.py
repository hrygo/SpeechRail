"""Read-only system endpoints: process health, readiness and model identity."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from speechrail.application.services import AppServices
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
            "ready": services.asr_ready or services.tts_ready,
        }

    @router.get("/readyz")
    async def readyz(request: Request) -> JSONResponse:
        if services.asr_ready or services.tts_ready:
            return JSONResponse(status_code=200, content={"ready": True})
        return error_response(
            503,
            request.state.request_id,
            "backend_not_ready",
            "SpeechRail inference backend is not ready",
            retryable=True,
        )

    @router.get("/v1/models")
    async def models() -> dict[str, Any]:
        return {
            "object": "list",
            "data": [
                {"id": item, "object": "model", "owned_by": "speechrail"}
                for item in (
                    resolved.model_id,
                    resolved.tts_model_id,
                    *resolved.compatibility_model_ids,
                )
            ],
        }

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
