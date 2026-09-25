"""Safe versioned discovery; legacy /v1 projections remain compatible."""

from __future__ import annotations

from uuid import uuid4

from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse

from speechrail.application.capability_snapshot import build_capability_snapshot, content_revision
from speechrail.application.services import AppServices
from speechrail.application.voice_validation_gate import (
    build_validation_binding,
    load_validation_evidence,
)
from speechrail.config.selection import active_model_catalog
from speechrail.domain.tts import VoiceStoreUnavailableError, get_voice_registry, resolve_voice
from speechrail.domain.voice_validation import VoiceValidationStoreUnavailableError
from speechrail.http.auth import http_auth_error
from speechrail.http.errors import error_response


def create_capability_router(services: AppServices) -> APIRouter:
    router = APIRouter()
    active = active_model_catalog(services.settings)
    epoch = uuid4().hex

    def asr_capability_facts() -> dict[str, object]:
        """Declared ASR-side facts for discovery; never includes busy state."""

        served = services.asr_ready
        return {
            "available": served,
            "ready": served,
            "reason": None if served else "asr_not_configured",
            "max_upload_bytes": services.settings.max_upload_bytes,
            "max_audio_seconds": services.settings.max_audio_seconds,
            "alignment_available": services.text_aligner is not None,
            "jobs_available": services.job_repository is not None,
            "realtime_formats": ("pcm16",),
            "realtime_pcm_sample_rate": 24_000,
            "realtime_endpointing": ("server_vad",),
            # WebSocket bidirectional traffic is not a joint realtime
            # certification; until that gate passes discovery reports
            # half-duplex only.
            "realtime_full_duplex_certified": False,
        }

    def respond(
        request: Request, *, voice_id: str | None = None, listing: bool = False
    ) -> Response:
        if (auth_error := http_auth_error(request, services.settings)) is not None:
            return auth_error
        try:
            registry = get_voice_registry()
            profiles = registry.snapshot_profiles()
            validations: dict[str, dict[str, object]] = {}
            validation_bindings: dict[str, dict[str, object]] = {}
            for profile in profiles:
                if profile.mode != "clone":
                    continue
                binding = build_validation_binding(
                    profile,
                    active.tts_clone,
                    services.tts_synthesizer,
                    require_current_binding=True,
                )
                validation_bindings[profile.id] = binding.as_mapping()
                evidence = load_validation_evidence(
                    registry.validation_store,
                    binding,
                    require_current_binding=True,
                )
                if evidence is not None:
                    validations[profile.id] = evidence
            snapshot = build_capability_snapshot(
                profiles,
                active,
                epoch=epoch,
                ready=services.tts_ready,
                enabled_voices=frozenset(services.settings.tts_voice_ids),
                sample_rate=services.settings.tts_sample_rate,
                validation_records=validations,
                validation_bindings=validation_bindings,
                asr_capabilities=asr_capability_facts(),
            )
        except (VoiceStoreUnavailableError, VoiceValidationStoreUnavailableError):
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
