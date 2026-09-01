"""Realtime v1 WebSocket route: append-then-commit batch transcription.

Deprecated: /v1/realtime now carries the OpenAI Realtime-compatible protocol.
This legacy batch protocol moved to /v1/realtime/legacy and is kept only for
existing consumers until they migrate.
"""

from __future__ import annotations

from uuid import uuid4

from fastapi import APIRouter, WebSocket

from speechrail.application.services import AppServices
from speechrail.domain.contracts import TranscriptResult
from speechrail.http.auth import websocket_is_authorized
from speechrail.http.errors import error
from speechrail.realtime.events import RealtimeSession, SessionError


def create_realtime_v1_router(services: AppServices) -> APIRouter:
    """v1 is a commit-then-batch protocol and does not emit partial deltas."""
    router = APIRouter()
    resolved = services.settings
    transcribe = services.transcribe
    admission = services.admission

    @router.websocket("/v1/realtime/legacy")
    async def realtime(websocket: WebSocket) -> None:
        if transcribe is None:
            await websocket.close(code=1013, reason="SpeechRail backend is not ready")
            return
        if not websocket_is_authorized(websocket, resolved):
            await websocket.close(code=1008, reason="Invalid API key")
            return
        await websocket.accept()
        session = RealtimeSession(
            session_id=f"sess_{uuid4().hex}",
            max_frame_bytes=resolved.max_realtime_frame_bytes,
            max_buffer_bytes=resolved.max_realtime_buffer_bytes,
        )
        try:
            while True:
                event = await websocket.receive_json()
                event_type = event.get("type") if isinstance(event, dict) else None
                if event_type == "transcription_session.update":
                    await websocket.send_json(session.update(event.get("session")))
                elif event_type == "input_audio_buffer.append":
                    session.append(event.get("audio"))
                elif event_type == "input_audio_buffer.commit":
                    audio = session.commit()

                    async def operation(
                        audio: bytes = audio,
                        language: str | None = session.language,
                        prompt: str = session.prompt,
                    ) -> TranscriptResult:
                        return await transcribe(audio, language, prompt)

                    result = await admission.run(
                        operation,
                        deadline=resolved.request_timeout_seconds,
                    )
                    await websocket.send_json(session.completed(result))
                    return
                else:
                    raise SessionError("invalid_event")
        except SessionError as exc:
            await websocket.send_json(
                {
                    "type": "error",
                    "error": error(
                        message="Invalid realtime event",
                        error_type="invalid_request_error",
                        code=exc.code,
                        request_id=f"req_{uuid4().hex}",
                        retryable=False,
                    )["error"],
                }
            )
            await websocket.close(code=1008)
        finally:
            session.close()

    return router
