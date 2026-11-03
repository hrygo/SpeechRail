"""Bounded voice activity admission state machine for Realtime server_vad.

Controls speech admission to prevent unbounded silence and noise from entering
ASR inference while preserving real short utterances, session timestamps, and EOF.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Literal


@dataclass(frozen=True)
class AdmissionDecision:
    """Decision event emitted by SpeechAdmission during stream processing."""

    kind: Literal["start", "audio", "end"]
    start_sample: int
    end_sample: int
    pcm: bytes = b""


class SpeechAdmission:
    """Deterministic, bounded speech admission state machine.

    States:
        IDLE -> CANDIDATE -> ACTIVE -> HANGOVER -> IDLE

    - IDLE: collects pre-roll PCM in a ring buffer. No ASR admission.
    - CANDIDATE: speech frames detected, debouncing confirmation window.
                 If unconfirmed, drops back to IDLE without admitting audio.
    - ACTIVE: confirmed speech. Emits start decision, pre-roll + speech audio,
              and continuous subsequent audio frames.
    - HANGOVER: silence after active speech. Keeps emitting audio to preserve
                word endings. If silence reaches stop_frames, emits end decision.

    Decision hysteresis mirrors Silero's official VADIterator: onset frames
    must clear the entry ``threshold`` while an utterance in progress only
    yields to frames below ``stop_threshold`` (default ``threshold - 0.15``),
    so mid-word probability dips do not chop the utterance.
    """

    PUNCTUATION_HINT_TTL_SAMPLES = 8_000

    def __init__(
        self,
        *,
        threshold: float = 0.5,
        stop_threshold: float | None = None,
        start_frames: int = 3,
        stop_frames: int = 12,
        prefix_samples: int = 4800,
        frame_samples: int = 512,
        sample_rate: int = 16_000,
        soft_max_samples: int | None = None,
        soft_stop_frames: int | None = None,
        terminal_stop_frames: int | None = None,
        clause_stop_frames: int | None = None,
    ) -> None:
        if threshold < 0.0 or threshold > 1.0:
            raise ValueError("threshold must be between 0.0 and 1.0")
        if stop_threshold is None:
            stop_threshold = max(0.0, threshold - 0.15)
        if not 0.0 <= stop_threshold <= threshold:
            raise ValueError("stop_threshold must be between 0.0 and threshold")
        if start_frames < 1:
            raise ValueError("start_frames must be >= 1")
        if stop_frames < 1:
            raise ValueError("stop_frames must be >= 1")
        if frame_samples < 1:
            raise ValueError("frame_samples must be >= 1")
        if prefix_samples < 0:
            raise ValueError("prefix_samples must be >= 0")
        if soft_max_samples is not None and soft_max_samples < 1:
            raise ValueError("soft_max_samples must be >= 1")
        if soft_stop_frames is not None and soft_stop_frames < 1:
            raise ValueError("soft_stop_frames must be >= 1")
        if terminal_stop_frames is not None and terminal_stop_frames < 1:
            raise ValueError("terminal_stop_frames must be >= 1")
        if clause_stop_frames is not None and clause_stop_frames < 1:
            raise ValueError("clause_stop_frames must be >= 1")

        self._threshold = threshold
        self._stop_threshold = stop_threshold
        self._start_frames = start_frames
        self._stop_frames = stop_frames
        self._frame_samples = frame_samples
        self._frame_bytes = frame_samples * 2  # 16-bit PCM mono
        self._sample_rate = sample_rate
        self._soft_max_samples = soft_max_samples
        self._soft_stop_frames = soft_stop_frames
        self._terminal_stop_frames = terminal_stop_frames
        self._clause_stop_frames = clause_stop_frames

        # Bounded pre-roll ring buffer in frames
        max_prefix_frames = max(1, (prefix_samples + frame_samples - 1) // frame_samples)
        self._max_prefix_frames = max_prefix_frames
        # Ring buffer holds tuple: (sample_offset, frame_bytes)
        self._prefix_ring: deque[tuple[int, bytes]] = deque(maxlen=max_prefix_frames)

        # Candidate buffer for debouncing: list of (sample_offset, frame_bytes)
        self._candidate_frames: list[tuple[int, bytes]] = []

        # Stream leftover bytes for sub-frame handling
        self._leftover_pcm = bytearray()
        self._leftover_sample_offset = 0

        # State tracking
        self._state: Literal["IDLE", "CANDIDATE", "ACTIVE", "HANGOVER"] = "IDLE"
        self._hangover_count = 0
        self._current_utterance_start_sample = 0
        self._last_emitted_sample = 0
        self._hint_kind: Literal["terminal", "clause"] | None = None
        self._hint_watermark: int | None = None
        self._last_speech_frame_end = 0
        self._soft_zone_flush_pending = False
        self._soft_zone_flush_triggered_in_hangover = False

    @property
    def state(self) -> Literal["IDLE", "CANDIDATE", "ACTIVE", "HANGOVER"]:
        return self._state

    @property
    def threshold(self) -> float:
        """Entry threshold: onset frames must reach this probability."""
        return self._threshold

    @property
    def stop_threshold(self) -> float:
        """Exit threshold: an active utterance yields below this probability."""
        return self._stop_threshold

    @property
    def retained_from_sample(self) -> int:
        """Earliest sample that may still be admitted, including failed onset."""
        retained = [sample for sample, _ in self._prefix_ring]
        retained.extend(sample for sample, _ in self._candidate_frames)
        if self._leftover_pcm:
            retained.append(self._leftover_sample_offset)
        return min(retained, default=self._last_emitted_sample)

    def _clear_punctuation_hint(self, *, baseline_sample: int = 0) -> None:
        self._hint_kind = None
        self._hint_watermark = None
        self._last_speech_frame_end = baseline_sample
        self._soft_zone_flush_pending = False
        self._soft_zone_flush_triggered_in_hangover = False

    def consume_soft_zone_flush_request(self) -> bool:
        """Return True once per hangover episode when a soft-zone partial flush is needed."""
        if not self._soft_zone_flush_pending:
            return False
        self._soft_zone_flush_pending = False
        return True

    def reset(self, *, next_sample: int = 0) -> None:
        """Reset internal buffers and state machine to IDLE."""
        self._prefix_ring.clear()
        self._candidate_frames.clear()
        self._leftover_pcm.clear()
        self._leftover_sample_offset = next_sample
        self._state = "IDLE"
        self._hangover_count = 0
        self._current_utterance_start_sample = next_sample
        self._last_emitted_sample = next_sample
        self._clear_punctuation_hint(baseline_sample=next_sample)

    def advance_segment_start(self, sample_offset: int) -> None:
        """Advance the current segment origin after an external budget rollover."""
        if sample_offset > self._current_utterance_start_sample:
            self._current_utterance_start_sample = sample_offset
        self._hangover_count = 0
        self._clear_punctuation_hint(
            baseline_sample=max(self._last_speech_frame_end, self._current_utterance_start_sample)
        )

    def set_punctuation_boundary_hint(
        self,
        kind: Literal["terminal", "clause"] | None,
        *,
        sample_watermark: int | None,
    ) -> None:
        """Update the latest ASR partial punctuation boundary hint with kernel watermark."""
        if kind not in (None, "terminal", "clause"):
            raise ValueError("kind must be 'terminal', 'clause', or None")
        if self._state not in ("ACTIVE", "HANGOVER"):
            self._hint_kind = None
            self._hint_watermark = None
            return
        if sample_watermark is None or isinstance(sample_watermark, bool):
            self._hint_kind = None
            self._hint_watermark = None
            return
        if (
            sample_watermark <= self._current_utterance_start_sample
            or sample_watermark > self._last_emitted_sample
        ):
            self._hint_kind = None
            self._hint_watermark = None
            return
        if self._hint_watermark is not None and sample_watermark < self._hint_watermark:
            return
        self._hint_watermark = sample_watermark
        self._hint_kind = kind
        if sample_watermark >= self._last_speech_frame_end:
            self._soft_zone_flush_pending = False

    def _in_soft_watermark_zone(self, frame_end_sample: int) -> bool:
        return (
            self._soft_max_samples is not None
            and (frame_end_sample - self._current_utterance_start_sample) >= self._soft_max_samples
        )

    def _effective_stop_threshold(self, frame_end_sample: int) -> float:
        if self._in_soft_watermark_zone(frame_end_sample):
            return (self._threshold + self._stop_threshold) / 2.0
        return self._stop_threshold

    def _active_punctuation_hint(
        self, frame_end_sample: int
    ) -> Literal["terminal", "clause"] | None:
        if self._state not in ("ACTIVE", "HANGOVER"):
            return None
        if self._hint_kind is None or self._hint_watermark is None:
            return None
        if (
            self._hint_watermark <= self._current_utterance_start_sample
            or self._hint_watermark > frame_end_sample
        ):
            return None
        age = frame_end_sample - self._hint_watermark
        if age < 0 or age > self.PUNCTUATION_HINT_TTL_SAMPLES:
            return None
        if self._hint_watermark < self._last_speech_frame_end:
            return None
        return self._hint_kind

    def _effective_stop_frames(self, frame_end_sample: int) -> int:
        if not self._in_soft_watermark_zone(frame_end_sample):
            return self._stop_frames
        soft_frames = (
            min(self._stop_frames, self._soft_stop_frames)
            if self._soft_stop_frames is not None
            else self._stop_frames
        )
        clause_frames = (
            min(soft_frames, self._clause_stop_frames)
            if self._clause_stop_frames is not None
            else soft_frames
        )
        terminal_frames = (
            min(clause_frames, self._terminal_stop_frames)
            if self._terminal_stop_frames is not None
            else clause_frames
        )
        hint = self._active_punctuation_hint(frame_end_sample)
        if hint == "terminal" and self._terminal_stop_frames is not None:
            return terminal_frames
        if hint == "clause" and self._clause_stop_frames is not None:
            return clause_frames
        return soft_frames

    def push(
        self,
        pcm: bytes,
        *,
        start_sample: int,
        probability: float,
    ) -> tuple[AdmissionDecision, ...]:
        """Push arbitrary PCM chunk with speech probability score."""
        if not pcm:
            return ()
        if len(pcm) % 2 != 0:
            raise ValueError("PCM chunk must contain an even number of bytes (16-bit PCM)")

        if not self._leftover_pcm:
            self._leftover_sample_offset = start_sample
        self._leftover_pcm.extend(pcm)

        decisions: list[AdmissionDecision] = []

        while len(self._leftover_pcm) >= self._frame_bytes:
            frame_bytes = bytes(self._leftover_pcm[: self._frame_bytes])
            frame_sample = self._leftover_sample_offset
            del self._leftover_pcm[: self._frame_bytes]
            self._leftover_sample_offset += self._frame_samples

            frame_decisions = self._process_frame(
                frame_bytes,
                sample_offset=frame_sample,
                probability=probability,
            )
            decisions.extend(frame_decisions)

        return tuple(decisions)

    def _process_frame(
        self,
        frame: bytes,
        *,
        sample_offset: int,
        probability: float,
    ) -> list[AdmissionDecision]:
        frame_end_sample = sample_offset + self._frame_samples
        # Dual-threshold hysteresis: onset confirmation uses the entry
        # threshold; an utterance in progress only yields below the lower
        # exit threshold (see class docstring).
        if self._state in ("ACTIVE", "HANGOVER"):
            is_speech = probability >= self._effective_stop_threshold(frame_end_sample)
        else:
            is_speech = probability >= self._threshold
        decisions: list[AdmissionDecision] = []

        if self._state == "IDLE":
            if is_speech:
                if self._start_frames == 1:
                    # Single frame confirmation -> direct ACTIVE
                    decisions.extend(self._activate(frame, sample_offset=sample_offset))
                else:
                    self._state = "CANDIDATE"
                    self._candidate_frames.append((sample_offset, frame))
            else:
                self._prefix_ring.append((sample_offset, frame))

        elif self._state == "CANDIDATE":
            if is_speech:
                self._candidate_frames.append((sample_offset, frame))
                if len(self._candidate_frames) >= self._start_frames:
                    # Debounce passed! Activate with prefix + candidate frames
                    decisions.extend(self._activate_from_candidate())
            else:
                # Failed debounce: spurious noise / transient -> discard candidate
                for c_sample, c_frame in self._candidate_frames:
                    self._prefix_ring.append((c_sample, c_frame))
                self._candidate_frames.clear()
                self._prefix_ring.append((sample_offset, frame))
                self._state = "IDLE"

        elif self._state == "ACTIVE":
            if is_speech:
                self._hangover_count = 0
                self._last_speech_frame_end = frame_end_sample
                self._soft_zone_flush_pending = False
                self._soft_zone_flush_triggered_in_hangover = False
                decisions.append(
                    AdmissionDecision(
                        kind="audio",
                        start_sample=sample_offset,
                        end_sample=frame_end_sample,
                        pcm=frame,
                    )
                )
                self._last_emitted_sample = frame_end_sample
            else:
                self._state = "HANGOVER"
                self._hangover_count = 1
                self._soft_zone_flush_pending = False
                self._soft_zone_flush_triggered_in_hangover = False
                decisions.append(
                    AdmissionDecision(
                        kind="audio",
                        start_sample=sample_offset,
                        end_sample=frame_end_sample,
                        pcm=frame,
                    )
                )
                self._last_emitted_sample = frame_end_sample
                if self._hangover_count >= self._effective_stop_frames(frame_end_sample):
                    decisions.append(self._close_active(frame_end_sample))

        elif self._state == "HANGOVER":
            if is_speech:
                self._state = "ACTIVE"
                self._hangover_count = 0
                self._last_speech_frame_end = frame_end_sample
                self._soft_zone_flush_pending = False
                self._soft_zone_flush_triggered_in_hangover = False
                decisions.append(
                    AdmissionDecision(
                        kind="audio",
                        start_sample=sample_offset,
                        end_sample=frame_end_sample,
                        pcm=frame,
                    )
                )
                self._last_emitted_sample = frame_end_sample
            else:
                self._hangover_count += 1
                decisions.append(
                    AdmissionDecision(
                        kind="audio",
                        start_sample=sample_offset,
                        end_sample=frame_end_sample,
                        pcm=frame,
                    )
                )
                self._last_emitted_sample = frame_end_sample
                if (
                    self._hangover_count >= 2
                    and not self._soft_zone_flush_triggered_in_hangover
                    and self._in_soft_watermark_zone(frame_end_sample)
                    and (
                        self._hint_watermark is None
                        or self._hint_watermark < self._last_speech_frame_end
                    )
                ):
                    self._soft_zone_flush_pending = True
                    self._soft_zone_flush_triggered_in_hangover = True
                if self._hangover_count >= self._effective_stop_frames(frame_end_sample):
                    decisions.append(self._close_active(frame_end_sample))

        if self._state in ("IDLE", "CANDIDATE"):
            self._last_emitted_sample = max(self._last_emitted_sample, frame_end_sample)
        return decisions

    def _activate(self, frame: bytes, *, sample_offset: int) -> list[AdmissionDecision]:
        """Direct activation for single-frame start."""
        pre_pcm_list: list[bytes] = []
        if self._prefix_ring:
            first_pre_sample = self._prefix_ring[0][0]
            for _, p_bytes in self._prefix_ring:
                pre_pcm_list.append(p_bytes)
        else:
            first_pre_sample = sample_offset

        self._prefix_ring.clear()
        self._state = "ACTIVE"
        self._hangover_count = 0
        self._current_utterance_start_sample = first_pre_sample
        frame_end_sample = sample_offset + self._frame_samples
        self._clear_punctuation_hint(baseline_sample=frame_end_sample)

        all_pcm = b"".join(pre_pcm_list) + frame
        self._last_emitted_sample = frame_end_sample

        return [
            AdmissionDecision(
                kind="start",
                start_sample=first_pre_sample,
                end_sample=frame_end_sample,
            ),
            AdmissionDecision(
                kind="audio",
                start_sample=first_pre_sample,
                end_sample=frame_end_sample,
                pcm=all_pcm,
            ),
        ]

    def _activate_from_candidate(self) -> list[AdmissionDecision]:
        """Activate from debounced candidate frames."""
        pre_pcm_list: list[bytes] = []
        if self._prefix_ring:
            first_pre_sample = self._prefix_ring[0][0]
            for _, p_bytes in self._prefix_ring:
                pre_pcm_list.append(p_bytes)
        elif self._candidate_frames:
            first_pre_sample = self._candidate_frames[0][0]
        else:
            first_pre_sample = self._last_emitted_sample

        self._prefix_ring.clear()
        cand_pcm_list = [f for _, f in self._candidate_frames]
        last_cand_sample = self._candidate_frames[-1][0] + self._frame_samples
        self._candidate_frames.clear()

        self._state = "ACTIVE"
        self._hangover_count = 0
        self._current_utterance_start_sample = first_pre_sample
        self._last_emitted_sample = last_cand_sample
        self._clear_punctuation_hint(baseline_sample=last_cand_sample)

        all_pcm = b"".join(pre_pcm_list) + b"".join(cand_pcm_list)

        return [
            AdmissionDecision(
                kind="start",
                start_sample=first_pre_sample,
                end_sample=last_cand_sample,
            ),
            AdmissionDecision(
                kind="audio",
                start_sample=first_pre_sample,
                end_sample=last_cand_sample,
                pcm=all_pcm,
            ),
        ]

    def _close_active(self, end_sample: int) -> AdmissionDecision:
        """Close the active utterance and return end decision."""
        start_sample = self._current_utterance_start_sample
        self._state = "IDLE"
        self._hangover_count = 0
        self._clear_punctuation_hint(baseline_sample=end_sample)
        return AdmissionDecision(
            kind="end",
            start_sample=start_sample,
            end_sample=end_sample,
        )

    def finish(self) -> tuple[AdmissionDecision, ...]:
        """Finish stream (EOF).

        Flushes any active utterance or candidate state.
        Subsequent calls return an empty tuple.
        """
        decisions: list[AdmissionDecision] = []

        if self._state in ("ACTIVE", "HANGOVER"):
            # If sub-frame leftover exists, emit it as audio
            if self._leftover_pcm:
                rem_bytes = bytes(self._leftover_pcm)
                rem_samples = len(rem_bytes) // 2
                start_s = self._last_emitted_sample
                end_s = start_s + rem_samples
                self._leftover_pcm.clear()
                decisions.append(
                    AdmissionDecision(
                        kind="audio",
                        start_sample=start_s,
                        end_sample=end_s,
                        pcm=rem_bytes,
                    )
                )
                self._last_emitted_sample = end_s
            decisions.append(self._close_active(self._last_emitted_sample))

        elif self._state == "CANDIDATE":
            # Unconfirmed speech at EOF is discarded
            self._candidate_frames.clear()
            self._state = "IDLE"

        self._leftover_pcm.clear()
        return tuple(decisions)


__all__ = ["AdmissionDecision", "SpeechAdmission"]
