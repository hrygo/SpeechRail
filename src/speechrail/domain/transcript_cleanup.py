"""Collapse ASR decoder-runaway repetition in final transcript text.

A decoding failure mode on the local Qwen3 ASR model repeats a token, a
character or a whole phrase until the turn window ends. Unlike rhetorical
repetition ("不不不不不"), which a speaker chose and which carries meaning,
a runaway run carries none: it is a fault, not speech. This module removes
runs at or above a threshold and reports what it removed, so the change is
auditable rather than silent.

Two passes, both bounded by ``min_run`` (default 6):

1. **Word pass** — the same token, compared case-insensitively, in a row.
   Each CJK ideograph is its own token, because CJK text has no spaces and
   a decoder loop there is a run of single characters.
2. **Substring pass** - a 2-60 character substring repeated against itself.
   This is what catches a looping *phrase*: "我说明一下这个事情" eight times
   produces no long run of one token, but it does produce eight copies of
   one substring.

A run is collapsed only when it is whole, and never across a passage
boundary, because "section 3, section 3, section 3" may be a real agenda
being read aloud. Rhetorical repetition below the threshold is left
byte-for-byte identical, and a caller that disables the cleanup gets the
input back unchanged rather than a copy.
"""

from __future__ import annotations

import re
from bisect import bisect_left, bisect_right
from dataclasses import dataclass

from speechrail.domain.contracts import TranscriptResult, TranscriptWord

DEFAULT_MIN_RUN = 6

# A one-character run belongs to the word pass; the substring pass starts at
# two so it can never swallow a legitimate doubled letter.
_MIN_SUBSTRING = 2
_MAX_SUBSTRING = 60
_PASSAGE_BREAK = "\n"
_MAX_PASSES = 8
_MAX_COPIES = 4096
_MAX_SUBSTRING_PROBES = 200_000

# One CJK ideograph is one token; every other script groups into maximal word
# runs so "don't" and "3.14" stay single-ish units. The CJK range is excluded
# from the word branch, not merely ordered after it, otherwise
# ``[^\W_]`` would swallow a whole run of ideographs in one token.
_TOKEN_RE = re.compile(
    r"[^\W\s\u3400-\u4dbf\u4e00-\u9fff_]+|[\u3400-\u4dbf\u4e00-\u9fff]",
    re.UNICODE,
)


@dataclass(frozen=True, slots=True)
class CollapseResult:
    """What one cleanup did to one string."""

    text: str
    collapsed_runs: int = 0
    collapsed_chars: int = 0


def _word_pass(text: str, min_run: int) -> tuple[str, int, int]:
    """Collapse runs of one repeated token; return text, runs, removed chars."""

    tokens = [(match.group(), match.start(), match.end()) for match in _TOKEN_RE.finditer(text)]
    if not tokens:
        return text, 0, 0

    pieces: list[str] = []
    cursor = 0
    runs = 0
    removed = 0
    index = 0
    while index < len(tokens):
        key = tokens[index][0].casefold()
        end = index
        while end + 1 < len(tokens) and tokens[end + 1][0].casefold() == key:
            end += 1
        if end - index + 1 >= min_run:
            runs += 1
            removed += tokens[end][2] - tokens[index][1] - len(tokens[index][0])
            pieces.append(text[cursor : tokens[index][1]])
            pieces.append(tokens[index][0])
            cursor = tokens[end][2]
        index = end + 1
    pieces.append(text[cursor:])
    return "".join(pieces), runs, removed


def _run_members(text: str, start: int, period: int) -> tuple[int, int]:
    """Return ``(whole copies, trailing prefix length)`` of one period run.

    A decoder runaway almost always ends where the audio ended, so the last
    copy is routinely cut short mid-unit. That partial prefix is still a member
    of the run — the loop was decaying, not finished — and collapsing it is
    what removes the nonsense tail. A single whole copy followed by a prefix
    is *not* a decaying run: "that" is one copy of "that", not a copy of
    "tha" plus a fragment.
    """

    length = len(text)
    unit = text[start : start + period]
    copies = 1
    while (
        copies < _MAX_COPIES
        and start + (copies + 1) * period <= length
        and text[start + copies * period : start + (copies + 1) * period] == unit
    ):
        copies += 1
    partial = 0
    tail_start = start + copies * period
    if tail_start < length:
        tail = text[tail_start:]
        if len(tail) < period and unit.startswith(tail):
            partial = len(tail)
    return copies, partial


def _is_run(copies: int, partial: int, min_run: int) -> bool:
    """Decide whether a period's copies form a runaway run at ``min_run``."""

    if copies >= min_run:
        return True
    # Only a run that was already one copy short of the threshold may be
    # extended by its decaying tail, and it needs at least two whole copies to
    # begin with. Otherwise every string that merely ends in a prefix of some
    # length would look like a loop.
    return partial > 0 and copies >= 2 and copies >= min_run - 1


def _substring_pass(text: str, min_run: int) -> tuple[str, int, int]:
    """Collapse runs of a repeated substring; return text, runs, removed chars.

    Candidate periods come from an index of character positions, so the scan
    costs about one lookup per character in ordinary prose rather than one
    slice comparison per (position, period) pair.
    """

    length = len(text)
    if length < min_run * _MIN_SUBSTRING:
        return text, 0, 0

    positions: dict[str, list[int]] = {}
    for index, char in enumerate(text):
        positions.setdefault(char, []).append(index)

    pieces: list[str] = []
    copied_until = 0
    runs = 0
    removed = 0
    probes = 0
    index = 0
    while index < length:
        starts = positions.get(text[index])
        if starts is None:
            index += 1
            continue
        left = bisect_left(starts, index + _MIN_SUBSTRING)
        right = bisect_right(starts, index + _MAX_SUBSTRING)
        collapsed = False
        for slot in range(left, right):
            probes += 1
            if probes > _MAX_SUBSTRING_PROBES:
                # A cost bound, never a correctness bound: pathological input
                # stops this pass instead of stalling a request.
                pieces.append(text[copied_until:])
                return "".join(pieces), runs, removed
            period = starts[slot] - index
            copies, partial = _run_members(text, index, period)
            if _is_run(copies, partial, min_run):
                span = index + copies * period + partial
                runs += 1
                removed += span - index - period
                pieces.append(text[copied_until:index])
                unit = text[index : index + period]
                if span == length and (stripped := unit.rstrip()) != unit:
                    # A trailing separator inside the run's period would leave
                    # the passage ending in a space; drop it.
                    unit, removed = stripped, removed + period - len(stripped)
                pieces.append(unit)
                copied_until = span
                index = span
                collapsed = True
                break
        if not collapsed:
            index += 1
    pieces.append(text[copied_until:])
    return "".join(pieces), runs, removed


def _collapse_passage_once(text: str, min_run: int) -> tuple[str, int, int]:
    """One word pass then one substring pass over a single passage."""

    after_words, word_runs, word_removed = _word_pass(text, min_run)
    after_substrings, substring_runs, substring_removed = _substring_pass(after_words, min_run)
    return after_substrings, word_runs + substring_runs, word_removed + substring_removed


def _collapse_passage(text: str, min_run: int) -> CollapseResult:
    """Repeat both passes until stable, so a nested run also falls."""

    current = text
    runs = 0
    removed = 0
    for _ in range(_MAX_PASSES):
        collapsed, pass_runs, pass_removed = _collapse_passage_once(current, min_run)
        if collapsed == current:
            break
        runs += pass_runs
        removed += pass_removed
        current = collapsed
    return CollapseResult(text=current, collapsed_runs=runs, collapsed_chars=removed)


def collapse_repetitions(text: str, *, min_run: int = DEFAULT_MIN_RUN) -> CollapseResult:
    """Collapse runaway runs in one transcript string, passage by passage.

    ``min_run`` below 2 is refused: at 1 every character is a run, and at 2 a
    doubled word is ordinary speech.
    """

    if not isinstance(min_run, int) or isinstance(min_run, bool) or min_run < 2:
        raise ValueError("min_run must be an integer of at least 2")
    if not isinstance(text, str) or not text:
        return CollapseResult(text=text)

    runs = 0
    removed = 0
    passages: list[str] = []
    for passage in text.split(_PASSAGE_BREAK):
        collapsed = _collapse_passage(passage, min_run)
        passages.append(collapsed.text)
        runs += collapsed.collapsed_runs
        removed += collapsed.collapsed_chars
    return CollapseResult(
        text=_PASSAGE_BREAK.join(passages),
        collapsed_runs=runs,
        collapsed_chars=removed,
    )


def _collapse_within_spans(
    text: str, spans: tuple[tuple[int, int], ...], min_run: int
) -> CollapseResult:
    """Collapse each span on its own; never merge across a span boundary.

    ``format_diarized`` reconstructs a transcript from its segment texts, so
    the top-level text and the segments have to shrink together. Collapsing
    only inside each segment's own span of the text makes that true by
    construction: a run straddling a segment boundary is left alone.
    """

    pieces: list[str] = []
    cursor = 0
    runs = 0
    removed = 0
    for start, end in sorted(spans):
        if start < cursor or end <= start or end > len(text):
            # A span model that no longer matches its own text is not one this
            # helper was promised; fall back to the whole string.
            return collapse_repetitions(text, min_run=min_run)
        pieces.append(text[cursor:start])
        collapsed = collapse_repetitions(text[start:end], min_run=min_run)
        pieces.append(collapsed.text)
        runs += collapsed.collapsed_runs
        removed += collapsed.collapsed_chars
        cursor = end
    pieces.append(text[cursor:])
    return CollapseResult(
        text="".join(pieces),
        collapsed_runs=runs,
        collapsed_chars=removed,
    )


def _collapse_word_runs(
    words: tuple[TranscriptWord, ...], min_run: int
) -> tuple[tuple[TranscriptWord, ...], bool]:
    """Collapse runs of one repeated word; the kept copy owns the whole run."""

    kept: list[TranscriptWord] = []
    changed = False
    index = 0
    while index < len(words):
        end = index
        while (
            end + 1 < len(words) and words[end + 1].word.casefold() == words[index].word.casefold()
        ):
            end += 1
        if end - index + 1 >= min_run:
            changed = True
            kept.append(
                words[index].model_copy(
                    update={"end_ms": max(words[index].end_ms, words[end].end_ms)}
                )
            )
        else:
            kept.extend(words[index : end + 1])
        index = end + 1
    return tuple(kept), changed


def collapse_transcript_result(
    result: TranscriptResult,
    *,
    enabled: bool = True,
    min_run: int = DEFAULT_MIN_RUN,
) -> TranscriptResult:
    """Collapse repetition in one final result, keeping it self-consistent.

    Text, segments and words shrink together or not at all: ``text`` is
    collapsed inside each segment's own span (or as a whole when the result
    carries no segments), every ``segment`` is collapsed on its own, and a run
    of identical words becomes one word covering the run's time span. The
    number of collapsed runs is reported in ``repetition_collapsed``.

    Disabling returns the very same object rather than a copy: an off switch
    that still rebuilt every result would be an off switch with a cost.
    """

    if not enabled:
        return result
    if not result.text and not result.segments and not result.words:
        return result

    spans: list[tuple[int, int]] = []
    if result.segments:
        cursor = 0
        for segment in result.segments:
            if not segment.text:
                spans = []
                break
            start = result.text.find(segment.text, cursor)
            if start < 0:
                spans = []
                break
            spans.append((start, start + len(segment.text)))
            cursor = start + len(segment.text)

    segment_cleaned = [
        collapse_repetitions(segment.text, min_run=min_run) for segment in result.segments
    ]
    segment_runs = sum(cleaned.collapsed_runs for cleaned in segment_cleaned)

    if spans:
        # The spans are the segments' own slices of the text, so the count that
        # comes back here already accounts for the segments; adding the
        # segments again would report the same collapse twice.
        collapsed = _collapse_within_spans(result.text, tuple(spans), min_run)
        count = collapsed.collapsed_runs
    else:
        collapsed = collapse_repetitions(result.text, min_run=min_run)
        count = collapsed.collapsed_runs + segment_runs

    segments = tuple(
        segment.model_copy(update={"text": cleaned.text})
        if cleaned.text != segment.text
        else segment
        for segment, cleaned in zip(result.segments, segment_cleaned, strict=True)
    )

    words, words_changed = _collapse_word_runs(result.words, min_run)

    if collapsed.text == result.text and segments == result.segments and not words_changed:
        return result

    return result.model_copy(
        update={
            "text": collapsed.text,
            "segments": segments,
            "words": words,
            "repetition_collapsed": count,
        }
    )
