"""Pure helpers for comparable SpeechRail benchmark measurements.

The resource sampler records one mapping per sampling instant.  A snapshot is
usable for a simultaneous total only when every observed process identity is
present in it; an absent value means that the sample is incomplete, not that
the process used zero bytes.
"""

from __future__ import annotations

import math
from collections.abc import Hashable, Mapping, Sequence
from dataclasses import dataclass
from numbers import Real


@dataclass(frozen=True, slots=True)
class ProcessIdentity:
    """Stable identity for one process lifetime.

    A PID may be reused after a process exits.  Resource samples that need to
    survive that boundary must key observations by both ``pid`` and the
    process start time, rather than by PID alone.
    """

    pid: int
    start_time_ns: int

    def __post_init__(self) -> None:
        if isinstance(self.pid, bool) or not isinstance(self.pid, int) or self.pid < 0:
            raise ValueError("pid must be a non-negative integer")
        if (
            isinstance(self.start_time_ns, bool)
            or not isinstance(self.start_time_ns, int)
            or self.start_time_ns < 0
        ):
            raise ValueError("start_time_ns must be a non-negative integer")


type ProcessIdentitySample = dict[ProcessIdentity, int]


def _finite_real(name: str, value: float) -> float:
    if isinstance(value, bool) or not isinstance(value, Real):
        raise ValueError(f"{name} must be a finite real number")
    converted = float(value)
    if not math.isfinite(converted):
        raise ValueError(f"{name} must be a finite real number")
    return converted


def rtf(elapsed_seconds: float, audio_seconds: float) -> float:
    """Return elapsed generation time divided by actual audio duration.

    Zero-length audio cannot define an RTF.  A zero elapsed time is valid for
    deterministic or very small fake responses and produces an RTF of zero.
    """

    elapsed = _finite_real("elapsed_seconds", elapsed_seconds)
    audio = _finite_real("audio_seconds", audio_seconds)
    if elapsed < 0:
        raise ValueError("elapsed_seconds must be non-negative")
    if audio <= 0:
        raise ValueError("audio_seconds must be positive")
    return elapsed / audio


def _validate_snapshot[IdentityT: Hashable](snapshot: Mapping[IdentityT, int]) -> None:
    for footprint in snapshot.values():
        if isinstance(footprint, bool) or not isinstance(footprint, int) or footprint < 0:
            raise ValueError("footprint values must be non-negative integers")


def _simultaneous_peak[IdentityT: Hashable](
    samples: Sequence[Mapping[IdentityT, int]],
) -> int:
    if not samples:
        raise ValueError("samples must contain at least one snapshot")

    identities: set[IdentityT] = set()
    for snapshot in samples:
        if not isinstance(snapshot, Mapping):
            raise TypeError("each sample must be a mapping of process identity to footprint")
        _validate_snapshot(snapshot)
        identities.update(snapshot)

    if not identities:
        raise ValueError("samples contain no process observations")

    complete = [snapshot for snapshot in samples if set(snapshot) == identities]
    if not complete:
        raise ValueError("samples contain no complete snapshot")
    return max(sum(snapshot.values()) for snapshot in complete)


def simultaneous_peak(samples: list[dict[int, int]]) -> int:
    """Return the largest same-instant sum of the supplied PID snapshots.

    Snapshots missing any PID from the observed union are discarded as
    incomplete.  This keeps a failed read from being interpreted as a zero
    footprint and prevents summing process maxima observed at different times.

    The integer-PID form is retained for the existing sampler contract.  It
    cannot identify PID reuse; callers spanning process lifetimes should use
    :func:`simultaneous_peak_by_identity` with :class:`ProcessIdentity` keys.
    """

    return _simultaneous_peak(samples)


def simultaneous_peak_by_identity(
    samples: list[ProcessIdentitySample],
) -> int:
    """Return a simultaneous peak while distinguishing reused PIDs by start time."""

    return _simultaneous_peak(samples)
