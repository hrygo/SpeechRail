"""Unified inference limits shared by every role.

These bounds are totals for the whole service, not per-role reservations: one
process must never hold 40 MiB of retained PCM for ASR *and* another 40 MiB for
alignment *and* another for a queue.  Callers that pin or queue audio account it
against the same budget.
"""

PCM_SAMPLE_BYTES = 2

# Retained PCM for one inference request.  A 16 kHz mono stream reaches this
# bound after ~21 minutes; longer audio must be segmented instead of silently
# truncated.
MAX_PCM_BYTES = 40 * 1024 * 1024
MAX_PCM_SAMPLES = MAX_PCM_BYTES // PCM_SAMPLE_BYTES

# Short-term pin for one realtime ASR item while an auxiliary fixed-text
# alignment task still needs its exact PCM: 30 s of 16 kHz mono PCM16.  This is
# a per-item cap, not an extra reservation; the pinned bytes and every queue
# that retains audio are accounted against the same global MAX_PCM_BYTES.
MAX_ALIGNMENT_PCM_BYTES = 30 * 32_000

__all__ = [
    "MAX_ALIGNMENT_PCM_BYTES",
    "MAX_PCM_BYTES",
    "MAX_PCM_SAMPLES",
    "PCM_SAMPLE_BYTES",
]
