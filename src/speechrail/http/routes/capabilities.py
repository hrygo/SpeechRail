"""Safe versioned discovery; legacy /v1 projections remain compatible."""

from __future__ import annotations

from uuid import uuid4

from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse

from speechrail.application.capability_snapshot import build_capability_snapshot, content_revision
from speechrail.application.services import AppServices
from speechrail.config.selection import active_model_catalog
from speechrail.domain.tts import VoiceStoreUnavailableError, get_voice_registry, resolve_voice
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error_response


def create_capability_router(services: AppServices) -> APIRouter:
    router = APIRouter()
    active = active_model_catalog(services.settings)
    epoch = uuid4().hex

    def respond(
        request: Request, *, voice_id: str | None = None, listing: bool = False
    ) -> Response:
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        try:
            profiles = get_voice_registry().snapshot_profiles()
            snapshot = build_capability_snapshot(
                profiles,
                active,
                epoch=epoch,
                ready=services.tts_ready,
                enabled_voices=frozenset(services.settings.tts_voice_ids),
                sample_rate=services.settings.tts_sample_rate,
            )
        except VoiceStoreUnavailableError:
            return error_response(
                503,
                request.state.request_id,
                "voice_store_unavailable",
                "Custom voice storage is unavailable",
                retryable=True,
            )
        payload = snapshot
        if listing:
            payload = {
                "object": "list",
                "snapshot_id": snapshot["snapshot_id"],
                "catalog_revision": snapshot["catalog_revision"],
                "data": snapshot["voices"],
            }
        if voice_id is not None:
            selected = next(
                (voice for voice in snapshot["voices"] if voice["id"] == resolve_voice(voice_id)),
                None,
            )
            if selected is None:
                return error_response(
                    404, request.state.request_id, "voice_not_found", "Voice not found"
                )
            payload = {**selected, "snapshot_id": snapshot["snapshot_id"]}
        etag = (
            '"'
            + content_revision({"snapshot": snapshot["snapshot_id"], "path": request.url.path})
            + '"'
        )
        headers = {"ETag": etag, "Cache-Control": "private, no-cache", "Vary": "Authorization"}
        validators = [
            value.strip().removeprefix("W/")
            for value in request.headers.get("If-None-Match", "").split(",")
        ]
        if etag in validators or "*" in validators:
            return Response(status_code=304, headers=headers)
        return JSONResponse(payload, headers=headers)

    @router.get("/v1/speechrail/capabilities")
    async def capabilities(request: Request) -> Response:
        return respond(request)

    @router.get("/v1/speechrail/voices")
    async def voices(request: Request) -> Response:
        return respond(request, listing=True)

    @router.get("/v1/speechrail/voices/{voice_id}")
    async def voice(voice_id: str, request: Request) -> Response:
        return respond(request, voice_id=voice_id)

    return router
