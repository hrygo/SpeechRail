"""Realtime v2 WebSocket route: ASR/TTS state machine with backpressure."""

from __future__ import annotations

import asyncio
import contextlib
import math
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, WebSocket
from starlette.websockets import WebSocketDisconnect

from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import TTSDeliveryError, iter_validated_audio
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.ports import (
    RealtimeAsrSession,
    SpeechRequest,
    TranscriptionRequest,
)
from speechrail.domain.realtime_v2 import RealtimeV2Error
from speechrail.http.auth import websocket_is_authorized
from speechrail.realtime.outbound import BoundedOutboundEventPump, SlowConsumerError
from speechrail.realtime.v2_session import SpeechSession, TranscriptionSession
from speechrail.runtime.diarization import DiarizationCoordinator
from speechrail.runtime.resource_governor import GovernorQueueFullError, WorkClass


def _speech_speed(event: dict[str, Any]) -> float:
    """Validate the optional realtime speed field at the protocol boundary."""
    value = event.get("speed", 1.0)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RealtimeV2Error("invalid speech speed", code="invalid_speed")
    speed = float(value)
    if not math.isfinite(speed) or not 0.25 <= speed <= 4.0:
        raise RealtimeV2Error("invalid speech speed", code="invalid_speed")
    return speed


def create_realtime_v2_router(services: AppServices) -> APIRouter:
    """v2 carries ASR/TTS only; no LLM response, playback or meeting state."""
    router = APIRouter()
    resolved = services.settings
    resolved_v2_transcriber = services.v2_transcriber
    realtime_asr_factory = services.realtime_asr_factory
    diarization_engine = services.diarization_engine
    tts_synthesizer = services.tts_synthesizer
    governor = services.governor

    @router.websocket("/v2/realtime")
    async def realtime_v2(websocket: WebSocket) -> None:
        if (
            resolved_v2_transcriber is None
            and realtime_asr_factory is None
            and not services.tts_ready
        ):
            await websocket.close(code=1013, reason="SpeechRail inference backend is not ready")
            return
        if not websocket_is_authorized(websocket, resolved):
            await websocket.close(code=1008, reason="Invalid API key")
            return
        await websocket.accept()
        session: TranscriptionSession | SpeechSession = TranscriptionSession(
            max_audio_bytes=resolved.max_realtime_buffer_bytes,
            max_frame_bytes=resolved.max_realtime_frame_bytes,
        )
        active_synthesis: asyncio.Task[None] | None = None
        active_streaming_asr: RealtimeAsrSession | None = None
        streaming_reader: asyncio.Task[None] | None = None
        active_diarization: DiarizationCoordinator | None = None
        streaming_item_id: str | None = None
        streaming_revision = 0

        async def consume_streaming_asr_events() -> None:
            nonlocal streaming_item_id, streaming_revision
            if active_streaming_asr is None:
                return
            async for event in active_streaming_asr.events():
                if not isinstance(session, TranscriptionSession):
                    return
                if event.kind == "partial":
                    if not event.text.strip():
                        continue
                    streaming_item_id = streaming_item_id or f"item_{uuid4().hex}"
                    streaming_revision += 1
                    await websocket.send_json(
                        session.transcription_delta(
                            item_id=streaming_item_id,
                            revision=streaming_revision,
                            text=event.text,
                            start_ms=0,
                            end_ms=0,
                        )
                    )
                elif event.kind == "completed":
                    if not event.text.strip():
                        continue
                    item_id = streaming_item_id or f"item_{uuid4().hex}"
                    segments = event.segments or (
                        TranscriptSegment(
                            id=f"seg_{uuid4().hex}", start_ms=0, end_ms=0, text=event.text
                        ),
                    )
                    if active_diarization is not None:
                        segments = await active_diarization.annotate(segments)
                    await websocket.send_json(
                        session.transcription_completed(
                            item_id=item_id,
                            text=event.text,
                            language=event.language,
                            segments=[segment.model_dump(mode="json") for segment in segments],
                        )
                    )
                    streaming_item_id = None
                    streaming_revision = 0
                else:
                    await websocket.send_json(
                        session.protocol_error(
                            code=event.error_code or "backend_error",
                            message="ASR backend reported an error",
                            retryable=True,
                        )
                    )
                    await websocket.close(code=1013)
                    return

        async def transcribe_item(audio: bytes) -> None:
            if not audio:
                return
            if not isinstance(session, TranscriptionSession) or resolved_v2_transcriber is None:
                raise RealtimeV2Error("ASR backend is not ready", code="backend_not_ready")
            request = TranscriptionRequest(
                request_id=session.request_id,
                audio=audio,
                language=session.language,
                prompt=session.prompt,
            )
            result = await governor.run(
                lambda: resolved_v2_transcriber.transcribe(request),
                WorkClass.REALTIME_ASR,
                deadline=resolved.request_timeout_seconds,
            )
            segments = result.segments
            if active_diarization is not None:
                segments = await active_diarization.annotate(segments)
            await websocket.send_json(
                session.transcription_completed(
                    item_id=f"item_{uuid4().hex}",
                    text=result.text,
                    language=result.language,
                    segments=[segment.model_dump(mode="json") for segment in segments],
                )
            )

        async def synthesize_text(text: str, *, speed: float = 1.0) -> None:
            if not text:
                return
            synthesizer = tts_synthesizer
            if (
                not isinstance(session, SpeechSession)
                or synthesizer is None
                or not services.tts_ready
            ):
                raise RealtimeV2Error("TTS backend is not ready", code="backend_not_ready")
            created = session.response_created()
            response_id = str(created["response_id"])
            await websocket.send_json(created)
            request = SpeechRequest(
                text=text,
                voice=session.voice,
                output_format="pcm16",
                sample_rate=24_000,
                speed=speed,
                language=session.language,
            )
            output = BoundedOutboundEventPump(
                max_events=resolved.realtime_outbound_max_events,
                send=websocket.send_json,
            )
            await output.start()

            async def fail_response(*, code: str, message: str) -> None:
                with contextlib.suppress(SlowConsumerError):
                    await output.publish(
                        session.protocol_error(code=code, message=message, retryable=True)
                    )
                    await output.finish()
                await websocket.close(code=1013)

            finished = False
            try:
                async with governor.reserve(
                    WorkClass.REALTIME_TTS, deadline=resolved.request_timeout_seconds
                ):
                    async for chunk in iter_validated_audio(synthesizer.synthesize(request)):
                        await output.publish(
                            session.audio_delta(
                                response_id=response_id,
                                chunk_index=chunk.chunk_index,
                                audio=chunk.audio,
                            )
                        )
                await output.publish(session.response_completed(response_id=response_id))
                completed = session.complete_if_input_committed()
                if completed is not None:
                    await output.publish(completed)
                await output.finish()
                finished = True
            except SlowConsumerError:
                await websocket.send_json(
                    session.protocol_error(
                        code="slow_consumer",
                        message="Realtime client cannot consume audio fast enough",
                        retryable=False,
                    )
                )
                await websocket.close(code=1013)
            except TTSDeliveryError as exc:
                await fail_response(
                    code=exc.code,
                    message="TTS backend delivered an invalid audio stream",
                )
            except GovernorQueueFullError:
                await fail_response(
                    code="queue_full", message="Realtime inference queue is full"
                )
            except TimeoutError:
                await fail_response(
                    code="backend_timeout", message="Realtime inference timed out"
                )
            finally:
                if not finished:
                    await output.abort()

        try:
            while True:
                event = await websocket.receive_json()
                event_type = event.get("type") if isinstance(event, dict) else None
                if event_type == "session.update":
                    configured = event.get("session")
                    if not isinstance(configured, dict):
                        raise RealtimeV2Error(
                            "session must be an object", code="invalid_session"
                        )
                    if configured.get("type") == "transcription":
                        if resolved_v2_transcriber is None and realtime_asr_factory is None:
                            raise RealtimeV2Error(
                                "ASR backend is not ready", code="backend_not_ready"
                            )
                        model = configured.get("model", resolved.model_id)
                        if model not in {resolved.model_id, *resolved.compatibility_model_ids}:
                            raise RealtimeV2Error("unknown model", code="model_not_found")
                        if not isinstance(session, TranscriptionSession):
                            raise RealtimeV2Error(
                                "session type cannot change", code="invalid_session"
                            )
                        created = session.configure(configured)
                        if session.diarization.enabled:
                            if diarization_engine is None:
                                raise RealtimeV2Error(
                                    "diarization profile is not available",
                                    code="diarization_not_available",
                                )
                            active_diarization = DiarizationCoordinator(
                                diarization_engine.create(config=session.diarization)
                            )
                        await websocket.send_json(created)
                        if realtime_asr_factory is not None:
                            active_streaming_asr = realtime_asr_factory.create(
                                language=session.language, prompt=session.prompt
                            )
                            await active_streaming_asr.connect()
                            streaming_reader = asyncio.create_task(consume_streaming_asr_events())
                    elif configured.get("type") == "speech":
                        if not services.tts_ready:
                            raise RealtimeV2Error(
                                "TTS backend is not ready", code="backend_not_ready"
                            )
                        model = configured.get("model", resolved.tts_model_id)
                        if model != resolved.tts_model_id:
                            raise RealtimeV2Error("unknown model", code="model_not_found")
                        session = SpeechSession(
                            max_text_chars=100_000,
                            allowed_voices=resolved.tts_voice_ids,
                            request_id=session.request_id,
                        )
                        await websocket.send_json(session.configure(configured))
                    else:
                        raise RealtimeV2Error(
                            "unsupported session type", code="capability_not_supported"
                        )
                elif event_type == "input_audio_buffer.append":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    audio = session.append_audio(event.get("audio"))
                    if active_diarization is not None:
                        await active_diarization.append_audio(audio)
                    if active_streaming_asr is not None:
                        await active_streaming_asr.append_audio(audio)
                    await websocket.send_json(session.audio_ack())
                elif event_type == "input_audio_buffer.flush":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    audio = session.flush_audio()
                    if active_streaming_asr is not None:
                        await active_streaming_asr.flush()
                    else:
                        await transcribe_item(audio)
                elif event_type == "input_audio_buffer.commit":
                    if not isinstance(session, TranscriptionSession):
                        raise RealtimeV2Error("event is not valid for speech", code="invalid_event")
                    if active_streaming_asr is not None:
                        # Drain final delta/completed before COMMITTED flips the
                        # session terminal, or the reader's events are rejected.
                        await active_streaming_asr.commit()
                        if streaming_reader is not None:
                            await streaming_reader
                        session.commit_audio()
                    else:
                        audio = session.commit_audio()
                        await transcribe_item(audio)
                    if active_diarization is not None and session.diarization.finalize:
                        await websocket.send_json(
                            session.diarization_completed(await active_diarization.finalize())
                        )
                    await websocket.send_json(session.session_completed())
                    await websocket.close()
                    return
                elif event_type == "speech_input.append":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    text = event.get("text")
                    if not isinstance(text, str):
                        raise RealtimeV2Error("text is required", code="invalid_event")
                    session.append_text(text)
                elif event_type == "speech_input.flush":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    if active_synthesis is not None and not active_synthesis.done():
                        raise RealtimeV2Error(
                            "a response is already active", code="response_in_progress"
                        )
                    speed = _speech_speed(event)
                    text = session.flush_text()
                    if text:
                        active_synthesis = asyncio.create_task(
                            synthesize_text(text, speed=speed)
                        )
                elif event_type == "speech_input.commit":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    if active_synthesis is not None and not active_synthesis.done():
                        raise RealtimeV2Error(
                            "a response is already active", code="response_in_progress"
                        )
                    speed = _speech_speed(event)
                    text = session.commit_text()
                    if text:
                        active_synthesis = asyncio.create_task(
                            synthesize_text(text, speed=speed)
                        )
                    else:
                        completed = session.complete_if_input_committed()
                        if completed is not None:
                            await websocket.send_json(completed)
                            await websocket.close()
                            return
                elif event_type == "response.cancel":
                    if not isinstance(session, SpeechSession):
                        raise RealtimeV2Error(
                            "event is not valid for transcription", code="invalid_event"
                        )
                    response_id = event.get("response_id")
                    if not isinstance(response_id, str):
                        raise RealtimeV2Error("response_id is required", code="invalid_event")
                    if active_synthesis is not None and not active_synthesis.done():
                        active_synthesis.cancel()
                        with contextlib.suppress(asyncio.CancelledError):
                            await active_synthesis
                    await websocket.send_json(session.response_cancel(response_id=response_id))
                    active_synthesis = None
                    completed = session.complete_if_input_committed()
                    if completed is not None:
                        await websocket.send_json(completed)
                        await websocket.close()
                        return
                elif event_type == "session.cancel":
                    if active_synthesis is not None and not active_synthesis.done():
                        active_synthesis.cancel()
                        with contextlib.suppress(asyncio.CancelledError):
                            await active_synthesis
                        active_synthesis = None
                    await websocket.send_json(session.cancel())
                    await websocket.close()
                    return
                else:
                    raise RealtimeV2Error("unsupported realtime v2 event", code="invalid_event")
        except RealtimeV2Error as exc:
            await websocket.send_json(
                session.protocol_error(code=exc.code, message=str(exc), retryable=False)
            )
            await websocket.close(code=1008)
        except GovernorQueueFullError:
            await websocket.send_json(
                session.protocol_error(
                    code="queue_full", message="Realtime inference queue is full", retryable=True
                )
            )
            await websocket.close(code=1013)
        except TimeoutError:
            await websocket.send_json(
                session.protocol_error(
                    code="backend_timeout", message="Realtime inference timed out", retryable=True
                )
            )
            await websocket.close(code=1013)
        except WebSocketDisconnect:
            pass
        finally:
            if active_synthesis is not None and not active_synthesis.done():
                active_synthesis.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await active_synthesis
            if streaming_reader is not None and not streaming_reader.done():
                streaming_reader.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await streaming_reader
            if active_streaming_asr is not None:
                await active_streaming_asr.close()
            if active_diarization is not None:
                await active_diarization.close()

    return router
