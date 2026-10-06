"""Score external human references without exposing either transcript."""

from __future__ import annotations

import unicodedata
from collections import Counter

_PUNCTUATION_CLASSES = ("comma", "period", "question", "exclamation")
_PUNCTUATION_CLASS_BY_MARK = {
    ",": "comma",
    "，": "comma",
    ".": "period",
    "。": "period",
    "?": "question",
    "？": "question",
    "!": "exclamation",
    "！": "exclamation",
}
_PUNCTUATION_GOLD_KINDS = frozenset(
    {"human_punctuation_annotation", "human_reading_prompt"}
)
_MAX_PUNCTUATION_ALIGNMENT_CELLS = 2_000_000
_MAX_PUNCTUATION_ALIGNMENT_TEXT_LENGTH = 10_000
_MAX_PUNCTUATION_RAW_TEXT_LENGTH = 20_000
_DIAGONAL, _DELETE, _INSERT = 1, 2, 3


def _characters(text: str) -> str:
    return "".join(
        char for char in unicodedata.normalize("NFKC", text).casefold()
        if unicodedata.category(char)[0] in {"L", "N", "M"}
    )


def character_error_metrics(reference: str, hypothesis: str) -> dict[str, object]:
    """Linear-space edit distance; punctuation needs a separate annotated set."""
    expected, actual = _characters(reference), _characters(hypothesis)
    if not expected or max(len(expected), len(actual)) > 10_000:
        raise ValueError("ASR quality text exceeds the scoring bounds")
    previous = list(range(len(actual) + 1))
    for row, left in enumerate(expected, 1):
        current = [row]
        for column, right in enumerate(actual, 1):
            current.append(min(
                current[-1] + 1,
                previous[column] + 1,
                previous[column - 1] + (left != right),
            ))
        previous = current
    errors = previous[-1]
    return {
        "reference_characters": len(expected),
        "hypothesis_characters": len(actual),
        "character_errors": errors,
        "cer": errors / len(expected),
        "normalization": "NFKC_casefold_letters_numbers_marks",
        "punctuation_gate": "unset",
    }


def _lexical_text_and_marks(
    text: str,
) -> tuple[str, list[tuple[str, int, str]]]:
    lexical: list[str] = []
    marks: list[tuple[str, int, str]] = []
    normalized = unicodedata.normalize("NFKC", text).casefold()
    index = 0
    while index < len(normalized):
        char = normalized[index]
        if char == ".":
            run_end = index + 1
            while run_end < len(normalized) and normalized[run_end] == ".":
                run_end += 1
            if run_end - index >= 3:
                index = run_end
                continue
        if unicodedata.category(char)[0] in {"L", "N", "M"}:
            lexical.append(char)
        else:
            punctuation_class = _PUNCTUATION_CLASS_BY_MARK.get(char)
            if punctuation_class is not None:
                if lexical:
                    marks.append(("after", len(lexical) - 1, punctuation_class))
                else:
                    marks.append(("before", 0, punctuation_class))
        index += 1
    return "".join(lexical), marks


def _aligned_reference_characters(
    reference: str, hypothesis: str,
) -> list[int | None] | None:
    """Return one deterministic minimum-edit alignment, bounded by cell count."""
    rows, columns = len(reference) + 1, len(hypothesis) + 1
    if (
        max(len(reference), len(hypothesis)) > _MAX_PUNCTUATION_ALIGNMENT_TEXT_LENGTH
        or rows * columns > _MAX_PUNCTUATION_ALIGNMENT_CELLS
    ):
        return None

    width = columns
    backpointers = bytearray(rows * columns)
    for column in range(1, columns):
        backpointers[column] = _INSERT

    previous = list(range(columns))
    for row, reference_char in enumerate(reference, start=1):
        current = [row] + [0] * (columns - 1)
        backpointers[row * width] = _DELETE
        for column, hypothesis_char in enumerate(hypothesis, start=1):
            diagonal = previous[column - 1] + (reference_char != hypothesis_char)
            deletion = previous[column] + 1
            insertion = current[column - 1] + 1
            best = min(diagonal, deletion, insertion)
            current[column] = best
            # Stable tie order: diagonal, then deletion, then insertion.
            backpointers[row * width + column] = (
                _DIAGONAL if diagonal == best
                else _DELETE if deletion == best
                else _INSERT
            )
        previous = current

    alignment: list[int | None] = [None] * len(reference)
    row, column = len(reference), len(hypothesis)
    while row or column:
        operation = backpointers[row * width + column]
        if operation == _DIAGONAL:
            row -= 1
            column -= 1
            alignment[row] = column
        elif operation == _DELETE:
            row -= 1
        elif operation == _INSERT:
            column -= 1
        else:  # pragma: no cover - every DP cell has a predecessor
            raise RuntimeError("punctuation alignment has no predecessor")
    return alignment


def _mark_counts(
    marks: list[tuple[str, int, str]],
    *,
    alignment: list[int | None] | None = None,
) -> Counter[tuple[str, int, str]]:
    counts: Counter[tuple[str, int, str]] = Counter()
    for side, character_index, punctuation_class in marks:
        if alignment is None:
            aligned_index = character_index
        elif not alignment and side == "before" and character_index == 0:
            aligned_index = 0
        elif character_index < len(alignment):
            aligned_index = alignment[character_index]
        else:
            aligned_index = None
        if aligned_index is None:
            # Unaligned marks remain false negatives; no hypothesis anchor can
            # collide with this reference-only key.
            counts[("unmapped", character_index, punctuation_class)] += 1
        else:
            # Keeping the side distinguishes punctuation before the first
            # character from punctuation after that same character.
            counts[(side, aligned_index, punctuation_class)] += 1
    return counts


def _ratio(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def _punctuation_result_base(
    *,
    gold_kind: str | None,
    status: str,
    reason: str | None,
) -> dict[str, object]:
    gold_scope = {
        "human_punctuation_annotation": "audio_specific_punctuation_annotation",
        "human_reading_prompt": (
            "reading_prompt_source_punctuation_not_audio_specific_annotation"
        ),
    }.get(gold_kind)
    return {
        "status": status,
        "reason": reason,
        "method": "normalized_lexical_character_alignment_v1",
        "interpretation": "project_declared_metric_not_an_industry_standard",
        "alignment_tie_break": "diagonal_then_delete_then_insert",
        "class_scope": list(_PUNCTUATION_CLASSES),
        "gold_kind": gold_kind,
        "gold_scope": gold_scope,
        "punctuation_gate": "unset",
    }


def punctuation_error_metrics(
    gold_text: str | None,
    hypothesis: str,
    *,
    gold_kind: str | None,
) -> dict[str, object]:
    """Score core punctuation at character-aligned positions without retaining text."""
    if not isinstance(hypothesis, str):
        raise ValueError("punctuation hypothesis must be a string")
    if gold_text is None:
        if gold_kind is not None:
            raise ValueError("punctuation gold kind requires punctuation gold text")
        return {
            **_punctuation_result_base(
                gold_kind=None, status="unset", reason="gold_not_provided"
            ),
            "gold_mark_count": None,
            "hypothesis_mark_count": None,
            "true_positives": None,
            "false_positives": None,
            "false_negatives": None,
            "precision": None,
            "recall": None,
            "f1": None,
            "class_support": {
                punctuation_class: {
                    "gold_marks": None,
                    "hypothesis_marks": None,
                    "true_positives": None,
                    "false_positives": None,
                    "false_negatives": None,
                    "precision": None,
                    "recall": None,
                    "f1": None,
                }
                for punctuation_class in _PUNCTUATION_CLASSES
            },
        }
    if not isinstance(gold_text, str) or not gold_text.strip():
        raise ValueError("punctuation gold text must be a non-blank string")
    if not isinstance(gold_kind, str) or gold_kind not in _PUNCTUATION_GOLD_KINDS:
        raise ValueError("unsupported punctuation gold kind")
    if len(gold_text) + len(hypothesis) > _MAX_PUNCTUATION_RAW_TEXT_LENGTH:
        return {
            **_punctuation_result_base(
                gold_kind=gold_kind,
                status="unset",
                reason="raw_text_length_limit",
            ),
            "gold_mark_count": None,
            "hypothesis_mark_count": None,
            "true_positives": None,
            "false_positives": None,
            "false_negatives": None,
            "precision": None,
            "recall": None,
            "f1": None,
            "class_support": {
                punctuation_class: {
                    "gold_marks": None,
                    "hypothesis_marks": None,
                    "true_positives": None,
                    "false_positives": None,
                    "false_negatives": None,
                    "precision": None,
                    "recall": None,
                    "f1": None,
                }
                for punctuation_class in _PUNCTUATION_CLASSES
            },
        }

    reference_lexical, reference_marks = _lexical_text_and_marks(gold_text)
    hypothesis_lexical, hypothesis_marks = _lexical_text_and_marks(hypothesis)
    alignment = _aligned_reference_characters(reference_lexical, hypothesis_lexical)
    raw_gold_counts = Counter(mark[2] for mark in reference_marks)
    raw_hypothesis_counts = Counter(mark[2] for mark in hypothesis_marks)
    if alignment is None:
        reason = (
            "alignment_text_length_limit"
            if max(len(reference_lexical), len(hypothesis_lexical))
            > _MAX_PUNCTUATION_ALIGNMENT_TEXT_LENGTH
            else "alignment_cell_limit"
        )
        return {
            **_punctuation_result_base(
                gold_kind=gold_kind,
                status="unset",
                reason=reason,
            ),
            "gold_mark_count": len(reference_marks),
            "hypothesis_mark_count": len(hypothesis_marks),
            "true_positives": None,
            "false_positives": None,
            "false_negatives": None,
            "precision": None,
            "recall": None,
            "f1": None,
            "class_support": {
                punctuation_class: {
                    "gold_marks": raw_gold_counts[punctuation_class],
                    "hypothesis_marks": raw_hypothesis_counts[punctuation_class],
                    "true_positives": None,
                    "false_positives": None,
                    "false_negatives": None,
                    "precision": None,
                    "recall": None,
                    "f1": None,
                }
                for punctuation_class in _PUNCTUATION_CLASSES
            },
        }

    gold_counts = _mark_counts(reference_marks, alignment=alignment)
    hypothesis_counts = _mark_counts(hypothesis_marks)
    class_support: dict[str, dict[str, int | float | None]] = {}
    total_true_positives = 0
    total_false_positives = 0
    total_false_negatives = 0
    for punctuation_class in _PUNCTUATION_CLASSES:
        class_gold = sum(
            count for (_, _, mark_class), count in gold_counts.items()
            if mark_class == punctuation_class
        )
        class_hypothesis = sum(
            count for (_, _, mark_class), count in hypothesis_counts.items()
            if mark_class == punctuation_class
        )
        class_true_positives = sum(
            min(count, hypothesis_counts.get(anchor, 0))
            for anchor, count in gold_counts.items()
            if anchor[2] == punctuation_class
        )
        class_false_positives = class_hypothesis - class_true_positives
        class_false_negatives = class_gold - class_true_positives
        class_f1_denominator = (
            2 * class_true_positives + class_false_positives + class_false_negatives
        )
        class_support[punctuation_class] = {
            "gold_marks": class_gold,
            "hypothesis_marks": class_hypothesis,
            "true_positives": class_true_positives,
            "false_positives": class_false_positives,
            "false_negatives": class_false_negatives,
            "precision": _ratio(class_true_positives, class_hypothesis),
            "recall": _ratio(class_true_positives, class_gold),
            "f1": (
                2 * class_true_positives / class_f1_denominator
                if class_f1_denominator else None
            ),
        }
        total_true_positives += class_true_positives
        total_false_positives += class_false_positives
        total_false_negatives += class_false_negatives

    gold_mark_count = sum(raw_gold_counts.values())
    hypothesis_mark_count = sum(raw_hypothesis_counts.values())
    f1_denominator = (
        2 * total_true_positives + total_false_positives + total_false_negatives
    )
    status = (
        "unset"
        if gold_mark_count == 0 and hypothesis_mark_count == 0
        else "scored"
    )
    reason = "no_scored_gold_marks" if status == "unset" else None
    return {
        **_punctuation_result_base(
            gold_kind=gold_kind, status=status, reason=reason
        ),
        "gold_mark_count": gold_mark_count,
        "hypothesis_mark_count": hypothesis_mark_count,
        "true_positives": total_true_positives,
        "false_positives": total_false_positives,
        "false_negatives": total_false_negatives,
        "precision": _ratio(total_true_positives, hypothesis_mark_count),
        "recall": _ratio(total_true_positives, gold_mark_count),
        "f1": (
            2 * total_true_positives / f1_denominator
            if f1_denominator else None
        ),
        "class_support": class_support,
    }
