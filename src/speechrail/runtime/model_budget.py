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
    """Estimated runtime footprint of loaded active components."""

    asr_bytes: int
    tts_bytes: int = 0
    diarization_bytes: int = 0
    device: Literal["mps", "cpu"] = "mps"

    @property
    def total_bytes(self) -> int:
        return self.asr_bytes + self.tts_bytes + self.diarization_bytes


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
    if footprint.tts_bytes == 0:
        return True, "TTS is inactive; ASR operates within budget"

    total_required = footprint.total_bytes
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
    """Detect total system physical memory in bytes, falling back to 8 GiB."""
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
    except (AttributeError, ValueError):
        pass

    return MIN_SYSTEM_MEMORY_BYTES


__all__ = [
    "GIB",
    "MIN_SERVICE_BUDGET_BYTES",
    "MIN_SYSTEM_MEMORY_BYTES",
    "ComponentFootprint",
    "budget_for_hardware",
    "can_overlap_heavy_compute",
    "detect_system_memory_bytes",
]
