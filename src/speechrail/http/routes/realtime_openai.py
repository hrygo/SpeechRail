"""OpenAI Realtime WebSocket transport for the ASR/TTS compatibility surface."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, WebSocket
from starlette.websockets import WebSocketDisconnect

from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppServices
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    error_event,
    resolve_handshake_model,
)
from speechrail.domain.diarization import DiarizationError
from speechrail.http.auth import websocket_is_authorized

logger = logging.getLogger(__name__)

HANDSHAKE_MODEL_CLOSE_CODE = 4004
QUEUE_OVERFLOW_CLOSE_CODE = 1013
# Bounded intake so a stalled handler cannot accumulate unbounded base64 audio;
# 64 events ≈ 64 chunks of audio, far above normal handler drain speed.
CLIENT_EVENT_QUEUE_LIMIT = 64


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
        requested_model = websocket.query_params.get("model")
        await websocket.accept()

        session_id = f"realtime_{uuid4().hex[:12]}"
        send_lock = asyncio.Lock()
        sequence = 0
        disconnected = False

        async def send_event(event: dict[str, object]) -> None:
            nonlocal sequence, disconnected
            if disconnected:
                return
            async with send_lock:
                if disconnected:
                    return
                sequence += 1
                payload = dict(event)
                payload["event_id"] = f"event_{uuid4().hex}"
                payload["session_id"] = session_id
                payload["sequence"] = sequence
                try:
                    await websocket.send_json(payload)
                except (WebSocketDisconnect, RuntimeError):
                    disconnected = True

        registered_asr = frozenset({settings.model_id, *settings.compatibility_model_ids})
        registered_tts = frozenset({settings.tts_model_id})
        try:
            if requested_model:
                model = resolve_handshake_model(
                    requested_model,
                    asr_model=settings.model_id,
                    registered_asr=registered_asr,
                    registered_tts=registered_tts,
                    diarization_ready=services.diarization_ready,
                )
                display_model = requested_model
            else:
                model = settings.model_id
                display_model = settings.model_id
        except RealtimeAdapterError as exc:
            await send_event(error_event(code=exc.code, message=exc.message))
            await websocket.close(code=HANDSHAKE_MODEL_CLOSE_CODE)
            return

        session = OpenAIRealtimeSession(
            services,
            session_id=session_id,
            send=send_event,
            model=model,
            display_model=display_model,
        )
        # Only count a session once the handshake resolved successfully: the
        # finally block below always pairs this with record_realtime_session_end.
        services.metrics.record_realtime_session_start()
        client_events: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue(
            maxsize=CLIENT_EVENT_QUEUE_LIMIT
        )

        async def receive_loop() -> None:
            try:
                while True:
                    event = _decode(await websocket.receive_text())
                    client_events.put_nowait(event)
            except WebSocketDisconnect:
                pass
            except asyncio.QueueFull:
                # The handler is stalled (e.g. a blocked backend); stop reading
                # instead of buffering unbounded base64 audio and close the
                # session so the client can reconnect with a fresh one.
                logger.warning(
                    "realtime client event queue overflow; closing session %s",
                    session_id,
                )
                with contextlib.suppress(Exception):
                    await websocket.close(
                        code=QUEUE_OVERFLOW_CLOSE_CODE, reason="event queue overflow"
                    )
            finally:
                with contextlib.suppress(asyncio.QueueFull):
                    client_events.put_nowait(None)

        async def handle_loop() -> None:
            while True:
                event = await client_events.get()
                if event is None:
                    return
                client_event_id: str | None = None
                try:
                    raw_event_id = event.get("event_id")
                    if isinstance(raw_event_id, str) and raw_event_id.strip():
                        client_event_id = raw_event_id
                    await session.handle(event)
                except (WebSocketDisconnect, RuntimeError):
                    logger.debug("realtime client disconnected during event handling")
                    return
                except RealtimeAdapterError as exc:
                    await send_event(
                        error_event(
                            code=exc.code,
                            message=exc.message,
                            client_event_id=exc.event_id or client_event_id,
                        )
                    )
                except DiarizationError as exc:
                    await send_event(
                        error_event(
                            code=exc.code, message=str(exc), client_event_id=client_event_id
                        )
                    )
                except Exception as exc:
                    # Do not let the task die with the slot still acquired: the
                    # factory releases the session in close() below, which only
                    # runs after both tasks complete normally or are cancelled.
                    logger.exception("realtime event handler failed: %s", exc)
                    await send_event(
                        error_event(
                            code="backend_error",
                            message=str(exc) or "internal backend error",
                            client_event_id=client_event_id,
                        )
                    )

        recv_task = asyncio.create_task(receive_loop())
        handle_task = asyncio.create_task(handle_loop())
        try:
            await session.start()
            # Finish when either side completes; the other is cancelled below so a
            # client disconnect interrupts a blocking handle instead of leaking
            # the ASR factory slot until the backend answers.
            await asyncio.wait(
                {recv_task, handle_task}, return_when=asyncio.FIRST_COMPLETED
            )
        finally:
            recv_task.cancel()
            handle_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await recv_task
            with contextlib.suppress(asyncio.CancelledError):
                await handle_task
            await session.close()
            services.metrics.record_realtime_session_end()

    return router


def _decode(raw: str) -> dict[str, Any]:
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RealtimeAdapterError("invalid_event", "event is not valid JSON") from exc
    if not isinstance(decoded, dict):
        raise RealtimeAdapterError("invalid_event", "event must be a JSON object")
    return decoded
