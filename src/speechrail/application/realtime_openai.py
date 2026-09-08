"""Application orchestration for the OpenAI Realtime ASR/TTS boundary."""

from __future__ import annotations

import asyncio
import base64
import contextlib
import logging
import time
import warnings
from collections import deque
from collections.abc import Awaitable, Callable
from contextlib import AsyncExitStack
from typing import Any, Literal
from uuid import uuid4

from starlette.websockets import WebSocketDisconnect

with warnings.catch_warnings():
    # SpeechRail supports Python 3.12 only.  ``ratecv`` is a stateful C
    # implementation that preserves sample continuity across WebSocket frames;
    # suppress its Python-3.13 removal warning until the supported runtime moves.
    warnings.filterwarnings(
        "ignore",
        message="'audioop' is deprecated and slated for removal in Python 3.13",
        category=DeprecationWarning,
    )
    import audioop

from speechrail.application.diarization import DiarizationCoordinator
from speechrail.application.services import AppServices
from speechrail.application.tts_delivery import TTSDeliveryError, iter_validated_audio
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.compatibility.openai_realtime import (
    SPEECHRAIL_DIARIZATION_V1,
    RealtimeAdapterError,
    conversation_created,
    conversation_item_created,
    conversation_text_item_created,
    diarization_contract,
    diarization_finalized_event,
    diarization_status_event,
    diarization_update_event,
    diarization_update_item,
    error_event,
    input_audio_buffer_cleared,
    input_audio_buffer_committed,
    parse_finalize_request,
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
    transcription_completed_extension,
    transcription_delta,
    transcription_failed,
    transcription_segment,
    validate_append,
)
from speechrail.config.selection import active_model_catalog
from speechrail.domain.contracts import TranscriptSegment
from speechrail.domain.diarization import DiarizationConfig, DiarizationError
from speechrail.domain.diarization_timeline import (
    AttributionLedger,
    AttributionResult,
    AttributionUnit,
    Timeline,
    build_alignment_units,
)
from speechrail.domain.itn import apply_light_itn
from speechrail.domain.ports import RealtimeAsrSession, SpeechRequest
from speechrail.domain.tts import DEFAULT_VOICE_ID, resolve_voice
from speechrail.realtime.speech_admission import AdmissionDecision, SpeechAdmission
from speechrail.runtime.resource_governor import GovernorQueueFullError, WorkClass

SendEvent = Callable[[dict[str, object]], Awaitable[int | None]]

_MAX_UPDATES_PER_EVENT = 256

logger = logging.getLogger(__name__)


class Pcm16RateConverter:
    """Stateful PCM16 mono rate conversion for the public 24 kHz profile."""

    def __init__(self, *, input_rate: int, output_rate: int = 16_000) -> None:
        self._input_rate = input_rate
        self._output_rate = output_rate
        self._state: Any = None

    def convert(self, audio: bytes) -> bytes:
        if len(audio) % 2:
            raise RealtimeAdapterError("invalid_audio", "PCM16 audio must contain whole samples")
        converted, self._state = audioop.ratecv(
            audio,
            2,
            1,
            self._input_rate,
            self._output_rate,
            self._state,
        )
        return converted

    def reset(self) -> None:
        self._state = None


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
        active = active_model_catalog(self._settings)
        self._tts_variant = active.tts.variant if active.tts is not None else None
        tts_available = services.tts_ready
        self._speech_capabilities: dict[str, object] = {
            "available": tts_available,
            "variant": self._tts_variant,
            "supports_speaker": tts_available and self._tts_variant == "custom_voice",
            "supports_instruction": tts_available and self._tts_variant == "voice_design",
        }
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
        self._unflushed_bytes = 0
        self._last_partial_text = ""
        self._input_sample_rate = 16_000
        self._input_resampler: Pcm16RateConverter | None = None
        self._vad: Any = None
        self._shadow_vad: Any = None
        self._speech_admission: SpeechAdmission | None = None
        self._turn_generation: int = 0
        self._turn_has_admitted_speech: bool = False
        self._admitted_start_sample: int = 0
        self._admitted_end_sample: int = 0
        self._vad_raw_buffer = bytearray()
        self._vad_sample_cursor: int = 0
        # Pre-speech window for the legacy path, bounded to prefix_padding_ms
        # (32 bytes per ms at 16kHz PCM16) so silence can neither grow the
        # buffer nor reach ASR when speech is confirmed.
        self._bargein_pending_audio: deque[bytes] = deque()
        self._bargein_pending_bytes = 0
        self._bargein_pending_max_bytes = 9_600
        # Barge-in cooldown: after a TTS cancellation or speech_stopped, a new
        # speech onset within this window does not re-trigger a cancellation,
        # preventing the TTS tail echo from making the agent never finish.
        self._bargein_cooldown_s = self._settings.realtime_vad_bargein_cooldown_ms / 1000.0
        self._bargein_cooldown_until = 0.0
        # Session-global sample clock (SPK-E2E-1): every accepted PCM sample
        # advances exactly once; each ASR item records the offset it starts at
        # so item-local vendor times lift into the session domain once.
        self._timeline = Timeline()
        self._item_start_sample = 0
        self._item_end_sample = 0
        self._extensions: tuple[str, ...] = ()
        # SPK-E2E-1 finalization state: attribution bookkeeping lives in the
        # ledger, phase guards the append barrier, and the degraded fields are
        # first-wins so a flapping stream can only degrade the session once.
        self._ledger: AttributionLedger | None = None
        self._diarization_phase = "active"
        self._degraded_reason: str | None = None
        self._status_sent = False
        self._finalization_id: str | None = None
        self._finalized_payload: dict[str, object] | None = None
        self._last_update_sequence = 0
        self._stable_through_at_degradation = 0
        self._current_item_id = self._new_item_id()
        self._config: dict[str, Any] = {
            "model": self._initial_model,
            "language": None,
            "prompt": "",
            "input_sample_rate": 16_000,
        }

    @staticmethod
    def _new_item_id() -> str:
        """Return an opaque id for exactly one input-audio transcription turn."""
        return f"item_{uuid4().hex[:12]}"

    async def start(self) -> None:
        await self._send(
            self._with_speech_capabilities(
                session_created(
                    session_id=self._session_id,
                    model=self._display_model,
                    tts_ready=self._services.tts_ready,
                    diarization_extensions=self._diarization_extension_capabilities(),
                )
            )
        )

        await self._send(conversation_created(session_id=self._session_id))

    def _diarization_extension_capabilities(self) -> tuple[str, ...]:
        """Advertise SPK-E2E-1 only when a verified continuous stream exists."""
        engine = self._diarization_engine
        if (
            self._services.diarization_ready
            and engine is not None
            and bool(getattr(engine, "supports_stream", False))
        ):
            return (SPEECHRAIL_DIARIZATION_V1,)
        return ()

    async def handle(self, event: dict[str, Any]) -> None:
        event_type = str(event.get("type") or "")
        if event_type == "session.update":
            await self._update_session(event)
        elif event_type == "input_audio_buffer.append":
            await self._append_audio(event)
        elif event_type == "input_audio_buffer.commit":
            await self._commit_audio()
        elif event_type == "speechrail.diarization.finalize":
            await self._handle_finalize(event)
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
        if self._shadow_vad is not None:
            self._shadow_vad.reset()
        self._bargein_pending_audio.clear()
        self._bargein_pending_bytes = 0
        self._buffered_audio_bytes = 0
        self._unflushed_bytes = 0
        self._last_partial_text = ""
        if self._input_resampler is not None:
            self._input_resampler.reset()

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
            current_config=self._config,
        )
        input_sample_rate = int(config.get("input_sample_rate", 16_000))
        if self._timeline.accepted_samples > 0 and input_sample_rate != self._input_sample_rate:
            raise RealtimeAdapterError(
                "invalid_state",
                "audio input format cannot change after the first audio frame",
            )
        requested_extensions = tuple(config.get("diarization_extensions") or ())
        if "diarization_extensions" in config and requested_extensions != self._extensions:
            if self._timeline.accepted_samples > 0:
                raise RealtimeAdapterError(
                    "invalid_state",
                    "diarization extensions can only be negotiated before the first audio",
                )
            if requested_extensions != self._diarization_extension_capabilities():
                raise RealtimeAdapterError(
                    "unsupported_operation",
                    f"{SPEECHRAIL_DIARIZATION_V1} is not available on this server",
                )
            raw_diarization_config = config.get("diarization")
            if (
                not isinstance(raw_diarization_config, dict)
                or not raw_diarization_config.get("enabled")
            ):
                raise RealtimeAdapterError(
                    "invalid_diarization",
                    "diarization extensions require enabled diarization",
                )
            self._extensions = requested_extensions
            self._ledger = AttributionLedger()
        configured_voice = config.get("voice")
        if isinstance(configured_voice, str):
            self._require_voice_available(configured_voice)
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
            threshold = float(turn_detection.get("threshold", 0.5))
            prefix_padding = int(turn_detection.get("prefix_padding_ms", 300))
            silence_duration = int(turn_detection.get("silence_duration_ms", 400))

            if self._settings.resolves_to_silero_vad:
                from speechrail.backends.neural_vad import SileroVadConfig, SileroVadDetector

                ready, reason = SileroVadDetector.check_readiness(
                    self._settings.realtime_vad_model_path
                )
                if not ready:
                    raise RealtimeAdapterError(
                        "backend_not_ready",
                        f"Silero VAD preflight failed: {reason}",
                    )
                self._vad = SileroVadDetector(
                    self._settings.realtime_vad_model_path,
                    config=SileroVadConfig(threshold=threshold),
                )
                self._shadow_vad = None
            else:
                from speechrail.backends.vad import VadConfig, VoiceActivityDetector

                self._vad = VoiceActivityDetector(
                    VadConfig(
                        threshold=threshold,
                        prefix_padding_ms=prefix_padding,
                        silence_duration_ms=silence_duration,
                    )
                )
                if self._settings.realtime_vad_shadow_enabled:
                    from speechrail.backends.neural_vad import SileroVadConfig, SileroVadDetector

                    ready, _ = SileroVadDetector.check_readiness(
                        self._settings.realtime_vad_model_path
                    )
                    if ready:
                        self._shadow_vad = SileroVadDetector(
                            self._settings.realtime_vad_model_path,
                            config=SileroVadConfig(threshold=threshold),
                        )
                    else:
                        self._shadow_vad = None
                else:
                    self._shadow_vad = None

            if self._settings.realtime_speech_admission_enabled:
                prefix_samples = int(prefix_padding * 16)
                stop_frames = max(1, (silence_duration + 31) // 32)
                self._speech_admission = SpeechAdmission(
                    threshold=threshold,
                    start_frames=3,
                    stop_frames=stop_frames,
                    prefix_samples=prefix_samples,
                    frame_samples=512,
                    sample_rate=16_000,
                )
                self._vad_raw_buffer.clear()
                self._vad_sample_cursor = self._timeline.accepted_samples
            else:
                self._speech_admission = None
            self._bargein_pending_max_bytes = max(1, prefix_padding * 32)
        elif (
            turn_detection is None
            or (isinstance(turn_detection, dict) and turn_detection.get("type") is None)
            or turn_detection == "manual"
        ):
            self._vad = None
            self._shadow_vad = None
            self._speech_admission = None
            self._vad_raw_buffer.clear()

        if input_sample_rate != self._input_sample_rate:
            self._input_sample_rate = input_sample_rate
            self._input_resampler = (
                Pcm16RateConverter(input_rate=input_sample_rate)
                if input_sample_rate != 16_000
                else None
            )
        self._config = config
        if self._extensions:
            session_payload = updated.get("session")
            if isinstance(session_payload, dict):
                # group_generation stays null until R3 wires group isolation.
                session_payload["diarization_contract"] = diarization_contract(
                    group_generation=None
                )
        await self._send(self._with_speech_capabilities(updated))

    def _with_speech_capabilities(
        self,
        event: dict[str, object],
    ) -> dict[str, object]:
        session = event.get("session")
        if isinstance(session, dict):
            session["speech_capabilities"] = dict(self._speech_capabilities)
        return event

    async def _ensure_asr_for_turn(self) -> None:
        if self._asr is not None:
            return
        if self._asr_factory is None:
            raise RealtimeAdapterError("backend_not_ready", "streaming ASR backend is not ready")

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
        except BaseException as exc:
            with contextlib.suppress(Exception):
                await self._release_asr()
            if asr is not None:
                with contextlib.suppress(Exception):
                    await asr.close()
                self._asr_factory.release(asr)
            if isinstance(exc, asyncio.CancelledError):
                raise
            message = str(exc)
            code = (
                "language_not_supported"
                if message.startswith("language_not_supported")
                else "backend_busy"
            )
            raise RealtimeAdapterError(code, message) from exc
        self._asr = asr
        self._asr_reader = asyncio.create_task(self._drain_asr_events())

    async def _handle_admission_decision(
        self, dec: AdmissionDecision, *, in_commit: bool = False
    ) -> None:
        from speechrail.compatibility.openai_realtime import (
            input_audio_buffer_speech_started,
            input_audio_buffer_speech_stopped,
        )

        if dec.kind == "start":
            self._turn_generation += 1
            self._turn_has_admitted_speech = True
            self._admitted_start_sample = dec.start_sample
            self._admitted_end_sample = dec.end_sample
            self._item_start_sample = dec.start_sample
            self._item_end_sample = dec.end_sample
            self._buffered_audio_bytes = 0
            self._unflushed_bytes = 0

            self._services.metrics.record_vad("started")
            if (
                self._tts_task is not None
                and not self._tts_task.done()
                and self._bargein_allowed()
            ):
                self._services.metrics.record_bargein()
                await self._cancel_response()
                self._mark_bargein_cooldown()

            audio_start_ms = int((dec.start_sample / 16_000) * 1000)
            await self._send(
                input_audio_buffer_speech_started(
                    session_id=self._session_id,
                    audio_start_ms=audio_start_ms,
                    item_id=self._current_item_id,
                )
            )
            await self._ensure_asr_for_turn()

        elif dec.kind == "audio":
            if not self._turn_has_admitted_speech or self._asr is None:
                await self._ensure_asr_for_turn()
                self._turn_has_admitted_speech = True
                self._admitted_start_sample = dec.start_sample
                self._item_start_sample = dec.start_sample

            max_item_bytes = (
                256_000
                if self._extensions
                else (self._settings.max_realtime_buffer_bytes or 8_388_608)
            )
            if self._buffered_audio_bytes > 0 and (
                self._buffered_audio_bytes + len(dec.pcm) > max_item_bytes
            ):
                await self._commit_audio(reason="rollover")
                self._turn_generation += 1
                self._turn_has_admitted_speech = True
                self._admitted_start_sample = dec.start_sample
                self._item_start_sample = dec.start_sample
                self._buffered_audio_bytes = 0
                self._unflushed_bytes = 0
                await self._ensure_asr_for_turn()

            if self._asr is not None:
                await self._asr.append_audio(dec.pcm)
                self._admitted_end_sample = dec.end_sample
                self._item_end_sample = dec.end_sample
                self._buffered_audio_bytes += len(dec.pcm)
                self._unflushed_bytes += len(dec.pcm)

                chunk_sec = self._settings.qwen3_streaming_chunk_sec
                flush_threshold = max(1, int(chunk_sec * 32_000))
                if self._unflushed_bytes >= flush_threshold:
                    self._unflushed_bytes = 0
                    with contextlib.suppress(Exception):
                        await self._asr.flush()

        elif dec.kind == "end":
            self._services.metrics.record_vad("ended")
            self._mark_bargein_cooldown()
            audio_end_ms = int((dec.end_sample / 16_000) * 1000)
            await self._send(
                input_audio_buffer_speech_stopped(
                    session_id=self._session_id,
                    audio_end_ms=audio_end_ms,
                    item_id=self._current_item_id,
                )
            )
            # A commit flushing the state machine is already the commit in
            # progress: nesting another one here would double-commit the item
            # and append a phantom empty close-out after the real transcript.
            if not in_commit:
                await self._commit_audio(reason="vad_stop")

    async def _append_audio(self, event: dict[str, Any]) -> None:
        if self._diarization_phase != "active":
            raise RealtimeAdapterError(
                "invalid_state",
                "diarization finalization has started; audio is no longer accepted",
            )
        audio = validate_append(
            event,
            max_frame_bytes=self._settings.max_realtime_frame_bytes,
            buffered_bytes=0,
            max_buffer_bytes=None,
        )
        if self._input_resampler is not None:
            audio = self._input_resampler.convert(audio)
        max_buf = self._settings.max_realtime_buffer_bytes
        if max_buf is not None and len(audio) > max_buf:
            raise RealtimeAdapterError(
                "buffer_too_large", "audio buffer exceeds the configured limit"
            )

        if self._asr_factory is None:
            raise RealtimeAdapterError("backend_not_ready", "streaming ASR backend is not ready")

        await self._ensure_diarization()
        self._item_end_sample = self._timeline.accept(audio)[1]
        if self._diarization is not None:
            await self._diarization.append_audio(audio)

        # 1. SpeechAdmission path (server_vad with admission enabled)
        if self._speech_admission is not None and self._vad is not None:
            self._vad_raw_buffer.extend(audio)
            while len(self._vad_raw_buffer) >= 1024:
                frame = bytes(self._vad_raw_buffer[:1024])
                del self._vad_raw_buffer[:1024]
                frame_start_sample = self._vad_sample_cursor
                self._vad_sample_cursor += 512
                prob = self._vad.score_frame(frame)
                if self._shadow_vad is not None:
                    with contextlib.suppress(Exception):
                        shadow_prob = self._shadow_vad.score_frame(frame)
                        self._services.metrics.record_vad_shadow(
                            primary_speech=prob >= self._vad.threshold,
                            shadow_speech=shadow_prob >= self._shadow_vad.threshold,
                        )
                decisions = self._speech_admission.push(
                    frame,
                    start_sample=frame_start_sample,
                    probability=prob,
                )
                for dec in decisions:
                    await self._handle_admission_decision(dec)
            return

        # 2. Legacy / manual path (unaltered behavior)
        if self._vad is not None:
            from speechrail.compatibility.openai_realtime import (
                input_audio_buffer_speech_started,
                input_audio_buffer_speech_stopped,
            )

            vad_events = self._vad.process_chunk(audio)
            for v_event in vad_events:
                if v_event.speech_started:
                    self._services.metrics.record_vad("started")
                    if (
                        self._tts_task is not None
                        and not self._tts_task.done()
                        and self._bargein_allowed()
                    ):
                        self._services.metrics.record_bargein()
                        await self._cancel_response()
                        self._mark_bargein_cooldown()
                    await self._send(
                        input_audio_buffer_speech_started(
                            session_id=self._session_id,
                            audio_start_ms=v_event.audio_start_ms,
                            item_id=self._current_item_id,
                        )
                    )
                elif v_event.speech_ended:
                    self._services.metrics.record_vad("ended")
                    self._mark_bargein_cooldown()
                    await self._send(
                        input_audio_buffer_speech_stopped(
                            session_id=self._session_id,
                            audio_end_ms=v_event.audio_end_ms,
                            item_id=self._current_item_id,
                        )
                    )
                    if self._asr is not None:
                        await self._asr.append_audio(audio)
                        self._buffered_audio_bytes += len(audio)
                        self._unflushed_bytes += len(audio)
                        await self._commit_audio()
                        return

            # If not yet in speech (debouncing or pure silence), defer ASR
            # acquisition. Keep only the most recent prefix window so long
            # silence cannot grow the buffer or reach ASR at speech onset.
            if not self._vad.in_speech:
                self._bargein_pending_audio.append(audio)
                self._bargein_pending_bytes += len(audio)
                while (
                    self._bargein_pending_bytes > self._bargein_pending_max_bytes
                    and len(self._bargein_pending_audio) > 1
                ):
                    dropped = self._bargein_pending_audio.popleft()
                    self._bargein_pending_bytes -= len(dropped)
                return

        # Normal legacy append flow
        if (
            max_buf is not None
            and self._buffered_audio_bytes > 0
            and self._buffered_audio_bytes + len(audio) > max_buf
            and self._asr is not None
        ):
            # Auto-commit rollover for long streaming sessions
            await self._commit_audio()

        if self._asr is None:
            await self._ensure_asr_for_turn()
            self._item_start_sample = self._timeline.accepted_samples - (len(audio) // 2)
            if self._bargein_pending_audio and self._asr is not None:
                for pending_chunk in self._bargein_pending_audio:
                    await self._asr.append_audio(pending_chunk)
                    self._buffered_audio_bytes += len(pending_chunk)
                    self._unflushed_bytes += len(pending_chunk)
                self._bargein_pending_audio.clear()
                self._bargein_pending_bytes = 0

        if self._asr is not None:
            await self._asr.append_audio(audio)
            self._buffered_audio_bytes += len(audio)
            self._unflushed_bytes += len(audio)

            chunk_sec = self._settings.qwen3_streaming_chunk_sec
            flush_threshold = max(1, int(chunk_sec * 32_000))
            if self._unflushed_bytes >= flush_threshold:
                self._unflushed_bytes = 0
                with contextlib.suppress(Exception):
                    await self._asr.flush()

    async def _commit_audio(self, reason: str = "client") -> None:
        # If speech admission is active, flush any remaining sub-frame leftover.
        # The remainder is always below one 512-sample frame (append drains full
        # frames), so it never forms a VAD decision here: admission parks it in
        # its own leftover buffer and emits it as tail audio on finish(). Scoring
        # a partial frame would crash the Silero engine, which requires exactly
        # 512 samples.
        if self._speech_admission is not None and self._vad is not None:
            if self._vad_raw_buffer:
                rem = bytes(self._vad_raw_buffer)
                self._vad_raw_buffer.clear()
                decisions = self._speech_admission.push(
                    rem, start_sample=self._vad_sample_cursor, probability=0.0
                )
                self._vad_sample_cursor += len(rem) // 2
                for dec in decisions:
                    await self._handle_admission_decision(dec, in_commit=True)
            fin_decisions = self._speech_admission.finish()
            for dec in fin_decisions:
                await self._handle_admission_decision(dec, in_commit=True)

        if self._speech_admission is not None and not self._turn_has_admitted_speech:
            await self._send(
                input_audio_buffer_committed(
                    session_id=self._session_id, item_id=self._current_item_id
                )
            )
            await self._send(
                conversation_item_created(
                    session_id=self._session_id,
                    transcript="",
                    item_id=self._current_item_id,
                )
            )
            await self._send(
                self._completed_event(transcript="")
            )
            self._last_partial_text = ""
            self._unflushed_bytes = 0
            self._buffered_audio_bytes = 0
            self._services.metrics.record_realtime_turn(
                mode="server_vad",
                commit_reason=reason,
                outcome="empty",
                characters=0,
                active_samples=0,
            )
            self._current_item_id = self._new_item_id()
            return

        if self._asr is None:
            await self._send(
                input_audio_buffer_committed(
                    session_id=self._session_id, item_id=self._current_item_id
                )
            )
            await self._send(
                conversation_item_created(
                    session_id=self._session_id,
                    transcript="",
                    item_id=self._current_item_id,
                )
            )
            await self._send(
                self._completed_event(transcript="")
            )
            self._last_partial_text = ""
            self._unflushed_bytes = 0
            self._services.metrics.record_realtime_turn(
                mode="manual",
                commit_reason=reason,
                outcome="empty",
                characters=0,
                active_samples=0,
            )
            self._current_item_id = self._new_item_id()
            return

        await self._send(
            input_audio_buffer_committed(
                session_id=self._session_id, item_id=self._current_item_id
            )
        )
        try:
            # The worker's own protocol timeout cannot bound a reader that has
            # already received the commit acknowledgement but never reaches its
            # terminal event.  Keep commit, final event delivery and teardown
            # under one request deadline so its governor lane is recoverable.
            async with asyncio.timeout(self._settings.request_timeout_seconds):
                await self._asr.commit(want_segments=self._diarization is not None)
                if self._asr_reader is not None:
                    await self._asr_reader
                    self._asr_reader = None
        except TimeoutError as exc:
            await self._discard_failed_commit()
            raise RealtimeAdapterError(
                "backend_timeout", "streaming ASR commit timed out"
            ) from exc
        except BaseException:
            await self._discard_failed_commit()
            raise
        finally:
            self._turn_has_admitted_speech = False
        await self._close_asr_session()
        await self._release_asr()
        self._buffered_audio_bytes = 0
        self._last_partial_text = ""
        self._unflushed_bytes = 0
        self._current_item_id = self._new_item_id()

    async def _discard_failed_commit(self) -> None:
        """Tear down a commit that will never finish.

        A failed commit (worker timeout/hang, dead pipe) must not leak the
        governor lane or the streaming factory slot: the next append has to be
        able to open a fresh ASR session.
        """

        with contextlib.suppress(Exception):
            await self._stop_asr_reader()
            await self._close_asr_session()
            await self._release_asr()
        self._turn_has_admitted_speech = False
        self._buffered_audio_bytes = 0
        self._last_partial_text = ""
        self._unflushed_bytes = 0
        self._item_start_sample = self._timeline.accepted_samples
        self._item_end_sample = self._timeline.accepted_samples
        self._current_item_id = self._new_item_id()

    async def _clear_audio(self) -> None:
        self._turn_generation += 1
        self._turn_has_admitted_speech = False
        self._bargein_cooldown_until = 0.0
        if self._speech_admission is not None:
            self._speech_admission.reset(next_sample=self._timeline.accepted_samples)
        self._vad_raw_buffer.clear()
        self._vad_sample_cursor = self._timeline.accepted_samples
        self._bargein_pending_audio.clear()
        self._bargein_pending_bytes = 0
        if self._vad is not None:
            self._vad.reset()
        if self._shadow_vad is not None:
            self._shadow_vad.reset()
        await self._stop_asr_reader()
        await self._close_asr_session()
        await self._release_asr()
        await self._close_diarization()
        self._buffered_audio_bytes = 0
        self._unflushed_bytes = 0
        self._last_partial_text = ""
        self._item_start_sample = self._timeline.accepted_samples
        self._item_end_sample = self._timeline.accepted_samples
        self._current_item_id = self._new_item_id()
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
            from speechrail.domain.tts import get_voice_profile
            try:
                get_voice_profile(response_voice)
            except ValueError:
                raise RealtimeAdapterError(
                    "voice_not_found", f"unknown voice: {response_voice[:200]}"
                ) from None
            self._require_voice_available(response_voice)
        response_id = f"resp_{uuid4().hex[:12]}"
        item_id = f"item_{uuid4().hex[:12]}"
        self._tts_response_id = response_id
        self._tts_task = asyncio.create_task(
            self._synthesize_tts(
                self._pending_text,
                voice=response_voice or str(self._config.get("voice") or DEFAULT_VOICE_ID),
                language=str(self._config.get("language") or "auto"),
                response_id=response_id,
                item_id=item_id,
            )
        )
        self._pending_text = None

    def _require_voice_available(self, voice: str) -> None:
        if self._tts_variant not in {"voice_design", "custom_voice"}:
            return
        try:
            resolve_binding(self._tts_variant, voice)
        except ValueError:
            raise RealtimeAdapterError(
                "voice_not_available",
                (
                    f"voice {voice[:200]} is unavailable for the active TTS weights; "
                    "use one of the available system voices from /v1/voices"
                ),
            ) from None

    def _bargein_allowed(self) -> bool:
        return time.monotonic() >= self._bargein_cooldown_until

    def _mark_bargein_cooldown(self) -> None:
        self._bargein_cooldown_until = time.monotonic() + self._bargein_cooldown_s

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

    def _completed_event(self, *, transcript: str) -> dict[str, object]:
        """Render the terminal completed event for the current ASR item."""
        if self._extensions:
            return transcription_completed_extension(
                item_id=self._current_item_id,
                transcript=transcript,
                audio_start_sample=self._item_start_sample,
                audio_end_sample=max(self._item_end_sample, self._item_start_sample),
                attribution_units=self._render_units(
                    self._build_units(transcript, ())
                ),
            )
        return transcription_completed(item_id=self._current_item_id, transcript=transcript)

    def _build_units(
        self, canonical: str, segments: tuple[TranscriptSegment, ...]
    ) -> tuple[AttributionUnit, ...]:
        """Build immutable attribution units over the canonical transcript.

        Align segments carry item-local millisecond bounds; they are ITN'd
        with the same rule as the canonical text and mapped onto canonical
        code point ranges, then lifted into session-global samples exactly
        once.  Any inconsistency — or an already degraded session — degrades
        the whole item to one ``timing_quality="unavailable"`` unit instead
        of re-timing words.
        """
        item_start = self._item_start_sample
        item_end = max(self._item_end_sample, self._item_start_sample)
        item_samples = item_end - item_start
        if not canonical:
            return ()
        if self._degraded_reason is not None:
            return (self._unavailable_unit(canonical, item_start, item_end),)
        parts: list[str] = []
        words: list[tuple[int, int, int, int]] = []
        cursor = 0
        for segment in segments:
            text = apply_light_itn(segment.text)
            if not text:
                continue
            start = cursor
            cursor += len(text)
            parts.append(text)
            words.append((start, cursor, segment.start_ms * 16, segment.end_ms * 16))
        candidate = "".join(parts)
        units = build_alignment_units(
            canonical, candidate, tuple(words), item_samples=item_samples
        )
        if units is None:
            return (self._unavailable_unit(canonical, item_start, item_end),)
        return tuple(
            AttributionUnit(
                segment_uid=f"seg_{uuid4().hex[:12]}",
                text_start=unit.text_start,
                text_end=unit.text_end,
                start_sample=item_start + unit.start_sample,
                end_sample=item_start + unit.end_sample,
                timing_quality="aligned",
            )
            for unit in units
        )

    def _unavailable_unit(self, canonical: str, item_start: int, item_end: int) -> AttributionUnit:
        return AttributionUnit(
            segment_uid=f"seg_{uuid4().hex[:12]}",
            text_start=0,
            text_end=len(canonical),
            start_sample=item_start,
            end_sample=item_end,
            timing_quality="unavailable",
        )

    @staticmethod
    def _render_units(units: tuple[AttributionUnit, ...]) -> list[dict[str, object]]:
        return [
            {
                "segment_uid": unit.segment_uid,
                "text_start": unit.text_start,
                "text_end": unit.text_end,
                "audio_start_sample": unit.start_sample,
                "audio_end_sample": unit.end_sample,
                "timing_quality": unit.timing_quality,
            }
            for unit in units
        ]

    async def _register_units(self, units: tuple[AttributionUnit, ...]) -> None:
        """Feed delivered units to the ledger, then fold fresh activities."""
        if self._ledger is None or not units:
            return
        immediate_results: list[AttributionResult] = []
        try:
            for unit in units:
                res = self._ledger.register(unit)
                if res is not None:
                    immediate_results.append(res)
        except DiarizationError as exc:
            await self._handle_degradation(exc)
            return
        if immediate_results:
            await self._send_diarization_updates(tuple(immediate_results))
        if self._degraded_reason is not None:
            # Degraded attribution keeps delivering text: any unit not already
            # delivered as an immediate result is terminated as unknown.
            delivered_uids = {r.segment_uid for r in immediate_results}
            pending = [
                self._unknown_result(u)
                for u in units
                if u.segment_uid not in delivered_uids
            ]
            if pending:
                await self._send_diarization_updates(tuple(pending))
            return
        await self._fold_stream_activities()

    async def _fold_stream_activities(self) -> None:
        """Query the continuous stream and emit changed attribution revisions."""
        if (
            self._ledger is None
            or self._diarization is None
            or not self._diarization.is_continuous
        ):
            return
        try:
            snapshot = await self._diarization.activities(self._timeline.accepted_samples)
        except DiarizationError as exc:
            await self._handle_degradation(exc)
            return
        if snapshot is not None:
            await self._send_diarization_updates(self._ledger.apply_activity(snapshot))

    async def _send_diarization_updates(self, results: tuple[AttributionResult, ...]) -> None:
        """Emit attribution revisions in bounded batches on one serializer."""
        if self._ledger is None or not results:
            return
        items = [
            diarization_update_item(
                segment_uid=result.segment_uid,
                revision=result.revision,
                status=result.status,
                speaker=result.speaker,
                coverage_ratio=result.coverage_ratio,
                overlap_ratio=result.overlap_ratio,
                candidates=result.candidates,
            )
            for result in results
        ]
        for start in range(0, len(items), _MAX_UPDATES_PER_EVENT):
            chunk = items[start : start + _MAX_UPDATES_PER_EVENT]
            sequence = await self._send(
                diarization_update_event(
                    group_generation=None,
                    stable_through_sample=self._ledger.stable_through_sample,
                    updates=chunk,
                    speaker_links=[],
                )
            )
            if sequence is not None:
                self._last_update_sequence = sequence

    @staticmethod
    def _unknown_result(unit: AttributionUnit) -> AttributionResult:
        return AttributionResult(
            segment_uid=unit.segment_uid,
            revision=1,
            status="unknown",
            speaker=None,
            coverage_ratio=0.0,
            overlap_ratio=0.0,
            candidates=(),
        )

    def _mark_degraded(self, reason: str) -> None:
        if self._degraded_reason is None:
            self._degraded_reason = reason

    async def _handle_degradation(self, exc: DiarizationError) -> None:
        """First-wins degradation: freeze units unknown, then one status event."""
        reason = (
            exc.code
            if exc.code in {"diarization_overloaded", "diarization_invalid_output"}
            else "diarization_invalid_output"
        )
        through = self._timeline.accepted_samples
        if self._ledger is not None and self._degraded_reason is None:
            self._stable_through_at_degradation = self._ledger.stable_through_sample
        self._mark_degraded(reason)
        if self._ledger is not None:
            await self._send_diarization_updates(self._ledger.freeze(through))
        if not self._status_sent:
            self._status_sent = True
            await self._send(diarization_status_event(reason=reason, since_sample=through))

    async def _handle_finalize(self, event: dict[str, Any]) -> None:
        if self._ledger is None:
            raise RealtimeAdapterError(
                "unsupported_operation",
                f"{SPEECHRAIL_DIARIZATION_V1} is not negotiated on this session",
            )
        finalization_id = parse_finalize_request(event)
        if self._diarization_phase == "finalized":
            if self._finalization_id != finalization_id or self._finalized_payload is None:
                raise RealtimeAdapterError(
                    "invalid_state",
                    "session already finalized with a different finalization_id",
                )
            await self._send(dict(self._finalized_payload))
            return
        if self._diarization_phase == "draining":
            if self._finalization_id != finalization_id:
                raise RealtimeAdapterError(
                    "invalid_state", "another finalization is already in progress"
                )
            return
        self._finalization_id = finalization_id
        self._diarization_phase = "draining"
        await self._drain_and_finalize()

    async def _drain_and_finalize(self) -> None:
        """Drain the native stream under a bounded deadline, then finalize."""
        deadline = self._settings.realtime_diarization_drain_deadline_seconds
        assert self._finalization_id is not None
        try:
            async with asyncio.timeout(deadline):
                if self._diarization is not None and self._diarization.is_continuous:
                    try:
                        snapshot = await self._diarization.finish_stream(
                            self._timeline.accepted_samples
                        )
                    except DiarizationError as exc:
                        await self._handle_degradation(exc)
                    else:
                        if snapshot is not None and self._ledger is not None:
                            await self._send_diarization_updates(
                                self._ledger.apply_activity(snapshot)
                            )
                if self._ledger is not None and self._degraded_reason is None:
                    await self._send_diarization_updates(
                        self._ledger.freeze(self._timeline.accepted_samples)
                    )
        except TimeoutError:
            through = self._timeline.accepted_samples
            if self._ledger is not None and self._degraded_reason is None:
                self._stable_through_at_degradation = self._ledger.stable_through_sample
            self._mark_degraded("finalization_timeout")
            if self._ledger is not None:
                await self._send_diarization_updates(self._ledger.freeze(through))
            if not self._status_sent:
                self._status_sent = True
                await self._send(
                    diarization_status_event(reason="finalization_timeout", since_sample=through)
                )
        through = self._timeline.accepted_samples
        if self._degraded_reason is None:
            stable_through = through
        else:
            stable_through = min(through, self._stable_through_at_degradation)
        payload = diarization_finalized_event(
            finalization_id=self._finalization_id,
            through_sample=through,
            stable_through_sample=stable_through,
            status="complete" if self._degraded_reason is None else "degraded",
            reason=self._degraded_reason,
            last_update_sequence=self._last_update_sequence,
        )
        self._finalized_payload = payload
        self._diarization_phase = "finalized"
        await self._send(payload)

    async def _drain_asr_events(self) -> None:
        asr = self._asr
        if asr is None:
            return

        try:
            async for event in asr.events():
                # Stop as soon as this session is no longer the current one
                # (superseded by barge-in, clear, or a commit): its remaining
                # events are stale. A generation counter cannot be used here —
                # a session opened by a rollover commit legitimately spans
                # later turn generations when speech re-activates on it.
                if self._asr is not asr:
                    break
                if event.kind == "partial":
                    if self._speech_admission is not None and not self._turn_has_admitted_speech:
                        continue
                    current_text = event.text
                    if not current_text:
                        continue
                    if not current_text.startswith(self._last_partial_text):
                        # This wire event is append-only. Keep a changed suffix
                        # private until the terminal completed event can replace
                        # the provisional transcript atomically.
                        continue
                    delta = current_text[len(self._last_partial_text):]
                    self._last_partial_text = current_text
                    if delta:
                        await self._send(
                            transcription_delta(item_id=self._current_item_id, delta=delta)
                        )
                elif event.kind == "completed":
                    if self._asr is not asr:
                        break
                    self._last_partial_text = ""
                    self._unflushed_bytes = 0
                    norm_text = apply_light_itn(event.text)
                    self._services.metrics.record_realtime_turn(
                        mode="server_vad" if self._vad is not None else "manual",
                        commit_reason="vad_stop" if self._vad is not None else "client",
                        outcome="text" if norm_text else "empty",
                        characters=len(norm_text),
                        active_samples=max(0, self._item_end_sample - self._item_start_sample),
                    )
                    if self._extensions:
                        # Extension mode: unique item, session-sample bounds and
                        # immutable units; legacy .segment events are never sent
                        # alongside the negotiated contract.
                        await self._send(
                            conversation_item_created(
                                session_id=self._session_id,
                                transcript=norm_text,
                                item_id=self._current_item_id,
                            )
                        )
                        units = self._build_units(norm_text, event.segments)
                        await self._send(
                            transcription_completed_extension(
                                item_id=self._current_item_id,
                                transcript=norm_text,
                                audio_start_sample=self._item_start_sample,
                                audio_end_sample=max(
                                    self._item_end_sample, self._item_start_sample
                                ),
                                attribution_units=self._render_units(units),
                            )
                        )
                        await self._register_units(units)
                        continue
                    await self._send(
                        conversation_item_created(
                            session_id=self._session_id,
                            transcript=norm_text,
                            item_id=self._current_item_id,
                        )
                    )
                    segments = event.segments
                    if self._diarization is not None and segments:
                        try:
                            segments = await self._diarization.annotate(segments)
                        except DiarizationError as exc:
                            await self._send(error_event(code=exc.code, message=str(exc)))
                            return
                        offset_ms = (
                            int(self._item_start_sample / 16)
                            if self._speech_admission is not None
                            else 0
                        )
                        for segment in segments:
                            await self._send(
                                transcription_segment(
                                    session_id=self._session_id,
                                    item_id=self._current_item_id,
                                    segment_id=segment.id,
                                    text=apply_light_itn(segment.text),
                                    speaker=segment.speaker,
                                    start_ms=segment.start_ms + offset_ms,
                                    end_ms=segment.end_ms + offset_ms,
                                )
                            )
                    await self._send(
                        transcription_completed(item_id=self._current_item_id, transcript=norm_text)
                    )
                elif event.kind == "error":
                    self._last_partial_text = ""
                    self._unflushed_bytes = 0
                    await self._send(
                        transcription_failed(
                            item_id=self._current_item_id,
                            code=event.error_code or "backend_error",
                            message="streaming transcription failed",
                        )
                    )
        except (asyncio.CancelledError, WebSocketDisconnect, RuntimeError):
            pass
        except Exception:
            # A dead reader must not die silently: the client would keep
            # believing ASR is alive and never see a terminal failure event.
            logger.exception("realtime ASR event reader failed")
            with contextlib.suppress(Exception):
                await self._send(
                    transcription_failed(
                        item_id=self._current_item_id,
                        code="backend_error",
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
        wire_profile: Literal["legacy", "current"] = (
            "current" if self._config.get("wire_profile") == "current" else "legacy"
        )
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
                import time as _time

                _ttfa_t0 = _time.monotonic()
                _ttfa_recorded = False
                _admission_started = _time.monotonic()
                async with asyncio.timeout(self._settings.request_timeout_seconds):
                    async with self._services.governor.reserve(
                        WorkClass.REALTIME_TTS, deadline=self._settings.request_timeout_seconds
                    ):
                        self._services.metrics.record_realtime_phase(
                            "tts_admission", _time.monotonic() - _admission_started
                        )
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
                                if not _ttfa_recorded:
                                    self._services.metrics.record_ttfa(_time.monotonic() - _ttfa_t0)
                                    _ttfa_recorded = True
                                await self._send(
                                    response_audio_delta(
                                        session_id=self._session_id,
                                        response_id=response_id,
                                        item_id=item_id,
                                        delta=base64.b64encode(chunk.audio).decode("ascii"),
                                        wire_profile=wire_profile,
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
                                            wire_profile=wire_profile,
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
                    session_id=self._session_id,
                    response_id=response_id,
                    item_id=item_id,
                    wire_profile=wire_profile,
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
        except (WebSocketDisconnect, RuntimeError):
            return
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            with contextlib.suppress(Exception):
                await self._send(error_event(code="tts_error", message=str(exc)))
                await self._send(
                    response_done(
                        session_id=self._session_id,
                        response_id=response_id,
                        status="failed",
                    )
                )

    async def _reserve_asr(self) -> None:
        self._asr_resources = AsyncExitStack()
        admission_started = time.monotonic()
        try:
            await self._asr_resources.enter_async_context(
                self._services.governor.reserve(
                    WorkClass.REALTIME_ASR, deadline=self._settings.request_timeout_seconds
                )
            )
            self._services.metrics.record_realtime_phase(
                "asr_admission", time.monotonic() - admission_started
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
        if self._extensions:
            self._diarization = DiarizationCoordinator(
                continuous=engine.create_stream(config=self._diarization_config)
            )
        else:
            self._diarization = DiarizationCoordinator(
                engine.create(config=self._diarization_config)
            )

    async def _close_diarization(self) -> None:
        if self._diarization is not None:
            with contextlib.suppress(Exception):
                await self._diarization.close()
            self._diarization = None
