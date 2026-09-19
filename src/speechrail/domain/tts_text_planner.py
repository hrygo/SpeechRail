"""Immutable planning over the existing normalized-text acoustic input.

Coordinates are Unicode codepoints in the text supplied to this planner, not
UTF-8 bytes, UTF-16 offsets, raw HTTP input, phonemes, or audio timestamps. The
existing normalization precedes this boundary; raw-input mapping belongs to the
separate pronunciation/normalization contract. Plans stay request-local.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, replace
from typing import Literal

from speechrail.domain.tts import (
    _BOUNDED_MAIN_PUNCTS,
    _advance_quote_state,
    _find_bounded_boundary,
    bounded_sentences,
)
from speechrail.domain.tts_pronunciation import SpokenText

PLANNER_VERSION: Literal["tts_bounded_v1"] = "tts_bounded_v1"
BoundaryKind = Literal["sentence", "secondary", "whitespace", "hard_limit", "end_of_input"]


@dataclass(frozen=True, slots=True)
class TtsPlannerChunk:
    index: int
    source_start: int
    source_end: int
    spoken_text: str
    boundary: BoundaryKind
    # Raw coordinates are present only when the planner receives a SpokenText map.
    raw_start: int | None = None
    raw_end: int | None = None
    pronunciation_entry_ids: tuple[str, ...] = ()
    # No additional silence is currently inserted. None is not a measured pause.
    suggested_pause_ms: int | None = None


@dataclass(frozen=True, slots=True)
class TtsTextPlan:
    version: str
    max_chars: int
    input_sha256: str
    chunks: tuple[TtsPlannerChunk, ...]
    coordinate_space: str = "normalized_text_unicode_codepoints"
    native_context_conditioning: str = "unsupported"

    def summary(self) -> dict[str, object]:
        """Low-cardinality policy/count fields, never source text or its hash."""
        return {
            "planner_version": self.version,
            "planner_chunks": len(self.chunks),
            "planner_max_chars": self.max_chars,
        }


@dataclass(frozen=True, slots=True)
class TtsTextPlanner:
    max_chars: int = 240

    def __post_init__(self) -> None:
        if type(self.max_chars) is not int or not 1 <= self.max_chars <= 4096:
            raise ValueError("invalid_planner_limit")

    def plan(self, normalized_text: str) -> TtsTextPlan:
        chunks: list[TtsPlannerChunk] = []
        position = 0
        quote_stack: list[str] = []
        ascii_quote_open = False
        for index, text in enumerate(bounded_sentences(normalized_text, self.max_chars)):
            end = position + len(text)
            boundary: BoundaryKind = "end_of_input"
            if end < len(normalized_text):
                preferred = _find_bounded_boundary(
                    normalized_text, position, min(len(normalized_text), position + self.max_chars),
                    quote_stack, ascii_quote_open,
                )
                if preferred == end:
                    boundary = "sentence" if text[-1] in _BOUNDED_MAIN_PUNCTS else "secondary"
                else:
                    boundary = "whitespace" if text.endswith(" ") else "hard_limit"
            chunks.append(TtsPlannerChunk(index, position, end, text, boundary))
            ascii_quote_open = _advance_quote_state(text, quote_stack, ascii_quote_open)
            position = end
        return TtsTextPlan(
            version=PLANNER_VERSION,
            max_chars=self.max_chars,
            input_sha256=hashlib.sha256(normalized_text.encode("utf-8")).hexdigest(),
            chunks=tuple(chunks),
        )

    def plan_spoken(self, spoken: SpokenText) -> TtsTextPlan:
        """Plan final spoken text while projecting every chunk back to raw input."""

        base = self.plan(spoken.text)
        mapped: list[TtsPlannerChunk] = []
        for chunk in base.chunks:
            overlaps = [
                span
                for span in spoken.spans
                if span.spoken_end > chunk.source_start
                and span.spoken_start < chunk.source_end
            ]
            raw_start = min((span.raw_start for span in overlaps), default=None)
            raw_end = max((span.raw_end for span in overlaps), default=None)
            entry_ids = tuple(
                dict.fromkeys(
                    span.entry_id
                    for span in overlaps
                    if span.entry_id is not None
                )
            )
            mapped.append(
                replace(
                    chunk,
                    raw_start=raw_start,
                    raw_end=raw_end,
                    pronunciation_entry_ids=entry_ids,
                )
            )
        return replace(base, chunks=tuple(mapped))
