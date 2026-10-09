"""Connection ledger and per-utterance ownership for Realtime TTS."""

from __future__ import annotations

import asyncio
import base64
import contextlib
import logging
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass, field
from typing import Any
from uuid import uuid4

from speechrail.application.tts_audio_window import TtsAudioWindow
from speechrail.application.tts_stream import (
    StreamController,
    TtsStreamAdmissionError,
    TtsStreamReceipt,
    TtsStreamService,
)
from speechrail.application.tts_stream_capability import resolve_tts_stream_capability
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    parse_tts_append_text,
    parse_tts_audio_ack,
    parse_tts_cancel,
    parse_tts_finish_text,
    parse_tts_start,
    plan_fingerprint,
    tts_audio_delta,
    tts_cancelled,
    tts_completed,
    tts_failed,
    tts_output_format,
    tts_stream_started,
    tts_text_accepted,
)
from speechrail.config.selection import ActiveModelCatalog
from speechrail.domain.tts import VoiceProfile, VoiceStoreUnavailableError, resolve_voice
from speechrail.domain.tts_execution import TtsExecutionPorts
from speechrail.domain.tts_stream import (
    TtsStreamError,
    TtsStreamEvent,
    TtsStreamEventKind,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamTerminal,
)
from speechrail.domain.voice_ports import VoiceDirectory

logger = logging.getLogger(__name__)
_MAX_TTS_REQUEST_IDS = 256
_MAX_PENDING_STREAM_APPENDS = 128


@dataclass(slots=True)
class TtsUtterance:
    """Mutable state belongs to this identity, including before admission."""

    request_id: str
    response_id: str
    plan_id: str = ""
    voice_revision: str | None = None
    limits: TtsStreamLimits | None = None
    audio_window: TtsAudioWindow | None = None
    task: asyncio.Task[None] | None = None
    controller: StreamController | None = None
    ready: asyncio.Event = field(default_factory=asyncio.Event)
    pending: dict[int, str] = field(default_factory=dict)
    accepted: int = 0
    generated_samples: int = 0
    receipt_id: str | None = None
    failure_code: str | None = None
    retired: bool = False
    terminal_sent: bool = False
    terminal_lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class RealtimeTtsOwner:
    """Own one live utterance and a bounded connection request ledger."""

    def __init__(
        self,
        *,
        task_id: str,
        send: Callable[[dict[str, object]], Awaitable[int | None]],
        config: Callable[[], Mapping[str, Any]],
        catalog: ActiveModelCatalog,
        voices: VoiceDirectory,
        streams: TtsStreamService | None,
        execution: TtsExecutionPorts,
        ready: Callable[[], bool],
        synthesizer_available: bool,
        timeout_seconds: float,
        initial_model: str,
    ) -> None:
        self._task_id = task_id
        self._send = send
        self._config = config
        self._catalog = catalog
        self._voices = voices
        self._streams = streams
        self._execution = execution
        self._ready = ready
        self._synthesizer_available = synthesizer_available
        self._timeout_seconds = timeout_seconds
        self._initial_model = initial_model
        self._request_ids: set[str] = set()
        self._current: TtsUtterance | None = None
        self._tasks: set[asyncio.Task[None]] = set()
        self._closing = False

    @property
    def busy(self) -> bool:
        context = self._current
        return (
            context is not None
            and not context.retired
            and (
                (context.task is not None and not context.task.done())
                or (context.controller is not None and not context.controller.closed)
            )
        )

    def _claim_request(self, request_id: str) -> None:
        if self.busy:
            raise RealtimeAdapterError("tts_in_progress", "a TTS response is already in progress")
        if request_id in self._request_ids:
            raise RealtimeAdapterError(
                "tts_request_invalid",
                "request_id must be unique within this WebSocket connection",
            )
        if len(self._request_ids) >= _MAX_TTS_REQUEST_IDS:
            raise RealtimeAdapterError(
                "tts_request_invalid",
                "TTS request id ledger is full; start a new WebSocket connection",
            )

    def _profile(self, voice: str) -> VoiceProfile:
        try:
            return self._voices.get_profile(voice)
        except VoiceStoreUnavailableError:
            raise RealtimeAdapterError(
                "voice_store_unavailable", "custom voice storage is unavailable"
            ) from None
        except ValueError:
            raise RealtimeAdapterError("voice_not_found", f"unknown voice: {voice[:200]}") from None

    def _require_voice_available(self, profile: VoiceProfile) -> None:
        if self._catalog.tts is None and self._catalog.tts_clone is None:
            return
        voice = profile.id
        if profile.revoked:
            raise RealtimeAdapterError("voice_revoked", f"voice {voice[:200]} is revoked")
        role = profile.runtime_role
        if role is None:
            raise RealtimeAdapterError(
                "voice_not_available",
                f"voice {voice[:200]} is unavailable for the active TTS capabilities",
            )
        try:
            resolve_binding(role, voice, profile=profile)
        except VoiceStoreUnavailableError:
            raise RealtimeAdapterError(
                "voice_store_unavailable", "custom voice storage is unavailable"
            ) from None
        except ValueError:
            raise RealtimeAdapterError(
                "voice_not_available",
                f"voice {voice[:200]} is unavailable for the active TTS weights; "
                "use one of the available system voices from /v1/voices",
            ) from None

    async def start(self, event: dict[str, Any]) -> None:
        request = parse_tts_start(event)
        config = self._config()
        if not bool(config.get("tts_enabled", False)):
            raise RealtimeAdapterError(
                "tts_not_enabled",
                "caller TTS must be enabled in the transcription session",
            )
        if self._streams is None:
            raise RealtimeAdapterError(
                "tts_streaming_unsupported",
                "this service exposes no incremental TTS stream",
            )
        if not self._ready() or not self._synthesizer_available:
            raise RealtimeAdapterError("backend_not_ready", "TTS backend is not ready")
        self._claim_request(request.request_id)
        voice = resolve_voice(request.voice)
        profile = self._profile(voice)
        if profile.revoked:
            raise RealtimeAdapterError("voice_revoked", f"voice {voice[:200]} is revoked")
        self._require_voice_available(profile)
        if (
            request.expected_voice_revision is not None
            and request.expected_voice_revision != profile.revision
        ):
            raise RealtimeAdapterError(
                "voice_revision_conflict", "Requested voice revision is not active"
            )
        artifact = self._catalog.artifact_for_voice_mode(profile.mode)
        if request.expected_model_revision is not None and (
            artifact is None or artifact.revision != request.expected_model_revision
        ):
            raise RealtimeAdapterError(
                "model_revision_conflict",
                "Requested model revision is not the active TTS artifact",
            )
        capability = resolve_tts_stream_capability(
            profile=profile,
            artifact=artifact,
            tts_ready=self._ready(),
            voice_enabled=True,
            execution=self._execution,
            stream_service=self._streams,
        )
        if not capability.supported:
            detail = capability.reason or "unsupported"
            hint = f"; {capability.hint}" if capability.hint else ""
            raise RealtimeAdapterError(
                "tts_streaming_unsupported",
                f"voice {voice[:200]} has no incremental TTS path: {detail}{hint}",
            )
        response_id = f"resp_{uuid4().hex[:12]}"
        window = TtsAudioWindow(
            request.audio_window_bytes,
            inactivity_seconds=request.limits.slow_consumer_seconds,
        )
        context = TtsUtterance(
            request_id=request.request_id,
            response_id=response_id,
            voice_revision=profile.revision,
            limits=request.limits,
            audio_window=window,
            plan_id=plan_fingerprint(
                task=request.task,
                asr_model=str(config.get("model") or self._initial_model),
                voice=voice,
                voice_revision=profile.revision,
                catalog_revision=artifact.revision if artifact is not None else None,
            ),
        )
        options = TtsStreamOptions(
            request_id=request.request_id,
            response_id=response_id,
            voice=voice,
            language=str(config.get("language") or "auto"),
            speed=request.speed,
            expected_voice_revision=profile.revision,
            expected_model_revision=request.expected_model_revision,
        )
        receipt = TtsStreamReceipt(
            voice_revision=profile.revision,
            model_artifact=artifact.key if artifact is not None else None,
            model_source=artifact.model_id if artifact is not None else None,
            model_variant=artifact.variant if artifact is not None else None,
            model_catalog_revision=artifact.revision if artifact is not None else None,
        )
        self._current = context
        self._request_ids.add(request.request_id)
        context.task = asyncio.create_task(
            self._run(context, options=options, receipt=receipt, window=window)
        )
        self._tasks.add(context.task)
        context.task.add_done_callback(self._task_done)

    def _task_done(self, task: asyncio.Task[None]) -> None:
        self._tasks.discard(task)
        if not task.cancelled() and (failure := task.exception()) is not None:
            logger.error("Realtime TTS owner failed: %s", type(failure).__name__)

    def _require_current(self, request_id: str) -> TtsUtterance:
        context = self._current
        if context is None or context.request_id != request_id:
            raise RealtimeAdapterError(
                "tts_not_active", "the requested incremental utterance is not active"
            )
        return context

    async def _controller(self, context: TtsUtterance) -> StreamController:
        if context.controller is None:
            try:
                await asyncio.wait_for(context.ready.wait(), timeout=self._timeout_seconds)
            except TimeoutError as exc:
                raise RealtimeAdapterError(
                    "backend_timeout", "the incremental utterance did not start in time"
                ) from exc
        if self._current is not context or context.controller is None:
            raise RealtimeAdapterError(
                "tts_not_active", "the requested incremental utterance is not active"
            )
        return context.controller

    async def append(self, event: dict[str, Any]) -> None:
        request = parse_tts_append_text(event)
        context = self._require_current(request.request_id)
        limits = context.limits
        if limits is not None:
            pending_codepoints = sum(len(text) for text in context.pending.values())
            if len(request.text) > limits.max_append_codepoints:
                raise RealtimeAdapterError(
                    "tts_stream_limit_exceeded",
                    "appended text exceeds the per-append codepoint limit",
                )
            if (
                context.accepted + pending_codepoints + len(request.text)
                > limits.max_total_codepoints
            ):
                raise RealtimeAdapterError(
                    "tts_stream_limit_exceeded",
                    "utterance exceeds the total codepoint limit",
                )
        controller = await self._controller(context)
        if len(context.pending) >= _MAX_PENDING_STREAM_APPENDS:
            raise RealtimeAdapterError(
                "tts_backpressure",
                "too many appends are still awaiting model acceptance",
            )
        context.pending[request.sequence] = request.text
        try:
            await controller.append_text(request.sequence, request.text)
        except BaseException as exc:
            context.pending.pop(request.sequence, None)
            if isinstance(exc, TtsStreamError):
                raise RealtimeAdapterError(exc.code, str(exc)) from None
            raise
        if self._current is not context or context.retired:
            return
        context.pending.pop(request.sequence, None)
        context.accepted += len(request.text)
        await self._send(
            tts_text_accepted(
                task_id=self._task_id,
                request_id=request.request_id,
                append_sequence=request.sequence,
                accepted_codepoints=len(request.text),
                total_codepoints=context.accepted,
            )
        )

    def acknowledge(self, event: dict[str, Any]) -> None:
        request = parse_tts_audio_ack(event)
        context = self._current
        window = context.audio_window if context is not None else None
        if (
            context is None
            or request.request_id != context.request_id
            or window is None
            or window.closed
        ):
            if request.request_id in self._request_ids:
                return
            raise RealtimeAdapterError("tts_not_active", "the audio request is not active")
        try:
            window.acknowledge(request.sample_offset)
        except ValueError as exc:
            raise RealtimeAdapterError("tts_audio_ack_invalid", str(exc)) from None

    async def finish(self, event: dict[str, Any]) -> None:
        request = parse_tts_finish_text(event)
        controller = await self._controller(self._require_current(request.request_id))
        if controller.terminal is not None or controller.closed:
            return
        try:
            await controller.finish_text(request.last_sequence)
        except TtsStreamError as exc:
            raise RealtimeAdapterError(exc.code, str(exc)) from None

    async def _run(
        self,
        context: TtsUtterance,
        *,
        options: TtsStreamOptions,
        receipt: TtsStreamReceipt,
        window: TtsAudioWindow,
    ) -> None:
        try:
            service = self._streams
            if service is None:
                raise TtsStreamAdmissionError(
                    "tts_streaming_unsupported",
                    "this service exposes no incremental TTS stream",
                )
            assert context.limits is not None
            controller = await service.open(
                options=options,
                sink=lambda event: self._on_event(context, event, window=window),
                receipt=receipt,
                limits=context.limits,
                audio_admission=window.reserve,
            )
        except asyncio.CancelledError:
            self._release_stream_state(context)
            raise
        except (TtsStreamAdmissionError, TtsStreamError) as exc:
            await self._fail_open(context, exc.code)
            return
        except Exception:
            logger.exception("incremental TTS stream failed to open")
            await self._fail_open(context, "tts_backend_failed")
            return
        context.controller = controller
        context.receipt_id = controller.receipt_id
        try:
            await self._send(
                tts_stream_started(
                    task_id=self._task_id,
                    plan_id=context.plan_id,
                    request_id=context.request_id,
                    voice_revision=context.voice_revision,
                    output_format=tts_output_format(),
                    limits=controller.limits,
                    audio_window_bytes=window.maximum_bytes,
                )
            )
            context.ready.set()
            await controller.wait_closed()
        finally:
            try:
                await controller.aclose(
                    reason="client_disconnected" if self._closing else "cancelled"
                )
            finally:
                # An unconfirmed backend remains owned; its controller keeps
                # the governor lane quarantined and the receipt pending.
                if controller.closed:
                    self._release_stream_state(context)
                else:
                    context.ready.set()

    async def _on_event(
        self, context: TtsUtterance, event: TtsStreamEvent, *, window: TtsAudioWindow
    ) -> None:
        if self._current is not context or event.response_id != context.response_id:
            return
        if event.terminal is not None:
            window.close()
            if self._closing:
                return
            context.retired = True
            if event.terminal is TtsStreamTerminal.COMPLETED:
                status = "completed"
            elif event.terminal is TtsStreamTerminal.CANCELLED:
                status = "cancelled"
            else:
                status = "failed"
                context.failure_code = event.error_code or "tts_backend_failed"
            await self._finalize_tts(context, status=status)
        elif event.kind is TtsStreamEventKind.AUDIO:
            context.generated_samples += len(event.pcm16) // 2
            await self._send(
                tts_audio_delta(
                    task_id=self._task_id,
                    request_id=context.request_id,
                    chunk_index=int(event.chunk_index or 0),
                    sample_offset=int(event.sample_offset or 0),
                    delta=base64.b64encode(event.pcm16).decode("ascii"),
                )
            )

    async def _fail_open(self, context: TtsUtterance, code: str) -> None:
        self._release_stream_state(context)
        if self._closing or context.terminal_sent:
            return
        context.failure_code = code
        await self._finalize_tts(context, status="failed")

    async def cancel(self, event: dict[str, Any]) -> None:
        request = parse_tts_cancel(event)
        context = self._require_current(request.request_id)
        if context.task is None or context.task.done():
            raise RealtimeAdapterError(
                "tts_not_active", "the requested TTS utterance is not active"
            )
        if context.audio_window is not None:
            context.audio_window.close()
        if context.controller is not None:
            await context.controller.cancel()
            return
        self._release_stream_state(context)
        context.task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await context.task
        if not self._closing:
            await self._finalize_tts(context, status="cancelled")

    async def close(self) -> None:
        self._closing = True
        context = self._current
        failures: list[Exception] = []
        tasks = set(self._tasks)
        if context is not None:
            if context.audio_window is not None:
                context.audio_window.close()
            if context.task is not None:
                tasks.add(context.task)
            if context.controller is not None:
                try:
                    await context.controller.aclose(reason="client_disconnected")
                except Exception as exc:
                    failures.append(exc)
        for task in tasks:
            if not task.done():
                task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                try:
                    await task
                except Exception as exc:
                    if not any(exc is failure for failure in failures):
                        failures.append(exc)
        if context is not None and (
            context.controller is None or context.controller.closed
        ):
            self._release_stream_state(context)
        if failures:
            raise ExceptionGroup("Realtime TTS cleanup failed", failures)

    def _release_stream_state(self, context: TtsUtterance) -> None:
        context.ready.set()
        if context.audio_window is not None:
            context.audio_window.close()
        if self._current is context:
            self._current = None

    async def _finalize_tts(self, context: TtsUtterance, *, status: str) -> None:
        if status == "completed":
            event = tts_completed(
                task_id=self._task_id,
                request_id=context.request_id,
                generated_samples=context.generated_samples,
            )
        elif status == "cancelled":
            event = tts_cancelled(task_id=self._task_id, request_id=context.request_id)
        else:
            event = tts_failed(
                task_id=self._task_id,
                request_id=context.request_id,
                code=context.failure_code or "tts_backend_failed",
                message="incremental TTS response failed",
            )
        async with context.terminal_lock:
            if context.terminal_sent:
                return
            send_task = asyncio.ensure_future(self._send(event))
            cancelled = False
            while True:
                try:
                    await asyncio.shield(send_task)
                except asyncio.CancelledError:
                    if send_task.done() and send_task.cancelled():
                        raise
                    cancelled = True
                    continue
                break
            await send_task
            context.terminal_sent = True
            if cancelled:
                raise asyncio.CancelledError
