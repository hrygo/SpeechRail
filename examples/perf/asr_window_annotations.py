"""Optional human annotation scores. Never emit reference or hypothesis text."""

from __future__ import annotations

import unicodedata
from typing import Any

FACT_CATEGORIES = ("number", "amount", "date", "negation", "proper_name")


def _contains_tokens(tokens: tuple[str, ...], term: tuple[str, ...]) -> bool:
    # KMP avoids repeated long-prefix comparisons on repetitive speech.
    prefix, matched = [0] * len(term), 0
    for index in range(1, len(term)):
        while matched and term[index] != term[matched]:
            matched = prefix[matched - 1]
        matched += term[index] == term[matched]
        prefix[index] = matched
    matched = 0
    for token in tokens:
        while matched and token != term[matched]:
            matched = prefix[matched - 1]
        matched += token == term[matched]
        if matched == len(term):
            return True
    return False


def _normalized_characters(text: str):
    # Keep normalization segments together (including combining marks and
    # Hangul composition across starters), with original half-open offsets.
    segment, start = [], 0
    for offset, char in enumerate(text):
        if segment and unicodedata.category(char)[0] != "M":
            previous = unicodedata.normalize("NFKC", "".join(segment))
            following = unicodedata.normalize("NFKC", char)
            if (
                unicodedata.normalize("NFKC", previous[-1:] + following)
                == previous[-1:] + following
            ):
                for normalized in previous.casefold():
                    yield normalized, start, offset
                segment = []
        if not segment:
            start = offset
        segment.append(char)
    for normalized in unicodedata.normalize("NFKC", "".join(segment)).casefold():
        yield normalized, start, len(text)


def _tokens(text: str) -> list[tuple[str, int, int]]:
    # Latin words are whitespace-delimited after punctuation removal. Other
    # scripts use individual lexical characters, so Chinese never becomes one
    # artificial WER word. Offsets always refer to original Unicode codepoints.
    result: list[tuple[str, int, int]] = []
    word, start, end = "", 0, 0
    for char, offset, limit in _normalized_characters(text):
        category = unicodedata.category(char)[0]
        if char.isspace():
            if word:
                result.append((word, start, end))
                word = ""
        elif category in {"L", "N", "M"}:
            latin = category in {"N", "M"} or "LATIN" in unicodedata.name(char, "")
            if latin:
                if not word:
                    start = offset
                word += char
                end = limit
            else:
                if word:
                    result.append((word, start, end))
                    word = ""
                result.append((char, offset, limit))
    if word:
        result.append((word, start, end))
    return result


def _alignment(expected, actual):
    rows, width = len(expected) + 1, len(actual) + 1
    if rows * width > 4_000_000:
        return None
    steps = bytearray(rows * width)
    steps[1:width] = bytes([3]) * (width - 1)
    previous = list(range(width))
    for row, left in enumerate(expected, 1):
        current = [row]
        steps[row * width] = 2
        for column, right in enumerate(actual, 1):
            diagonal = previous[column - 1] + (left[0] != right[0])
            delete, insert = previous[column] + 1, current[-1] + 1
            best = min(diagonal, delete, insert)
            current.append(best)
            steps[row * width + column] = 1 if diagonal == best else 2 if delete == best else 3
        previous = current
    operations = []
    row, column = len(expected), len(actual)
    while row or column:
        step = steps[row * width + column]
        if step == 1:
            row, column = row - 1, column - 1
            operations.append((row, column, row))
        elif step == 2:
            row -= 1
            operations.append((row, None, row))
        else:
            column -= 1
            operations.append((None, column, row))
    return list(reversed(operations))


def _ranges(value, reference, tokens, *, english=False):
    if not isinstance(value, list) or len(value) > 256:
        raise ValueError("invalid human annotation ranges")
    result, previous = [], 0
    for entry in value:
        if not isinstance(entry, dict):
            raise ValueError("invalid human annotation range")
        start, end = entry.get("start"), entry.get("end")
        if (
            type(start) is not int
            or type(end) is not int
            or not previous <= start < end <= len(reference)
        ):
            raise ValueError("overlapping or invalid human annotation range")
        if english and any(
            unicodedata.category(c)[0] == "L" and "LATIN" not in unicodedata.name(c, "")
            for c in reference[start:end]
        ):
            raise ValueError("English annotation contains a non-Latin word")
        indices = [i for i, (_, a, b) in enumerate(tokens) if a < end and b > start]
        if not indices or any(tokens[i][1] < start or tokens[i][2] > end for i in indices):
            raise ValueError("human annotation splits or omits a lexical token")
        result.append((indices[0], indices[-1] + 1))
        previous = end
    return result


def _range_counts(bounds, expected, actual, operations):
    errors = words = 0
    # An insertion touching a marked boundary is conservatively charged to
    # the marked span, once even when marked spans are adjacent.
    for left, right, anchor in operations:
        selected = (
            any(a <= left < b for a, b in bounds)
            if left is not None
            else any(a <= anchor <= b for a, b in bounds)
        )
        if selected:
            words += left is not None
            errors += left is None or right is None or expected[left][0] != actual[right][0]
    return int(errors), int(words)


def annotated_quality_metrics(
    reference: str, hypothesis: str, annotations: dict[str, Any] | None
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "wer": "not_observed",
        "facts": "not_observed",
        "vocabulary_negative_control": "not_observed",
    }
    if annotations is None:
        return result
    if (
        not isinstance(annotations, dict)
        or annotations.get("kind") != "independent_human_annotation"
        or set(annotations) - {"kind", "english_spans", "facts", "vocabulary_negative_controls"}
    ):
        raise ValueError("independent human annotation provenance is required")
    if max(len(reference), len(hypothesis)) > 20000:
        raise ValueError("annotated quality text exceeds scoring bounds")
    expected, actual = _tokens(reference), _tokens(hypothesis)
    english = _ranges(annotations.get("english_spans", []), reference, expected, english=True)
    fact_entries = annotations.get("facts", [])
    facts = _ranges(fact_entries, reference, expected)
    if any(
        not isinstance(entry.get("category"), str) or entry["category"] not in FACT_CATEGORIES
        for entry in fact_entries
    ):
        raise ValueError("facts require a finite human annotation category")
    controls = annotations.get("vocabulary_negative_controls", [])
    if (
        not isinstance(controls, list)
        or len(controls) > 256
        or any(not isinstance(s, str) or not s.strip() or len(s) > 256 for s in controls)
    ):
        raise ValueError("invalid vocabulary negative controls")
    normalized_reference = tuple(t[0] for t in expected)
    normalized_hypothesis = tuple(t[0] for t in actual)
    normalized_controls = [tuple(t[0] for t in _tokens(s)) for s in controls]
    if len(set(normalized_controls)) != len(controls) or any(
        not s or _contains_tokens(normalized_reference, s) for s in normalized_controls
    ):
        raise ValueError("negative controls must be distinct and absent from human reference")
    if controls:
        result["vocabulary_negative_control"] = {
            "reference_absent_count": len(controls),
            "false_positive_count": sum(
                _contains_tokens(normalized_hypothesis, s) for s in normalized_controls
            ),
            "normalization": (
                "NFKC_casefold_contiguous_tokens_Latin_whole_words_other_lexical_characters"
            ),
        }
    if not english and not facts:
        return result
    operations = _alignment(expected, actual)
    if operations is None:
        result["annotation_alignment"] = {"status": "not_observed", "reason": "cell_budget"}
        return result
    result["annotation_alignment"] = {
        "method": "whole_transcript_mixed_token_edit_alignment_v1",
        "tie_break": "diagonal_then_delete_then_insert",
        "insertions": "within_or_touching_marked_span_boundaries_counted_once",
        "offset_unit": "original_reference_unicode_codepoint_half_open",
    }
    if english:
        errors, words = _range_counts(english, expected, actual, operations)
        result["wer"] = errors / words
        result["english_spans"] = {
            "span_count": len(english),
            "word_errors": errors,
            "reference_words": words,
        }
        result["word_normalization"] = "NFKC_casefold_remove_punctuation_whitespace_tokens"
    if facts:
        matches = [
            _range_counts([bounds], expected, actual, operations)[0] == 0 for bounds in facts
        ]
        correct = sum(matches)
        result["facts"] = {
            "reference_count": len(facts),
            "correct_count": correct,
            "error_count": len(facts) - correct,
            "by_category": {
                category: {
                    "reference_count": sum(entry["category"] == category for entry in fact_entries),
                    "correct_count": sum(
                        match
                        for entry, match in zip(fact_entries, matches, strict=True)
                        if entry["category"] == category
                    ),
                    "error_count": sum(
                        not match
                        for entry, match in zip(fact_entries, matches, strict=True)
                        if entry["category"] == category
                    ),
                }
                for category in FACT_CATEGORIES
            },
        }
    return result
