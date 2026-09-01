"""Legacy /asr WebSocket skeleton: config handshake and empty-PCM EOF only."""

from __future__ import annotations

from fastapi import APIRouter, WebSocket

from speechrail.application.services import AppServices
from speechrail.compatibility.presenters import legacy_config, legacy_ready_to_stop


def create_legacy_router(services: AppServices) -> APIRouter:
    """Loopback-only compatibility skeleton; no WLK parity, no authentication."""
    router = APIRouter()
    resolved = services.settings

    @router.websocket("/asr")
    async def legacy_asr(websocket: WebSocket) -> None:
        if not resolved.legacy_wlk_enabled:
            await websocket.close(code=1008, reason="Legacy endpoint disabled")
            return
        await websocket.accept()
        await websocket.send_json(legacy_config())
        try:
            while True:
                chunk = await websocket.receive_bytes()
                if not chunk:
                    await websocket.send_json(legacy_ready_to_stop())
                    return
        finally:
            await websocket.close()

    return router
