"""Application orchestration for the OpenAI Realtime ASR/TTS boundary."""

from __future__ import annotations

import asyncio
import base64
import contextlib
from collections.abc import Awaitable, Callable
from contextlib import AsyncExitStack
from typing import Any
from uuid import uuid4

from speechrail.application.diarization import DiarizationCoordinator
from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import TTSDeliveryError, iter_validated_audio
from speechrail.backends.vad import VoiceActivityDetector
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    conversation_created,
    conversation_item_created,
    conversation_text_item_created,
    error_event,
    input_audio_buffer_cleared,
    input_audio_buffer_committed,
    parse_text_item,
    reject_unsupported,
    response_audio_delta,
    response_audio_done,
    response_audio_transcript_delta,
    response_audio_transcript_done,
    response_content_part_added,
    response_content_part_done,
    response_created,
    response_done,
    response_output_item_added,
    response_output_item_done,
    session_created,
    transcription_completed,
    transcription_delta,
    transcription_failed,
    transcription_segment,
    validate_append,
)
from speechrail.domain.diarization import DiarizationConfig, DiarizationError
from speechrail.domain.ports import RealtimeAsrSession, SpeechRequest
from speechrail.domain.tts import resolve_voice
from speechrail.runtime.resource_governor import GovernorQueueFullError, WorkClass

SendEvent = Callable[[dict[str, object]], Awaitable[None]]


class OpenAIRealtimeSession:
    """Own one protocol-independent ASR/TTS session lifecycle.

    The HTTP route owns only WebSocket transport and JSON decoding. This class
    owns backend resources, cancellation, and the mapping from validated
    compatibility events to domain ports.
    """

    def __init__(
        self,
        services: AppServices,
        *,
        session_id: str,
        send: SendEvent,
        model: str | None = None,
        display_model: str | None = None,
    ) -> None:
        self._services = services
        self._settings = services.settings
        self._session_id = session_id
        self._send = send
        self._initial_model = model or self._settings.model_id
        self._display_model = display_model or self._initial_model
        self._asr_factory = services.realtime_asr_factory
        self._diarization_engine = services.diarization_engine
        self._tts = services.tts_synthesizer
        self._registered_asr = frozenset(
            {self._settings.model_id, *self._settings.compatibility_model_ids}
        )
        self._registered_tts = frozenset({self._settings.tts_model_id})
        self._tts_voice_ids = frozenset(self._settings.tts_voice_ids)
        self._asr: RealtimeAsrSession | None = None
        self._asr_reader: asyncio.Task[None] | None = None
        self._asr_resources: AsyncExitStack | None = None
        self._tts_task: asyncio.Task[None] | None = None
        self._tts_response_id: str | None = None
        self._diarization: DiarizationCoordinator | None = None
        self._diarization_config: DiarizationConfig | None = None
        self._pending_text: str | None = None
        self._buffered_audio_bytes = 0
        self._vad: VoiceActivityDetector | None = None
        self._config: dict[str, Any] = {
            "model": self._initial_model,
            "language": None,
            "prompt": "",
        }

    async def start(self) -> None:
        await self._send(
            session_created(
                session_id=self._session_id,
                model=self._display_model,
                tts_ready=self._services.tts_ready,
            )
        )
        await self._send(conversation_created(session_id=self._session_id))

    async def handle(self, event: dict[str, Any]) -> None:
        event_type = str(event.get("type") or "")
        if event_type == "session.update":
            await self._update_session(event)
        elif event_type == "input_audio_buffer.append":
            await self._append_audio(event)
        elif event_type == "input_audio_buffer.commit":
            await self._commit_audio()
        elif event_type == "input_audio_buffer.clear":
            await self._clear_audio()
        elif event_type == "conversation.item.create":
            await self._create_text_item(event)
        elif event_type == "response.create":
            await self._create_response(event)
        elif event_type == "response.cancel":
            await self._cancel_response()
        elif event_type == "input_audio_buffer.cleared":
            return
        else:
            reject_unsupported(event_type)
            raise RealtimeAdapterError("unknown_event", f"unsupported event type: {event_type}")

    async def close(self) -> None:
        await self._stop_asr_reader()
        await self._close_asr_session()
        await self._release_asr()
        if self._diarization is not None:
            with contextlib.suppress(Exception):
                await self._diarization.close()
            self._diarization = None
        if self._tts_task is not None and not self._tts_task.done():
            self._tts_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._tts_task
        self._tts_task = None
        if self._vad is not None:
            self._vad.reset()

    async def _update_session(self, event: dict[str, Any]) -> None:
        from speechrail.compatibility.openai_realtime import apply_session_update

        updated, config = apply_session_update(
            event,
            session_id=self._session_id,
            asr_model=self._settings.model_id,
            tts_model=self._settings.tts_model_id,
            tts_ready=self._services.tts_ready,
            registered_asr=self._registered_asr,
            registered_tts=self._registered_tts,
            tts_voice_ids=self._tts_voice_ids,
        )
        raw_diarization = config.get("diarization")
        self._diarization_config = (
            None if raw_diarization is None else DiarizationConfig.model_validate(raw_diarization)
        )
        if self._diarization_config is not None and self._diarization_config.enabled:
            await self._ensure_diarization()
        else:
            await self._close_diarization()

        turn_detection = config.get("turn_detection")
        if isinstance(turn_detection, dict) and turn_detection.get("type") == "server_vad":
            from speechrail.backends.vad import VadConfig, VoiceActivityDetector

            threshold = float(turn_detection.get("threshold", 0.5))
            prefix_padding = int(turn_detection.get("prefix_padding_ms", 300))
            silence_duration = int(turn_detection.get("silence_duration_ms", 400))
            self._vad = VoiceActivityDetector(
                VadConfig(
                    threshold=threshold,
                    prefix_padding_ms=prefix_padding,
                    silence_duration_ms=silence_duration,
                )
            )
        elif (
            turn_detection is None
            or (isinstance(turn_detection, dict) and turn_detection.get("type") is None)
            or turn_detection == "manual"
        ):
            self._vad = None

        self._config = config
        await self._send(updated)

    async def _append_audio(self, event: dict[str, Any]) -> None:
        audio = validate_append(
            event,
            max_frame_bytes=self._settings.max_realtime_frame_bytes,
            buffered_bytes=self._buffered_audio_bytes,
            max_buffer_bytes=self._settings.max_realtime_buffer_bytes,
        )
        if self._asr_factory is None:
            raise RealtimeAdapterError("backend_not_ready", "streaming ASR backend is not ready")

        if self._vad is not None:
            from speechrail.compatibility.openai_realtime import (
                input_audio_buffer_speech_started,
                input_audio_buffer_speech_stopped,
            )

            vad_events = self._vad.process_chunk(audio)
            for v_event in vad_events:
                if v_event.speech_started:
                    # Barge-in: immediately cancel in-progress TTS response
                    if self._tts_task is not None and not self._tts_task.done():
                        await self._cancel_response()
                    await self._send(
                        input_audio_buffer_speech_started(
                            session_id=self._session_id,
                            audio_start_ms=v_event.audio_start_ms,
                            item_id=f"item_{self._session_id}_input",
                        )
                    )
                elif v_event.speech_ended:
                    await self._send(
                        input_audio_buffer_speech_stopped(
                            session_id=self._session_id,
                            audio_end_ms=v_event.audio_end_ms,
                            item_id=f"item_{self._session_id}_input",
                        )
                    )
                    if self._asr is not None:
                        await self._commit_audio()
                        return

        if self._asr is None:
            await self._reserve_asr()
            asr: RealtimeAsrSession | None = None
            from speechrail.domain.itn import compose_hotword_prompt

            asr_prompt = compose_hotword_prompt(
                str(self._config.get("prompt") or ""),
                self._config.get("keywords"),
            )
            try:
                asr = self._asr_factory.create(
                    language=self._config.get("language"),
                    prompt=asr_prompt,
                )
                await asr.connect()
            except Exception as exc:
                # Any failure (factory RuntimeError, BrokenPipeError/OSError from a
                # dead worker pipe, ...) must release both the governor reservation
                # and the factory slot, or the single streaming slot leaks until
                # restart and every later session gets backend_busy.
                await self._release_asr()
                if asr is not None:
                    with contextlib.suppress(Exception):
                        await asr.close()
                    self._asr_factory.release(asr)
                message = str(exc)
                code = (
                    "language_not_supported"
                    if message.startswith("language_not_supported")
                    else "backend_busy"
                )
                raise RealtimeAdapterError(code, message) from exc
            self._asr = asr
            self._asr_reader = asyncio.create_task(self._drain_asr_events())
        await self._ensure_diarization()
        await self._asr.append_audio(audio)
        if self._diarization is not None:
            await self._diarization.append_audio(audio)
        self._buffered_audio_bytes += len(audio)

    async def _commit_audio(self) -> None:
        if self._asr is None:
            raise RealtimeAdapterError("invalid_state", "no audio appended before commit")
        await self._send(input_audio_buffer_committed(session_id=self._session_id))
        await self._asr.commit()
        if self._asr_reader is not None:
            await self._asr_reader
            self._asr_reader = None
        await self._close_asr_session()
        await self._release_asr()
        self._buffered_audio_bytes = 0

    async def _clear_audio(self) -> None:
        if self._vad is not None:
            self._vad.reset()
        await self._stop_asr_reader()
        await self._close_asr_session()
        await self._release_asr()
        await self._close_diarization()
        self._buffered_audio_bytes = 0
        await self._send(input_audio_buffer_cleared(session_id=self._session_id))

    async def _create_text_item(self, event: dict[str, Any]) -> None:
        text = parse_text_item(event)
        if not self._services.tts_ready or self._tts is None:
            raise RealtimeAdapterError("backend_not_ready", "TTS backend is not ready")
        item_id = f"item_{uuid4().hex[:12]}"
        self._pending_text = text
        await self._send(
            conversation_text_item_created(session_id=self._session_id, item_id=item_id, text=text)
        )

    async def _create_response(self, event: dict[str, Any]) -> None:
        if self._pending_text is None:
            raise RealtimeAdapterError(
                "invalid_state",
                "response.create requires a preceding conversation.item.create text input",
            )
        if self._tts_task is not None and not self._tts_task.done():
            raise RealtimeAdapterError("invalid_state", "a TTS response is already in progress")
        response_body = event.get("response")
        response_voice: str | None = None
        if isinstance(response_body, dict) and response_body.get("voice") is not None:
            raw_voice = response_body["voice"]
            if not isinstance(raw_voice, str) or not raw_voice.strip():
                raise RealtimeAdapterError(
                    "invalid_voice", "response.voice must be a non-blank string"
                )
            response_voice = resolve_voice(raw_voice.strip())
            if response_voice not in self._tts_voice_ids:
                raise RealtimeAdapterError(
                    "voice_not_found", f"unknown voice: {response_voice[:200]}"
                )
        response_id = f"resp_{uuid4().hex[:12]}"
        item_id = f"item_{uuid4().hex[:12]}"
        self._tts_response_id = response_id
        self._tts_task = asyncio.create_task(
            self._synthesize_tts(
                self._pending_text,
                voice=response_voice or str(self._config.get("voice") or "default"),
                language=str(self._config.get("language") or "auto"),
                response_id=response_id,
                item_id=item_id,
            )
        )
        self._pending_text = None

    async def _cancel_response(self) -> None:
        if self._tts_task is None or self._tts_task.done() or self._tts_response_id is None:
            raise RealtimeAdapterError("invalid_state", "no active TTS response to cancel")
        response_id = self._tts_response_id
        self._tts_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await self._tts_task
        await self._send(
            response_done(session_id=self._session_id, response_id=response_id, status="cancelled")
        )
        self._tts_task = None
        self._tts_response_id = None

    async def _drain_asr_events(self) -> None:
        if self._asr is None:
            return
        from speechrail.domain.itn import apply_light_itn

        async for event in self._asr.events():
            if event.kind == "partial":
                await self._send(transcription_delta(session_id=self._session_id, delta=event.text))
            elif event.kind == "completed":
                norm_text = apply_light_itn(event.text)
                await self._send(
                    conversation_item_created(session_id=self._session_id, transcript=norm_text)
                )
                segments = event.segments
                if self._diarization is not None and segments:
                    try:
                        segments = await self._diarization.annotate(segments)
                    except DiarizationError as exc:
                        await self._send(error_event(code=exc.code, message=str(exc)))
                        return
                    for segment in segments:
                        await self._send(
                            transcription_segment(
                                session_id=self._session_id,
                                item_id=f"item_{self._session_id}_input",
                                segment_id=segment.id,
                                text=apply_light_itn(segment.text),
                                speaker=segment.speaker,
                                start_ms=segment.start_ms,
                                end_ms=segment.end_ms,
                            )
                        )
                await self._send(
                    transcription_completed(session_id=self._session_id, transcript=norm_text)
                )
            elif event.kind == "error":
                await self._send(
                    transcription_failed(
                        session_id=self._session_id,
                        code=event.error_code or "backend_error",
                        message="streaming transcription failed",
                    )
                )

    async def _synthesize_tts(
        self,
        text: str,
        *,
        voice: str,
        language: str,
        response_id: str,
        item_id: str,
    ) -> None:
        import sys
        import traceback
        if self._tts is None:
            await self._send(
                error_event(code="backend_not_ready", message="TTS backend is not ready")
            )
            return
        try:
            await self._send(response_created(session_id=self._session_id, response_id=response_id))
            await self._send(
                response_output_item_added(
                    session_id=self._session_id, response_id=response_id, item_id=item_id
                )
            )
            await self._send(
                response_content_part_added(
                    session_id=self._session_id, response_id=response_id, item_id=item_id
                )
            )

            from speechrail.domain.tts import (
                StreamingSentenceSplitter,
                create_breath_pause,
            )

            splitter = StreamingSentenceSplitter()
            sentences = splitter.feed(text) + splitter.flush()
            if not sentences:
                sentences = [text]

            try:
                async with self._services.governor.reserve(
                    WorkClass.REALTIME_TTS, deadline=self._settings.request_timeout_seconds
                ):
                    for s_idx, sentence in enumerate(sentences):
                        request = SpeechRequest(
                            text=sentence,
                            voice=voice,
                            output_format="pcm16",
                            sample_rate=24_000,
                            speed=1.0,
                            language=language,
                        )
                        async for chunk in iter_validated_audio(self._tts.synthesize(request)):
                            await self._send(
                                response_audio_delta(
                                    session_id=self._session_id,
                                    response_id=response_id,
                                    item_id=item_id,
                                    delta=base64.b64encode(chunk.audio).decode("ascii"),
                                )
                            )
                        if s_idx < len(sentences) - 1:
                            pause_pcm = create_breath_pause(sample_rate=24_000, pause_ms=80)
                            if pause_pcm:
                                await self._send(
                                    response_audio_delta(
                                        session_id=self._session_id,
                                        response_id=response_id,
                                        item_id=item_id,
                                        delta=base64.b64encode(pause_pcm).decode("ascii"),
                                    )
                                )
            except asyncio.CancelledError:
                raise
            except (TTSDeliveryError, GovernorQueueFullError, TimeoutError) as exc:
                code = getattr(exc, "code", None) or (
                    "queue_full" if isinstance(exc, GovernorQueueFullError) else "backend_timeout"
                )
                await self._send(error_event(code=code, message="TTS response failed"))
                await self._send(
                    response_done(
                        session_id=self._session_id, response_id=response_id, status="failed"
                    )
                )
                return

            await self._send(
                response_audio_transcript_delta(
                    session_id=self._session_id,
                    response_id=response_id,
                    item_id=item_id,
                    delta=text,
                )
            )
            await self._send(
                response_audio_transcript_done(
                    session_id=self._session_id,
                    response_id=response_id,
                    item_id=item_id,
                    transcript=text,
                )
            )
            await self._send(
                response_audio_done(
                    session_id=self._session_id, response_id=response_id, item_id=item_id
                )
            )
            await self._send(
                response_content_part_done(
                    session_id=self._session_id,
                    response_id=response_id,
                    item_id=item_id,
                    transcript=text,
                )
            )
            await self._send(
                response_output_item_done(
                    session_id=self._session_id,
                    response_id=response_id,
                    item_id=item_id,
                    transcript=text,
                )
            )
            await self._send(response_done(session_id=self._session_id, response_id=response_id))
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            await self._send(error_event(code="tts_error", message=str(exc)))
            await self._send(
                response_done(session_id=self._session_id, response_id=response_id, status="failed")
            )

    async def _reserve_asr(self) -> None:
        self._asr_resources = AsyncExitStack()
        try:
            await self._asr_resources.enter_async_context(
                self._services.governor.reserve(
                    WorkClass.REALTIME_ASR, deadline=self._settings.request_timeout_seconds
                )
            )
        except GovernorQueueFullError as exc:
            await self._asr_resources.aclose()
            self._asr_resources = None
            raise RealtimeAdapterError("queue_full", "Realtime ASR queue is full") from exc
        except TimeoutError as exc:
            await self._asr_resources.aclose()
            self._asr_resources = None
            raise RealtimeAdapterError(
                "backend_timeout", "Realtime ASR admission timed out"
            ) from exc

    async def _release_asr(self) -> None:
        if self._asr_resources is not None:
            await self._asr_resources.aclose()
            self._asr_resources = None

    async def _close_asr_session(self) -> None:
        if self._asr is None:
            return
        session = self._asr
        self._asr = None
        with contextlib.suppress(Exception):
            await session.close()
        if self._asr_factory is not None:
            self._asr_factory.release(session)

    async def _stop_asr_reader(self) -> None:
        if self._asr_reader is None:
            return
        reader = self._asr_reader
        self._asr_reader = None
        if not reader.done():
            reader.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await reader

    async def _ensure_diarization(self) -> None:
        if self._diarization is not None:
            return
        if self._diarization_config is None or not self._diarization_config.enabled:
            return
        engine = self._diarization_engine
        if not self._services.diarization_ready or engine is None:
            raise RealtimeAdapterError(
                "diarization_not_available",
                str(self._services.diarization_status["message"]),
            )
        self._diarization = DiarizationCoordinator(
            engine.create(config=self._diarization_config)
        )

    async def _close_diarization(self) -> None:
        if self._diarization is not None:
            with contextlib.suppress(Exception):
                await self._diarization.close()
            self._diarization = None
