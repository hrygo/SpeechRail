"""Real-time Voice Activity Detection (VAD) and boundary detector for full-duplex Barge-in."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import math
import numpy as np


@dataclass(frozen=True)
class VadConfig:
    """Configuration for server-side VAD and Barge-in boundary detection."""

    threshold: float = 0.5
    prefix_padding_ms: int = 300
    silence_duration_ms: int = 400
    debounce_frames: int = 3
    sample_rate: int = 16_000
    frame_samples: int = 512  # 32ms at 16kHz (1024 bytes PCM16)


@dataclass(frozen=True)
class VadEvent:
    """Speech boundary event emitted during stream processing."""

    is_speech: bool
    speech_started: bool
    speech_ended: bool
    audio_start_ms: int = 0
    audio_end_ms: int = 0
    pre_speech_audio: bytes = b""


class VoiceActivityDetector:
    """Stateful, debounced stream VAD with pre-speech prefix buffering."""

    def __init__(self, config: VadConfig | None = None) -> None:
        self._config = config or VadConfig()
        self._bytes_per_frame = self._config.frame_samples * 2  # 16-bit mono
        self._frame_duration_ms = int(
            (self._config.frame_samples / self._config.sample_rate) * 1000
        )

        # Buffering
        self._raw_buffer = bytearray()
        max_prefix_frames = max(1, self._config.prefix_padding_ms // self._frame_duration_ms)
        self._prefix_ring: deque[bytes] = deque(maxlen=max_prefix_frames)

        # State tracking
        self._in_speech = False
        self._speech_debounce_count = 0
        self._silence_frame_count = 0
        self._total_processed_ms = 0
        self._speech_start_ms = 0

    @property
    def in_speech(self) -> bool:
        return self._in_speech

    def reset(self) -> None:
        """Reset internal buffers and state machine."""
        self._raw_buffer.clear()
        self._prefix_ring.clear()
        self._in_speech = False
        self._speech_debounce_count = 0
        self._silence_frame_count = 0
        self._total_processed_ms = 0
        self._speech_start_ms = 0

    def process_chunk(self, pcm_chunk: bytes) -> list[VadEvent]:
        """Process arbitrary length PCM16 chunk and return any boundary events."""
        if not pcm_chunk:
            return []
        self._raw_buffer.extend(pcm_chunk)
        events: list[VadEvent] = []

        while len(self._raw_buffer) >= self._bytes_per_frame:
            frame = bytes(self._raw_buffer[: self._bytes_per_frame])
            del self._raw_buffer[: self._bytes_per_frame]

            event = self._process_single_frame(frame)
            if event is not None:
                events.append(event)

        return events

    def _process_single_frame(self, frame: bytes) -> VadEvent | None:
        self._total_processed_ms += self._frame_duration_ms
        prob = self._score_frame(frame)
        is_active = prob >= self._config.threshold

        if is_active:
            self._silence_frame_count = 0
            if not self._in_speech:
                self._speech_debounce_count += 1
                if self._speech_debounce_count >= self._config.debounce_frames:
                    self._in_speech = True
                    self._speech_start_ms = max(
                        0, self._total_processed_ms - (self._config.debounce_frames * self._frame_duration_ms)
                    )
                    pre_audio = b"".join(self._prefix_ring)
                    return VadEvent(
                        is_speech=True,
                        speech_started=True,
                        speech_ended=False,
                        audio_start_ms=self._speech_start_ms,
                        audio_end_ms=self._total_processed_ms,
                        pre_speech_audio=pre_audio,
                    )
            else:
                return VadEvent(
                    is_speech=True,
                    speech_started=False,
                    speech_ended=False,
                    audio_start_ms=self._speech_start_ms,
                    audio_end_ms=self._total_processed_ms,
                )
        else:
            self._speech_debounce_count = 0
            if self._in_speech:
                self._silence_frame_count += 1
                silence_ms = self._silence_frame_count * self._frame_duration_ms
                if silence_ms >= self._config.silence_duration_ms:
                    self._in_speech = False
                    speech_end_ms = self._total_processed_ms
                    self._silence_frame_count = 0
                    return VadEvent(
                        is_speech=False,
                        speech_started=False,
                        speech_ended=True,
                        audio_start_ms=self._speech_start_ms,
                        audio_end_ms=speech_end_ms,
                    )
            else:
                # Add idle silent frame to prefix ring buffer
                self._prefix_ring.append(frame)

        return None

    def _score_frame(self, frame: bytes) -> float:
        """Calculate speech probability score using normalized RMS energy & zero-crossing."""
        if len(frame) < 2:
            return 0.0
        samples = np.frombuffer(frame, dtype="<i2").astype(np.float32)
        if len(samples) == 0:
            return 0.0

        # Normalized RMS (range ~ [0.0, 1.0])
        rms = float(np.sqrt(np.mean(samples**2)))
        # Zero-crossing rate
        zero_crossings = float(np.sum(np.abs(np.diff(np.signbit(samples))))) / len(samples)

        # Baseline noise floor threshold around RMS 120 (~ -46 dBFS)
        if rms < 120:
            return 0.0
        
        # Sigmoid scoring
        energy_score = 1.0 / (1.0 + math.exp(-((rms - 250.0) / 100.0)))
        # Speech typical zero crossings fall between 0.01 and 0.50
        zc_weight = 1.0 if (0.01 <= zero_crossings <= 0.50) else 0.4

        return float(np.clip(energy_score * zc_weight, 0.0, 1.0))


__all__ = ["VadConfig", "VadEvent", "VoiceActivityDetector"]
