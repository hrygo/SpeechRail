"""Render every REST response format from the domain result only."""

from __future__ import annotations

from speechrail.domain.contracts import TranscriptResult


def format_json(result: TranscriptResult) -> dict[str, object]:
    return {
        "text": result.text,
        "usage": {"type": "duration", "seconds": result.duration_ms / 1000},
    }


def format_verbose(result: TranscriptResult) -> dict[str, object]:
    return {
        "task": "transcribe",
        "language": result.language or "",
        "duration": result.duration_ms / 1000,
        "text": result.text,
        "segments": [
            {
                "id": s.id,
                "start": s.start_ms / 1000,
                "end": s.end_ms / 1000,
                "text": s.text,
                "speaker": s.speaker,
            }
            for s in result.segments
        ],
        "words": [
            {"word": w.word, "start": w.start_ms / 1000, "end": w.end_ms / 1000}
            for w in result.words
        ],
        "usage": {"type": "duration", "seconds": result.duration_ms / 1000},
    }


def _stamp(milliseconds: int, separator: str) -> str:
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    seconds, millis = divmod(remainder, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02}{separator}{millis:03}"


def format_srt(result: TranscriptResult) -> str:
    blocks = [
        f"{index}\n{_stamp(s.start_ms, ',')} --> {_stamp(s.end_ms, ',')}\n{s.text}"
        for index, s in enumerate(result.segments, 1)
    ]
    return "\n\n".join(blocks) + ("\n" if blocks else "")


def format_vtt(result: TranscriptResult) -> str:
    blocks = [
        f"{_stamp(s.start_ms, '.')} --> {_stamp(s.end_ms, '.')}\n{s.text}" for s in result.segments
    ]
    return "WEBVTT\n\n" + "\n\n".join(blocks) + ("\n" if blocks else "")
