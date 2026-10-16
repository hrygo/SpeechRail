"""Continuous RAM PCM with bounded retention and explicit copy reservations."""

from __future__ import annotations

from speechrail.domain.asr_window import MAX_PCM_BYTES, require_integer, require_span
from speechrail.domain.audio_timeline import SampleSpan


class PcmBudgetExceededError(RuntimeError):
    """Admission refused without silently discarding accepted or pinned audio."""


class PcmBudget:
    """Shared event-loop-local accounting for all ASR/auxiliary RAM copies."""

    def __init__(self, *, limit_bytes: int = MAX_PCM_BYTES) -> None:
        require_integer(limit_bytes, minimum=1, maximum=MAX_PCM_BYTES)
        self.limit_bytes = limit_bytes
        self.used_bytes = 0

    def reserve(self, count: int) -> None:
        if count < 0 or self.used_bytes + count > self.limit_bytes:
            raise PcmBudgetExceededError("shared PCM memory budget exceeded")
        self.used_bytes += count

    def release(self, count: int) -> None:
        if not 0 <= count <= self.used_bytes:
            raise ValueError("unbalanced PCM memory reservation")
        self.used_bytes -= count


class PcmBorrow:
    def __init__(self, ring: WindowPcmRing, token: int, pcm16: bytes) -> None:
        self._ring = ring
        self._token = token
        self.pcm16 = pcm16
        self._released = False

    def release(self) -> None:
        if not self._released:
            self._released = True
            _, charge = self._ring._borrows.pop(self._token)
            self._ring._budget.release(charge)
            self.pcm16 = b""

    def __enter__(self) -> PcmBorrow:
        return self

    def __exit__(self, *_: object) -> None:
        self.release()


class WindowPcmRing:
    def __init__(
        self,
        *,
        max_samples: int = 60 * 16000,
        budget_bytes: int = MAX_PCM_BYTES,
        budget_account: PcmBudget | None = None,
    ) -> None:
        require_integer(max_samples, minimum=1, maximum=60 * 16000)
        require_integer(budget_bytes, minimum=1, maximum=MAX_PCM_BYTES)
        self.max_samples = max_samples
        self.budget_bytes = budget_bytes
        self._budget = budget_account or PcmBudget(limit_bytes=budget_bytes)
        self.accepted_samples = 0
        self.retained_from_sample = 0
        self._pcm = bytearray()
        self._borrows: dict[int, tuple[SampleSpan, int]] = {}
        self._next_token = 0

    @property
    def charged_bytes(self) -> int:
        return len(self._pcm) + sum(charge for _, charge in self._borrows.values())

    @property
    def active_borrows(self) -> int:
        return len(self._borrows)

    @property
    def discardable_through(self) -> int:
        return min(
            (span.start for span, _ in self._borrows.values()), default=self.accepted_samples
        )

    def append(self, start: int, pcm16: bytes) -> None:
        require_integer(start)
        if start != self.accepted_samples or not isinstance(pcm16, bytes) or len(pcm16) % 2:
            raise ValueError("PCM input must be contiguous whole PCM16 samples")
        if not pcm16:
            return
        end = start + len(pcm16) // 2
        trim = max(self.retained_from_sample, end - self.max_samples)
        if len(pcm16) // 2 > self.max_samples or any(
            span.start < trim for span, _ in self._borrows.values()
        ):
            raise PcmBudgetExceededError(
                "PCM retention would overwrite a pin or a complete input packet"
            )
        retained_bytes = (end - trim) * 2
        if retained_bytes + sum(charge for _, charge in self._borrows.values()) > self.budget_bytes:
            raise PcmBudgetExceededError("PCM append exceeds reserved memory")
        self._budget.reserve(len(pcm16))
        try:
            self.discard_before(trim)
            self._pcm.extend(pcm16)
        except BaseException:
            self._budget.release(len(pcm16))
            raise
        self.accepted_samples = end

    def borrow(self, span: SampleSpan, *, copy_factor: int = 4) -> PcmBorrow:
        require_span(span)
        require_integer(copy_factor, minimum=1, maximum=16)
        if span.start < self.retained_from_sample or span.end > self.accepted_samples:
            raise ValueError("requested PCM is unavailable")
        charge = span.length * 2 * copy_factor
        if self.charged_bytes + charge > self.budget_bytes:
            raise PcmBudgetExceededError("PCM snapshot and conversion reservations exceed memory")
        self._budget.reserve(charge)
        self._next_token += 1
        token = self._next_token
        self._borrows[token] = (span, charge)
        try:
            begin = (span.start - self.retained_from_sample) * 2
            pcm = bytes(memoryview(self._pcm)[begin : begin + span.length * 2])
        except BaseException:
            self._borrows.pop(token)
            self._budget.release(charge)
            raise
        return PcmBorrow(self, token, pcm)

    def discard_before(self, sample: int) -> None:
        require_integer(sample)
        if not self.retained_from_sample <= sample <= self.accepted_samples:
            raise ValueError("invalid PCM retained frontier")
        if any(span.start < sample for span, _ in self._borrows.values()):
            raise PcmBudgetExceededError("cannot discard pinned PCM")
        count = (sample - self.retained_from_sample) * 2
        del self._pcm[:count]
        self._budget.release(count)
        self.retained_from_sample = sample

    def clear(self) -> None:
        if self._borrows:
            raise PcmBudgetExceededError("cleanup must wait for all actual consumers")
        self._budget.release(len(self._pcm))
        self._pcm.clear()
        self.accepted_samples = 0
        self.retained_from_sample = 0
