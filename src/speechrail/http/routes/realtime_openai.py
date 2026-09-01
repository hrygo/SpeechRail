"""OpenAI Realtime WebSocket transport for the ASR/TTS compatibility surface."""

from __future__ import annotations

import asyncio
import json
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, WebSocket
from starlette.websockets import WebSocketDisconnect

from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppServices
from speechrail.compatibility.openai_realtime import RealtimeAdapterError, error_event
from speechrail.domain.diarization import DiarizationError
from speechrail.http.auth import websocket_is_authorized


def create_openai_realtime_router(services: AppServices) -> APIRouter:
    """Expose the sole public Realtime endpoint, ``/v1/realtime``."""
    router = APIRouter()
    settings = services.settings

    @router.websocket("/v1/realtime")
    async def realtime_openai(websocket: WebSocket) -> None:
        if services.realtime_asr_factory is None and not services.tts_ready:
            await websocket.close(code=1013, reason="SpeechRail inference backend is not ready")
            return
        if not websocket_is_authorized(websocket, settings):
            await websocket.close(code=1008, reason="Invalid API key")
            return
        await websocket.accept()

        session_id = f"realtime_{uuid4().hex[:12]}"
        send_lock = asyncio.Lock()
        sequence = 0

        async def send_event(event: dict[str, object]) -> None:
            nonlocal sequence
            async with send_lock:
                sequence += 1
                payload = dict(event)
                payload["event_id"] = f"event_{uuid4().hex}"
                payload["session_id"] = session_id
                payload["sequence"] = sequence
                await websocket.send_json(payload)

        session = OpenAIRealtimeSession(services, session_id=session_id, send=send_event)
        try:
            await session.start()
            while True:
                try:
                    event = _decode(await websocket.receive_text())
                    await session.handle(event)
                except RealtimeAdapterError as exc:
                    await send_event(
                        error_event(code=exc.code, message=exc.message, event_id=exc.event_id)
                    )
                except DiarizationError as exc:
                    await send_event(error_event(code=exc.code, message=str(exc)))
        except WebSocketDisconnect:
            pass
        finally:
            await session.close()

    return router


def _decode(raw: str) -> dict[str, Any]:
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RealtimeAdapterError("invalid_event", "event is not valid JSON") from exc
    if not isinstance(decoded, dict):
        raise RealtimeAdapterError("invalid_event", "event must be a JSON object")
    return decoded
