"""Bounded failure categories and content-free fixed-text alignment diagnostics."""

from __future__ import annotations

import logging

_LOGGER = logging.getLogger(__name__)

_FAILURE_MESSAGES = {
    "alignment_failed": "Fixed text alignment failed; the transcript is preserved.",
    "alignment_unavailable": "The fixed text aligner is unavailable.",
    "alignment_worker_failed": "The fixed text alignment worker failed.",
    "alignment_stale": "The alignment belongs to an expired audio epoch.",
    "alignment_timeout": "Fixed text alignment exceeded its time budget.",
    "alignment_overloaded": "Fixed text alignment admission is full.",
    "alignment_pcm_overflow": "The captured audio exceeded the alignment buffer limit.",
    "alignment_pcm_mismatch": "The captured audio does not match the frozen sample span.",
    "invalid_alignment": "The aligner returned invalid token timestamps.",
    "text_mismatch": "The aligned tokens do not cover the fixed text.",
    "alignment_out_of_bounds": "Aligned timestamps extend outside the frozen audio span.",
    "alignment_not_monotonic": "Aligned token timestamps overlap or move backwards.",
    "granularity_unsupported": "The aligner cannot provide the requested text granularity.",
    "alignment_time_resolution_insufficient": (
        "The timestamp resolution cannot support the requested text granularity."
    ),
}


def normalize_alignment_failure(code: str) -> str:
    """Never turn an adapter's free-form failure into a log or metric label."""
    return code if code in _FAILURE_MESSAGES else "alignment_failed"


def alignment_failure_message(code: str) -> str:
    return _FAILURE_MESSAGES[normalize_alignment_failure(code)]


def log_alignment_failure(
    *,
    code: str,
    stage: str,
    audio_samples: int,
    text_characters: int,
    expected_audio_samples: int | None = None,
    span_start_sample: int = 0,
    transcript_revision: int = 0,
    token_count: int = 0,
    collapsed_tokens: int = 0,
    timestamp_min_start_sample: int = -1,
    timestamp_max_end_sample: int = -1,
    exception: BaseException | None = None,
) -> None:
    """Record enough to identify a failed span without text, PCM or exception bodies."""
    stages = {"initialize", "admission", "worker", "validation", "realtime"}
    stage = stage if stage in stages else "unknown"
    exception_type = "none"
    if exception is not None:
        exception_type = next(
            (
                kind.__name__
                for kind in (TimeoutError, OSError, ValueError, RuntimeError)
                if isinstance(exception, kind)
            ),
            "unexpected",
        )
    _LOGGER.warning(
        "fixed_text_alignment_failed code=%s stage=%s audio_samples=%d "
        "expected_audio_samples=%d "
        "text_characters=%d span_start_sample=%d transcript_revision=%d "
        "token_count=%d collapsed_tokens=%d timestamp_min_start_sample=%d "
        "timestamp_max_end_sample=%d exception_type=%s",
        normalize_alignment_failure(code),
        stage,
        audio_samples,
        expected_audio_samples if expected_audio_samples is not None else -1,
        text_characters,
        span_start_sample,
        transcript_revision,
        token_count,
        collapsed_tokens,
        timestamp_min_start_sample,
        timestamp_max_end_sample,
        exception_type,
    )
