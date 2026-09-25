"""Application orchestration for the OpenAI Realtime ASR/TTS boundary."""

from __future__ import annotations

import asyncio
import base64
import contextlib
import logging
import re
import time
from collections import deque
from collections.abc import Awaitable, Callable
from contextlib import AsyncExitStack
from typing import Any
from uuid import uuid4

from starlette.websockets import WebSocketDisconnect

from speechrail.application.diarization import (
    DiarizationSession,
    ItemAttributionUpdated,
    SessionDone,
    StatusChanged,
)
from speechrail.application.services import AppServices
from speechrail.application.tts_stream import (
    StreamController,
    TtsStreamAdmissionError,
    TtsStreamReceipt,
)
from speechrail.application.tts_stream_capability import (
    TtsStreamCapability,
    resolve_tts_stream_capability,
)
from speechrail.backends.qwen3_voice_binding import resolve_binding
from speechrail.compatibility.openai_realtime import (
    ASR_KERNEL_SAMPLE_RATE,
    WIRE_SAMPLE_RATE,
    RealtimeAdapterError,
    alignment_done,
    alignment_failed,
    diarization_done_event,
    diarization_failed,
    diarization_updated,
    parse_client_event,
    parse_finish_request,
    parse_tts_append_text,
    parse_tts_cancel,
    parse_tts_finish_text,
    parse_tts_start,
    plan_fingerprint,
    session_created,
    transcription_completed,
    transcription_delta,
    transcription_failed,
    transcription_hypothesis,
    tts_audio_delta,
    tts_cancelled,
    tts_completed,
    tts_failed,
    tts_output_format,
    tts_stream_started,
    tts_text_accepted,
    validate_append,
)
from speechrail.config.model_catalog import ModelArtifact
from speechrail.config.selection import active_model_catalog
from speechrail.domain.alignment import AlignmentGranularity, AlignmentRequest
from speechrail.domain.audio_timeline import (
    RateMap,
    RationalResampler,
    SampleClock,
    SampleSpan,
)
from speechrail.domain.diarization import (
    Attribution,
    DiarizationError,
    TextUnit,
)
from speechrail.domain.diarization.attribution import AttributionLedger
from speechrail.domain.diarization.timeline import AttributionUnit
from speechrail.domain.itn import apply_light_itn
from speechrail.domain.ports import (
    RealtimeAsrSession,
    RealtimeTranscriptionOptions,
)
from speechrail.domain.tts import (
    DEFAULT_VOICE_ID,
    VoiceProfile,
    VoiceStoreUnavailableError,
    resolve_voice,
)
from speechrail.domain.tts_stream import (
    TtsStreamError,
    TtsStreamEvent,
    TtsStreamEventKind,
    TtsStreamLimits,
    TtsStreamOptions,
    TtsStreamTerminal,
)
from speechrail.realtime.speech_admission import AdmissionDecision, SpeechAdmission
from speechrail.runtime.alignment_admission import AlignmentAdmissionFullError
from speechrail.runtime.busy import BusyReason, infer_backend_busy_reason
from speechrail.runtime.diarization_admission import DiarizationAdmissionFullError
from speechrail.runtime.limits import MAX_ALIGNMENT_PCM_BYTES
from speechrail.runtime.pcm_buffer import BoundedPcmBuffer, PcmBufferOverflowError
from speechrail.runtime.resource_governor import (
    GovernorQueueFullError,
    WorkClass,
    WorkPurpose,
)

SendEvent = Callable[[dict[str, object]], Awaitable[int | None]]

_MAX_UPDATES_PER_EVENT = 256
_MAX_TTS_REQUEST_IDS = 256
_MODEL_REVISION_RE = re.compile(r"^[0-9a-f]{40}$")


def _str_list(value: object) -> list[str] | None:
    """Return a wire-safe string list, or None when the option is unset."""

    if isinstance(value, (list, tuple)) and all(isinstance(item, str) for item in value):
        return list(value)
    return None


# Each append awaiting the model's acceptance keeps its bounded packet so the
# transcript can be echoed after - never before - that acceptance.
_MAX_PENDING_STREAM_APPENDS = 128

logger = logging.getLogger(__name__)


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
        self._active_model_catalog = active
        self._tts_artifact = active.tts
        self._tts_clone_artifact = active.tts_clone
        self._tts_variant = active.tts.variant if active.tts is not None else None
        self._tts_clone_variant = (
            active.tts_clone.variant if active.tts_clone is not None else None
        )
        self._registered_asr = frozenset(
            {self._settings.model_id, *self._settings.compatibility_model_ids}
        )
        self._asr: RealtimeAsrSession | None = None
        self._asr_reader: asyncio.Task[None] | None = None
        self._asr_resources: AsyncExitStack | None = None
        self._commit_lock = asyncio.Lock()
        self._commit_owner: str | None = None
        self._input_generation = 0
        self._committed_input_generation = -1
        # Set only while the current ASR item is being committed.  The reader
        # uses this monotonic anchor to record commit-tail latency without
        # putting a session/request identifier into metrics labels.
        self._asr_commit_started_at: float | None = None
        # First-hypothesis observability keeps distinct origins separate.  The
        # App remains responsible for the true "visible on screen" timestamp.
        self._first_upstream_received_at: float | None = None
        self._admitted_started_at: float | None = None
        self._latest_append_received_at: float | None = None
        self._first_partial_received_at: float | None = None
        self._first_hypothesis_recorded = False
        self._hypothesis_revision = 0
        self._stable_prefix_codepoints = 0
        self._last_hypothesis_text = ""
        self._task_id = f"task_{uuid4().hex[:12]}"
        self._wire_epoch = 0
        self._current_transcript_revision = 0
        self._metadata_revision = 0
        self._tts_task: asyncio.Task[None] | None = None
        # Request ids are connection-scoped idempotency keys. Keep a bounded,
        # non-evicting ledger: evicting an old id would make a duplicate valid
        # again later on the same connection.
        self._tts_request_ids: set[str] = set()
        self._tts_terminal_lock = asyncio.Lock()
        self._tts_terminal_sent = False
        self._tts_request_id: str | None = None
        self._tts_response_id: str | None = None
        self._tts_item_id: str | None = None
        self._tts_text: str | None = None
        self._tts_voice_revision: str | None = None
        self._tts_receipt_id: str | None = None
        # Incremental utterance state. ``_tts_stream`` only becomes non-None
        # after the vendor session is open, so appends that arrive during
        # admission wait on ``_tts_stream_ready`` instead of failing.
        self._tts_stream: StreamController | None = None
        self._tts_stream_ready: asyncio.Event | None = None
        self._tts_stream_mode = False
        self._tts_stream_pending: dict[int, str] = {}
        self._tts_stream_accepted = 0
        self._tts_stream_limits: TtsStreamLimits | None = None
        self._tts_generated_samples = 0
        self._tts_failure_code: str | None = None
        self._closing = False
        self._diarization: DiarizationSession | None = None
        self._diarization_events: asyncio.Task[None] | None = None
        self._diarization_resources: AsyncExitStack | None = None
        self._diarization_epoch: str | None = None
        # Fixed-text alignment owns only the current ASR item's normalized PCM.
        # It is a short-term pin: bounded, released on commit/failure/cancel, and
        # never written to disk, independently of generic WebSocket buffering.
        self._alignment_pcm = BoundedPcmBuffer(MAX_ALIGNMENT_PCM_BYTES)
        self._alignment_overflow = False
        self._alignment_tasks: set[asyncio.Task[None]] = set()
        self._buffered_audio_bytes = 0
        self._unflushed_bytes = 0
        self._last_partial_text = ""
        self._alignment_pcm.clear()
        self._alignment_overflow = False
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
        # The caller's 24 kHz wire clock is the public sample axis.  The ASR,
        # VAD and alignment kernels run at 16 kHz behind one continuous
        # rational resampler; both clocks are integer and never drift.
        self._wire_timeline = SampleClock(WIRE_SAMPLE_RATE)
        self._kernel_timeline = SampleClock(ASR_KERNEL_SAMPLE_RATE)
        self._resampler = RationalResampler(
            WIRE_SAMPLE_RATE, ASR_KERNEL_SAMPLE_RATE
        )
        self._wire_to_kernel = RateMap(
            WIRE_SAMPLE_RATE, ASR_KERNEL_SAMPLE_RATE
        )
        self._kernel_to_wire = RateMap(
            ASR_KERNEL_SAMPLE_RATE, WIRE_SAMPLE_RATE
        )
        self._item_start_sample = 0
        self._item_end_sample = 0
        self._item_start_kernel = 0
        self._item_end_kernel = 0
        self._diarization_enabled = False
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
        self._units_by_id: dict[str, AttributionUnit] = {}
        self._speaker_by_unit: dict[str, str | None] = {}
        self._current_item_id = self._new_item_id()
        self._config: dict[str, Any] = {
            "model": self._initial_model,
            "language": None,
            "prompt": "",
            "expected_model_revision": None,
            "tts_enabled": False,
            "task": "conversation",
            "transcription_partial_mode": "delta",
            "transcription_chunk_duration_ms": (
                self._settings.qwen3_streaming_chunk_duration_ms
            ),
        }
        # Stable plan identity echoed on every ``speechrail.tts.*`` event. It is
        # derived from the effective task/models/voice so a caller can tie one
        # utterance to the exact plan it was admitted under.
        self._plan_id = plan_fingerprint(
            task=str(self._config.get("task") or "conversation"),
            asr_model=self._initial_model,
            voice=DEFAULT_VOICE_ID,
            voice_revision=None,
            catalog_revision=(
                self._tts_artifact.revision if self._tts_artifact is not None else None
            ),
        )

    @staticmethod
    def _new_item_id() -> str:
        """Return an opaque id for exactly one input-audio transcription turn."""
        return f"item_{uuid4().hex[:12]}"

    @staticmethod
    def _common_prefix_codepoints(left: str, right: str) -> int:
        """Return a conservative stable-prefix count in Python codepoint units."""

        count = 0
        for left_char, right_char in zip(left, right, strict=False):
            if left_char != right_char:
                break
            count += 1
        return count

    def _transcription_chunk_seconds(self) -> float:
        """Return the effective per-session ASR flush duration."""
        return int(
            self._config.get(
                "transcription_chunk_duration_ms",
                self._settings.qwen3_streaming_chunk_duration_ms,
            )
        ) / 1_000

    def _alignment_granularity(self) -> AlignmentGranularity:
        """Return the requested alignment granularity, defaulting to segments.

        The wire field is a list; the finest requested granularity wins, and an
        empty or unknown request degrades to segment-level units.
        """

        declared = self._config.get("alignment_granularity")
        if declared in {"character", "word", "segment"}:
            return declared  # type: ignore[return-value]
        requested = self._config.get("timestamp_granularities")
        if isinstance(requested, (list, tuple)) and "character" in requested:
            return "character"
        if isinstance(requested, (list, tuple)) and "word" in requested:
            return "word"
        return "segment"

    def _to_wire_sample(self, kernel_sample: int) -> int:
        return self._kernel_to_wire.to_source(kernel_sample)

    def _to_kernel_sample(self, wire_sample: int) -> int:
        return self._wire_to_kernel.to_target(wire_sample)

    def _to_wire_span(self, kernel_span: SampleSpan) -> SampleSpan:
        return SampleSpan(
            self._to_wire_sample(kernel_span.start),
            self._to_wire_sample(kernel_span.end),
        )

    def _mark_upstream_received(self, received_at: float) -> None:
        """Anchor the first upstream PCM packet for this input item."""

        self._latest_append_received_at = received_at
        if self._first_upstream_received_at is None:
            self._first_upstream_received_at = received_at

    def _mark_admitted_started(self, start_sample: int) -> None:
        """Anchor the first admitted speech sample without zero-filling unknowns."""

        if self._admitted_started_at is not None:
            return
        received_at = self._latest_append_received_at
        if received_at is None:
            received_at = time.monotonic()
        lag_seconds = max(
            0.0, (self._item_end_sample - start_sample) / WIRE_SAMPLE_RATE
        )
        self._admitted_started_at = max(0.0, received_at - lag_seconds)

    def _reset_turn_observability(self) -> None:
        self._first_upstream_received_at = None
        self._admitted_started_at = None
        self._latest_append_received_at = None
        self._first_partial_received_at = None
        self._first_hypothesis_recorded = False
        self._hypothesis_revision = 0
        self._stable_prefix_codepoints = 0
        self._last_hypothesis_text = ""
        self._current_transcript_revision = 0

    def _record_first_hypothesis(self, outcome: str) -> None:
        """Record one terminal first-hypothesis observation per input item."""

        if self._first_hypothesis_recorded:
            return
        self._first_hypothesis_recorded = True
        worker_received_at = self._first_partial_received_at
        now = time.monotonic()
        admitted_to_worker = (
            max(0.0, worker_received_at - self._admitted_started_at)
            if worker_received_at is not None and self._admitted_started_at is not None
            else None
        )
        upstream_to_worker = (
            max(0.0, worker_received_at - self._first_upstream_received_at)
            if worker_received_at is not None and self._first_upstream_received_at is not None
            else None
        )
        worker_to_socket = (
            max(0.0, now - worker_received_at) if worker_received_at is not None else None
        )
        admitted_to_socket = (
            max(0.0, now - self._admitted_started_at)
            if self._admitted_started_at is not None
            else None
        )
        admitted_audio_seconds = (
            max(
                0.0,
                (self._item_end_sample - self._item_start_sample)
                / WIRE_SAMPLE_RATE,
            )
            if outcome == "partial"
            else None
        )
        self._services.metrics.record_realtime_first_hypothesis(
            outcome,
            admitted_to_worker_seconds=admitted_to_worker,
            upstream_to_worker_seconds=upstream_to_worker,
            worker_to_socket_seconds=worker_to_socket,
            admitted_to_socket_seconds=admitted_to_socket,
            admitted_audio_seconds=admitted_audio_seconds,
        )

    async def _cancel_alignment_tasks(self) -> None:
        """Cancel auxiliary work before releasing the session's model owner."""

        tasks = tuple(self._alignment_tasks)
        for task in tasks:
            if not task.done():
                task.cancel()
        for task in tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await task
        self._alignment_tasks.clear()

    async def start(self) -> None:
        await self._send(
            session_created(session_id=self._session_id, **self._session_fields())
        )

    async def handle(self, event: dict[str, Any]) -> None:
        parsed = parse_client_event(event)
        if parsed.kind == "session_update":
            await self._update_session(event)
        elif parsed.kind == "append":
            await self._append_audio(event)
        elif parsed.kind == "commit":
            await self._commit_audio()
        elif parsed.kind == "diarization_finish":
            await self._handle_finish(event)
        elif parsed.kind == "clear":
            await self._clear_audio()
        elif parsed.kind == "tts_start":
            await self._start_tts_stream(event)
        elif parsed.kind == "tts_append_text":
            await self._append_tts_stream(event)
        elif parsed.kind == "tts_finish_text":
            await self._finish_tts_stream(event)
        elif parsed.kind == "tts_cancel":
            await self._cancel_response(event)
        else:
            raise RealtimeAdapterError(
                "unsupported_operation", "unsupported SpeechRail event"
            )

    async def close(self) -> None:
        self._closing = True
        if self._first_upstream_received_at is not None:
            self._record_first_hypothesis("cancelled")
        await self._cancel_alignment_tasks()
        await self._close_tts_stream()
        await self._stop_asr_reader()
        await self._close_asr_session()
        await self._release_asr()
        await self._close_diarization()
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
        self._reset_turn_observability()

    def _session_fields(self) -> dict[str, object]:
        """Render the effective current session object for create/update."""

        endpointing = self._config.get("turn_detection")
        expected_asr = self._config.get("expected_asr_revision")
        expected_tts = self._config.get("expected_model_revision")
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
            "timestamp_granularities": _str_list(
                self._config.get("timestamp_granularities")
            ),
            "turn_detection": "manual" if endpointing == "manual" else None,
            "task": str(self._config.get("task") or "conversation"),
            "tts_enabled": bool(self._config.get("tts_enabled", False)),
            "alignment_enabled": bool(self._config.get("alignment_enabled", False)),
            "diarization_enabled": bool(self._diarization_enabled),
            "endpointing": endpointing if isinstance(endpointing, dict) else None,
            "expected_asr_revision": (
                expected_asr if isinstance(expected_asr, str) else None
            ),
            "expected_tts_revision": (
                expected_tts if isinstance(expected_tts, str) else None
            ),
        }

    async def _update_session(self, event: dict[str, Any]) -> None:
        from speechrail.compatibility.openai_realtime import apply_session_update

        updated, candidate = apply_session_update(
            event,
            session_id=self._session_id,
            asr_model=self._settings.model_id,
            registered_asr=self._registered_asr,
            current_config=self._config,
        )
        # The caller opts in to stateless incremental TTS; SpeechRail never
        # infers an assistant mode.
        if candidate.get("tts_explicit"):
            requested_tts_enabled = bool(candidate.get("tts_enabled", False))
            if requested_tts_enabled and not self._services.tts_ready:
                raise RealtimeAdapterError("backend_not_ready", "TTS backend is not ready")
            if (
                not requested_tts_enabled
                and self._tts_task is not None
                and not self._tts_task.done()
            ):
                raise RealtimeAdapterError(
                    "invalid_state", "cannot disable TTS while a response is active"
                )
            candidate["tts_enabled"] = requested_tts_enabled
        else:
            candidate["tts_enabled"] = bool(self._config.get("tts_enabled", False))
        if self._wire_timeline.accepted_samples > 0:
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

        previous_enabled = self._diarization_enabled
        if candidate.get("diarization_explicit"):
            requested_enabled = bool(candidate.get("diarization_enabled", False))
            if requested_enabled != self._diarization_enabled:
                if self._wire_timeline.accepted_samples > 0:
                    raise RealtimeAdapterError(
                        "invalid_state",
                        "diarization can only be enabled before the first audio",
                    )
                if requested_enabled and (
                    not self._services.diarization_ready
                    or self._diarization_engine is None
                    or not bool(getattr(self._diarization_engine, "supports_stream", False))
                    or self._services.text_aligner is None
                ):
                    raise RealtimeAdapterError(
                        "diarization_not_available",
                        str(self._services.diarization_status["message"]),
                    )
                self._diarization_enabled = requested_enabled

        configured_voice = candidate.get("voice")
        if isinstance(configured_voice, str):
            self._require_voice_available(configured_voice)
        expected_model_revision = candidate.get("expected_model_revision")
        if expected_model_revision is not None:
            artifact = self._tts_artifact_for_voice(
                configured_voice if isinstance(configured_voice, str) else DEFAULT_VOICE_ID
            )
            if artifact is None or artifact.revision != expected_model_revision:
                raise RealtimeAdapterError(
                    "model_revision_conflict",
                    "Requested model revision is not the active TTS artifact",
                )
        expected_asr_revision = candidate.get("expected_asr_revision")
        if isinstance(expected_asr_revision, str):
            asr_artifact = self._active_model_catalog.asr
            if asr_artifact is None or asr_artifact.revision != expected_asr_revision:
                raise RealtimeAdapterError(
                    "model_revision_conflict",
                    "Requested ASR revision is not the active ASR artifact",
                )
        if self._diarization_enabled:
            try:
                await self._ensure_diarization()
            except BaseException:
                self._diarization_enabled = False
                await self._close_diarization()
                self._diarization_enabled = previous_enabled
                raise
        else:
            await self._close_diarization()

        turn_detection = candidate.get("turn_detection")
        if isinstance(turn_detection, dict) and turn_detection.get("mode") == "server_vad":
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
                self._vad_sample_cursor = self._kernel_timeline.accepted_samples
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

        self._config = candidate
        await self._send(updated)

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
                options=RealtimeTranscriptionOptions(
                    partial_mode=self._config.get("transcription_partial_mode", "delta"),
                    chunk_duration_ms=int(
                        self._config.get(
                            "transcription_chunk_duration_ms",
                            self._settings.qwen3_streaming_chunk_duration_ms,
                        )
                    ),
                ),
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
            if message.startswith("language_not_supported"):
                raise RealtimeAdapterError("language_not_supported", message) from exc
            busy_reason = str(infer_backend_busy_reason(exc))
            raise RealtimeAdapterError(
                "backend_busy",
                message,
                busy_reason=busy_reason,
            ) from exc
        self._asr = asr
        self._alignment_pcm.clear()
        self._alignment_overflow = False
        self._asr_reader = asyncio.create_task(self._drain_asr_events())

    async def _append_asr_audio(self, audio: bytes) -> None:
        """Feed ASR and retain exactly this item's bounded alignment PCM."""

        assert self._asr is not None
        await self._asr.append_audio(audio)
        if not self._diarization_enabled:
            return
        try:
            self._alignment_pcm.append(audio)
        except PcmBufferOverflowError:
            # Surface the overflow explicitly instead of retaining a partial span:
            # the committed item is marked so alignment fails with a reason.
            if not self._alignment_overflow:
                self._services.metrics.record_alignment_event("fixed_text_overflow")
            self._alignment_overflow = True

    async def _handle_admission_decision(
        self, dec: AdmissionDecision, *, in_commit: bool = False
    ) -> None:
        if dec.kind == "start":
            self._turn_generation += 1
            self._turn_has_admitted_speech = True
            self._admitted_start_sample = dec.start_sample
            self._admitted_end_sample = dec.end_sample
            self._item_start_kernel = dec.start_sample
            self._item_end_kernel = dec.end_sample
            self._item_start_sample = self._to_wire_sample(dec.start_sample)
            self._item_end_sample = self._to_wire_sample(dec.end_sample)
            self._mark_admitted_started(self._item_start_sample)
            self._buffered_audio_bytes = 0
            self._unflushed_bytes = 0

            self._services.metrics.record_vad("started")
            await self._ensure_asr_for_turn()

        elif dec.kind == "audio":
            if not self._turn_has_admitted_speech or self._asr is None:
                await self._ensure_asr_for_turn()
                self._turn_has_admitted_speech = True
                self._admitted_start_sample = dec.start_sample
                self._item_start_kernel = dec.start_sample
                self._item_start_sample = self._to_wire_sample(dec.start_sample)
                self._mark_admitted_started(self._item_start_sample)

            max_item_bytes = (
                256_000
                if self._diarization_enabled
                else (self._settings.max_realtime_buffer_bytes or 8_388_608)
            )
            if self._buffered_audio_bytes > 0 and (
                self._buffered_audio_bytes + len(dec.pcm) > max_item_bytes
            ):
                await self._commit_audio(reason="rollover")
                self._input_generation += 1
                self._turn_generation += 1
                self._turn_has_admitted_speech = True
                self._admitted_start_sample = dec.start_sample
                self._item_start_kernel = dec.start_sample
                self._item_start_sample = self._to_wire_sample(dec.start_sample)
                self._buffered_audio_bytes = 0
                self._unflushed_bytes = 0
                await self._ensure_asr_for_turn()

            if self._asr is not None:
                await self._append_asr_audio(dec.pcm)
                self._admitted_end_sample = dec.end_sample
                self._item_end_kernel = dec.end_sample
                self._item_end_sample = self._to_wire_sample(dec.end_sample)
                self._buffered_audio_bytes += len(dec.pcm)
                self._unflushed_bytes += len(dec.pcm)

                chunk_sec = self._transcription_chunk_seconds()
                flush_threshold = max(1, int(chunk_sec * 32_000))
                if self._unflushed_bytes >= flush_threshold:
                    self._unflushed_bytes = 0
                    flush_started = time.monotonic()
                    with contextlib.suppress(Exception):
                        await self._asr.flush()
                    self._services.metrics.record_realtime_phase(
                        "asr_flush", time.monotonic() - flush_started
                    )

        elif dec.kind == "end":
            self._services.metrics.record_vad("ended")
            self._admitted_end_sample = dec.end_sample
            self._item_end_kernel = dec.end_sample
            self._item_end_sample = self._to_wire_sample(dec.end_sample)
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
        self._mark_upstream_received(time.monotonic())
        self._input_generation += 1
        max_buf = self._settings.max_realtime_buffer_bytes
        if max_buf is not None and len(audio) > max_buf:
            raise RealtimeAdapterError(
                "buffer_too_large", "audio buffer exceeds the configured limit"
            )

        if self._asr_factory is None:
            raise RealtimeAdapterError("backend_not_ready", "streaming ASR backend is not ready")

        await self._ensure_diarization()
        wire_span = self._wire_timeline.accept(audio)
        kernel_audio = self._resampler.process(audio)
        kernel_span = self._kernel_timeline.accept(kernel_audio)
        self._item_end_sample = wire_span.end
        self._item_end_kernel = kernel_span.end
        if kernel_audio and self._diarization is not None:
            await self._diarization.append(kernel_audio)
        if not kernel_audio:
            if self._asr is None:
                self._item_start_kernel = kernel_span.start
                self._item_start_sample = self._to_wire_sample(kernel_span.start)
            return

        # 1. SpeechAdmission path (server_vad with admission enabled)
        if self._speech_admission is not None and self._vad is not None:
            self._vad_raw_buffer.extend(kernel_audio)
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
            vad_events = self._vad.process_chunk(kernel_audio)
            for v_event in vad_events:
                if v_event.speech_started:
                    self._services.metrics.record_vad("started")
                    kernel_start = int(float(v_event.audio_start_ms) * 16)
                    self._item_start_kernel = kernel_start
                    self._item_start_sample = self._to_wire_sample(kernel_start)
                    self._mark_admitted_started(self._item_start_sample)
                elif v_event.speech_ended:
                    self._services.metrics.record_vad("ended")
                    self._item_end_kernel = self._kernel_timeline.accepted_samples
                    self._item_end_sample = self._to_wire_sample(
                        self._item_end_kernel
                    )
                    if self._asr is not None:
                        await self._append_asr_audio(kernel_audio)
                        self._buffered_audio_bytes += len(kernel_audio)
                        self._unflushed_bytes += len(kernel_audio)
                        await self._commit_audio()
                        return

            # If not yet in speech (debouncing or pure silence), defer ASR
            # acquisition. Keep only the most recent prefix window so long
            # silence cannot grow the buffer or reach ASR at speech onset.
            if not self._vad.in_speech:
                if kernel_audio:
                    self._bargein_pending_audio.append(kernel_audio)
                    self._bargein_pending_bytes += len(kernel_audio)
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
            and self._buffered_audio_bytes + len(kernel_audio) > max_buf
            and self._asr is not None
        ):
            # Auto-commit rollover for long streaming sessions
            await self._commit_audio()
            self._input_generation += 1

        if self._asr is None:
            await self._ensure_asr_for_turn()
            self._item_start_kernel = kernel_span.start
            self._item_start_sample = self._to_wire_sample(kernel_span.start)
            # The manual/legacy path has no VAD gate: any appended audio belongs
            # to this turn.  Marking it admitted keeps the resampler tail on
            # commit flowing to both ASR and the bounded alignment buffer so the
            # alignment span and retained PCM stay exactly equal.
            self._turn_has_admitted_speech = True
            self._mark_admitted_started(self._item_start_sample)
            if self._bargein_pending_audio and self._asr is not None:
                for pending_chunk in self._bargein_pending_audio:
                    await self._append_asr_audio(pending_chunk)
                    self._buffered_audio_bytes += len(pending_chunk)
                    self._unflushed_bytes += len(pending_chunk)
                self._bargein_pending_audio.clear()
                self._bargein_pending_bytes = 0

        if self._asr is not None:
            await self._append_asr_audio(kernel_audio)
            self._buffered_audio_bytes += len(kernel_audio)
            self._unflushed_bytes += len(kernel_audio)

            chunk_sec = self._transcription_chunk_seconds()
            flush_threshold = max(1, int(chunk_sec * 32_000))
            if self._unflushed_bytes >= flush_threshold:
                self._unflushed_bytes = 0
                flush_started = time.monotonic()
                with contextlib.suppress(Exception):
                    await self._asr.flush()
                self._services.metrics.record_realtime_phase(
                    "asr_flush", time.monotonic() - flush_started
                )

    async def _commit_audio(self, reason: str = "client") -> None:
        """Run at most one commit owner for the current input item."""

        async with self._commit_lock:
            item_id = self._current_item_id
            if (
                self._commit_owner == item_id
                or self._committed_input_generation == self._input_generation
            ):
                return
            self._commit_owner = item_id
            self._committed_input_generation = self._input_generation
            await self._commit_audio_once(reason)

    async def _commit_audio_once(self, reason: str) -> None:
        tail = self._resampler.flush()
        if tail:
            kernel_span = self._kernel_timeline.accept(tail)
            self._item_end_kernel = kernel_span.end
            if self._diarization is not None:
                await self._diarization.append(tail)
            if self._asr is not None and self._turn_has_admitted_speech:
                await self._append_asr_audio(tail)
                self._buffered_audio_bytes += len(tail)
                self._unflushed_bytes += len(tail)

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
            self._record_first_hypothesis("missing")
            self._reset_turn_observability()
            self._current_item_id = self._new_item_id()
            return

        if self._asr is None:
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
            self._record_first_hypothesis("missing")
            self._reset_turn_observability()
            self._current_item_id = self._new_item_id()
            return

        try:
            # The worker's own protocol timeout cannot bound a reader that has
            # already received the commit acknowledgement but never reaches its
            # terminal event.  Keep commit, final event delivery and teardown
            # under one request deadline so its governor lane is recoverable.
            async with asyncio.timeout(self._settings.request_timeout_seconds):
                commit_started = time.monotonic()
                self._asr_commit_started_at = commit_started
                timestamp_granularities = self._config.get("timestamp_granularities")
                want_segments = isinstance(timestamp_granularities, list) and (
                    "segment" in timestamp_granularities
                )
                await self._asr.commit(want_segments=want_segments)
                self._services.metrics.record_realtime_phase(
                    "asr_commit_ack", time.monotonic() - commit_started
                )
                if self._asr_reader is not None:
                    terminal_started = time.monotonic()
                    await self._asr_reader
                    self._services.metrics.record_realtime_phase(
                        "asr_terminal_wait", time.monotonic() - terminal_started
                    )
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
            self._asr_commit_started_at = None
            self._turn_has_admitted_speech = False
        await self._close_asr_session()
        await self._release_asr()
        self._buffered_audio_bytes = 0
        self._last_partial_text = ""
        self._unflushed_bytes = 0
        self._record_first_hypothesis("missing")
        self._reset_turn_observability()
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
        self._item_start_sample = self._wire_timeline.accepted_samples
        self._item_end_sample = self._wire_timeline.accepted_samples
        self._item_start_kernel = self._kernel_timeline.accepted_samples
        self._item_end_kernel = self._kernel_timeline.accepted_samples
        self._record_first_hypothesis("failed")
        self._reset_turn_observability()
        self._committed_input_generation = self._input_generation
        self._current_item_id = self._new_item_id()

    async def _clear_audio(self) -> None:
        if self._first_upstream_received_at is not None:
            self._record_first_hypothesis("cancelled")
        self._turn_generation += 1
        self._input_generation += 1
        self._turn_has_admitted_speech = False
        if self._speech_admission is not None:
            self._speech_admission.reset(
                next_sample=self._kernel_timeline.accepted_samples
            )
        self._vad_raw_buffer.clear()
        self._vad_sample_cursor = self._kernel_timeline.accepted_samples
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
        self._item_start_sample = self._wire_timeline.accepted_samples
        self._item_end_sample = self._wire_timeline.accepted_samples
        self._item_start_kernel = self._kernel_timeline.accepted_samples
        self._item_end_kernel = self._kernel_timeline.accepted_samples
        self._units_by_id.clear()
        self._speaker_by_unit.clear()
        self._reset_turn_observability()
        self._current_item_id = self._new_item_id()

    @staticmethod
    def _stream_request_id_fallback(response_id: str) -> str:
        return response_id

    def _claim_tts_request(self, request_id: str) -> None:
        """Apply the shared activity/ledger gate for the TTS stream entry point.

        ``speechrail.tts.start`` owns a per-connection request id, so the guard
        rejects in a fixed order: an utterance that is still live is
        ``tts_in_progress``, and only an idle connection reports the
        duplicate/full ledger as ``tts_request_invalid``.
        """

        if self._tts_task is not None and not self._tts_task.done():
            raise RealtimeAdapterError(
                "tts_in_progress", "a TTS response is already in progress"
            )
        if request_id in self._tts_request_ids:
            raise RealtimeAdapterError(
                "tts_request_invalid",
                "request_id must be unique within this WebSocket connection",
            )
        if len(self._tts_request_ids) >= _MAX_TTS_REQUEST_IDS:
            raise RealtimeAdapterError(
                "tts_request_invalid",
                "TTS request id ledger is full; start a new WebSocket connection",
            )

    def _resolve_voice_profile(self, selected_voice: str) -> VoiceProfile:
        from speechrail.domain.tts import get_voice_profile

        try:
            return get_voice_profile(selected_voice)
        except VoiceStoreUnavailableError:
            raise RealtimeAdapterError(
                "voice_store_unavailable", "custom voice storage is unavailable"
            ) from None
        except ValueError:
            raise RealtimeAdapterError(
                "voice_not_found", f"unknown voice: {selected_voice[:200]}"
            ) from None

    def _expected_model_revision(self) -> str | None:
        value = self._config.get("expected_model_revision")
        return value if isinstance(value, str) else None

    def _tts_artifact_for_mode(self, voice_mode: str) -> ModelArtifact | None:
        return self._active_model_catalog.artifact_for_voice_mode(voice_mode)

    def _tts_artifact_for_voice(self, voice: str) -> ModelArtifact | None:
        from speechrail.domain.tts import get_voice_profile

        try:
            profile = get_voice_profile(voice)
        except (ValueError, VoiceStoreUnavailableError):
            return None
        return self._tts_artifact_for_mode(profile.mode)

    def _require_voice_available(self, voice: str) -> None:
        from speechrail.domain.tts import get_voice_profile

        # Injected/test synthesizers may not have an active catalog-backed TTS
        # variant. Preserve the historical contract in that case: endpoint
        # readiness is authoritative and model-specific binding is not enforced.
        if self._tts_variant is None and self._tts_clone_variant is None:
            return

        try:
            profile = get_voice_profile(voice)
        except VoiceStoreUnavailableError:
            raise RealtimeAdapterError(
                "voice_store_unavailable", "custom voice storage is unavailable"
            ) from None
        except ValueError:
            raise RealtimeAdapterError(
                "voice_not_found", f"unknown voice: {voice[:200]}"
            ) from None

        if profile.revoked:
            raise RealtimeAdapterError(
                "voice_revoked",
                f"voice {voice[:200]} is revoked",
            )
        role = profile.runtime_role
        if role is None:
            raise RealtimeAdapterError(
                "voice_not_available",
                f"voice {voice[:200]} is unavailable for the active TTS capabilities",
            )
        try:
            resolve_binding(role, voice)
        except VoiceStoreUnavailableError:
            raise RealtimeAdapterError(
                "voice_store_unavailable", "custom voice storage is unavailable"
            ) from None
        except ValueError:
            raise RealtimeAdapterError(
                "voice_not_available",
                (
                    f"voice {voice[:200]} is unavailable for the active TTS weights; "
                    "use one of the available system voices from /v1/voices"
                ),
            ) from None

    # ------------------------------------------------------------------
    # Incremental TTS: start / append_text / finish_text
    #
    # The incremental path owns its terminal through ``StreamController``: this
    # class only translates the controller's events onto the wire, so a
    # complete/cancel/failure race still produces exactly one
    # ``speechrail.tts.completed`` / ``cancelled`` / ``failed`` terminal.
    # ------------------------------------------------------------------

    def _stream_capability(self, voice: str, mode: str) -> TtsStreamCapability:
        return resolve_tts_stream_capability(
            voice_id=voice,
            voice_mode=mode,
            artifact=self._tts_artifact_for_mode(mode),
            tts_ready=self._services.tts_ready,
            voice_enabled=True,
            synthesizer=self._tts,
            stream_service=self._services.tts_streams,
        )

    async def _start_tts_stream(self, event: dict[str, Any]) -> None:
        """Validate and schedule one incremental utterance without blocking on it."""

        request = parse_tts_start(event)
        if not bool(self._config.get("tts_enabled", False)):
            raise RealtimeAdapterError(
                "tts_not_enabled",
                "caller TTS must be enabled in the transcription session",
            )
        if self._services.tts_streams is None:
            raise RealtimeAdapterError(
                "tts_streaming_unsupported",
                "this service exposes no incremental TTS stream",
            )
        if not self._services.tts_ready or self._tts is None:
            raise RealtimeAdapterError("backend_not_ready", "TTS backend is not ready")
        self._claim_tts_request(request.request_id)

        selected_voice = resolve_voice(
            request.voice or str(self._config.get("voice") or DEFAULT_VOICE_ID)
        )
        selected_profile = self._resolve_voice_profile(selected_voice)
        if selected_profile.revoked:
            raise RealtimeAdapterError(
                "voice_revoked", f"voice {selected_voice[:200]} is revoked"
            )
        self._require_voice_available(selected_voice)
        if (
            request.expected_voice_revision is not None
            and request.expected_voice_revision != selected_profile.revision
        ):
            raise RealtimeAdapterError(
                "voice_revision_conflict", "Requested voice revision is not active"
            )
        expected_model_revision = (
            request.expected_model_revision or self._expected_model_revision()
        )
        artifact = self._tts_artifact_for_mode(selected_profile.mode)
        if expected_model_revision is not None and (
            artifact is None or artifact.revision != expected_model_revision
        ):
            raise RealtimeAdapterError(
                "model_revision_conflict",
                "Requested model revision is not the active TTS artifact",
            )
        capability = self._stream_capability(selected_voice, selected_profile.mode)
        if not capability.supported:
            detail = capability.reason or "unsupported"
            hint = f"; {capability.hint}" if capability.hint else ""
            raise RealtimeAdapterError(
                "tts_streaming_unsupported",
                f"voice {selected_voice[:200]} has no incremental TTS path: {detail}{hint}",
            )

        response_id = f"resp_{uuid4().hex[:12]}"
        item_id = f"item_{uuid4().hex[:12]}"
        options = TtsStreamOptions(
            request_id=request.request_id,
            response_id=response_id,
            voice=selected_voice,
            language=str(self._config.get("language") or "auto"),
            speed=request.speed,
            expected_voice_revision=selected_profile.revision,
            expected_model_revision=expected_model_revision,
        )
        receipt = TtsStreamReceipt(
            voice_revision=selected_profile.revision,
            model_artifact=artifact.key if artifact is not None else None,
            model_source=artifact.model_id if artifact is not None else None,
            model_variant=artifact.variant if artifact is not None else None,
            model_catalog_revision=artifact.revision if artifact is not None else None,
        )
        self._tts_request_id = request.request_id
        self._tts_response_id = response_id
        self._tts_item_id = item_id
        self._tts_text = ""
        self._tts_voice_revision = selected_profile.revision
        self._tts_receipt_id = None
        self._tts_request_ids.add(request.request_id)
        self._tts_terminal_sent = False
        self._tts_stream_mode = True
        self._tts_stream_pending.clear()
        self._tts_stream_accepted = 0
        self._tts_stream_limits = request.limits
        self._tts_generated_samples = 0
        self._tts_failure_code = None
        self._plan_id = plan_fingerprint(
            task=request.task,
            asr_model=str(self._config.get("model") or self._initial_model),
            voice=selected_voice,
            voice_revision=selected_profile.revision,
            catalog_revision=artifact.revision if artifact is not None else None,
        )
        self._tts_stream_ready = asyncio.Event()
        self._tts_task = asyncio.create_task(
            self._run_tts_stream(
                options=options,
                receipt=receipt,
                limits=request.limits,
                voice_mode=selected_profile.mode,
                voice_variant=artifact.variant if artifact is not None else None,
            )
        )

    async def _append_tts_stream(self, event: dict[str, Any]) -> None:
        request = parse_tts_append_text(event)
        limits = self._tts_stream_limits
        if limits is not None:
            # The wire advertised these limits at start, so the wire must
            # enforce them: the worker only ever sees the server defaults.
            pending_codepoints = sum(
                len(text) for text in self._tts_stream_pending.values()
            )
            if len(request.text) > limits.max_append_codepoints:
                raise RealtimeAdapterError(
                    "tts_stream_limit_exceeded",
                    "appended text exceeds the per-append codepoint limit",
                )
            if (
                self._tts_stream_accepted + pending_codepoints + len(request.text)
                > limits.max_total_codepoints
            ):
                raise RealtimeAdapterError(
                    "tts_stream_limit_exceeded",
                    "utterance exceeds the total codepoint limit",
                )
        controller = await self._await_stream_controller(request.request_id)
        if len(self._tts_stream_pending) >= _MAX_PENDING_STREAM_APPENDS:
            raise RealtimeAdapterError(
                "tts_backpressure",
                "too many appends are still awaiting model acceptance",
            )
        # Remember the bounded packet before awaiting the model, so an
        # acceptance that lands first still finds its transcript text.
        self._tts_stream_pending[request.sequence] = request.text
        try:
            await controller.append_text(request.sequence, request.text)
        except BaseException as exc:
            self._tts_stream_pending.pop(request.sequence, None)
            if isinstance(exc, TtsStreamError):
                raise RealtimeAdapterError(exc.code, str(exc)) from None
            raise

    async def _finish_tts_stream(self, event: dict[str, Any]) -> None:
        request = parse_tts_finish_text(event)
        controller = await self._await_stream_controller(request.request_id)
        try:
            await controller.finish_text(request.last_sequence)
        except TtsStreamError as exc:
            raise RealtimeAdapterError(exc.code, str(exc)) from None

    async def _await_stream_controller(self, request_id: str) -> StreamController:
        """Return the live controller, waiting only for bounded admission."""

        if self._tts_request_id != request_id:
            raise RealtimeAdapterError(
                "tts_not_active", "the requested incremental utterance is not active"
            )
        controller = self._tts_stream
        if controller is not None:
            return controller
        ready = self._tts_stream_ready
        if ready is None:
            raise RealtimeAdapterError(
                "tts_not_active", "the requested incremental utterance is not active"
            )
        try:
            await asyncio.wait_for(
                ready.wait(), timeout=self._settings.request_timeout_seconds
            )
        except TimeoutError as exc:
            raise RealtimeAdapterError(
                "backend_timeout", "the incremental utterance did not start in time"
            ) from exc
        controller = self._tts_stream
        if controller is None:
            raise RealtimeAdapterError(
                "tts_not_active", "the requested incremental utterance is not active"
            )
        return controller

    async def _run_tts_stream(
        self,
        *,
        options: TtsStreamOptions,
        receipt: TtsStreamReceipt,
        limits: TtsStreamLimits,
        voice_mode: str,
        voice_variant: str | None,
    ) -> None:
        service = self._services.tts_streams
        try:
            if service is None:
                raise TtsStreamAdmissionError(
                    "tts_streaming_unsupported",
                    "this service exposes no incremental TTS stream",
                )
            controller = await service.open(
                options=options,
                sink=self._on_stream_event,
                receipt=receipt,
                limits=limits,
            )
        except asyncio.CancelledError:
            self._release_stream_state(response_id=options.response_id)
            raise
        except TtsStreamAdmissionError as exc:
            await self._fail_stream_open(
                response_id=options.response_id,
                code=exc.code,
                busy_reason=getattr(exc, "busy_reason", None),
            )
            return
        except TtsStreamError as exc:
            await self._fail_stream_open(
                response_id=options.response_id, code=exc.code, busy_reason=None
            )
            return
        except Exception:
            logger.exception("incremental TTS stream failed to open")
            await self._fail_stream_open(
                response_id=options.response_id,
                code="tts_backend_failed",
                busy_reason=None,
            )
            return
        self._tts_stream = controller
        self._tts_receipt_id = controller.receipt_id
        try:
            await self._send(
                tts_stream_started(
                    task_id=self._task_id,
                    plan_id=self._plan_id,
                    request_id=options.request_id,
                    voice_revision=self._tts_voice_revision,
                    output_format=tts_output_format(),
                    limits=controller.limits,
                )
            )
            if self._tts_stream_ready is not None:
                self._tts_stream_ready.set()
            await controller.wait_closed()
        finally:
            try:
                with contextlib.suppress(Exception):
                    await controller.aclose(
                        reason="client_disconnected" if self._closing else "cancelled"
                    )
            finally:
                self._release_stream_state(response_id=options.response_id)

    async def _on_stream_event(self, event: TtsStreamEvent) -> None:
        """Translate one controller event onto the SpeechRail TTS namespace."""

        if event.terminal is not None:
            await self._settle_stream_terminal(event)
            return
        if event.kind is TtsStreamEventKind.AUDIO:
            self._tts_generated_samples += len(event.pcm16) // 2
            await self._send(
                tts_audio_delta(
                    task_id=self._task_id,
                    request_id=self._tts_request_id or "",
                    chunk_index=int(event.chunk_index or 0),
                    sample_offset=int(event.sample_offset or 0),
                    delta=base64.b64encode(event.pcm16).decode("ascii"),
                )
            )
            return
        if event.kind is not TtsStreamEventKind.TEXT_ACCEPTED:
            return
        sequence = event.sequence
        if sequence is None:
            return
        self._tts_stream_pending.pop(sequence, None)
        self._tts_stream_accepted += event.accepted_codepoints
        await self._send(
            tts_text_accepted(
                task_id=self._task_id,
                request_id=self._tts_request_id or "",
                append_sequence=sequence,
                accepted_codepoints=event.accepted_codepoints,
                total_codepoints=self._tts_stream_accepted,
            )
        )

    async def _settle_stream_terminal(self, event: TtsStreamEvent) -> None:
        """Project the controller's single terminal onto one SpeechRail terminal."""

        if self._closing:
            return
        if event.terminal is TtsStreamTerminal.COMPLETED:
            await self._finalize_tts(
                status="completed",
                receipt_id=self._tts_receipt_id,
                request_id=self._tts_request_id,
            )
            return
        if event.terminal is TtsStreamTerminal.CANCELLED:
            await self._finalize_tts(
                status="cancelled",
                receipt_id=self._tts_receipt_id,
                request_id=self._tts_request_id,
            )
            return
        self._tts_failure_code = event.error_code or "tts_backend_failed"
        await self._finalize_tts(
            status="failed",
            receipt_id=self._tts_receipt_id,
            request_id=self._tts_request_id,
        )

    async def _fail_stream_open(
        self, *, response_id: str, code: str, busy_reason: object
    ) -> None:
        request_id = self._tts_request_id
        self._release_stream_state(response_id=response_id)
        if self._closing or self._tts_terminal_sent:
            return
        self._tts_failure_code = code
        await self._finalize_tts(status="failed", receipt_id=None, request_id=request_id)

    async def _cancel_tts_stream(self) -> None:
        """Cancel the active incremental utterance; the controller owns the terminal."""

        controller = self._tts_stream
        if controller is not None:
            await controller.cancel()
            return
        task = self._tts_task
        response_id = self._tts_response_id
        request_id = self._tts_request_id
        self._release_stream_state(response_id=response_id)
        if task is not None and not task.done():
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        if self._closing or response_id is None:
            return
        await self._finalize_tts(status="cancelled", receipt_id=None, request_id=request_id)

    async def _close_tts_stream(self) -> None:
        controller = self._tts_stream
        if controller is None:
            return
        with contextlib.suppress(Exception):
            await controller.aclose(reason="client_disconnected")

    def _release_stream_state(self, *, response_id: str | None) -> None:
        ready = self._tts_stream_ready
        if ready is not None:
            ready.set()
        self._clear_tts_state(response_id=response_id)

    async def _cancel_response(self, event: dict[str, Any]) -> None:
        request = parse_tts_cancel(event)
        if (
            self._tts_task is None
            or self._tts_task.done()
            or self._tts_response_id is None
            or self._tts_request_id != request.request_id
        ):
            raise RealtimeAdapterError(
                "tts_not_active", "the requested TTS utterance is not active"
            )
        await self._cancel_tts_stream()

    def _clear_tts_state(self, *, response_id: str | None = None) -> None:
        """Release one utterance's identity once it is no longer current."""

        if response_id is not None and self._tts_response_id != response_id:
            return
        self._tts_task = None
        self._tts_request_id = None
        self._tts_response_id = None
        self._tts_item_id = None
        self._tts_text = None
        self._tts_voice_revision = None
        self._tts_receipt_id = None
        self._tts_stream = None
        self._tts_stream_ready = None
        self._tts_stream_mode = False
        self._tts_stream_pending.clear()
        self._tts_stream_accepted = 0
        self._tts_stream_limits = None
        self._tts_generated_samples = 0
        self._tts_failure_code = None

    def _completed_event(self, *, transcript: str) -> dict[str, object]:
        """Render the terminal completed event for the current ASR item."""
        return transcription_completed(item_id=self._current_item_id, transcript=transcript)

    def _start_alignment_task(
        self,
        *,
        task_id: str,
        epoch: int,
        item_id: str,
        transcript: str,
        transcript_revision: int,
        item_start_wire: int,
        item_end_wire: int,
        item_start_kernel: int,
        item_end_kernel: int,
        pcm16: bytes,
        overflow: bool,
        degraded_reason: str | None,
    ) -> None:
        """Run optional alignment after the text final has already been sent."""

        task = asyncio.create_task(
            self._finish_alignment(
                task_id=task_id,
                epoch=epoch,
                item_id=item_id,
                transcript=transcript,
                transcript_revision=transcript_revision,
                item_start_wire=item_start_wire,
                item_end_wire=item_end_wire,
                item_start_kernel=item_start_kernel,
                item_end_kernel=item_end_kernel,
                pcm16=pcm16,
                overflow=overflow,
                degraded_reason=degraded_reason,
            )
        )
        self._alignment_tasks.add(task)
        task.add_done_callback(self._alignment_tasks.discard)

    async def _finish_alignment(
        self,
        *,
        task_id: str,
        epoch: int,
        item_id: str,
        transcript: str,
        transcript_revision: int,
        item_start_wire: int,
        item_end_wire: int,
        item_start_kernel: int,
        item_end_kernel: int,
        pcm16: bytes,
        overflow: bool,
        degraded_reason: str | None,
    ) -> None:
        try:
            # Auxiliary results never cross an epoch or utterance boundary: a
            # reconnect, a newer turn, or a newer transcript revision makes this
            # request stale, and stale metadata must never reach the caller.
            if (
                task_id != self._task_id
                or epoch != self._wire_epoch
                or item_id != self._current_item_id
                or transcript_revision != self._current_transcript_revision
            ):
                self._services.metrics.record_alignment_event("fixed_text_stale")
                return
            units, failure = await self._build_alignment_units(
                item_id=item_id,
                transcript=transcript,
                transcript_revision=transcript_revision,
                item_start=item_start_kernel,
                item_end=item_end_kernel,
                pcm16=pcm16,
                overflow=overflow,
                degraded_reason=degraded_reason,
            )
            aligned = bool(units) and all(
                unit.timing_quality == "aligned" for unit in units
            )
            if not transcript or aligned:
                self._services.metrics.record_alignment_event("fixed_text_completed")
                await self._send(
                    alignment_done(
                        task_id=task_id,
                        epoch=epoch,
                        utterance_id=item_id,
                        transcript_revision=transcript_revision,
                        metadata_revision=self._metadata_revision,
                        sample_span=(item_start_wire, item_end_wire),
                        codepoint_span=(0, len(transcript)),
                        units=self._render_units(units),
                    )
                )
            else:
                self._services.metrics.record_alignment_event("fixed_text_unavailable")
                await self._send(
                    alignment_failed(
                        task_id=task_id,
                        epoch=epoch,
                        utterance_id=item_id,
                        transcript_revision=transcript_revision,
                        metadata_revision=self._metadata_revision,
                        code=failure or "alignment_unavailable",
                        message="fixed-text alignment failed",
                    )
                )
            if units:
                self._metadata_revision += 1
            await self._register_units(item_id, units)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("realtime alignment task failed")
            with contextlib.suppress(Exception):
                await self._send(
                    alignment_failed(
                        task_id=task_id,
                        epoch=epoch,
                        utterance_id=item_id,
                        transcript_revision=transcript_revision,
                        metadata_revision=self._metadata_revision,
                        code="alignment_failed",
                        message="fixed-text alignment failed",
                    )
                )

    async def _build_alignment_units(
        self,
        *,
        item_id: str,
        transcript: str,
        transcript_revision: int,
        item_start: int,
        item_end: int,
        pcm16: bytes,
        overflow: bool,
        degraded_reason: str | None,
    ) -> tuple[tuple[AttributionUnit, ...], str | None]:
        """Align frozen text without ever replacing the ASR final."""

        if not transcript:
            return (), None

        def unavailable(reason: str) -> tuple[tuple[AttributionUnit, ...], str]:
            return (
                (self._unavailable_unit(transcript, item_start, item_end),),
                reason,
            )

        if degraded_reason is not None:
            return unavailable(degraded_reason)
        aligner = self._services.text_aligner
        item_samples = item_end - item_start
        if overflow:
            # The retained pin is bounded; overflow fails loudly instead of
            # aligning a truncated span and pretending the timestamps are exact.
            return unavailable("alignment_pcm_overflow")
        if (
            aligner is None
            or self._diarization_epoch is None
            or len(pcm16) // 2 != item_samples
        ):
            return unavailable("alignment_unavailable")
        try:
            async with self._services.alignment_admission.reserve():
                async with asyncio.timeout(self._settings.request_timeout_seconds):
                    result = await aligner.align(
                        AlignmentRequest(
                            task_id=self._task_id,
                            epoch=self._diarization_epoch,
                            utterance_id=item_id,
                            transcript_revision=transcript_revision,
                            pcm16=pcm16,
                            span=SampleSpan(item_start, item_end),
                            text=transcript,
                            language=self._config.get("language"),
                            granularity=self._alignment_granularity(),
                        )
                    )
        except AlignmentAdmissionFullError:
            self._services.metrics.record_alignment_event("fixed_text_overflow")
            return unavailable("alignment_overloaded")
        except TimeoutError:
            return unavailable("alignment_timeout")
        if result.failure is not None:
            return unavailable(result.failure)
        return (
            tuple(
                AttributionUnit(
                    segment_uid=f"seg_{uuid4().hex[:12]}",
                    text_start=unit.text_start,
                    text_end=unit.text_end,
                    start_sample=(
                        unit.audio_span.start if unit.audio_span is not None else item_start
                    ),
                    end_sample=(
                        unit.audio_span.end if unit.audio_span is not None else item_end
                    ),
                    timing_quality="aligned",
                    granularity=unit.granularity,
                )
                for unit in result.units
            ),
            None,
        )

    def _unavailable_unit(self, canonical: str, item_start: int, item_end: int) -> AttributionUnit:
        return AttributionUnit(
            segment_uid=f"seg_{uuid4().hex[:12]}",
            text_start=0,
            text_end=len(canonical),
            start_sample=item_start,
            end_sample=item_end,
            timing_quality="unavailable",
            granularity=self._alignment_granularity(),
        )

    def _render_units(self, units: tuple[AttributionUnit, ...]) -> list[dict[str, object]]:
        rendered: list[dict[str, object]] = []
        for unit in units:
            wire_span = self._to_wire_span(
                SampleSpan(unit.start_sample, unit.end_sample)
            )
            rendered.append(
                {
                    "segment_uid": unit.segment_uid,
                    "text_start": unit.text_start,
                    "text_end": unit.text_end,
                    "audio_start_sample": wire_span.start,
                    "audio_end_sample": wire_span.end,
                    "timing_quality": unit.timing_quality,
                    "granularity": unit.granularity,
                }
            )
        return rendered

    async def _register_units(
        self, item_id: str, units: tuple[AttributionUnit, ...]
    ) -> None:
        """Register immutable text units; actor events carry only speaker revisions."""
        if self._diarization is None or not units:
            return
        for unit in units:
            self._units_by_id[unit.segment_uid] = unit
            self._speaker_by_unit.setdefault(unit.segment_uid, None)
        try:
            await self._diarization.register_completed(
                item_id,
                tuple(
                    TextUnit(
                        id=unit.segment_uid,
                        text_start=unit.text_start,
                        text_end=unit.text_end,
                        audio_span=(
                            None
                            if unit.timing_quality == "unavailable"
                            else SampleSpan(unit.start_sample, unit.end_sample)
                        ),
                    )
                    for unit in units
                ),
            )
        except DiarizationError as exc:
            await self._handle_degradation(exc)
        except ValueError as exc:
            await self._handle_degradation(
                DiarizationError(str(exc), code="diarization_invalid_output")
            )

    def _diarization_units_payload(self) -> list[dict[str, object]]:
        """Project immutable unit spans onto the 24 kHz public sample axis."""

        payload: list[dict[str, object]] = []
        for unit in sorted(
            self._units_by_id.values(), key=lambda item: (item.start_sample, item.segment_uid)
        ):
            wire_span = self._to_wire_span(
                SampleSpan(unit.start_sample, unit.end_sample)
            )
            payload.append(
                {
                    "speaker": self._speaker_by_unit.get(unit.segment_uid),
                    "sample_span": {"start": wire_span.start, "end": wire_span.end},
                }
            )
        return payload

    async def _send_diarization_updates(self, attributions: tuple[Attribution, ...]) -> None:
        """Project domain speaker revisions into the current extension DTO."""
        if self._ledger is None or not attributions:
            return
        for attribution in attributions:
            if attribution.unit_id in self._units_by_id:
                self._speaker_by_unit[attribution.unit_id] = attribution.speaker
        units = self._diarization_units_payload()
        if not units:
            return
        self._metadata_revision += 1
        for start in range(0, len(units), _MAX_UPDATES_PER_EVENT):
            chunk = units[start : start + _MAX_UPDATES_PER_EVENT]
            sequence = await self._send(
                diarization_updated(
                    task_id=self._task_id,
                    epoch=self._wire_epoch,
                    utterance_id=self._current_item_id,
                    transcript_revision=self._current_transcript_revision,
                    metadata_revision=self._metadata_revision,
                    units=chunk,
                )
            )
            if sequence is not None:
                self._last_update_sequence = sequence

    def _mark_degraded(self, reason: str) -> None:
        if self._degraded_reason is None:
            self._degraded_reason = reason

    async def _handle_degradation(self, exc: DiarizationError) -> None:
        """First-wins transport projection for an actor degradation."""
        reason = (
            exc.code
            if exc.code in {"diarization_overloaded", "diarization_invalid_output"}
            else "diarization_invalid_output"
        )
        self._mark_degraded(reason)
        if not self._status_sent:
            self._status_sent = True
            await self._send(
                diarization_failed(
                    task_id=self._task_id,
                    epoch=self._wire_epoch,
                    utterance_id=self._current_item_id,
                    transcript_revision=self._current_transcript_revision,
                    metadata_revision=self._metadata_revision,
                    code=reason,
                    message="streaming diarization failed",
                )
            )

    async def _handle_finish(self, event: dict[str, Any]) -> None:
        if self._ledger is None:
            raise RealtimeAdapterError(
                "unsupported_operation",
                "diarization is not enabled on this session",
            )
        finalization_id = parse_finish_request(event)
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
        """Ask the actor to close its append barrier and drain its activity port."""
        deadline = self._settings.realtime_diarization_drain_deadline_seconds
        assert self._finalization_id is not None
        done: SessionDone | None = None
        try:
            async with asyncio.timeout(deadline):
                if self._diarization is not None:
                    done = await self._diarization.finish(self._finalization_id)
        except TimeoutError:
            self._mark_degraded("finalization_timeout")
            if not self._status_sent:
                self._status_sent = True
                await self._send(
                    diarization_failed(
                        task_id=self._task_id,
                        epoch=self._wire_epoch,
                        utterance_id=self._current_item_id,
                        transcript_revision=self._current_transcript_revision,
                        metadata_revision=self._metadata_revision,
                        code="finalization_timeout",
                        message="streaming diarization finalization timed out",
                    )
                )
        if done is not None and done.status == "degraded" and self._degraded_reason is None:
            self._mark_degraded("finalization_incomplete")
        if self._degraded_reason is None:
            payload = diarization_done_event(
                task_id=self._task_id,
                epoch=self._wire_epoch,
                utterance_id=self._current_item_id,
                transcript_revision=self._current_transcript_revision,
                metadata_revision=self._metadata_revision,
                units=self._diarization_units_payload(),
            )
        else:
            payload = diarization_failed(
                task_id=self._task_id,
                epoch=self._wire_epoch,
                utterance_id=self._current_item_id,
                transcript_revision=self._current_transcript_revision,
                metadata_revision=self._metadata_revision,
                code=self._degraded_reason,
                message="streaming diarization finalization did not complete",
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
                    current_text = apply_light_itn(event.text)
                    if not current_text:
                        continue
                    if self._first_partial_received_at is None:
                        self._first_partial_received_at = time.monotonic()
                    self._stable_prefix_codepoints = self._common_prefix_codepoints(
                        self._last_hypothesis_text, current_text
                    )
                    self._hypothesis_revision += 1
                    hypothesis_sequence = await self._send(
                        transcription_hypothesis(
                            task_id=self._task_id,
                            epoch=self._wire_epoch,
                            utterance_id=self._current_item_id,
                            revision=self._hypothesis_revision,
                            text=current_text,
                            sample_span=(self._item_start_sample, self._item_end_sample),
                            stable_prefix_codepoints=self._stable_prefix_codepoints,
                        )
                    )
                    self._last_hypothesis_text = current_text
                    if hypothesis_sequence is None:
                        self._record_first_hypothesis("send_failed")
                    else:
                        self._record_first_hypothesis("partial")
                    if self._config.get("transcription_partial_mode", "delta") == "snapshot":
                        # The revisioned hypothesis is the only mutable-text
                        # event on the current wire: a snapshot consumer reads
                        # ``speechrail.transcription.hypothesis`` and needs no
                        # separate append-only reconstruction.
                        self._services.metrics.record_realtime_partial("snapshot_sent")
                    else:
                        if not current_text.startswith(self._last_partial_text):
                            # This wire event is append-only. Keep a changed suffix
                            # private until the terminal completed event can replace
                            # the provisional transcript atomically.
                            self._services.metrics.record_realtime_partial("rewrite_withheld")
                            continue
                        delta = current_text[len(self._last_partial_text):]
                        self._last_partial_text = current_text
                        if delta:
                            self._services.metrics.record_realtime_partial("delta_sent")
                            await self._send(
                                transcription_delta(item_id=self._current_item_id, delta=delta)
                            )
                elif event.kind == "completed":
                    if self._asr is not asr:
                        break
                    self._last_partial_text = ""
                    self._last_hypothesis_text = ""
                    self._unflushed_bytes = 0
                    norm_text = apply_light_itn(event.text)
                    self._current_transcript_revision = max(
                        1, self._hypothesis_revision + 1
                    )
                    self._record_first_hypothesis("missing")
                    self._services.metrics.record_realtime_turn(
                        mode="server_vad" if self._vad is not None else "manual",
                        commit_reason="vad_stop" if self._vad is not None else "client",
                        outcome="text" if norm_text else "empty",
                        characters=len(norm_text),
                        active_samples=max(0, self._item_end_sample - self._item_start_sample),
                        duration_seconds=(
                            max(0.0, time.monotonic() - self._asr_commit_started_at)
                            if self._asr_commit_started_at is not None
                            else 0.0
                        ),
                    )
                    if self._diarization_enabled:
                        item_id = self._current_item_id
                        item_start_sample = self._item_start_sample
                        item_end_sample = max(
                            self._item_end_sample, self._item_start_sample
                        )
                        item_start_kernel = self._item_start_kernel
                        item_end_kernel = max(
                            self._item_end_kernel, self._item_start_kernel
                        )
                        # Text final is deliberately independent from the slow
                        # auxiliary aligner.  Timing and speaker units travel in
                        # their own SpeechRail events.
                        await self._send(
                            transcription_completed(
                                item_id=item_id, transcript=norm_text
                            )
                        )
                        self._start_alignment_task(
                            task_id=self._task_id,
                            epoch=self._wire_epoch,
                            item_id=item_id,
                            transcript=norm_text,
                            transcript_revision=self._current_transcript_revision,
                            item_start_wire=item_start_sample,
                            item_end_wire=item_end_sample,
                            item_start_kernel=item_start_kernel,
                            item_end_kernel=item_end_kernel,
                            pcm16=self._alignment_pcm.pin(),
                            overflow=self._alignment_overflow,
                            degraded_reason=self._degraded_reason,
                        )
                        self._alignment_pcm.clear()
                        self._alignment_overflow = False
                        continue
                    await self._send(
                        transcription_completed(
                            item_id=self._current_item_id, transcript=norm_text
                        )
                    )
                elif event.kind == "error":
                    self._last_partial_text = ""
                    self._unflushed_bytes = 0
                    self._record_first_hypothesis("failed")
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

    async def _finalize_tts(
        self,
        *,
        status: str,
        receipt_id: str | None,
        request_id: str | None,
    ) -> None:
        """Send exactly one SpeechRail TTS terminal event, even across races.

        A normal synthesis task can have already started sending ``completed``
        when the control lane cancels it.  Claiming the terminal under a lock
        and shielding the actual send makes cancellation wait for that one
        event instead of appending a second ``cancelled`` terminal.
        """
        event = self._tts_terminal_event(
            status=status, receipt_id=receipt_id, request_id=request_id
        )
        async with self._tts_terminal_lock:
            if self._tts_terminal_sent:
                return
            send_task: asyncio.Future[int | None] = asyncio.ensure_future(self._send(event))
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
            self._tts_terminal_sent = True
            if cancelled:
                raise asyncio.CancelledError

    def _tts_terminal_event(
        self,
        *,
        status: str,
        receipt_id: str | None,
        request_id: str | None = None,
    ) -> dict[str, object]:
        """Render the one SpeechRail TTS terminal for this utterance."""

        resolved_request_id = request_id or self._tts_request_id or ""
        if status == "completed":
            event: dict[str, object] = tts_completed(
                task_id=self._task_id,
                request_id=resolved_request_id,
                generated_samples=self._tts_generated_samples,
            )
        elif status == "cancelled":
            event = tts_cancelled(task_id=self._task_id, request_id=resolved_request_id)
        else:
            event = tts_failed(
                task_id=self._task_id,
                request_id=resolved_request_id,
                code=self._tts_failure_code or "tts_backend_failed",
                message="incremental TTS response failed",
            )
        return event

    async def _reserve_asr(self) -> None:
        self._asr_resources = AsyncExitStack()
        admission_started = time.monotonic()
        try:
            await self._asr_resources.enter_async_context(
                self._services.governor.reserve(
                    WorkClass.REALTIME_ASR,
                    deadline=self._settings.request_timeout_seconds,
                    purpose=WorkPurpose.INTERACTIVE,
                )
            )
            self._services.metrics.record_realtime_phase(
                "asr_admission", time.monotonic() - admission_started
            )
        except GovernorQueueFullError as exc:
            await self._asr_resources.aclose()
            self._asr_resources = None
            raise RealtimeAdapterError(
                "queue_full",
                "Realtime ASR queue is full",
                busy_reason=str(BusyReason.GOVERNOR_QUEUE_FULL),
            ) from exc
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
        if not self._diarization_enabled:
            return
        engine = self._diarization_engine
        if not self._services.diarization_ready or engine is None:
            raise RealtimeAdapterError(
                "diarization_not_available",
                str(self._services.diarization_status["message"]),
            )
        await self._reserve_diarization()
        try:
            holder: dict[str, DiarizationSession] = {}
            epoch = f"rt-{uuid4().hex}"
            self._ledger = AttributionLedger(
                accepted_samples=lambda: holder["session"].accepted_samples
            )
            self._diarization = DiarizationSession(
                activity=engine.open(epoch=epoch), ledger=self._ledger
            )
            self._diarization_epoch = epoch
            holder["session"] = self._diarization
            await self._diarization.start()
            self._diarization_events = asyncio.create_task(self._consume_diarization_events())
        except BaseException:
            await self._release_diarization()
            raise

    async def _close_diarization(self) -> None:
        if self._diarization is not None:
            with contextlib.suppress(Exception):
                await self._diarization.cancel()
            self._diarization = None
        if self._diarization_events is not None:
            self._diarization_events.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._diarization_events
            self._diarization_events = None
        self._ledger = None
        self._diarization_epoch = None
        await self._release_diarization()

    async def _reserve_diarization(self) -> None:
        self._diarization_resources = AsyncExitStack()
        try:
            await self._diarization_resources.enter_async_context(
                self._services.diarization_admission.reserve()
            )
        except DiarizationAdmissionFullError as exc:
            await self._diarization_resources.aclose()
            self._diarization_resources = None
            raise RealtimeAdapterError(
                "backend_busy",
                "another diarization session is active",
                busy_reason=str(exc.busy_reason),
            ) from exc

    async def _release_diarization(self) -> None:
        if self._diarization_resources is not None:
            await self._diarization_resources.aclose()
            self._diarization_resources = None

    async def _consume_diarization_events(self) -> None:
        """Project actor output without allowing transport code into its state."""

        assert self._diarization is not None
        async for event in self._diarization.events():
            if isinstance(event, ItemAttributionUpdated):
                await self._send_diarization_updates(event.attributions)
            elif isinstance(event, StatusChanged):
                await self._handle_degradation(
                    DiarizationError(
                        "streaming diarization degraded",
                        code=event.reason,
                    )
                )
