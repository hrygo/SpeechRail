"""Core resource-admission limits shared by configuration and runtime."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class GovernorLimits:
    """Validated capacity policy for the local single-owner runtime."""

    total_capacity: int
    realtime_reserved_capacity: int
    max_pending_per_class: int
    batch_aging_seconds: float = 30.0

    def __post_init__(self) -> None:
        if self.total_capacity < 2:
            raise ValueError("total_capacity must be at least two")
        if not 1 <= self.realtime_reserved_capacity < self.total_capacity:
            raise ValueError("realtime_reserved_capacity must be between one and total_capacity")
        if self.max_pending_per_class < 1:
            raise ValueError("max_pending_per_class must be positive")
        if self.batch_aging_seconds <= 0:
            raise ValueError("batch_aging_seconds must be positive")


__all__ = ["GovernorLimits"]
