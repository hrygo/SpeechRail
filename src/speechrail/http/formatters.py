"""Render every REST response format from the domain result only."""

from __future__ import annotations

from speechrail.domain.contracts import TranscriptResult


def format_json(result: TranscriptResult) -> dict[str, object]:
    return {
        "text": result.text,
        "usage": {"type": "duration", "seconds": result.duration_ms / 1000},
    }


def format_verbose(
    result: TranscriptResult, *, granularities: frozenset[str] = frozenset({"segment", "word"})
) -> dict[str, object]:
    payload: dict[str, object] = {
        "task": "transcribe",
        "language": (result.language or "").strip().lower(),
        "duration": result.duration_ms / 1000,
        "text": result.text,
        "usage": {"type": "duration", "seconds": result.duration_ms / 1000},
    }
    if "segment" in granularities:
        payload["segments"] = [
            {
                "id": s.id,
                # Whisper-style confidence fields the Qwen3 runtime cannot
                # produce; emitted as explicit nulls so the OpenAI verbose
                # field set stays intact without fabricating values.
                "seek": None,
                "tokens": None,
                "temperature": None,
                "avg_logprob": None,
                "compression_ratio": None,
                "no_speech_prob": None,
                "start": s.start_ms / 1000,
                "end": s.end_ms / 1000,
                "text": s.text,
            }
            for s in result.segments
        ]
    if "word" in granularities:
        payload["words"] = [
            {"word": w.word, "start": w.start_ms / 1000, "end": w.end_ms / 1000}
            for w in result.words
        ]
    return payload


def format_diarized(result: TranscriptResult) -> dict[str, object]:
    """Render OpenAI's ``diarized_json`` response without verbose-JSON fields.

    This serializer deliberately has a separate DTO from ``format_verbose``:
    diarized segments use string ids and the transcript event type, while
    Whisper confidence fields and SpeechRail's internal attribution metadata
    are not part of this public response.
    """

    labels: dict[str, str] = {}
    segments: list[dict[str, object]] = []
    text_cursor = 0
    for segment in result.segments:
        if segment.speaker is None or not segment.text:
            raise ValueError("diarization_unresolved")
        label = labels.setdefault(segment.speaker, chr(ord("A") + len(labels)))
        if label > "D":
            raise ValueError("diarization_speaker_limit")
        start = result.text.find(segment.text, text_cursor)
        if start < text_cursor:
            raise ValueError("diarization_unresolved")
        end = start + len(segment.text)
        rendered_text = result.text[text_cursor:end]
        text_cursor = end
        rendered = {
            "id": f"seg_{len(segments)}",
            "type": "transcript.text.segment",
            "start": segment.start_ms / 1000,
            "end": segment.end_ms / 1000,
            "speaker": label,
            # Attach punctuation and whitespace before a source segment to the
            # following ownership span. This preserves the frozen transcript
            # exactly without inventing a separate unowned segment.
            "text": rendered_text,
        }
        if segments and segments[-1]["speaker"] == label:
            segments[-1]["end"] = rendered["end"]
            segments[-1]["text"] = str(segments[-1]["text"]) + str(rendered["text"])
        else:
            segments.append(rendered)
    if result.text and not segments:
        raise ValueError("diarization_unresolved")
    if segments and text_cursor < len(result.text):
        segments[-1]["text"] = str(segments[-1]["text"]) + result.text[text_cursor:]
    if "".join(str(item["text"]) for item in segments) != result.text:
        raise ValueError("diarization_unresolved")
    return {
        "task": "transcribe",
        "duration": result.duration_ms / 1000,
        "text": result.text,
        "segments": segments,
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
