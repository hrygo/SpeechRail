"""Selective attribution scores for a frozen, at-most-four identity mapping.

Evaluation only; no model imports, identity inference, text-loss claims or quality
gate. Intervals are half-open seconds, strictly within the evaluation duration.
Each input track must be nonoverlapping; use the separate DER/JER scorer for
overlapping speech. Hypothesis gaps, ``None`` and ``"unknown"`` all mean rejection.
The caller must freeze one confirmed mapping for the entire session; this pure
function cannot certify how that mapping was obtained or persisted across calls.
"""

from __future__ import annotations

import math
from collections import defaultdict
from typing import Any

_IDENTITY_LIMIT = 4
_SHORT_TURN_SECONDS = 1.5
_MAX_INTERVALS = 100_000


def _finite_number(value: Any) -> bool:
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _identity(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip()) and value != "unknown"


def _intervals(
    rows: list[dict], *, duration: float, reference: bool
) -> list[tuple[float, float, str | None]]:
    if not isinstance(rows, list) or len(rows) > _MAX_INTERVALS:
        raise ValueError("invalid evaluation intervals")
    result = []
    for row in rows:
        if not isinstance(row, dict) or not {"start", "end", "speaker"} <= row.keys():
            raise ValueError("invalid evaluation interval")
        start, end, speaker = row["start"], row["end"], row["speaker"]
        unknown = speaker is None or speaker == "unknown"
        if (
            not _finite_number(start)
            or not _finite_number(end)
            or not 0 <= start < end <= duration
            or (not _identity(speaker) and (reference or not unknown))
        ):
            raise ValueError("invalid evaluation interval")
        result.append((float(start), float(end), None if unknown else speaker))
    result.sort(key=lambda row: (row[0], row[1]))
    merged = []
    for row in result:
        if merged and row[0] < merged[-1][1]:
            raise ValueError("overlapping evaluation intervals are not supported")
        # A turn is contiguous speech by the same reference identity, regardless
        # of annotation fragmentation. Hypothesis merging is harmless as well.
        if merged and row[0] == merged[-1][1] and row[2] == merged[-1][2]:
            merged[-1] = (merged[-1][0], row[1], row[2])
        else:
            merged.append(row)
    return merged


def _ratio(numerator: float, denominator: float) -> float | None:
    return numerator / denominator if denominator else None


def score_stable_speakers(
    reference: list[dict],
    hypothesis: list[dict],
    *,
    duration: float,
    speaker_mapping: dict[str, str],
) -> dict:
    """Score attribution without remapping identities or discarding unknown speech.

    ``speaker_mapping`` maps automatic labels to confirmed anonymous reference
    identities, one-to-one, with at most four entries (including currently silent
    tracked identities). Unmapped known outputs and invalid mappings raise
    ``ValueError`` rather than silently ignoring identity-budget violations.

    ``known_precision`` uses *all* known hypothesis seconds, including false
    alarms outside reference speech. Other global speech fractions use reference
    speech, not recording duration. Out-of-set false acceptance uses reference
    speech whose identity is absent from the mapping targets. ``per_speaker``
    includes every reference identity; its known/unknown seconds describe any
    assignment/rejection on that identity's speech, not predictions of its name.
    Undefined rates are ``None``. The oracle top-four fraction is only an ideal
    duration ceiling and never determines the tracked identities.

    Short turns are maximal contiguous same-identity reference spans shorter
    than 1.5 seconds. A turn is misattributed if *any* of its duration receives
    an incorrect known identity; rejection alone is not misattribution.
    """
    if not _finite_number(duration) or duration <= 0:
        raise ValueError("invalid evaluation duration")
    if (
        not isinstance(speaker_mapping, dict)
        or len(speaker_mapping) > _IDENTITY_LIMIT
        or any(not _identity(k) or not _identity(v) for k, v in speaker_mapping.items())
        or len(set(speaker_mapping.values())) != len(speaker_mapping)
    ):
        raise ValueError("identity budget or one-to-one mapping violation")
    mapping = dict(speaker_mapping)
    ref = _intervals(reference, duration=duration, reference=True)
    hyp = _intervals(hypothesis, duration=duration, reference=False)
    if any(speaker is not None and speaker not in mapping for _, _, speaker in hyp):
        raise ValueError("known output label is absent from frozen speaker mapping")

    # Linear intersection sweep after sorting: gaps remain unknown, even when
    # the hypothesis omits the entire turn. No gap implies anything about text.
    per: dict[str, dict[str, Any]] = {}
    short = {
        "threshold_seconds": _SHORT_TURN_SECONDS,
        "count": 0,
        "misattributed_count": 0,
        "reference_seconds": 0.0,
        "correct_seconds": 0.0,
        "unknown_seconds": 0.0,
    }
    hypothesis_index = 0
    for start, end, identity in ref:
        seconds = end - start
        overlaps: dict[str, list[float]] = defaultdict(list)
        while hypothesis_index < len(hyp) and hyp[hypothesis_index][1] <= start:
            hypothesis_index += 1
        index = hypothesis_index
        while index < len(hyp) and hyp[index][0] < end:
            h_start, h_end, label = hyp[index]
            if label is not None:
                overlaps[mapping[label]].append(min(end, h_end) - max(start, h_start))
            index += 1
        known = math.fsum(value for values in overlaps.values() for value in values)
        correct = math.fsum(overlaps.get(identity, []))
        unknown = max(0.0, seconds - known)
        values = per.setdefault(
            identity,
            {
                "reference_seconds": 0.0,
                "correct_seconds": 0.0,
                "known_seconds": 0.0,
                "unknown_seconds": 0.0,
            },
        )
        for key, value in (
            ("reference_seconds", seconds),
            ("correct_seconds", correct),
            ("known_seconds", known),
            ("unknown_seconds", unknown),
        ):
            values[key] += value
        if seconds < _SHORT_TURN_SECONDS:
            short["count"] += 1
            short["misattributed_count"] += int(any(key != identity for key in overlaps))
            short["reference_seconds"] += seconds
            short["correct_seconds"] += correct
            short["unknown_seconds"] += unknown

    reference_seconds = math.fsum(v["reference_seconds"] for v in per.values())
    correct_seconds = math.fsum(v["correct_seconds"] for v in per.values())
    unknown_seconds = math.fsum(v["unknown_seconds"] for v in per.values())
    known_seconds = math.fsum(end - start for start, end, label in hyp if label is not None)
    tracked = set(mapping.values())
    tracked_seconds = math.fsum(v["reference_seconds"] for k, v in per.items() if k in tracked)
    untracked_seconds = math.fsum(
        v["reference_seconds"] for k, v in per.items() if k not in tracked
    )
    out_of_set_known = math.fsum(v["known_seconds"] for k, v in per.items() if k not in tracked)
    oracle_seconds = math.fsum(
        sorted((v["reference_seconds"] for v in per.values()), reverse=True)[:_IDENTITY_LIMIT]
    )
    for values in per.values():
        values["correct_coverage"] = _ratio(values["correct_seconds"], values["reference_seconds"])
    return {
        "identity_limit": _IDENTITY_LIMIT,
        "identity_budget_exceeded": False,
        "mapping_scope": "whole_session_once_frozen",
        "reference_seconds": reference_seconds,
        "known_seconds": known_seconds,
        "correct_seconds": correct_seconds,
        "unknown_seconds": unknown_seconds,
        "known_precision": _ratio(correct_seconds, known_seconds),
        "correct_coverage": _ratio(correct_seconds, reference_seconds),
        "unknown_fraction": _ratio(unknown_seconds, reference_seconds),
        "out_of_set_false_accept_rate": _ratio(out_of_set_known, untracked_seconds),
        "per_speaker": dict(sorted(per.items())),
        "tracked_speech_fraction": _ratio(tracked_seconds, reference_seconds),
        "oracle_top_four_fraction": _ratio(oracle_seconds, reference_seconds),
        "short_turns": short,
    }
