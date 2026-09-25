"""Integer sample timebase plus explicit rational resampling.

A Realtime session has exactly one master clock: the caller's *wire* sample
rate.  The ASR and alignment kernels run at 16 kHz, so every span that reaches
a kernel needs an explicit mapping that records the source rate, the target
rate, the sample origin of the mapping, and the resampler delay.  All positions
are integers and every conversion happens at a span boundary.  A long session
must never be assembled by accumulating float durations.
"""

from __future__ import annotations

import sys
from array import array
from dataclasses import dataclass

CORE_SAMPLE_RATE = 16_000
PCM_SAMPLE_BYTES = 2


@dataclass(frozen=True, slots=True)
class SampleSpan:
    """Half-open ``[start, end)`` span in one sample clock."""

    start: int
    end: int

    def __post_init__(self) -> None:
        if self.start < 0 or self.end < self.start:
            raise ValueError("sample span must be non-negative and ordered")

    @property
    def length(self) -> int:
        return self.end - self.start

    def overlaps(self, other: SampleSpan) -> bool:
        return self.start < other.end and other.start < self.end

    def contains(self, other: SampleSpan) -> bool:
        return self.start <= other.start and other.end <= self.end


@dataclass(frozen=True, slots=True)
class RateMap:
    """Rational map from a source sample clock to a target sample clock.

    ``origin_source`` is the source sample that maps to ``origin_target`` in the
    target clock, and ``resampler_delay_samples`` is the target-domain group
    delay introduced by the resampler.  Consumers subtract the delay explicitly
    instead of pretending the resampled stream is aligned sample-for-sample.
    """

    source_rate: int
    target_rate: int
    origin_source: int = 0
    origin_target: int = 0
    resampler_delay_samples: int = 0

    def __post_init__(self) -> None:
        if self.source_rate <= 0 or self.target_rate <= 0:
            raise ValueError("rate map requires positive sample rates")
        if self.origin_source < 0 or self.origin_target < 0:
            raise ValueError("rate map origin must be non-negative")
        if self.resampler_delay_samples < 0:
            raise ValueError("resampler delay must be non-negative")

    @property
    def identity(self) -> bool:
        return (
            self.source_rate == self.target_rate
            and self.origin_source == self.origin_target
            and self.resampler_delay_samples == 0
        )

    def to_target(self, source_sample: int) -> int:
        """Map one source sample position, rounding only at the boundary."""

        delta = source_sample - self.origin_source
        return self.origin_target + _floor_div(delta * self.target_rate, self.source_rate)

    def to_source(self, target_sample: int) -> int:
        delta = target_sample - self.origin_target
        return self.origin_source + _floor_div(delta * self.source_rate, self.target_rate)

    def map_span(self, span: SampleSpan) -> SampleSpan:
        return SampleSpan(self.to_target(span.start), self.to_target(span.end))

    def with_delay(self, span: SampleSpan) -> SampleSpan:
        """Return a target-domain span with the resampler delay removed."""

        shift = self.resampler_delay_samples
        return SampleSpan(max(0, span.start - shift), max(0, span.end - shift))


class SampleClock:
    """Monotonic half-open sample spans over accepted PCM at one rate."""

    __slots__ = ("_accepted_samples", "_sample_rate")

    def __init__(self, sample_rate: int = CORE_SAMPLE_RATE) -> None:
        if sample_rate <= 0:
            raise ValueError("sample clock rate must be positive")
        self._sample_rate = sample_rate
        self._accepted_samples = 0

    @property
    def sample_rate(self) -> int:
        return self._sample_rate

    @property
    def accepted_samples(self) -> int:
        return self._accepted_samples

    def accept(self, pcm16: bytes) -> SampleSpan:
        """Account one PCM16 chunk and return its half-open sample span."""

        if len(pcm16) % PCM_SAMPLE_BYTES:
            raise ValueError("sample clock accepts whole PCM16 samples only")
        span = SampleSpan(
            self._accepted_samples,
            self._accepted_samples + len(pcm16) // PCM_SAMPLE_BYTES,
        )
        self._accepted_samples = span.end
        return span

    def reset(self) -> None:
        self._accepted_samples = 0


def _floor_div(numerator: int, denominator: int) -> int:
    return numerator // denominator


class RationalResampler:
    """Streaming linear resampler with an integer, non-drifting phase.

    The output sample ``n`` is read at source position
    ``n * source_rate / target_rate``.  Because ``n`` is an integer counter
    rather than an accumulated float, splitting the input into arbitrary chunks
    produces exactly the same output as one continuous stream.  One source
    sample of lookahead is held back until it arrives, so callers must call
    :meth:`flush` to drain the tail at end of stream.
    """

    __slots__ = ("_consumed", "_out_index", "_pending", "_source_rate", "_target_rate")

    def __init__(self, source_rate: int, target_rate: int) -> None:
        if source_rate <= 0 or target_rate <= 0:
            raise ValueError("resampler requires positive sample rates")
        self._source_rate = source_rate
        self._target_rate = target_rate
        self._pending = array("h")
        self._consumed = 0
        self._out_index = 0

    @property
    def rate_map(self) -> RateMap:
        return RateMap(source_rate=self._source_rate, target_rate=self._target_rate)

    @property
    def output_samples(self) -> int:
        """Target samples emitted so far, excluding an undrained tail."""

        return self._out_index

    @property
    def pending_source_samples(self) -> int:
        """Source samples still buffered as lookahead."""

        return len(self._pending)

    def reset(self) -> None:
        """Clear the filter state; a cancelled or new epoch never leaks phase."""

        self._pending = array("h")
        self._consumed = 0
        self._out_index = 0

    def process(self, pcm16: bytes) -> bytes:
        if len(pcm16) % PCM_SAMPLE_BYTES:
            raise ValueError("resampler accepts whole PCM16 samples only")
        if not pcm16:
            return b""
        samples = array("h")
        samples.frombytes(pcm16)
        if sys.byteorder != "little":  # pragma: no cover - Apple silicon is little-endian.
            samples.byteswap()
        self._pending.extend(samples)
        return self._drain(tail_fill=False)

    def flush(self) -> bytes:
        """Emit the remaining tail, holding the final sample constant."""

        return self._drain(tail_fill=True)

    def _drain(self, *, tail_fill: bool) -> bytes:
        if not self._pending:
            return b""
        produced = array("h")
        while True:
            position, remainder = divmod(self._out_index * self._source_rate, self._target_rate)
            relative = position - self._consumed
            if relative < 0:  # pragma: no cover - defensive; the phase is monotonic.
                raise RuntimeError("resampler phase moved backwards")
            last_index = len(self._pending) - 1
            if relative > last_index:
                break
            if relative == last_index:
                if not tail_fill:
                    break
                first = self._pending[relative]
                second = first
            else:
                first = self._pending[relative]
                second = self._pending[relative + 1]
            if remainder == 0:
                produced.append(first)
            else:
                weight = remainder / self._target_rate
                produced.append(round(first + (second - first) * weight))
            self._out_index += 1
        self._discard_consumed()
        if not produced:
            return b""
        if sys.byteorder != "little":  # pragma: no cover - Apple silicon is little-endian.
            produced.byteswap()
        return produced.tobytes()

    def _discard_consumed(self) -> None:
        next_position = (self._out_index * self._source_rate) // self._target_rate
        drop = next_position - self._consumed
        if drop > 0:
            del self._pending[:drop]
            self._consumed = next_position


__all__ = [
    "CORE_SAMPLE_RATE",
    "PCM_SAMPLE_BYTES",
    "RateMap",
    "RationalResampler",
    "SampleClock",
    "SampleSpan",
]
