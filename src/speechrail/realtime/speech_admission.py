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

        self._threshold = threshold
        self._stop_threshold = stop_threshold
        self._start_frames = start_frames
        self._stop_frames = stop_frames
        self._frame_samples = frame_samples
        self._frame_bytes = frame_samples * 2  # 16-bit PCM mono
        self._sample_rate = sample_rate

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
        # Dual-threshold hysteresis: onset confirmation uses the entry
        # threshold; an utterance in progress only yields below the lower
        # exit threshold (see class docstring).
        if self._state in ("ACTIVE", "HANGOVER"):
            is_speech = probability >= self._stop_threshold
        else:
            is_speech = probability >= self._threshold
        frame_end_sample = sample_offset + self._frame_samples
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
                decisions.append(
                    AdmissionDecision(
                        kind="audio",
                        start_sample=sample_offset,
                        end_sample=frame_end_sample,
                        pcm=frame,
                    )
                )
                self._last_emitted_sample = frame_end_sample
                if self._hangover_count >= self._stop_frames:
                    decisions.append(self._close_active(frame_end_sample))

        elif self._state == "HANGOVER":
            if is_speech:
                self._state = "ACTIVE"
                self._hangover_count = 0
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
                if self._hangover_count >= self._stop_frames:
                    decisions.append(self._close_active(frame_end_sample))

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
