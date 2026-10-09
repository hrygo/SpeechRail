"""ASR ingress, frozen items and commit ownership."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections import deque
from collections.abc import Awaitable, Callable, Mapping
from contextlib import AsyncExitStack
from dataclasses import dataclass, field
from typing import Any, cast
from uuid import uuid4

from starlette.websockets import WebSocketDisconnect

from speechrail.application.asr_turn_coordinator import AsrTurnCoordinator
from speechrail.application.realtime_auxiliary import AuxiliaryIngress
from speechrail.application.realtime_state import AsrIdentity, FrozenTranscript
from speechrail.compatibility.openai_realtime import (
    ASR_KERNEL_SAMPLE_RATE,
    WIRE_SAMPLE_RATE,
    RealtimeAdapterError,
    transcription_completed,
    transcription_failed,
    transcription_hypothesis,
    transcription_segment_closed,
    validate_append,
)
from speechrail.config import Settings
from speechrail.domain.asr_policy import ASRPolicy, resolve_effective_max_segment_ms
from speechrail.domain.audio_timeline import (
    RateMap,
    RationalResampler,
    SampleClock,
    SampleSpan,
)
from speechrail.domain.itn import apply_light_itn
from speechrail.domain.ports import (
    RealtimeAsrFactory,
    RealtimeAsrSession,
    RealtimeTranscriptionOptions,
    SegmentCloseReason,
)
from speechrail.observability.metrics import Metrics
from speechrail.realtime.speech_admission import AdmissionDecision, SpeechAdmission
from speechrail.runtime.asr_debug_tap import AsrDebugTap
from speechrail.runtime.busy import BusyReason, infer_backend_busy_reason
from speechrail.runtime.limits import MAX_ALIGNMENT_PCM_BYTES
from speechrail.runtime.pcm_buffer import BoundedPcmBuffer, PcmBufferOverflowError
from speechrail.runtime.resource_governor import (
    GovernorLaneIsolatedError,
    GovernorQueueFullError,
    ResourceGovernor,
    WorkClass,
    WorkPurpose,
)

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class _AsrItem:
    """Identity and evidence stay with a frozen item while ingress advances."""

    asr: RealtimeAsrSession
    item_id: str
    generation: int
    start_wire: int = 0
    end_wire: int = 0
    start_kernel: int = 0
    end_kernel: int = 0
    commit_event_id: str | None = None
    close_reason: str | None = None
    terminal: bool = False
    revision: int = 0
    preview_revision: int = 0
    pcm: BoundedPcmBuffer = field(default_factory=lambda: BoundedPcmBuffer(MAX_ALIGNMENT_PCM_BYTES))
    overflow: bool = False
    reader: asyncio.Task[None] | None = None
    first_upstream: float | None = None
    admitted_at: float | None = None
    first_partial: float | None = None
    first_recorded: bool = False
    commit_started: float | None = None
    failure_code: str | None = None


@dataclass(frozen=True, slots=True)
class _AsrInputBarrier:
    input_generation: int
    asr_generation: int
    accepted_samples: int
    start_input_generation: int
    finals: tuple[tuple[asyncio.Task[str | None], int], ...]
    failure_code: str | None = None


@dataclass(frozen=True, slots=True)
class RealtimeAsrPorts:
    factory: RealtimeAsrFactory | None
    governor: ResourceGovernor
    metrics: Metrics


@dataclass(slots=True)
class EndpointingUpdate:
    replace: bool
    reset_buffer: bool
    vad: Any
    shadow_vad: Any
    admission: SpeechAdmission | None
    pending_max_bytes: int


class RealtimeAsrOwner:
    """Own ingress, frozen items, commit barriers and the sole ASR lane."""

    def __init__(
        self,
        *,
        ports: RealtimeAsrPorts,
        settings: Settings,
        session_id: str,
        task_id: str,
        send: Callable[[dict[str, object]], Awaitable[int | None]],
        config: Callable[[], Mapping[str, Any]],
    ) -> None:
        self._ports = ports
        self._settings = settings
        self._send = send
        self._task_id = task_id
        self._config_snapshot = config
        self._auxiliary: AuxiliaryIngress | None = None
        self._closing = False
        self._asr_factory = ports.factory
        self._asr: RealtimeAsrSession | None = None
        self._asr_reader: asyncio.Task[None] | None = None
        self._asr_resources: AsyncExitStack | None = None
        self._asr_lane: AsrTurnCoordinator | None = None
        self._asr_input_error: str | None = None
        self._asr_barrier_failure: tuple[int, str] | None = None
        self._asr_item: _AsrItem | None = None
        self._asr_generation = 0
        self._asr_finals: dict[asyncio.Task[str | None], int] = {}
        self._asr_empty_terminals: dict[str, str | None] = {}
        self._asr_closed_items: dict[str, _AsrItem] = {}
        self._commit_lock = asyncio.Lock()
        self._commit_owner: str | None = None
        self._input_generation = 0
        self._committed_input_generation = -1
        self._input_barrier: _AsrInputBarrier | None = None
        self._next_barrier_start_generation = 0

        self._active_commit_event_id: str | None = None
        self._first_upstream_received_at: float | None = None
        self._admitted_started_at: float | None = None
        self._latest_append_received_at: float | None = None
        self._first_partial_received_at: float | None = None
        self._first_hypothesis_recorded = False
        self._hypothesis_revision = 0
        self._stable_prefix_codepoints = 0
        self._last_hypothesis_text = ""
        self._wire_epoch = 0
        self._current_transcript_revision = 0

        self._alignment_pcm = BoundedPcmBuffer(MAX_ALIGNMENT_PCM_BYTES)
        self._alignment_overflow = False
        self._asr_debug_tap = AsrDebugTap(session_id)
        self._buffered_audio_bytes = 0
        self._unflushed_bytes = 0
        self._last_partial_text = ""

        self._vad: Any = None
        self._shadow_vad: Any = None
        self._speech_admission: SpeechAdmission | None = None
        self._turn_generation: int = 0
        self._turn_has_admitted_speech: bool = False
        self._admitted_start_sample: int = 0
        self._admitted_end_sample: int = 0
        self._vad_raw_buffer = bytearray()
        self._vad_sample_cursor: int = 0
        self._bargein_pending_audio: deque[bytes] = deque()
        self._bargein_pending_bytes = 0
        self._bargein_pending_max_bytes = 9_600

        self._wire_timeline = SampleClock(WIRE_SAMPLE_RATE)
        self._kernel_timeline = SampleClock(ASR_KERNEL_SAMPLE_RATE)
        self._resampler = RationalResampler(WIRE_SAMPLE_RATE, ASR_KERNEL_SAMPLE_RATE)
        self._wire_to_kernel = RateMap(WIRE_SAMPLE_RATE, ASR_KERNEL_SAMPLE_RATE)
        self._kernel_to_wire = RateMap(ASR_KERNEL_SAMPLE_RATE, WIRE_SAMPLE_RATE)
        self._item_start_sample = 0
        self._item_end_sample = 0
        self._item_start_kernel = 0
        self._item_end_kernel = 0
        self._current_item_id = self._new_item_id()

    def bind_auxiliary(self, auxiliary: AuxiliaryIngress) -> None:
        if self._auxiliary is not None:
            raise RuntimeError("auxiliary owner is already bound")
        self._auxiliary = auxiliary

    @property
    def auxiliary(self) -> AuxiliaryIngress:
        assert self._auxiliary is not None
        return self._auxiliary

    @property
    def _config(self) -> Mapping[str, Any]:
        return self._config_snapshot()

    @property
    def identity(self) -> AsrIdentity:
        return AsrIdentity(
            self._asr_generation,
            self._wire_epoch,
            self._current_item_id,
            self._current_transcript_revision,
        )

    @property
    def accepted_samples(self) -> int:
        return self._wire_timeline.accepted_samples

    @property
    def policy_busy(self) -> bool:
        return bool(
            self._asr is not None
            or (self._asr_lane is not None and self._asr_lane.busy)
            or self._vad_raw_buffer
        )

    async def wait_finals(self) -> None:
        await self._await_asr_finals()

    async def begin_close(self) -> None:
        self._closing = True
        self._asr_generation += 1
        self._asr_debug_tap.close()
        if self._asr_lane is not None:
            await self._asr_lane.close()
            self._asr_lane = None
        for final in tuple(self._asr_finals):
            final.cancel()
        if self._asr_finals:
            await asyncio.gather(*self._asr_finals, return_exceptions=True)
        self._asr_finals.clear()
        self._asr_empty_terminals.clear()
        if self._first_upstream_received_at is not None:
            self._record_first_hypothesis("cancelled")

    async def close(self) -> None:
        await self._stop_asr_reader()
        await self._close_asr_session()
        await self._release_asr()
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

    def prepare_endpointing(self, candidate: Mapping[str, Any]) -> EndpointingUpdate:
        turn_detection = candidate.get("turn_detection")
        if (
            isinstance(turn_detection, dict)
            and turn_detection.get("mode") == "server_vad"
            and self._settings.resolves_to_silero_vad
        ):
            from speechrail.backends.neural_vad import SileroVadDetector

            ready, reason = SileroVadDetector.check_readiness(
                self._settings.realtime_vad_model_path
            )
            if not ready:
                raise RealtimeAdapterError(
                    "backend_not_ready",
                    f"Silero VAD preflight failed: {reason}",
                )

        candidate_vad: Any = None
        candidate_shadow_vad: Any = None
        candidate_admission: SpeechAdmission | None = None
        candidate_bargein_max_bytes = self._bargein_pending_max_bytes
        resets_vad_buffer = False
        replaces_vad_state = False
        if isinstance(turn_detection, dict) and turn_detection.get("mode") == "server_vad":
            replaces_vad_state = True
            threshold = float(turn_detection.get("threshold", 0.5))
            prefix_padding = int(turn_detection.get("prefix_padding_ms", 300))
            silence_duration = int(turn_detection.get("silence_duration_ms", 400))

            if self._settings.resolves_to_silero_vad:
                from speechrail.backends.neural_vad import (
                    SileroVadConfig,
                    SileroVadDetector,
                )

                candidate_vad = SileroVadDetector(
                    self._settings.realtime_vad_model_path,
                    config=SileroVadConfig(threshold=threshold),
                )
            else:
                from speechrail.backends.vad import VadConfig, VoiceActivityDetector

                candidate_vad = VoiceActivityDetector(
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
                        candidate_shadow_vad = SileroVadDetector(
                            self._settings.realtime_vad_model_path,
                            config=SileroVadConfig(threshold=threshold),
                        )

            if self._settings.realtime_speech_admission_enabled:
                prefix_samples = int(prefix_padding * 16)
                stop_frames = max(1, (silence_duration + 31) // 32)
                candidate_admission = SpeechAdmission(
                    threshold=threshold,
                    start_frames=3,
                    stop_frames=stop_frames,
                    prefix_samples=prefix_samples,
                    frame_samples=512,
                    sample_rate=16_000,
                )
                # 与原实现一致: 只有 speech admission 接管时才重置采样游标与原始缓冲.
                resets_vad_buffer = True
            candidate_bargein_max_bytes = max(1, prefix_padding * 32)
        elif (
            turn_detection is None
            or (isinstance(turn_detection, dict) and turn_detection.get("type") is None)
            or turn_detection == "manual"
        ):
            replaces_vad_state = True
            resets_vad_buffer = True

        return EndpointingUpdate(
            replaces_vad_state,
            resets_vad_buffer,
            candidate_vad,
            candidate_shadow_vad,
            candidate_admission,
            candidate_bargein_max_bytes,
        )

    def apply_endpointing(self, update: EndpointingUpdate) -> None:
        if update.replace:
            self._vad = update.vad
            self._shadow_vad = update.shadow_vad
            self._speech_admission = update.admission
            self._bargein_pending_max_bytes = update.pending_max_bytes
        if update.reset_buffer:
            self._vad_raw_buffer.clear()
            if update.admission is not None:
                self._vad_sample_cursor = self._kernel_timeline.accepted_samples

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
        return self.policy().preview_interval_ms / 1_000

    def policy(self) -> ASRPolicy:
        policy = self._config.get("asr_policy")
        if isinstance(policy, ASRPolicy):
            return policy
        return ASRPolicy()

    def effective_segment_ms(self) -> int:
        policy = self.policy()
        # Two retained spans account for PCM and its inference snapshot; the
        # capability additionally bounds the admitted audio itself.
        service_bytes = self._settings.max_realtime_buffer_bytes or 8_388_608
        return resolve_effective_max_segment_ms(
            policy,
            service_max_segment_ms=service_bytes // 64,
            capability_max_segment_ms=8_000 if self.auxiliary.diarization_enabled else None,
            decoder_max_segment_ms=30_000,
        )

    def _sync_asr_item(self) -> None:
        item = self._asr_item
        if item is None:
            return
        item.start_wire = self._item_start_sample
        item.end_wire = self._item_end_sample
        item.start_kernel = self._item_start_kernel
        item.end_kernel = self._item_end_kernel
        item.first_upstream = self._first_upstream_received_at
        item.admitted_at = self._admitted_started_at
        item.overflow = self._alignment_overflow

    async def _await_asr_finals(self) -> None:
        while self._asr_finals:
            tasks = tuple(self._asr_finals)
            await asyncio.gather(*tasks)
            for task in tasks:
                self._discard_asr_final(task)

    def _to_wire_sample(self, kernel_sample: int) -> int:
        return self._kernel_to_wire.to_target(kernel_sample)

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
        lag_seconds = max(0.0, (self._item_end_sample - start_sample) / WIRE_SAMPLE_RATE)
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
                (self._item_end_sample - self._item_start_sample) / WIRE_SAMPLE_RATE,
            )
            if outcome == "partial"
            else None
        )
        self._ports.metrics.record_realtime_first_hypothesis(
            outcome,
            admitted_to_worker_seconds=admitted_to_worker,
            upstream_to_worker_seconds=upstream_to_worker,
            worker_to_socket_seconds=worker_to_socket,
            admitted_to_socket_seconds=admitted_to_socket,
            admitted_audio_seconds=admitted_audio_seconds,
        )

    async def _ensure_asr_for_turn(self) -> None:
        if self._asr is not None:
            return
        if self._asr_factory is None:
            raise RealtimeAdapterError("backend_not_ready", "streaming ASR backend is not ready")

        asr: RealtimeAsrSession | None = None
        from speechrail.domain.itn import compose_hotword_prompt

        asr_prompt = compose_hotword_prompt(
            str(self._config.get("prompt") or ""),
            self._config.get("keywords"),
        )
        try:
            if self._asr_lane is None:
                self._asr_lane = AsrTurnCoordinator(
                    self._asr_factory,
                    capacity_bytes=self._settings.max_realtime_buffer_bytes or 8_388_608,
                    acquire=self._reserve_asr,
                    release=self._release_asr,
                )
            requested_policy = self.policy()
            policy = ASRPolicy(
                preview_interval_ms=requested_policy.preview_interval_ms,
                max_segment_ms=requested_policy.max_segment_ms,
                finalization=requested_policy.finalization,
                final_deadline_ms=requested_policy.effective_deadline_ms(
                    request_timeout_ms=int(self._settings.request_timeout_seconds * 1000)
                ),
            )
            asr = self._asr_lane.create(
                language=self._config.get("language"),
                prompt=asr_prompt,
                options=RealtimeTranscriptionOptions(
                    partial_mode="snapshot",
                    chunk_duration_ms=policy.preview_interval_ms,
                    asr_policy=policy,
                    effective_max_segment_ms=self.effective_segment_ms(),
                ),
            )
            await asr.connect()
        except BaseException as exc:
            if asr is not None:
                with contextlib.suppress(Exception):
                    await asr.close()
            if isinstance(exc, asyncio.CancelledError):
                raise
            message = str(exc)
            if message.startswith("asr_buffer_overflow"):
                await self._fail_asr_input("asr_buffer_overflow")
                raise RealtimeAdapterError(
                    "asr_buffer_overflow", "ASR pending segment capacity exhausted"
                ) from exc
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
        item = _AsrItem(
            asr=asr,
            item_id=self._current_item_id,
            generation=self._asr_generation,
            pcm=self._alignment_pcm,
        )
        self._asr_item = item
        self._sync_asr_item()
        self._asr_reader = asyncio.create_task(self._drain_asr_events(item))
        item.reader = self._asr_reader

    async def _append_asr_audio(self, audio: bytes) -> None:
        """Feed ASR and retain exactly this item's bounded alignment PCM."""

        assert self._asr is not None
        try:
            await self._asr.append_audio(audio)
        except RuntimeError as exc:
            if str(exc).startswith("asr_buffer_overflow"):
                await self._fail_asr_input("asr_buffer_overflow")
                raise RealtimeAdapterError(
                    "asr_buffer_overflow", "ASR retained input capacity exhausted"
                ) from exc
            raise
        self._sync_asr_item()
        # Diagnosis tap: records the exact kernel PCM fed to ASR while armed.
        # Placed after backend acceptance so failed appends leave no trace.
        self._asr_debug_tap.append(audio)
        if not (self.auxiliary.alignment_enabled or self.auxiliary.diarization_enabled):
            return
        try:
            self._alignment_pcm.append(audio)
        except PcmBufferOverflowError:
            # Surface the overflow explicitly instead of retaining a partial span:
            # the committed item is marked so alignment fails with a reason.
            if not self._alignment_overflow:
                self._ports.metrics.record_alignment_event("fixed_text_overflow")
            self._alignment_overflow = True

    async def _fail_asr_input(self, code: str) -> None:
        self._asr_input_error = code
        if self._asr_lane is not None:
            await self._asr_lane.abort(code)

    async def _feed_admitted_pcm(
        self, pcm: bytes, start_sample: int, *, in_commit: bool = False
    ) -> None:
        """Split on PCM frames once; every accepted sample has one item owner."""
        offset = 0
        segment_bytes = self.effective_segment_ms() * 32
        if segment_bytes < 2:
            raise RealtimeAdapterError("asr_policy_invalid", "ASR budget holds no PCM sample")
        while offset < len(pcm):
            await self._retire_terminal_asr(
                next_wire_sample=self._to_wire_sample(start_sample + offset // 2)
            )
            if self._asr is not None and self._buffered_audio_bytes >= segment_bytes:
                if in_commit:
                    await self._commit_audio_once("rollover")
                else:
                    await self.commit(reason="rollover")
                self._input_generation += 1
            if self._asr is None:
                self._item_start_kernel = start_sample + offset // 2
                self._item_start_sample = max(
                    self._item_start_sample, self._to_wire_sample(self._item_start_kernel)
                )
                self._item_end_kernel = self._item_start_kernel
                self._item_end_sample = self._item_start_sample
                self._turn_has_admitted_speech = True
                self._mark_admitted_started(self._item_start_sample)
                await self._ensure_asr_for_turn()
            take = min(len(pcm) - offset, segment_bytes - self._buffered_audio_bytes)
            part = pcm[offset : offset + take]
            self._item_end_kernel = start_sample + (offset + take) // 2
            self._item_end_sample = min(
                self._wire_timeline.accepted_samples,
                self._to_wire_sample(self._item_end_kernel),
            )
            await self._append_asr_audio(part)
            self._buffered_audio_bytes += take
            self._unflushed_bytes += take
            offset += take
            self._sync_asr_item()
            if self._unflushed_bytes >= self.policy().preview_interval_ms * 32:
                self._unflushed_bytes = 0
                assert self._asr is not None
                await self._asr.flush()
            # Yield to the sole lane, without awaiting a GPU operation. Large
            # packets cannot fill an arbitrary number of pending segments.
            await asyncio.sleep(0)

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

            self._ports.metrics.record_vad("started")
            await self._ensure_asr_for_turn()

        elif dec.kind == "audio":
            if not self._turn_has_admitted_speech or self._asr is None:
                await self._ensure_asr_for_turn()
                self._turn_has_admitted_speech = True
                self._admitted_start_sample = dec.start_sample
                self._item_start_kernel = dec.start_sample
                self._item_start_sample = self._to_wire_sample(dec.start_sample)
                self._mark_admitted_started(self._item_start_sample)

            await self._feed_admitted_pcm(dec.pcm, dec.start_sample, in_commit=in_commit)
            self._admitted_end_sample = dec.end_sample

        elif dec.kind == "end":
            self._ports.metrics.record_vad("ended")
            self._admitted_end_sample = dec.end_sample
            self._item_end_kernel = dec.end_sample
            self._item_end_sample = self._to_wire_sample(dec.end_sample)
            # A commit flushing the state machine is already the commit in
            # progress: nesting another one here would double-commit the item
            # and append a phantom empty close-out after the real transcript.
            if not in_commit:
                # ``_commit_audio`` treats the VAD buffer as EOF and pushes it
                # into admission.  A legal append may still contain complete
                # frames after this utterance ends, so hide those unscored
                # frames while the current item is finalized and restore them
                # for the outer frame loop afterwards.  They must not be
                # misclassified as silence.
                unscored = bytes(self._vad_raw_buffer)
                self._vad_raw_buffer.clear()
                try:
                    await self.commit(reason="vad_stop")
                finally:
                    self._vad_raw_buffer.extend(unscored)

    async def append(self, event: dict[str, Any]) -> None:
        if self._asr_input_error is not None:
            raise RealtimeAdapterError(
                "invalid_state", "ASR input failed; clear the input before appending"
            )
        if self.auxiliary.phase != "active":
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
        await self._retire_terminal_asr()
        max_buf = self._settings.max_realtime_buffer_bytes
        if max_buf is not None and len(audio) > max_buf:
            raise RealtimeAdapterError(
                "buffer_too_large", "audio buffer exceeds the configured limit"
            )

        if self._asr_factory is None:
            raise RealtimeAdapterError("backend_not_ready", "streaming ASR backend is not ready")

        await self.auxiliary.ensure_diarization()
        self._wire_timeline.accept(audio)
        self._mark_upstream_received(time.monotonic())
        self._input_generation += 1
        kernel_audio = self._resampler.process(audio)
        kernel_span = self._kernel_timeline.accept(kernel_audio)
        # Accepted input may belong to the next item. Only admitted PCM
        # advances the current item's end, including across a packet boundary
        # at which the old item has already filled its segment budget.
        if kernel_audio and self.auxiliary.diarization_active:
            await self.auxiliary.append(kernel_audio)
        if not kernel_audio:
            if self._asr is None:
                self._item_start_kernel = kernel_span.start
                if self._vad is not None:
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
                        self._ports.metrics.record_vad_shadow(
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
                    self._ports.metrics.record_vad("started")
                    kernel_start = int(float(v_event.audio_start_ms) * 16)
                    self._item_start_kernel = kernel_start
                    self._item_start_sample = self._to_wire_sample(kernel_start)
                    self._mark_admitted_started(self._item_start_sample)
                elif v_event.speech_ended:
                    self._ports.metrics.record_vad("ended")
                    if self._asr is not None:
                        await self._feed_admitted_pcm(kernel_audio, kernel_span.start)
                        await self.commit(reason="vad_stop")
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

        if self._asr is None:
            await self._ensure_asr_for_turn()
            self._item_start_kernel = kernel_span.start
            # Manual input starts at the unassigned wire cursor. Resampling
            # may retain a fractional tail, so reversing its kernel cursor
            # can otherwise overlap or skip one already accepted sample.
            if self._vad is not None:
                self._item_start_sample = self._to_wire_sample(kernel_span.start)
            # The manual/legacy path has no VAD gate: any appended audio belongs
            # to this turn.  Marking it admitted keeps the resampler tail on
            # commit flowing to both ASR and the bounded alignment buffer so the
            # alignment span and retained PCM stay exactly equal.
            self._turn_has_admitted_speech = True
            self._mark_admitted_started(self._item_start_sample)
            if self._bargein_pending_audio and self._asr is not None:
                for pending_chunk in self._bargein_pending_audio:
                    pending_start = max(0, kernel_span.start - self._bargein_pending_bytes // 2)
                    await self._feed_admitted_pcm(pending_chunk, pending_start)
                    self._bargein_pending_bytes -= len(pending_chunk)
                self._bargein_pending_audio.clear()
                self._bargein_pending_bytes = 0

        await self._feed_admitted_pcm(kernel_audio, kernel_span.start)

    async def commit(
        self,
        reason: str = "client",
        *,
        commit_event_id: str | None = None,
        request_receipt: bool = False,
    ) -> None:
        barrier = await self.freeze_commit(reason, commit_event_id=commit_event_id)
        if reason == "client" or request_receipt:
            await self.complete_commit(
                barrier,
                commit_event_id=commit_event_id,
                request_receipt=request_receipt,
            )

    async def freeze_commit(
        self,
        reason: str,
        *,
        commit_event_id: str | None,
    ) -> _AsrInputBarrier:
        """Freeze input in FIFO order; model finalization does not hold this lock."""
        async with self._commit_lock:
            if self._asr_input_error is not None:
                raise RealtimeAdapterError(
                    self._asr_input_error, "the input barrier contains rejected audio"
                )
            item_id = self._current_item_id
            if not (
                self._commit_owner == item_id
                or self._committed_input_generation == self._input_generation
            ):
                self._commit_owner = item_id
                self._committed_input_generation = self._input_generation
                self._active_commit_event_id = commit_event_id
                try:
                    final = await self._commit_audio_once(reason)
                    self._committed_input_generation = self._input_generation
                    finals = tuple(self._asr_finals.items())
                    if final is not None and final not in self._asr_finals:
                        finals += ((final, self._input_generation),)
                    self._input_barrier = _AsrInputBarrier(
                        input_generation=self._input_generation,
                        asr_generation=self._asr_generation,
                        accepted_samples=self._wire_timeline.accepted_samples,
                        start_input_generation=self._next_barrier_start_generation,
                        finals=finals,
                        failure_code=(
                            self._asr_barrier_failure[1]
                            if self._asr_barrier_failure is not None
                            and self._asr_barrier_failure[0] >= self._next_barrier_start_generation
                            else None
                        ),
                    )
                except Exception as exc:
                    self._input_barrier = _AsrInputBarrier(
                        self._input_generation,
                        self._asr_generation,
                        self._wire_timeline.accepted_samples,
                        self._next_barrier_start_generation,
                        tuple(self._asr_finals.items()),
                        exc.code
                        if isinstance(exc, RealtimeAdapterError)
                        else (
                            "backend_timeout" if isinstance(exc, TimeoutError) else "backend_error"
                        ),
                    )
                    if reason == "client":
                        self._next_barrier_start_generation = self._input_generation + 1
                    raise
                finally:
                    self._active_commit_event_id = None
            if self._input_barrier is None:
                self._input_barrier = _AsrInputBarrier(
                    self._input_generation,
                    self._asr_generation,
                    self._wire_timeline.accepted_samples,
                    self._next_barrier_start_generation,
                    (),
                    self._asr_barrier_failure[1]
                    if (
                        self._asr_barrier_failure is not None
                        and self._asr_barrier_failure[0] >= self._next_barrier_start_generation
                    )
                    else None,
                )
            if self._input_barrier.input_generation != self._input_generation:
                raise RealtimeAdapterError(
                    "backend_error",
                    "the input barrier has uncommitted audio",
                )
            if reason == "client":
                self._next_barrier_start_generation = self._input_generation + 1
            return self._input_barrier

    async def complete_commit(
        self,
        barrier: _AsrInputBarrier,
        *,
        commit_event_id: str | None,
        request_receipt: bool,
    ) -> None:
        try:
            results = await asyncio.gather(*(asyncio.shield(t) for t, _ in barrier.finals))
        except asyncio.CancelledError:
            task = asyncio.current_task()
            if task is not None and task.cancelling():
                raise
            raise RealtimeAdapterError(
                "invalid_state", "the input barrier was canceled by input clear"
            ) from None
        if barrier.asr_generation != self._asr_generation:
            raise RealtimeAdapterError("invalid_state", "the input barrier was cleared")
        failure = barrier.failure_code or next(
            (
                code
                for (_, generation), code in zip(barrier.finals, results, strict=True)
                if code and generation >= barrier.start_input_generation
            ),
            None,
        )
        if request_receipt:
            if failure:
                raise RealtimeAdapterError(
                    failure,
                    "the input barrier did not reach a worker transcription terminal",
                )
            await self._send(
                {
                    "type": "speechrail.input_audio_buffer.committed",
                    "commit_event_id": commit_event_id,
                    "accepted_samples": barrier.accepted_samples,
                }
            )

    def _schedule_empty_asr_terminal(self) -> asyncio.Task[str | None]:
        event = self._completed_event(
            transcript="",
            commit_event_id=self._active_commit_event_id,
        )
        item_id = self._current_item_id
        self._asr_empty_terminals[item_id] = self._active_commit_event_id
        previous = tuple(self._asr_finals)
        generation = self._asr_generation

        async def finish() -> str | None:
            try:
                await asyncio.gather(*(asyncio.shield(t) for t in previous))
                if (
                    item_id in self._asr_empty_terminals
                    and generation == self._asr_generation
                    and not self._closing
                ):
                    self._asr_empty_terminals.pop(item_id)
                    await self._send(event)
                return None
            finally:
                self._asr_empty_terminals.pop(item_id, None)

        task = asyncio.create_task(finish())
        self._asr_finals[task] = self._input_generation
        task.add_done_callback(self._discard_asr_final)
        return task

    def _discard_asr_final(self, task: asyncio.Task[str | None]) -> None:
        self._asr_finals.pop(task, None)
        if not task.cancelled() and (error := task.exception()) is not None:
            logger.warning(
                "ASR final task ended with an error: type=%s",
                type(error).__name__,
            )

    async def _commit_audio_once(self, reason: str) -> asyncio.Task[str | None] | None:
        tail = self._resampler.flush() if reason == "client" else b""
        if tail:
            kernel_span = self._kernel_timeline.accept(tail)
            if self.auxiliary.diarization_active:
                await self.auxiliary.append(tail)
            if self._asr is None and self._vad is None and self._speech_admission is None:
                # A one-sample manual packet may live entirely in the
                # resampler's interpolation tail. It is admitted input too.
                self._item_start_kernel = kernel_span.start
                self._turn_has_admitted_speech = True
                self._mark_admitted_started(self._item_start_sample)
                await self._ensure_asr_for_turn()
            if self._asr is not None and self._turn_has_admitted_speech:
                await self._feed_admitted_pcm(tail, kernel_span.start, in_commit=True)

        # If speech admission is active, flush any remaining sub-frame leftover.
        # The remainder is always below one 512-sample frame (append drains full
        # frames), so it never forms a VAD decision here: admission parks it in
        # its own leftover buffer and emits it as tail audio on finish(). Scoring
        # a partial frame would crash the Silero engine, which requires exactly
        # 512 samples.
        if reason == "client" and self._speech_admission is not None and self._vad is not None:
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
            final = self._schedule_empty_asr_terminal()
            self._last_partial_text = ""
            self._unflushed_bytes = 0
            self._buffered_audio_bytes = 0
            self._ports.metrics.record_realtime_turn(
                mode="server_vad",
                commit_reason=reason,
                outcome="empty",
                characters=0,
                active_samples=0,
            )
            self._record_first_hypothesis("missing")
            self._reset_turn_observability()
            self._current_item_id = self._new_item_id()
            return final

        if self._asr is None:
            final = self._schedule_empty_asr_terminal()
            self._last_partial_text = ""
            self._unflushed_bytes = 0
            self._ports.metrics.record_realtime_turn(
                mode="manual",
                commit_reason=reason,
                outcome="empty",
                characters=0,
                active_samples=0,
            )
            self._record_first_hypothesis("missing")
            self._reset_turn_observability()
            self._current_item_id = self._new_item_id()
            return final

        self._sync_asr_item()
        item = self._asr_item
        assert item is not None
        item.commit_event_id = self._active_commit_event_id if reason == "client" else None
        item.close_reason = (
            "budget_rollover"
            if reason == "rollover"
            else "vad"
            if reason == "vad_stop"
            else "client_commit"
        )
        if item.end_wire > item.start_wire:
            await self._send(
                transcription_segment_closed(
                    item_id=item.item_id,
                    sample_span=(item.start_wire, item.end_wire),
                    reason=cast(SegmentCloseReason, item.close_reason),
                    commit_event_id=item.commit_event_id,
                )
            )
        item.commit_started = time.monotonic()
        want_segments = "segment" in (self._config.get("timestamp_granularities") or [])
        self._asr_closed_items[item.item_id] = item
        final = asyncio.create_task(
            self._finish_asr_item(item, want_segments, self._input_generation)
        )
        self._asr_finals[final] = self._input_generation
        final.add_done_callback(self._discard_asr_final)
        self._asr = None
        self._asr_item = None
        self._asr_reader = None
        self._alignment_pcm = BoundedPcmBuffer(MAX_ALIGNMENT_PCM_BYTES)
        self._alignment_overflow = False
        self._turn_has_admitted_speech = False
        self._buffered_audio_bytes = 0
        self._last_partial_text = ""
        self._unflushed_bytes = 0
        self._reset_turn_observability()
        self._item_start_sample = item.end_wire
        self._item_end_sample = item.end_wire
        self._item_start_kernel = item.end_kernel
        self._item_end_kernel = item.end_kernel
        self._current_item_id = self._new_item_id()
        return final

    async def _finish_asr_item(
        self, item: _AsrItem, want_segments: bool, input_generation: int
    ) -> str | None:
        try:
            await item.asr.commit(want_segments=want_segments)
            if item.reader is not None:
                await item.reader
            if not item.terminal:
                raise RuntimeError("streaming ASR ended without a transcription terminal")
        except asyncio.CancelledError:
            await item.asr.close()
            raise
        except Exception as exc:
            if item.reader is not None:
                await item.reader
            code = item.failure_code or (
                "backend_timeout" if isinstance(exc, TimeoutError) else "backend_error"
            )
            if item.generation == self._asr_generation and (
                self._asr_barrier_failure is None
                or input_generation >= self._asr_barrier_failure[0]
            ):
                self._asr_barrier_failure = (input_generation, code)
            if not item.terminal and item.generation == self._asr_generation:
                item.terminal = True
                item.failure_code = code
                await self._send(
                    transcription_failed(
                        item_id=item.item_id,
                        code=(
                            "backend_timeout" if isinstance(exc, TimeoutError) else "backend_error"
                        ),
                        message="streaming transcription failed",
                        commit_event_id=item.commit_event_id,
                    )
                )
            # The terminal fact is already delivered. A background VAD final
            # must not throw an unobserved task exception into another item.
            return code if item.generation == self._asr_generation else "backend_error"
        finally:
            item.pcm.clear()
            self._asr_closed_items.pop(item.item_id, None)
        return None

    async def _retire_terminal_asr(self, *, next_wire_sample: int | None = None) -> None:
        """Join an unsealed failed item's cleanup before accepting its successor."""

        item = self._asr_item
        if item is None or not item.terminal:
            return
        # The coordinator may report a create/connect/reader failure before
        # the caller commits. Its terminal precedes actual owner cleanup;
        # join that result instead of canceling teardown or reusing the item.
        with contextlib.suppress(Exception):
            await item.asr.commit()
        if item.reader is not None:
            await item.reader
            if self._asr_reader is item.reader:
                self._asr_reader = None
        await self._close_asr_session()
        item.pcm.clear()
        self._alignment_pcm = BoundedPcmBuffer(MAX_ALIGNMENT_PCM_BYTES)
        self._alignment_overflow = False
        self._turn_has_admitted_speech = False
        self._buffered_audio_bytes = 0
        self._last_partial_text = ""
        self._unflushed_bytes = 0
        self._item_start_sample = (
            self._wire_timeline.accepted_samples if next_wire_sample is None else next_wire_sample
        )
        self._item_end_sample = self._item_start_sample
        self._item_start_kernel = self._kernel_timeline.accepted_samples
        self._item_end_kernel = self._item_start_kernel
        self._reset_turn_observability()
        self._committed_input_generation = self._input_generation
        self._current_item_id = self._new_item_id()

    async def _discard_failed_commit(self) -> None:
        """Tear down a commit that will never finish.

        A failed commit (worker timeout/hang, dead pipe) must not leak the
        governor lane or the streaming factory slot: the next append has to be
        able to open a fresh ASR session.
        """

        with contextlib.suppress(Exception):
            if self._asr_lane is not None:
                await self._asr_lane.close()
                self._asr_lane = None
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

    async def clear(self) -> None:
        # Only unfrozen input is discarded without a terminal. A boundary
        # already published to the caller creates an obligation to finish
        # that item, even when its inference is canceled by clear.
        canceled_events = []
        for item in tuple(self._asr_closed_items.values()):
            if not item.terminal:
                item.terminal = True
                item.failure_code = "backend_error"
                canceled_events.append(
                    transcription_failed(
                        item_id=item.item_id,
                        code="backend_error",
                        message="streaming transcription canceled by input clear",
                        commit_event_id=item.commit_event_id,
                    )
                )
        empty_terminals = tuple(self._asr_empty_terminals.items())
        self._asr_empty_terminals.clear()
        for item_id, commit_event_id in empty_terminals:
            canceled_events.append(
                transcription_failed(
                    item_id=item_id,
                    code="backend_error",
                    message="streaming transcription canceled by input clear",
                    commit_event_id=commit_event_id,
                )
            )
        # Revoke all old barriers before yielding to a slow terminal send.
        # A naturally completed final must not win a receipt while clear waits.
        self._asr_generation += 1
        for event in canceled_events:
            await self._send(event)
        if self._asr_lane is not None:
            await self._asr_lane.close()
            self._asr_lane = None
        for final in tuple(self._asr_finals):
            final.cancel()
        if self._asr_finals:
            await asyncio.gather(*self._asr_finals, return_exceptions=True)
        self._asr_finals.clear()
        await self.auxiliary.cancel_alignment_tasks()
        self._asr_input_error = None
        self._asr_barrier_failure = None
        # Consume the canceled interpolation tail into the timeline only.
        # It must not leak into the next item's decoder input.
        tail = self._resampler.flush()
        if tail:
            self._kernel_timeline.accept(tail)
        if self._first_upstream_received_at is not None:
            self._record_first_hypothesis("cancelled")
        self._turn_generation += 1
        self._input_generation += 1
        self._turn_has_admitted_speech = False
        if self._speech_admission is not None:
            self._speech_admission.reset(next_sample=self._kernel_timeline.accepted_samples)
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
        await self.auxiliary.reset()
        self._buffered_audio_bytes = 0
        self._unflushed_bytes = 0
        self._last_partial_text = ""
        self._item_start_sample = self._wire_timeline.accepted_samples
        self._item_end_sample = self._wire_timeline.accepted_samples
        self._item_start_kernel = self._kernel_timeline.accepted_samples
        self._item_end_kernel = self._kernel_timeline.accepted_samples
        self._reset_turn_observability()
        self._current_item_id = self._new_item_id()

    def _completed_event(
        self, *, transcript: str, commit_event_id: str | None = None
    ) -> dict[str, object]:
        """Render the terminal completed event for the current ASR item."""
        return transcription_completed(
            item_id=self._current_item_id,
            transcript=transcript,
            commit_event_id=commit_event_id,
        )

    async def _drain_asr_events(self, item: _AsrItem) -> None:
        asr = item.asr
        try:
            async for event in asr.events():
                # Stop as soon as this session is no longer the current one
                # (superseded by barge-in, clear, or a commit): its remaining
                # events are stale. A generation counter cannot be used here —
                # a session opened by a rollover commit legitimately spans
                # later turn generations when speech re-activates on it.
                if item.generation != self._asr_generation or item.terminal:
                    break
                if event.kind == "partial":
                    current_text = apply_light_itn(event.text)
                    if item.first_partial is None:
                        item.first_partial = time.monotonic()
                    item.preview_revision += 1
                    decoded_end = item.end_wire
                    if event.sample_watermark is not None:
                        decoded_end = min(
                            item.end_wire,
                            self._to_wire_sample(item.start_kernel + event.sample_watermark),
                        )
                    hypothesis_sequence = await self._send(
                        transcription_hypothesis(
                            task_id=self._task_id,
                            epoch=self._wire_epoch,
                            utterance_id=item.item_id,
                            revision=item.preview_revision,
                            text=current_text,
                            sample_span=(item.start_wire, max(item.start_wire, decoded_end)),
                            stable_prefix_codepoints=0,
                        )
                    )
                    if hypothesis_sequence is None:
                        self._record_item_first_hypothesis(item, "send_failed")
                    else:
                        self._record_item_first_hypothesis(item, "partial")
                    self._ports.metrics.record_realtime_partial("snapshot_sent")
                elif event.kind == "completed":
                    # Claim before yielding to transport: clear must not
                    # append a second terminal while this one is being sent.
                    item.terminal = True
                    norm_text = apply_light_itn(event.text)
                    item.revision = max(1, item.preview_revision + 1)
                    self._record_item_first_hypothesis(item, "missing")
                    self._ports.metrics.record_realtime_turn(
                        mode="server_vad" if self._vad is not None else "manual",
                        commit_reason=item.close_reason or "client",
                        outcome="text" if norm_text else "empty",
                        characters=len(norm_text),
                        active_samples=max(0, item.end_wire - item.start_wire),
                        duration_seconds=(
                            max(0.0, time.monotonic() - item.commit_started)
                            if item.commit_started is not None
                            else 0.0
                        ),
                    )
                    if self.auxiliary.alignment_enabled or self.auxiliary.diarization_enabled:
                        item_id = item.item_id
                        item_start_sample = item.start_wire
                        item_end_sample = max(item.end_wire, item.start_wire)
                        item_start_kernel = item.start_kernel
                        item_end_kernel = max(item.end_kernel, item.start_kernel)
                        # Text final is deliberately independent from the slow
                        # auxiliary aligner.  Timing and speaker units travel in
                        # their own SpeechRail events.
                        await self._send(
                            transcription_completed(
                                item_id=item_id,
                                transcript=norm_text,
                                commit_event_id=item.commit_event_id,
                            )
                        )
                        item.terminal = True
                        self.auxiliary.start_alignment(
                            FrozenTranscript(
                                generation=self._asr_generation,
                                task_id=self._task_id,
                                epoch=self._wire_epoch,
                                item_id=item_id,
                                transcript=norm_text,
                                transcript_revision=item.revision,
                                item_start_wire=item_start_sample,
                                item_end_wire=item_end_sample,
                                item_start_kernel=item_start_kernel,
                                item_end_kernel=item_end_kernel,
                                pcm16=item.pcm.pin(),
                                overflow=item.overflow,
                                degraded_reason=self.auxiliary.degraded_reason,
                            )
                        )
                        item.pcm.clear()
                        item.overflow = False
                        continue
                    await self._send(
                        transcription_completed(
                            item_id=item.item_id,
                            transcript=norm_text,
                            commit_event_id=item.commit_event_id,
                        )
                    )
                    item.terminal = True
                elif event.kind == "error":
                    item.terminal = True
                    item.failure_code = event.error_code or "backend_error"
                    self._record_item_first_hypothesis(item, "failed")
                    await self._send(
                        transcription_failed(
                            item_id=item.item_id,
                            code=item.failure_code,
                            message="streaming transcription failed",
                            commit_event_id=item.commit_event_id,
                        )
                    )
                    item.terminal = True
        except asyncio.CancelledError:
            # The commit deadline cancels this reader while awaiting its
            # terminal event.  Swallowing that cancellation lets the commit
            # look successful without ever observing an ASR terminal.
            raise
        except WebSocketDisconnect:
            pass
        except Exception:
            # A dead reader must not die silently: the client would keep
            # believing ASR is alive and never see a terminal failure event.
            logger.exception("realtime ASR event reader failed")
            if not item.terminal and item.generation == self._asr_generation:
                item.terminal = True
                item.failure_code = "backend_error"
                with contextlib.suppress(Exception):
                    await self._send(
                        transcription_failed(
                            item_id=item.item_id,
                            code="backend_error",
                            message="streaming transcription failed",
                            commit_event_id=item.commit_event_id,
                        )
                    )

    def _record_item_first_hypothesis(self, item: _AsrItem, outcome: str) -> None:
        if item.first_recorded:
            return
        item.first_recorded = True
        now = time.monotonic()
        worker = item.first_partial
        self._ports.metrics.record_realtime_first_hypothesis(
            outcome,
            admitted_to_worker_seconds=(
                max(0.0, worker - item.admitted_at)
                if worker is not None and item.admitted_at is not None
                else None
            ),
            upstream_to_worker_seconds=(
                max(0.0, worker - item.first_upstream)
                if worker is not None and item.first_upstream is not None
                else None
            ),
            worker_to_socket_seconds=max(0.0, now - worker) if worker is not None else None,
            admitted_to_socket_seconds=(
                max(0.0, now - item.admitted_at) if item.admitted_at is not None else None
            ),
            admitted_audio_seconds=(
                max(0, item.end_wire - item.start_wire) / WIRE_SAMPLE_RATE
                if outcome == "partial"
                else None
            ),
        )

    async def _reserve_asr(self) -> None:
        self._asr_resources = AsyncExitStack()
        admission_started = time.monotonic()
        try:
            await self._asr_resources.enter_async_context(
                self._ports.governor.reserve(
                    WorkClass.REALTIME_ASR,
                    deadline=self._settings.request_timeout_seconds,
                    purpose=WorkPurpose.INTERACTIVE,
                )
            )
            self._ports.metrics.record_realtime_phase(
                "asr_admission", time.monotonic() - admission_started
            )
        except GovernorLaneIsolatedError as exc:
            await self._asr_resources.aclose()
            self._asr_resources = None
            raise RealtimeAdapterError(
                "backend_reclamation_failed",
                "Backend resources remain isolated until runtime recovery",
            ) from exc
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
        self._asr_item = None

    async def _stop_asr_reader(self) -> None:
        if self._asr_reader is None:
            return
        reader = self._asr_reader
        self._asr_reader = None
        if not reader.done():
            reader.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await reader
