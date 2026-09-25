"""Unified memory budgeting and hardware resource protection.

Calculates base service budget from detected or configured hardware memory
and decides whether heavy compute workloads (ASR, TTS, Diarization) can safely overlap.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import Literal

GIB = 1024 ** 3
MIN_SYSTEM_MEMORY_BYTES = 8 * GIB
MIN_SERVICE_BUDGET_BYTES = 4 * GIB


@dataclass(frozen=True, slots=True)
class ComponentFootprint:
    """Explicit runtime footprint schema for one admission decision.

    The schema separates four categories so the same peak can never be counted
    twice: per-component resident weights (``asr``/``tts``/``diarization``),
    unique shared dependencies (codec/tokenizer), the incremental active peak
    (KV/state), and queue/temporary workspace plus a safety margin.

    ``includes_shared_dependencies`` records whether the declared component
    values already fold in the shared dependencies (the documented workflow of
    declaring a measured per-component ``phys_footprint`` peak). When true, an
    explicit ``shared_dependency_bytes`` would double-count and is rejected;
    when false the shared term is added exactly once.
    """

    asr_bytes: int | None
    tts_bytes: int | None = 0
    diarization_bytes: int | None = 0
    service_bytes: int = 0
    shared_dependency_bytes: int | None = 0
    active_peak_bytes: int | None = 0
    workspace_bytes: int | None = 0
    safety_margin_bytes: int | None = 0
    includes_shared_dependencies: bool = True
    device: Literal["mps", "cpu"] = "mps"

    def __post_init__(self) -> None:
        values = (
            self.asr_bytes,
            self.tts_bytes,
            self.diarization_bytes,
            self.service_bytes,
            self.shared_dependency_bytes,
            self.active_peak_bytes,
            self.workspace_bytes,
            self.safety_margin_bytes,
        )
        if any(
            value is not None
            and (isinstance(value, bool) or not isinstance(value, int) or value < 0)
            for value in values
        ):
            raise ValueError("component footprint values must be non-negative integers or null")
        if not isinstance(self.includes_shared_dependencies, bool):
            raise ValueError("includes_shared_dependencies must be a boolean")
        if self.includes_shared_dependencies and self.shared_dependency_bytes:
            raise ValueError(
                "shared_dependency_bytes must be 0 when the component values already "
                "include shared dependencies"
            )

    @property
    def resident_bytes(self) -> int | None:
        """Total resident weights/service plus any separately declared shared deps."""

        values = (self.asr_bytes, self.tts_bytes, self.diarization_bytes)
        if any(value is None for value in values):
            return None
        total = self.service_bytes + sum(value for value in values if value is not None)
        if not self.includes_shared_dependencies:
            if self.shared_dependency_bytes is None:
                return None
            total += self.shared_dependency_bytes
        return total

    @property
    def incremental_bytes(self) -> int | None:
        """Activity-added peak: KV/state, queue/temporary workspace, safety margin."""

        values = (self.active_peak_bytes, self.workspace_bytes, self.safety_margin_bytes)
        if any(value is None for value in values):
            return None
        return sum(value for value in values if value is not None)

    @property
    def total_bytes(self) -> int | None:
        resident = self.resident_bytes
        incremental = self.incremental_bytes
        if resident is None or incremental is None:
            return None
        return resident + incremental

    @property
    def overhead_bytes(self) -> int | None:
        """Service overhead, shared deps (when separate) and incremental extras."""

        incremental = self.incremental_bytes
        if incremental is None:
            return None
        shared = 0
        if not self.includes_shared_dependencies:
            if self.shared_dependency_bytes is None:
                return None
            shared = self.shared_dependency_bytes
        return self.service_bytes + shared + incremental

    def single_component_total(self, component: str) -> int | None:
        """Bytes needed to run exactly one heavy component, or null when unknown."""

        own = {
            "asr": self.asr_bytes,
            "tts": self.tts_bytes,
            "diarization": self.diarization_bytes,
        }[component]
        overhead = self.overhead_bytes
        if own is None or overhead is None:
            return None
        return own + overhead

    def serial_admission(self, budget_bytes: int) -> tuple[bool, str, bool]:
        """Decide whether one heavy task at a time is admissible.

        Returns ``(admit, reason, certified)``.  Serial execution is not
        budget-free: a *declared* single-task peak that exceeds the budget is
        refused instead of being loaded.  An undeclared peak is not certified
        for concurrency, so callers must serialize, but it is not positive
        evidence that the task cannot fit.
        """

        enabled = {
            "asr": self.asr_bytes,
            "tts": self.tts_bytes,
            "diarization": self.diarization_bytes,
        }
        running = {name: value for name, value in enabled.items() if value != 0}
        if not running:
            return True, "no heavy component enabled", True
        unknown = sorted(name for name, value in running.items() if value is None)
        if unknown:
            return (
                True,
                f"single-task footprint is undeclared for {unknown}; serializing without "
                "concurrency certification",
                False,
            )
        totals = {name: self.single_component_total(name) for name in running}
        if any(value is None for value in totals.values()):
            return True, "single-task overhead is undeclared; serializing", False
        worst = max(value for value in totals.values() if value is not None)
        if worst > budget_bytes:
            return (
                False,
                f"Single-task footprint {worst} bytes exceeds available "
                f"budget {budget_bytes} bytes; refusing heavy compute",
                True,
            )
        return (
            True,
            f"Single-task footprint {worst} bytes is within budget {budget_bytes} bytes",
            True,
        )


def budget_for_hardware(total_bytes: int) -> int:
    """Calculate the base service memory budget from host physical memory.

    Accepts total_bytes without preset_id. Requires at least 8 GiB physical memory.
    """
    if total_bytes < MIN_SYSTEM_MEMORY_BYTES:
        raise ValueError(
            f"minimum 8 GiB system memory required for known devices, got {total_bytes} bytes"
        )
    return max(MIN_SERVICE_BUDGET_BYTES, total_bytes // 2)


def can_overlap_heavy_compute(
    budget_bytes: int,
    footprint: ComponentFootprint,
) -> tuple[bool, str]:
    """Determine whether concurrent ASR and TTS compute can safely overlap.

    Returns (can_overlap, reason).
    """
    total_required = footprint.total_bytes
    if total_required is None:
        return False, "Enabled component footprint is unknown; serializing workloads"
    if total_required > budget_bytes:
        return (
            False,
            (
                f"Total footprint {total_required} bytes exceeds available "
                f"budget {budget_bytes} bytes; serializing workloads"
            ),
        )

    return (
        True,
        f"Total footprint {total_required} bytes is within budget {budget_bytes} bytes",
    )


def detect_system_memory_bytes() -> int:
    """Detect total system physical memory in bytes or fail closed."""
    if sys.platform == "darwin":
        try:
            import subprocess

            out = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True).strip()
            return int(out)
        except Exception:
            pass

    try:
        pages = os.sysconf("SC_PHYS_PAGES")
        page_size = os.sysconf("SC_PAGE_SIZE")
        if pages > 0 and page_size > 0:
            return pages * page_size
    except (AttributeError, OSError, ValueError):
        pass

    raise RuntimeError("system physical memory is unavailable")


__all__ = [
    "GIB",
    "MIN_SERVICE_BUDGET_BYTES",
    "MIN_SYSTEM_MEMORY_BYTES",
    "ComponentFootprint",
    "budget_for_hardware",
    "can_overlap_heavy_compute",
    "detect_system_memory_bytes",
]
