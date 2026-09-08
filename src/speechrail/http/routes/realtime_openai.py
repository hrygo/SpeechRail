"""OpenAI Realtime WebSocket transport for the ASR/TTS compatibility surface."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
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
OUTBOUND_SEND_TIMEOUT_CLOSE_CODE = 1011
# Bounded intake so a stalled handler cannot accumulate unbounded base64 audio;
# 512 events ≈ 16.4s of 32ms audio chunks, accommodating commit/diarization spikes.
CLIENT_EVENT_QUEUE_LIMIT = 512
CONTROL_EVENT_QUEUE_LIMIT = 16
_CONTROL_EVENT_TYPES = frozenset({"response.cancel"})


async def _send_json_with_deadline(
    websocket: WebSocket, payload: dict[str, object], *, timeout_seconds: float
) -> bool:
    """Send one server event without letting a slow consumer pin the session."""

    try:
        async with asyncio.timeout(timeout_seconds):
            await websocket.send_json(payload)
    except TimeoutError:
        with contextlib.suppress(Exception):
            await websocket.close(
                code=OUTBOUND_SEND_TIMEOUT_CLOSE_CODE,
                reason="outbound send timed out",
            )
        return False
    except (WebSocketDisconnect, RuntimeError):
        return False
    return True


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

        async def send_event(event: dict[str, object]) -> int | None:
            """Send one event; return its sequence, or None when disconnected."""
            nonlocal sequence, disconnected
            if disconnected:
                return None
            async with send_lock:
                if disconnected:
                    return None
                sequence += 1
                payload = dict(event)
                payload["event_id"] = f"event_{uuid4().hex}"
                payload["session_id"] = session_id
                payload["sequence"] = sequence
                send_started = time.monotonic()
                sent = await _send_json_with_deadline(
                    websocket,
                    payload,
                    timeout_seconds=settings.request_timeout_seconds,
                )
                if not sent:
                    disconnected = True
                    return None
                services.metrics.record_realtime_phase("send", time.monotonic() - send_started)
                return sequence

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
        event_envelope = tuple[dict[str, Any], int, asyncio.Future[None] | None]
        client_events: asyncio.Queue[event_envelope | None] = asyncio.Queue(
            maxsize=CLIENT_EVENT_QUEUE_LIMIT
        )
        control_events: asyncio.Queue[event_envelope | None] = asyncio.Queue(
            maxsize=CONTROL_EVENT_QUEUE_LIMIT
        )
        pending_client_event_bytes = 0
        latest_append_dispatch: asyncio.Future[None] | None = None
        # JSON/Base64 is larger than decoded PCM.  Leave headroom for one
        # legal maximum frame so API-level ``buffer_too_large`` remains a
        # stable error rather than being shadowed by transport backpressure.
        client_event_byte_limit = 2 * max(
            settings.max_realtime_frame_bytes,
            settings.max_realtime_buffer_bytes or 8_388_608,
        )

        async def receive_loop() -> None:
            nonlocal latest_append_dispatch, pending_client_event_bytes
            try:
                while True:
                    raw = await websocket.receive_text()
                    raw_size = len(raw.encode("utf-8"))
                    if raw_size > client_event_byte_limit or (
                        pending_client_event_bytes + raw_size > client_event_byte_limit
                    ):
                        logger.warning(
                            "realtime client event byte budget exceeded; closing session %s",
                            session_id,
                        )
                        with contextlib.suppress(Exception):
                            await websocket.close(
                                code=QUEUE_OVERFLOW_CLOSE_CODE,
                                reason="event byte budget exceeded",
                            )
                        return
                    try:
                        event = _decode(raw)
                    except RealtimeAdapterError as exc:
                        # A malformed frame is a client protocol error, not a
                        # task failure.  Keep this session usable and leave its
                        # admission slot to the normal close path.
                        await send_event(error_event(code=exc.code, message=exc.message))
                        continue
                    event_type = event.get("type")
                    append_dispatch: asyncio.Future[None] | None = None
                    if event_type == "input_audio_buffer.append":
                        append_dispatch = asyncio.get_running_loop().create_future()
                        latest_append_dispatch = append_dispatch
                    elif event_type in _CONTROL_EVENT_TYPES:
                        # A TTS cancellation may bypass a long ASR commit, but
                        # it must never overtake audio already accepted on this
                        # websocket. The newest append dispatch subsumes all
                        # earlier append events because the data lane is FIFO.
                        # Waiting for inference completion here would deadlock
                        # when the append is waiting for the TTS-held lane that
                        # this cancel must release.
                        append_dispatch = latest_append_dispatch
                    queue = (
                        control_events
                        if event_type in _CONTROL_EVENT_TYPES
                        else client_events
                    )
                    queue.put_nowait((event, raw_size, append_dispatch))
                    pending_client_event_bytes += raw_size
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
                with contextlib.suppress(asyncio.QueueFull):
                    control_events.put_nowait(None)

        async def handle_client_event(payload: dict[str, Any], payload_size: int) -> None:
            nonlocal pending_client_event_bytes
            pending_client_event_bytes -= payload_size
            client_event_id: str | None = None
            try:
                raw_event_id = payload.get("event_id")
                if isinstance(raw_event_id, str) and raw_event_id.strip():
                    client_event_id = raw_event_id
                await session.handle(payload)
            except (WebSocketDisconnect, RuntimeError):
                logger.debug("realtime client disconnected during event handling")
                raise
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
                logger.exception("realtime event handler failed: %s", exc)
                await send_event(
                    error_event(
                        code="backend_error",
                        message=str(exc) or "internal backend error",
                        client_event_id=client_event_id,
                    )
                )

        async def handle_loop() -> None:
            while True:
                event = await client_events.get()
                if event is None:
                    return
                payload, payload_size, append_dispatch = event
                try:
                    if append_dispatch is not None and not append_dispatch.done():
                        append_dispatch.set_result(None)
                    await handle_client_event(payload, payload_size)
                except (WebSocketDisconnect, RuntimeError):
                    return

        async def control_loop() -> None:
            while True:
                event = await control_events.get()
                if event is None:
                    return
                payload, payload_size, append_dispatch = event
                try:
                    if append_dispatch is not None:
                        await append_dispatch
                    await handle_client_event(payload, payload_size)
                except (WebSocketDisconnect, RuntimeError):
                    return

        recv_task = asyncio.create_task(receive_loop())
        handle_task = asyncio.create_task(handle_loop())
        control_task = asyncio.create_task(control_loop())
        try:
            await session.start()
            # Finish when either side completes; the other is cancelled below so a
            # client disconnect interrupts a blocking handle instead of leaking
            # the ASR factory slot until the backend answers.
            await asyncio.wait(
                {recv_task, handle_task, control_task}, return_when=asyncio.FIRST_COMPLETED
            )
        finally:
            recv_task.cancel()
            handle_task.cancel()
            control_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await recv_task
            with contextlib.suppress(asyncio.CancelledError):
                await handle_task
            with contextlib.suppress(asyncio.CancelledError):
                await control_task
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
