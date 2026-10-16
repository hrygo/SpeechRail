"""Offline retrospective scores from independent references and display traces.

Input text stays in RAM after reading the caller's external trace. This tool
does not collect UI evidence or verify its origin. Human trace correspondence
is required for correctness/word latency; caller declarations never certify UI.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

try:
    from .asr_window_annotations import _alignment, _tokens
except ImportError:  # pragma: no cover - standalone CLI
    from asr_window_annotations import _alignment, _tokens  # type: ignore[no-redef]


def _seconds(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("trace time must be finite and nonnegative")
    try:
        if not math.isfinite(value) or value < 0:
            raise ValueError("trace time must be finite and nonnegative")
        return float(value)
    except OverflowError as exc:
        raise ValueError("trace time must be finite and nonnegative") from exc


def _distribution(values: list[float]) -> dict[str, Any]:
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "p50": ordered[math.ceil(len(ordered) * .50) - 1] if ordered else None,
        "p95": ordered[math.ceil(len(ordered) * .95) - 1] if ordered else None,
        "max": ordered[-1] if ordered else None,
        "quantile": "nearest_rank",
    }


def _timings(annotation, expected):
    if "token_timings" not in annotation:
        if "timing_provenance" in annotation:
            raise ValueError("timing provenance requires token timings")
        return None
    entries = annotation["token_timings"]
    if (
        annotation.get("timing_provenance") != "human_reviewed_audio"
        or not isinstance(entries, list)
        or not expected
        or len(entries) != len(expected)
    ):
        raise ValueError("complete independent human token timings are required")
    endings, previous_begin, previous_finish = [], 0.0, 0.0
    for entry, (_, start, end) in zip(entries, expected, strict=True):
        if (
            not isinstance(entry, dict)
            or set(entry) != {"start", "end", "audio_start_seconds", "audio_end_seconds"}
            or type(entry["start"]) is not int
            or type(entry["end"]) is not int
            or (entry["start"], entry["end"]) != (start, end)
        ):
            raise ValueError("timings must cover each complete scoring token once")
        begin, finish = _seconds(entry["audio_start_seconds"]), _seconds(entry["audio_end_seconds"])
        if finish <= begin or begin < previous_begin or finish < previous_finish:
            raise ValueError("token audio intervals must be positive and monotonic")
        endings.append(finish)
        previous_begin, previous_finish = begin, finish
    return endings


def score_revision_trace(
    reference: str,
    observations: list[dict[str, Any]],
    *,
    annotation: dict[str, Any] | None,
    clock: str,
    cell_budget: int = 100_000_000,
) -> dict[str, Any]:
    """Score one complete, linear-text trace; independent slices can be aggregated.

    Every snapshot is the full displayed text for the same slice, with seconds
    relative to audio playback start. The final snapshot alone is sealed.
    reference_token_map assigns each displayed scoring token a human-reviewed
    reference index or None (insertion). Text edits cannot identify repeated
    spoken words reliably, so missing correspondence stays not_observed.
    """
    if (
        not isinstance(reference, str)
        or len(reference) > 20000
        or not isinstance(clock, str)
        or clock not in {"api_received", "app_ui_submission"}
        or type(cell_budget) is not int
        or not 1 <= cell_budget <= 100_000_000
        or not isinstance(observations, list)
        or not 1 <= len(observations) <= 2048
    ):
        raise ValueError("revision trace exceeds scoring bounds or has invalid metadata")
    total_characters, previous_at = 0, 0.0
    prepared = []
    for index, observation in enumerate(observations):
        if (
            not isinstance(observation, dict)
            or set(observation) - {"at_seconds", "text", "sealed", "reference_token_map"}
            or not {"at_seconds", "text", "sealed"} <= set(observation)
            or not isinstance(observation["text"], str)
            or len(observation["text"]) > 20000
            or type(observation["sealed"]) is not bool
            or observation["sealed"] != (index == len(observations) - 1)
        ):
            raise ValueError("trace requires bounded snapshots and one final seal")
        at = _seconds(observation["at_seconds"])
        if at < previous_at:
            raise ValueError("trace clock regressed")
        total_characters += len(observation["text"])
        if total_characters > 1_000_000:
            raise ValueError("trace text exceeds aggregate scoring bounds")
        prepared.append((at, observation["text"], observation.get("reference_token_map")))
        previous_at = at
    expected = _tokens(reference)
    endings, correspondence = None, False
    if annotation is not None:
        if (
            not isinstance(annotation, dict)
            or annotation.get("kind") != "independent_human_annotation"
            or set(annotation) - {
                "kind", "token_timings", "timing_provenance", "correspondence_provenance"
            }
        ):
            raise ValueError("independent reference provenance is required")
        endings = _timings(annotation, expected)
        if "correspondence_provenance" in annotation:
            if annotation["correspondence_provenance"] != "human_reviewed_trace":
                raise ValueError("independent human trace correspondence is required")
            correspondence = True
        if endings and max(endings) > prepared[-1][0]:
            raise ValueError("trace sealed before the reference audio ended")
    for _, text, mapping in prepared:
        if correspondence:
            actual = _tokens(text)
            if not isinstance(mapping, list) or len(mapping) != len(actual):
                raise ValueError("each displayed token needs human trace correspondence")
            indices = [index for index in mapping if index is not None]
            if any(type(index) is not int or not 0 <= index < len(expected) for index in indices):
                raise ValueError("invalid reference token correspondence")
            if indices != sorted(set(indices)):
                raise ValueError("reference correspondence must be unique and monotonic")
        elif mapping is not None:
            raise ValueError("trace correspondence lacks independent human provenance")
    result: dict[str, Any] = {
        "correct_to_wrong": "not_observed",
        "ui_submission_latency": "not_observed",
        "churn": "not_observed",
        "trace_scoring": {
            "status": "observed", "clock": clock,
            "reference_correspondence": "human_reviewed" if correspondence else "not_observed",
            "clock_provenance": "caller_declared_unverified",
            "production_gate": "unset",
            "tokenization": "NFKC_casefold_Latin_words_other_lexical_characters",
            "observation_count": len(prepared),
        },
    }
    first_display: list[float | None] = [None] * len(expected)
    first_correct: list[float | None] = [None] * len(expected)
    last_changed: list[float | None] = [None] * len(expected)
    previous_values: list[str | None] = [None] * len(expected)
    ever_correct, affected, transitions = set(), set(), 0
    rewritten, inline_insertions, ages, spent = 0, 0, [], 0
    previous_tokens, previous_births = [], []
    for at, text, mapping in prepared:
        actual = _tokens(text)
        old_values, new_values = [t[0] for t in previous_tokens], [t[0] for t in actual]
        if new_values[:len(old_values)] == old_values:
            changes = [(i, i, i) for i in range(len(old_values))]
            changes += [(None, i, len(old_values)) for i in range(len(old_values), len(new_values))]
        elif old_values[:len(new_values)] == new_values:
            changes = [(i, i, i) for i in range(len(new_values))]
            changes += [(i, None, i) for i in range(len(new_values), len(old_values))]
        else:
            spent += (len(previous_tokens) + 1) * (len(actual) + 1)
            if spent > cell_budget:
                return {
                    **result, "trace_scoring": {"status": "not_observed", "reason": "cell_budget"}
                }
            changes = _alignment(previous_tokens, actual)
        if changes is None:
            return {**result, "trace_scoring": {"status": "not_observed", "reason": "cell_budget"}}
        births = [at] * len(actual)
        for left, right, anchor in changes:
            if left is None:
                inline_insertions += anchor < len(previous_tokens)
            elif right is not None and previous_tokens[left][0] == actual[right][0]:
                births[right] = previous_births[left]
            else:
                rewritten += 1
                ages.append(at - previous_births[left])
        if correspondence:
            values: list[str | None] = [None] * len(expected)
            for right, left in enumerate(mapping):
                if left is not None:
                    values[left] = actual[right][0]
            for index, value in enumerate(values):
                old = previous_values[index]
                correct = value == expected[index][0]
                if correct:
                    ever_correct.add(index)
                    if first_correct[index] is None:
                        first_correct[index] = at
                if old == expected[index][0] and not correct:
                    affected.add(index)
                    transitions += 1
                if value is not None and first_display[index] is None:
                    first_display[index] = at
                if value != old:
                    last_changed[index] = at
            previous_values = values
        previous_tokens, previous_births = actual, births
    result["churn"] = {
        "rewritten_tokens": rewritten,
        "inline_inserted_tokens": inline_insertions,
        "rewrite_age_seconds": _distribution(ages),
        "pure_tail_append_counted": False,
    }
    if correspondence:
        result["correct_to_wrong"] = {
            "reference_tokens": len(expected), "ever_correct_tokens": len(ever_correct),
            "affected_tokens": len(affected), "transition_count": transitions,
            "rate": len(affected) / len(ever_correct) if ever_correct else None,
        }
    if correspondence and endings is not None and clock == "app_ui_submission":
        result["ui_submission_latency"] = {
            "reference_tokens": len(expected),
            "unobserved_tokens": sum(value is None for value in first_display),
            "first_display_seconds": _distribution([
                value - end for value, end in zip(first_display, endings, strict=True)
                if value is not None
            ]),
            "first_correct_display_seconds": _distribution([
                value - end for value, end in zip(first_correct, endings, strict=True)
                if value is not None
            ]),
            "last_change_to_seal_seconds": _distribution([
                prepared[-1][0] - value for value in last_changed if value is not None
            ]),
            "method": "independent_human_trace_correspondence",
            "evidence_provenance": "caller_declared_unverified",
            "audio_origin": "playback_start",
        }
    return result


def main() -> None:  # pragma: no cover - thin file adapter
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.trace.resolve().is_relative_to(Path(__file__).resolve().parents[2]):
        raise ValueError("reference traces must stay outside the repository")
    if args.trace.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("trace file exceeds input bounds")
    payload = json.loads(args.trace.read_text())
    if not isinstance(payload, dict) or set(payload) != {
        "reference", "observations", "annotation", "clock"
    }:
        raise ValueError("invalid revision trace envelope")
    result = score_revision_trace(**payload)
    with args.output.open("x") as destination:
        destination.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
