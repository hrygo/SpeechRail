"""Protocol configuration, dispatch and owned Realtime use-case composition."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Mapping
from typing import Any, cast
from uuid import uuid4

from speechrail.application.asr_window_boundaries import WindowBoundaryReview
from speechrail.application.realtime_asr import RealtimeAsrOwner, RealtimeAsrPorts
from speechrail.application.realtime_auxiliary import RealtimeAuxiliaryOwner, RealtimeAuxiliaryPorts
from speechrail.application.realtime_state import RealtimeConfiguration
from speechrail.application.realtime_tts import RealtimeTtsOwner
from speechrail.application.services import AppServices
from speechrail.compatibility.openai_realtime import (
    RealtimeAdapterError,
    parse_client_event,
    parse_commit_receipt_request,
    parse_commit_request,
    session_created,
    session_updated,
)
from speechrail.config.selection import active_model_catalog
from speechrail.domain.alignment import AlignTextPort
from speechrail.domain.asr_policy import resolve_effective_max_segment_ms
from speechrail.runtime.cleanup import join_cleanup

SendEvent = Callable[[dict[str, object]], Awaitable[int | None]]


def _str_list(value: object) -> list[str] | None:
    if isinstance(value, (list, tuple)) and all(isinstance(item, str) for item in value):
        return list(value)
    return None


class OpenAIRealtimeSession:
    """Compose one connection's input, output and auxiliary owners."""

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
        self._active_model_catalog = active_model_catalog(self._settings)
        self._registered_asr = frozenset(
            {self._settings.model_id, *self._settings.compatibility_model_ids}
        )
        task_id = f"task_{uuid4().hex[:12]}"
        self._protocol_config = RealtimeConfiguration(
            {
                "model": self._initial_model,
                "language": None,
                "prompt": "",
                "tts_enabled": False,
                "task": "conversation",
                "transcription_partial_mode": "delta",
                "transcription_chunk_duration_ms": self._settings.qwen3_streaming_chunk_duration_ms,
            }
        )
        self._asr_owner = RealtimeAsrOwner(
            ports=RealtimeAsrPorts(
                services.realtime_asr_factory,
                services.governor,
                services.metrics,
                services.window_asr_factory,
                (
                    lambda decoder: WindowBoundaryReview(
                        decoder=decoder,
                        aligner=cast(AlignTextPort, services.text_aligner),
                        admission=services.alignment_admission,
                        governor=services.governor,
                        metrics=services.metrics,
                    )
                )
                if services.text_aligner is not None
                else None,
                pcm_budget=services.pcm_budget,
            ),
            settings=self._settings,
            session_id=session_id,
            task_id=task_id,
            send=send,
            config=self._protocol_config.snapshot,
        )
        self._auxiliary_owner = RealtimeAuxiliaryOwner(
            ports=RealtimeAuxiliaryPorts(
                aligner=cast(AlignTextPort, services.text_aligner),
                engine=services.diarization_engine,
                alignment_admission=services.alignment_admission,
                diarization_admission=services.diarization_admission,
                metrics=services.metrics,
                ready=lambda: services.diarization_ready,
                status_message=lambda: str(services.diarization_status["message"]),
                engine_for_backend=services.diarization_engine_for,
                backend_ready=lambda backend: bool(
                    services.diarization_backend_status(backend)["ready"]
                ),
            ),
            settings=self._settings,
            session_id=session_id,
            task_id=task_id,
            send=send,
            config=self._protocol_config.snapshot,
            input_source=self._asr_owner,
        )
        self._asr_owner.bind_auxiliary(self._auxiliary_owner)
        self._tts_owner = RealtimeTtsOwner(
            task_id=task_id,
            send=send,
            config=self._protocol_config.snapshot,
            catalog=self._active_model_catalog,
            voices=services.voice_store,
            streams=services.tts_streams,
            execution=services.tts_execution,
            ready=lambda: services.tts_ready,
            synthesizer_available=services.tts_synthesizer is not None,
            timeout_seconds=self._settings.request_timeout_seconds,
            initial_model=self._initial_model,
        )
        self._close_task: asyncio.Task[None] | None = None

    @property
    def _config(self) -> Mapping[str, Any]:
        return self._protocol_config.snapshot()

    async def close(self) -> None:
        if self._close_task is None:
            self._close_task = asyncio.create_task(self._close_owned(), name="realtime-close")
        await join_cleanup(self._close_task)

    async def _close_owned(self) -> None:
        failures: list[Exception] = []
        for close in (
            self._asr_owner.begin_close,
            self._auxiliary_owner.cancel_alignment_tasks,
            self._tts_owner.close,
            self._asr_owner.close,
            self._auxiliary_owner.close,
        ):
            try:
                await close()
            except Exception as exc:
                failures.append(exc)
        if failures:
            raise ExceptionGroup("Realtime owner cleanup failed", failures)

    async def start(self) -> None:
        await self._send(session_created(session_id=self._session_id, **self._session_fields()))

    async def handle(
        self,
        event: dict[str, Any],
        *,
        defer_asr_commit: bool = False,
    ) -> Awaitable[None] | None:
        if self._close_task is not None:
            raise RealtimeAdapterError("invalid_state", "the session is closing")
        parsed = parse_client_event(event)
        if parsed.kind == "session_update":
            await self._update_session(event)
        elif parsed.kind == "append":
            await self._asr_owner.append(event)
        elif parsed.kind == "commit":
            commit_event_id = parse_commit_request(event)
            request_receipt = parse_commit_receipt_request(event)
            barrier = await self._asr_owner.freeze_commit(
                reason="client",
                commit_event_id=commit_event_id,
            )
            completion = self._asr_owner.complete_commit(
                barrier,
                commit_event_id=commit_event_id,
                request_receipt=request_receipt,
            )
            if defer_asr_commit:
                return completion
            await completion
        elif parsed.kind == "diarization_finish":
            await self._auxiliary_owner.finish(event)
        elif parsed.kind == "clear":
            await self._asr_owner.clear()
        elif parsed.kind == "tts_start":
            await self._tts_owner.start(event)
        elif parsed.kind == "tts_append_text":
            await self._tts_owner.append(event)
        elif parsed.kind == "tts_finish_text":
            await self._tts_owner.finish(event)
        elif parsed.kind == "tts_cancel":
            await self._tts_owner.cancel(event)
        elif parsed.kind == "tts_audio_ack":
            self._tts_owner.acknowledge(event)
        else:
            raise RealtimeAdapterError("unsupported_operation", "unsupported SpeechRail event")
        return None

    def _session_fields(self) -> dict[str, object]:
        """Render the effective current session object for create/update."""

        endpointing = self._config.get("turn_detection")
        expected_asr = self._config.get("expected_asr_revision")
        return {
            "model": str(self._config.get("model") or self._display_model),
            "language": (
                self._config.get("language")
                if isinstance(self._config.get("language"), str)
                else None
            ),
            "languages": _str_list(self._config.get("languages")),
            "prompt": str(self._config.get("prompt") or ""),
            "keywords": _str_list(self._config.get("keywords")),
            "timestamp_granularities": _str_list(self._config.get("timestamp_granularities")),
            "turn_detection": "manual" if endpointing == "manual" else None,
            "task": str(self._config.get("task") or "conversation"),
            "tts_enabled": bool(self._config.get("tts_enabled", False)),
            "alignment_enabled": bool(self._config.get("alignment_enabled", False)),
            "diarization_enabled": bool(self._auxiliary_owner.diarization_enabled),
            "diarization_backend": self._config.get("diarization_backend"),
            "diarization_max_speakers": self._services.diarization_backend_status(
                str(self._config.get("diarization_backend", "sortformer"))
            )["max_speakers"],
            "endpointing": endpointing if isinstance(endpointing, dict) else None,
            "expected_asr_revision": (expected_asr if isinstance(expected_asr, str) else None),
            "window_scene": self._config.get("window_scene"),
            "asr_policy": self._asr_owner.policy(),
            "effective_max_segment_ms": self._asr_owner.effective_segment_ms(),
            "request_timeout_ms": int(self._settings.request_timeout_seconds * 1000),
        }

    async def _update_session(self, event: dict[str, Any]) -> None:
        from speechrail.compatibility.openai_realtime import apply_session_update

        session_request = event.get("session")
        extension = session_request.get("speechrail") if isinstance(session_request, dict) else None
        audio = session_request.get("audio") if isinstance(session_request, dict) else None
        audio_input = audio.get("input") if isinstance(audio, dict) else None
        nested_extension = audio_input.get("speechrail") if isinstance(audio_input, dict) else None
        requested_window = any(
            isinstance(value, dict) and "window" in value for value in (extension, nested_extension)
        )
        _updated, candidate = apply_session_update(
            event,
            session_id=self._session_id,
            revision_window_ready=(
                self._settings.asr_revision_windows_enabled
                if requested_window
                else self._services.revision_window_ready
            ),
            asr_model=self._settings.model_id,
            registered_asr=self._registered_asr,
            current_config=self._config,
            request_timeout_ms=int(self._settings.request_timeout_seconds * 1000),
            service_max_segment_ms=(self._settings.max_realtime_buffer_bytes or 8_388_608) // 64,
            capability_max_segment_ms=None,
        )
        if (
            candidate.get("window_scene") != self._config.get("window_scene")
            and self._asr_owner.accepted_samples > 0
        ):
            raise RealtimeAdapterError(
                "invalid_state", "window mode is frozen after the first input"
            )
        if candidate.get("asr_policy") != self._asr_owner.policy() and self._asr_owner.policy_busy:
            raise RealtimeAdapterError(
                "invalid_state", "ASR policy cannot change while input is retained"
            )
        if candidate.get("window_scene") is not None:
            await self._services.prepare_revision_window()
            if not self._services.revision_window_ready:
                raise RealtimeAdapterError(
                    "unsupported_operation", "revision window dependencies are not ready"
                )
        # The caller opts in to stateless incremental TTS; SpeechRail never
        # infers an assistant mode.
        if candidate.get("tts_explicit"):
            requested_tts_enabled = bool(candidate.get("tts_enabled", False))
            if requested_tts_enabled and not self._services.tts_ready:
                raise RealtimeAdapterError("backend_not_ready", "TTS backend is not ready")
            if not requested_tts_enabled and self._tts_owner.busy:
                raise RealtimeAdapterError(
                    "invalid_state", "cannot disable TTS while a response is active"
                )
            candidate["tts_enabled"] = requested_tts_enabled
        else:
            candidate["tts_enabled"] = bool(self._config.get("tts_enabled", False))
        if self._asr_owner.accepted_samples > 0:
            for key in (
                "alignment_enabled",
                "alignment_granularity",
                "task",
                "timestamp_granularities",
            ):
                if candidate.get(key) != self._config.get(key):
                    raise RealtimeAdapterError(
                        "invalid_state",
                        "transcription options cannot change after the first audio frame",
                    )

        requested_alignment = self._auxiliary_owner.alignment_enabled
        if candidate.get("alignment_explicit"):
            requested_alignment = bool(candidate.get("alignment_enabled", False))
            if requested_alignment != self._auxiliary_owner.alignment_enabled:
                if self._asr_owner.accepted_samples > 0:
                    raise RealtimeAdapterError(
                        "invalid_state",
                        "alignment can only be enabled before the first audio",
                    )
                if requested_alignment and self._services.text_aligner is None:
                    raise RealtimeAdapterError(
                        "backend_not_ready",
                        "fixed-text alignment is not available",
                    )

        requested_diarization = self._auxiliary_owner.diarization_enabled
        requested_backend = str(candidate.get("diarization_backend", "sortformer"))
        if self._asr_owner.accepted_samples > 0 and requested_backend != self._config.get(
            "diarization_backend", "sortformer"
        ):
            raise RealtimeAdapterError("invalid_state", "diarization backend is frozen after input")
        backend_engine = self._services.diarization_engine_for(requested_backend)
        if candidate.get("diarization_explicit"):
            requested_diarization = bool(candidate.get("diarization_enabled", False))
            if requested_diarization != self._auxiliary_owner.diarization_enabled:
                if self._asr_owner.accepted_samples > 0:
                    raise RealtimeAdapterError(
                        "invalid_state",
                        "diarization can only be enabled before the first audio",
                    )
                if requested_diarization and (
                    not self._services.diarization_backend_status(requested_backend)["ready"]
                    or backend_engine is None
                    or not bool(getattr(backend_engine, "supports_stream", False))
                    or self._services.text_aligner is None
                ):
                    raise RealtimeAdapterError(
                        "diarization_not_available",
                        str(self._services.diarization_status["message"]),
                    )
        candidate["effective_max_segment_ms"] = resolve_effective_max_segment_ms(
            candidate["asr_policy"],
            service_max_segment_ms=(self._settings.max_realtime_buffer_bytes or 8_388_608) // 64,
            capability_max_segment_ms=None,
            decoder_max_segment_ms=30_000,
        )

        expected_asr_revision = candidate.get("expected_asr_revision")
        if isinstance(expected_asr_revision, str):
            asr_artifact = self._active_model_catalog.asr
            if asr_artifact is None or asr_artifact.revision != expected_asr_revision:
                raise RealtimeAdapterError(
                    "model_revision_conflict",
                    "Requested ASR revision is not the active ASR artifact",
                )
        endpointing = self._asr_owner.prepare_endpointing(candidate)
        await self._auxiliary_owner.configure(
            alignment=requested_alignment,
            diarization=requested_diarization,
            backend=requested_backend,
        )
        self._asr_owner.apply_endpointing(endpointing)
        await self._asr_owner.configure_window(candidate)
        self._protocol_config.replace(candidate)
        await self._send(session_updated(session_id=self._session_id, **self._session_fields()))
