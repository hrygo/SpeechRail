"""Convert untrusted WLK snapshots into SpeechRail domain data."""

from __future__ import annotations

import math
from collections.abc import Mapping

from speechrail.domain.contracts import TranscriptSegment, TranscriptWindow


def _milliseconds(value: object) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return max(0, round(float(value) * 1000)) if math.isfinite(float(value)) else 0
    text = str(value or "").strip()
    try:
        if ":" not in text:
            return max(0, round(float(text) * 1000))
        parts = text.split(":")
        if len(parts) > 3:
            return 0
        seconds = float(parts[-1])
        minutes = int(parts[-2]) if len(parts) >= 2 else 0
        hours = int(parts[-3]) if len(parts) == 3 else 0
        return max(0, round((hours * 3600 + minutes * 60 + seconds) * 1000))
    except ValueError:
        return 0


def normalize_snapshot(payload: Mapping[str, object], *, source_epoch: int) -> TranscriptWindow:
    raw_lines = payload.get("lines")
    segments: list[TranscriptSegment] = []
    if isinstance(raw_lines, list):
        for index, raw in enumerate(raw_lines):
            if not isinstance(raw, Mapping):
                continue
            text = str(raw.get("text") or "").strip()
            if not text or raw.get("speaker") == -2:
                continue
            start_ms = _milliseconds(raw.get("start"))
            end_ms = max(start_ms, _milliseconds(raw.get("end")))
            segments.append(
                TranscriptSegment(
                    id=f"seg_{source_epoch}_{index}",
                    start_ms=start_ms,
                    end_ms=end_ms,
                    text=text,
                    speaker=str(raw.get("speaker", "0")),
                    source_epoch=source_epoch,
                )
            )
    partial = str(payload.get("buffer_transcription") or "").strip() or None
    return TranscriptWindow(
        source_epoch=source_epoch, partial=partial, segments=tuple(segments), final=partial is None
    )
