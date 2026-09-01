"""OpenAI Realtime-compatible WebSocket route (ASR/TTS subset only)."""

from __future__ import annotations

import asyncio
import base64
import contextlib
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, WebSocket
from starlette.websockets import WebSocketDisconnect

from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import TTSDeliveryError, iter_validated_audio
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    apply_session_update,
    conversation_created,
    conversation_item_created,
    error_event,
    input_audio_buffer_cleared,
    input_audio_buffer_committed,
    parse_text_item,
    reject_unsupported,
    response_created,
    response_done,
    response_output_audio_delta,
    response_output_audio_done,
    response_output_audio_transcript_done,
    response_output_item_added,
    session_created,
    transcription_completed,
    transcription_failed,
    validate_append,
)
from speechrail.domain.ports import (
    RealtimeAsrSession,
    SpeechRequest,
)
from speechrail.http.auth import websocket_is_authorized

_PCM16_24K: dict[str, object] = {
    "type": "pcm16",
    "sample_rate": 24_000,
    "channels": 1,
    "bits_per_sample": 16,
}


def create_openai_realtime_router(services: AppServices) -> APIRouter:
    """The OpenAI-compatible /v1/realtime endpoint; ASR/TTS only, no LLM."""
    router = APIRouter()
    resolved = services.settings
    realtime_asr_factory = services.realtime_asr_factory
    tts_synthesizer = services.tts_synthesizer

    registered_asr = frozenset({resolved.model_id, *resolved.compatibility_model_ids})
    registered_tts = frozenset({resolved.tts_model_id})

    @router.websocket("/v1/realtime")
    async def realtime_openai(websocket: WebSocket) -> None:
        if realtime_asr_factory is None and not services.tts_ready:
            await websocket.close(code=1013, reason="SpeechRail inference backend is not ready")
            return
        if not websocket_is_authorized(websocket, resolved):
            await websocket.close(code=1008, reason="Invalid API key")
            return
        await websocket.accept()

        session_id = f"realtime_{uuid4().hex[:12]}"
        asr_session: RealtimeAsrSession | None = None
        asr_reader: asyncio.Task[None] | None = None
        tts_task: asyncio.Task[None] | None = None
        config: dict[str, Any] = {"model": resolved.model_id, "language": None}

        async def drain_asr_events() -> None:
            if asr_session is None:
                return
            async for event in asr_session.events():
                if event.kind == "partial":
                    continue
                if event.kind == "completed":
                    await websocket.send_json(
                        conversation_item_created(session_id=session_id, transcript=event.text)
                    )
                    await websocket.send_json(
                        transcription_completed(session_id=session_id, transcript=event.text)
                    )
                elif event.kind == "error":
                    await websocket.send_json(
                        transcription_failed(
                            session_id=session_id,
                            code=event.error_code or "backend_error",
                            message="streaming transcription failed",
                        )
                    )

        async def synthesize_tts(text: str, *, voice: str, language: str) -> None:
            if tts_synthesizer is None:
                await websocket.send_json(
                    error_event(code="backend_not_ready", message="TTS backend is not ready")
                )
                return
            response_id = f"resp_{uuid4().hex[:12]}"
            item_id = f"item_{uuid4().hex[:12]}"
            await websocket.send_json(
                response_created(session_id=session_id, response_id=response_id)
            )
            await websocket.send_json(
                response_output_item_added(
                    session_id=session_id, response_id=response_id, item_id=item_id
                )
            )
            request = SpeechRequest(
                text=text,
                voice=voice,
                output_format="pcm16",
                sample_rate=24_000,
                speed=1.0,
                language=language,
            )
            try:
                async for chunk in iter_validated_audio(tts_synthesizer.synthesize(request)):
                    await websocket.send_json(
                        response_output_audio_delta(
                            session_id=session_id,
                            response_id=response_id,
                            delta=base64.b64encode(chunk.audio).decode("ascii"),
                        )
                    )
            except TTSDeliveryError as exc:
                await websocket.send_json(
                    error_event(code=exc.code, message="TTS backend delivered invalid audio")
                )
            finally:
                await websocket.send_json(
                    response_output_audio_transcript_done(
                        session_id=session_id, response_id=response_id, transcript=text
                    )
                )
                await websocket.send_json(
                    response_output_audio_done(session_id=session_id, response_id=response_id)
                )
                await websocket.send_json(
                    response_done(session_id=session_id, response_id=response_id)
                )

        try:
            await websocket.send_json(
                session_created(
                    session_id=session_id,
                    model=resolved.model_id,
                    tts_ready=services.tts_ready,
                )
            )
            await websocket.send_json(conversation_created(session_id=session_id))

            while True:
                raw = await websocket.receive_text()
                try:
                    event = _decode(raw)
                    event_type = str(event.get("type") or "")
                    if event_type == "session.update":
                        updated, config = apply_session_update(
                            event,
                            session_id=session_id,
                            asr_model=resolved.model_id,
                            tts_model=resolved.tts_model_id,
                            tts_ready=services.tts_ready,
                            registered_asr=registered_asr,
                            registered_tts=registered_tts,
                        )
                        await websocket.send_json(updated)
                    elif event_type == "input_audio_buffer.append":
                        audio = validate_append(event)
                        if realtime_asr_factory is None:
                            raise RealtimeAdapterError(
                                "backend_not_ready", "streaming ASR backend is not ready"
                            )
                        if asr_session is None:
                            asr_session = realtime_asr_factory.create(
                                language=config.get("language"),
                                prompt="",
                            )
                            await asr_session.connect()
                            asr_reader = asyncio.create_task(drain_asr_events())
                        await asr_session.append_audio(audio)
                    elif event_type == "input_audio_buffer.commit":
                        if asr_session is None:
                            raise RealtimeAdapterError(
                                "invalid_state", "no audio appended before commit"
                            )
                        await asr_session.commit()
                        await websocket.send_json(
                            input_audio_buffer_committed(session_id=session_id)
                        )
                        if asr_reader is not None:
                            await asr_reader
                            asr_reader = None
                        asr_session = None
                    elif event_type == "input_audio_buffer.clear":
                        if asr_session is not None:
                            await asr_session.close()
                            asr_session = None
                        await websocket.send_json(
                            input_audio_buffer_cleared(session_id=session_id)
                        )
                    elif event_type == "conversation.item.create":
                        text = parse_text_item(event)
                        if not services.tts_ready or tts_synthesizer is None:
                            raise RealtimeAdapterError(
                                "backend_not_ready", "TTS backend is not ready"
                            )
                        if tts_task is None or tts_task.done():
                            tts_task = asyncio.create_task(
                                synthesize_tts(
                                    text,
                                    voice=str(config.get("voice") or "default"),
                                    language=str(config.get("language") or "auto"),
                                )
                            )
                        else:
                            raise RealtimeAdapterError(
                                "invalid_state", "a TTS response is already in progress"
                            )
                    elif event_type == "response.create":
                        raise RealtimeAdapterError(
                            "unsupported_operation",
                            "response.create requires a preceding "
                            "conversation.item.create text input",
                        )
                    elif event_type == "response.cancel":
                        if tts_task is not None and not tts_task.done():
                            tts_task.cancel()
                            with contextlib.suppress(asyncio.CancelledError):
                                await tts_task
                        else:
                            raise RealtimeAdapterError(
                                "invalid_state", "no active TTS response to cancel"
                            )
                    elif event_type == "input_audio_buffer.cleared":
                        continue
                    else:
                        reject_unsupported(event_type)
                        raise RealtimeAdapterError(
                            "unknown_event", f"unsupported event type: {event_type}"
                        )
                except RealtimeAdapterError as exc:
                    await websocket.send_json(
                        error_event(code=exc.code, message=exc.message, event_id=exc.event_id)
                    )
        except WebSocketDisconnect:
            pass
        finally:
            if asr_reader is not None and not asr_reader.done():
                asr_reader.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await asr_reader
            if asr_session is not None:
                await asr_session.close()
                if realtime_asr_factory is not None:
                    realtime_asr_factory.release(asr_session)
            if tts_task is not None and not tts_task.done():
                tts_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await tts_task

    return router


def _decode(raw: str) -> dict[str, Any]:
    import json

    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RealtimeAdapterError("invalid_event", "event is not valid JSON") from exc
    if not isinstance(decoded, dict):
        raise RealtimeAdapterError("invalid_event", "event must be a JSON object")
    return decoded
