"""Stateful loudness control for streamed PCM16 TTS output."""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass
from statistics import median


@dataclass(frozen=True, slots=True)
class Pcm16LoudnessConfig:
    """Boundaries for the clone-voice PCM16 loudness controller."""

    target_rms: float = 10 ** (-20 / 20)
    peak_ceiling: float = 10 ** (-1 / 20)
    silence_rms: float = 10 ** (-60 / 20)
    calibration_ms: int = 200
    attack_ms: int = 250
    release_ms: int = 800
    max_gain_db: float = 18.0
    max_attenuation_db: float = -6.0
    limiter_release_ms: int = 100

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
        for name in ("calibration_ms", "attack_ms", "release_ms", "limiter_release_ms"):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                raise ValueError(f"{name} must be a positive integer")
        if self.max_gain_db < 0.0:
            raise ValueError("max_gain_db must be non-negative")
        if self.max_attenuation_db > 0.0:
            raise ValueError("max_attenuation_db must be non-positive")
        if self.max_attenuation_db > self.max_gain_db:
            raise ValueError("max_attenuation_db must not exceed max_gain_db")


class StreamingPcm16LoudnessController:
    """Normalize one PCM16 request without independently normalizing chunks.

    The legacy dynamic mode retains its RMS-window policy. Frozen clone mode
    measures complete media-time frames, waits for credible calibration, then
    ramps to a fixed request gain. Its sample-peak limiter attacks immediately
    and releases across calls: no block-wide attenuation or noise-gate toggle.
    This causal policy adds no audio buffering and is not a true-peak limiter.
    """

    _MAX_GAIN_TRANSITION_DB = 6.0
    # A median needs more than one sample: require several eligible frames so a
    # misconfigured sub-frame calibration_ms cannot lock from a single frame.
    _MIN_CALIBRATION_FRAMES = 3

    def __init__(
        self,
        *,
        sample_rate: int,
        config: Pcm16LoudnessConfig | None = None,
        freeze_gain_after_calibration: bool = False,
    ) -> None:
        if isinstance(sample_rate, bool) or not isinstance(sample_rate, int) or sample_rate <= 0:
            raise ValueError("sample_rate must be positive")
        self._sample_rate = sample_rate
        self._config = config or Pcm16LoudnessConfig()
        self._freeze_gain_after_calibration = freeze_gain_after_calibration
        self._calibration_samples = max(
            1,
            round(self._sample_rate * self._config.calibration_ms / 1000),
        )
        # These private media-time constants do not depend on transport chunks.
        self._analysis_samples = max(1, round(sample_rate * 0.010))
        self._calibration_wait_samples = max(sample_rate, self._calibration_samples * 5)
        self._gain_ramp_alpha = 1.0 - math.exp(-1.0 / (sample_rate * 0.020))
        self._limiter_release_decay = math.exp(
            -1000.0 / (sample_rate * self._config.limiter_release_ms)
        )
        self.reset()

    def reset(self) -> None:
        """Clear all request-scoped state before the next synthesis request."""

        self._calibration_elapsed_samples = 0
        self._calibration_active_samples = 0
        self._calibration_sum_squares = 0.0
        self._calibration_gain_db: float | None = None
        self._calibration_applied = False
        self._current_gain_db: float | None = None
        self._peak_ceiling_count = 0
        self._frozen_state = "waiting"
        self._frozen_frame_samples = 0
        self._frozen_frame_active = 0
        self._frozen_frame_energy = 0.0
        self._frozen_frame_powers: list[float] = []
        self._frozen_wait_samples = 0
        self._frozen_applied_gain_db = 0.0
        self._frozen_limiter_gain = 1.0

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
        if self._freeze_gain_after_calibration:
            return self._process_frozen(normalized)
        active = tuple(
            sample for sample in normalized if abs(sample) > self._config.silence_rms
        )
        self._advance_calibration(normalized)
        if not active:
            return pcm

        chunk_rms = math.sqrt(sum(sample * sample for sample in normalized) / len(normalized))
        desired_gain_db = self._bounded_gain_db(
            20.0 * math.log10(max(self._config.target_rms, 1e-12))
            - 20.0 * math.log10(max(chunk_rms, 1e-12))
        )
        if (
            self._calibration_gain_db is not None
            and not self._calibration_applied
            and self._current_gain_db is None
        ):
            desired_gain_db = self._calibration_gain_db
            self._calibration_applied = True
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

    def _observe_frozen_sample(self, sample: float) -> None:
        """Collect bounded frame statistics, never retaining source PCM.

        A frame needs RMS above the gate AND at least 20% above-gate samples.
        This rejects isolated impulses, not all non-speech noise. The first
        eligible frame starts a bounded collection deadline; leading silence
        cannot exhaust calibration. Median frame power limits transient bias.
        """
        if self._current_gain_db is not None:
            return
        self._frozen_frame_samples += 1
        self._frozen_frame_energy += sample * sample
        if abs(sample) > self._config.silence_rms:
            self._frozen_frame_active += 1
        if self._frozen_frame_samples < self._analysis_samples:
            return

        count = self._frozen_frame_samples
        power = self._frozen_frame_energy / count
        eligible = (
            self._frozen_frame_active >= max(2, math.ceil(count * 0.20))
            and power > self._config.silence_rms ** 2
        )
        if eligible:
            self._frozen_state = "collecting"
            self._frozen_frame_powers.append(power)
            self._calibration_active_samples += count
        if self._frozen_state == "collecting":
            self._frozen_wait_samples += count
            self._calibration_elapsed_samples = self._frozen_wait_samples
        if (
            self._calibration_active_samples >= self._calibration_samples
            and len(self._frozen_frame_powers) >= self._MIN_CALIBRATION_FRAMES
        ):
            reference_rms = math.sqrt(median(self._frozen_frame_powers))
            self._calibration_gain_db = self._bounded_gain_db(
                20.0 * math.log10(self._config.target_rms / reference_rms)
            )
            self._current_gain_db = self._calibration_gain_db
            self._calibration_applied = True
            self._frozen_state = "calibrated"
        elif self._frozen_wait_samples >= self._calibration_wait_samples:
            # Too little credible signal: stay at unity instead of boosting
            # a sparse/noisy onset. Short requests also remain at unity.
            self._current_gain_db = 0.0
            self._frozen_state = "fallback"
        self._frozen_frame_samples = 0
        self._frozen_frame_active = 0
        self._frozen_frame_energy = 0.0

    def _process_frozen(self, samples: tuple[float, ...]) -> bytes:
        """Causal, partition-invariant gain and cross-call peak release.

        No lookahead is available with the length-preserving process contract.
        Attack must therefore be immediate to guarantee sample-peak safety;
        release is smooth. Transient distortion and initial unity-gain audio
        require real-model/listening acceptance, not just unit-test approval.
        """
        encoded: list[int] = []
        ceiling = self._config.peak_ceiling
        integer_ceiling = math.floor(ceiling * 32768.0)
        limited = False
        for sample in samples:
            self._observe_frozen_sample(sample)
            target_db = self._current_gain_db if self._current_gain_db is not None else 0.0
            self._frozen_applied_gain_db += (
                target_db - self._frozen_applied_gain_db
            ) * self._gain_ramp_alpha
            value = sample * 10 ** (self._frozen_applied_gain_db / 20.0)
            required_gain = min(1.0, ceiling / abs(value)) if value else 1.0
            released_gain = 1.0 - (
                1.0 - self._frozen_limiter_gain
            ) * self._limiter_release_decay
            self._frozen_limiter_gain = min(required_gain, released_gain)
            limited = limited or required_gain < 1.0
            encoded.append(max(
                -32768,
                -integer_ceiling,
                min(32767, integer_ceiling, round(value * self._frozen_limiter_gain * 32768.0)),
            ))
        if limited:
            self._peak_ceiling_count += 1
        return struct.pack(f"<{len(encoded)}h", *encoded)

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
        rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
        if rms <= self._config.silence_rms:
            return samples
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
