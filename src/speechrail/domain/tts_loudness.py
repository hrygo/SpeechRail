"""Stateful loudness control for streamed PCM16 TTS output."""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Pcm16LoudnessConfig:
    """Boundaries for the clone-voice PCM16 loudness controller."""

    target_rms: float = 10 ** (-20 / 20)
    peak_ceiling: float = 10 ** (-1 / 20)
    silence_rms: float = 10 ** (-50 / 20)
    calibration_ms: int = 240
    attack_ms: int = 250
    release_ms: int = 800
    max_gain_db: float = 18.0
    max_attenuation_db: float = -6.0

    def __post_init__(self) -> None:
        for name in (
            "target_rms",
            "peak_ceiling",
            "silence_rms",
            "max_gain_db",
            "max_attenuation_db",
        ):
            value = getattr(self, name)
            if not math.isfinite(value):
                raise ValueError(f"{name} must be finite")
        if not 0.0 < self.target_rms <= 1.0:
            raise ValueError("target_rms must be between 0 and 1")
        if not 0.0 < self.peak_ceiling <= 1.0:
            raise ValueError("peak_ceiling must be between 0 and 1")
        if not 0.0 < self.silence_rms < self.target_rms:
            raise ValueError("silence_rms must be below target_rms")
        if self.calibration_ms <= 0:
            raise ValueError("calibration_ms must be positive")
        if self.attack_ms <= 0:
            raise ValueError("attack_ms must be positive")
        if self.release_ms <= 0:
            raise ValueError("release_ms must be positive")
        if self.max_gain_db < 0.0:
            raise ValueError("max_gain_db must be non-negative")
        if self.max_attenuation_db > 0.0:
            raise ValueError("max_attenuation_db must be non-positive")
        if self.max_attenuation_db > self.max_gain_db:
            raise ValueError("max_attenuation_db must not exceed max_gain_db")


class StreamingPcm16LoudnessController:
    """Normalize one PCM16 request without independently normalizing chunks.

    The controller keeps its gain state for the lifetime of a synthesis request.
    It uses a bounded calibration window, slow gain movement, and a downward
    RMS guard so a loud chunk cannot create a sudden playback spike while quiet
    or silent chunks are never amplified from noise.
    """

    _MAX_GAIN_TRANSITION_DB = 6.0

    def __init__(
        self,
        *,
        sample_rate: int,
        config: Pcm16LoudnessConfig | None = None,
    ) -> None:
        if sample_rate <= 0:
            raise ValueError("sample_rate must be positive")
        self._sample_rate = sample_rate
        self._config = config or Pcm16LoudnessConfig()
        self._calibration_samples = max(
            1,
            round(self._sample_rate * self._config.calibration_ms / 1000),
        )
        self.reset()

    def reset(self) -> None:
        """Clear all request-scoped state before the next synthesis request."""

        self._calibration_elapsed_samples = 0
        self._calibration_active_samples = 0
        self._calibration_sum_squares = 0.0
        self._calibration_gain_db: float | None = None
        self._current_gain_db: float | None = None
        self._peak_ceiling_count = 0

    def consume_stats(self) -> dict[str, int]:
        """Return low-cardinality request stats without exposing audio features."""

        stats: dict[str, int] = {}
        if self._calibration_gain_db is not None:
            stats["calibrated"] = 1
        if self._peak_ceiling_count:
            stats["peak_ceiling"] = self._peak_ceiling_count
        self._peak_ceiling_count = 0
        return stats

    def process(self, pcm: bytes) -> bytes:
        """Apply stateful loudness control to one little-endian PCM16 chunk."""

        if len(pcm) % 2:
            raise ValueError("PCM16 payload length must be even")
        if not pcm:
            return b""

        samples = struct.unpack(f"<{len(pcm) // 2}h", pcm)
        normalized = tuple(sample / 32768.0 for sample in samples)
        active = tuple(
            sample for sample in normalized if abs(sample) > self._config.silence_rms
        )
        self._advance_calibration(normalized)
        if not active:
            return pcm

        active_rms = math.sqrt(sum(sample * sample for sample in active) / len(active))
        desired_gain_db = self._bounded_gain_db(
            20.0 * math.log10(max(self._config.target_rms, 1e-12))
            - 20.0 * math.log10(max(active_rms, 1e-12))
        )
        previous_gain_db = self._current_gain_db
        if previous_gain_db is None:
            gain_start_db = (
                self._calibration_gain_db
                if self._calibration_gain_db is not None
                else desired_gain_db
            )
        else:
            slewed_gain_db = self._move_gain(
                previous_gain_db,
                desired_gain_db,
                len(normalized),
            )
            gain_start_db = min(
                desired_gain_db + self._MAX_GAIN_TRANSITION_DB,
                max(desired_gain_db - self._MAX_GAIN_TRANSITION_DB, slewed_gain_db),
            )
        gain_end_db = desired_gain_db
        self._current_gain_db = gain_end_db
        output = [
            sample
            * 10 ** (
                (gain_start_db + (gain_end_db - gain_start_db) * index / len(normalized))
                / 20.0
            )
            for index, sample in enumerate(normalized)
        ]
        output = self._apply_rms_window(output)
        output = self._apply_peak_ceiling(output)
        return self._encode(output)

    def _advance_calibration(self, samples: tuple[float, ...]) -> None:
        if self._calibration_elapsed_samples >= self._calibration_samples:
            return
        remaining = self._calibration_samples - self._calibration_elapsed_samples
        window = samples[:remaining]
        for sample in window:
            if abs(sample) > self._config.silence_rms:
                self._calibration_active_samples += 1
                self._calibration_sum_squares += sample * sample
        self._calibration_elapsed_samples += len(samples)
        if (
            self._calibration_elapsed_samples >= self._calibration_samples
            and self._calibration_active_samples > 0
        ):
            reference_rms = math.sqrt(
                self._calibration_sum_squares / self._calibration_active_samples
            )
            target_db = 20.0 * math.log10(max(self._config.target_rms, 1e-12))
            reference_db = 20.0 * math.log10(max(reference_rms, 1e-12))
            self._calibration_gain_db = self._bounded_gain_db(target_db - reference_db)

    def _bounded_gain_db(self, gain_db: float) -> float:
        return min(
            self._config.max_gain_db,
            max(self._config.max_attenuation_db, gain_db),
        )

    def _move_gain(self, current_db: float, desired_db: float, samples: int) -> float:
        duration_ms = samples * 1000.0 / self._sample_rate
        time_constant_ms = (
            self._config.attack_ms if desired_db < current_db else self._config.release_ms
        )
        alpha = 1.0 - math.exp(-duration_ms / time_constant_ms)
        return current_db + (desired_db - current_db) * alpha

    def _apply_rms_window(self, samples: list[float]) -> list[float]:
        active = tuple(sample for sample in samples if abs(sample) > self._config.silence_rms)
        if not active:
            return samples
        rms = math.sqrt(sum(sample * sample for sample in active) / len(active))
        min_rms = self._config.target_rms / math.sqrt(2.0)
        max_rms = min(self._config.target_rms * math.sqrt(2.0), self._config.peak_ceiling)
        if min_rms <= rms <= max_rms:
            return samples
        scale = (
            min(min_rms / rms, 10 ** (6.0 / 20.0))
            if rms < min_rms
            else max_rms / rms
        )
        return [sample * scale for sample in samples]

    def _apply_peak_ceiling(self, samples: list[float]) -> list[float]:
        peak = max((abs(sample) for sample in samples), default=0.0)
        if peak <= self._config.peak_ceiling:
            return samples
        self._peak_ceiling_count += 1
        scale = self._config.peak_ceiling / peak
        return [sample * scale for sample in samples]

    @staticmethod
    def _encode(samples: list[float]) -> bytes:
        encoded = tuple(
            max(-32768, min(32767, round(sample * 32768.0))) for sample in samples
        )
        return struct.pack(f"<{len(encoded)}h", *encoded)
