"""Score external human references without exposing either transcript."""

from __future__ import annotations

import unicodedata


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
