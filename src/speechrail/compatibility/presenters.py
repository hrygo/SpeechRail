"""Legacy WLK wire renderers sourced solely from domain objects."""

from __future__ import annotations

from speechrail.domain.contracts import TranscriptWindow


def legacy_config(mode: str = "full") -> dict[str, str]:
    return {"type": "config", "mode": mode}


def legacy_snapshot(window: TranscriptWindow) -> dict[str, object]:
    return {
        "type": "partial",
        "lines": [
            {
                "start": segment.start_ms / 1000,
                "end": segment.end_ms / 1000,
                "text": segment.text,
                "speaker": segment.speaker,
            }
            for segment in window.segments
        ],
        "buffer_transcription": window.partial or "",
    }


def legacy_ready_to_stop() -> dict[str, str]:
    return {"type": "ready_to_stop"}
