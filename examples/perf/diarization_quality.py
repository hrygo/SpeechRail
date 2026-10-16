"""Independent, session-wide anonymous diarization scoring (evaluation only)."""

from __future__ import annotations

import importlib.metadata
import math
from collections import Counter, defaultdict
from collections.abc import Sequence
from typing import Any


def score_diarization(
    reference: Sequence[dict[str, Any]],
    hypothesis: Sequence[dict[str, Any]],
    *,
    duration: float,
) -> dict[str, Any]:
    # Locked evaluation dependency; never imported by service request paths.
    from pyannote.core import Annotation, Segment, Timeline
    from pyannote.metrics.diarization import DiarizationErrorRate, JaccardErrorRate
    from pyannote.metrics.identification import IdentificationErrorRate

    if importlib.metadata.version("pyannote-metrics") != "4.1":
        raise ValueError("diarization scorer version differs from evaluation lock")
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("invalid evaluation duration")

    def annotation(rows):
        if len(rows) > 100000:
            raise ValueError("too many evaluation intervals")
        result = Annotation()
        for index, row in enumerate(rows):
            a, b, label = row["start"], row["end"], row["speaker"]
            if (
                type(a) not in (int, float)
                or type(b) not in (int, float)
                or not math.isfinite(a + b)
                or not 0 <= a < b <= duration + 1/16000 + 1e-9
                or not isinstance(label, str)
                or not label
            ):
                raise ValueError("invalid evaluation interval")
            result[Segment(a, min(b, duration)), index] = label
        return result

    ref, hyp = annotation(reference), annotation(hypothesis)
    uem = Timeline([Segment(0, duration)])
    mapper = DiarizationErrorRate(collar=0, skip_overlap=False)
    mapping = mapper.optimal_mapping(ref, hyp, uem=uem)
    mapped = hyp.rename_labels(
        mapping={label: mapping.get(label, "unmapped:" + label) for label in hyp.labels()}
    )
    der = IdentificationErrorRate(collar=0, skip_overlap=False)(ref, mapped, uem=uem)
    jer = JaccardErrorRate(collar=0, skip_overlap=False)(ref, hyp, uem=uem)
    comparable = IdentificationErrorRate(collar=0.25, skip_overlap=True)(ref, mapped, uem=uem)
    events = defaultdict(list)
    for group, rows in (("reference", reference), ("hypothesis", hypothesis)):
        for row in rows:
            label = (
                row["speaker"]
                if group == "reference"
                else mapping.get(row["speaker"], "unmapped:" + row["speaker"])
            )
            events[float(row["start"])].append((group, label, 1))
            events[min(float(row["end"]), duration)].append((group, label, -1))
    events[0.0]
    events[duration]
    active = {"reference": Counter(), "hypothesis": Counter()}
    per = {
        label: {
            "reference_seconds": 0.0,
            "known_seconds": 0.0,
            "correct_seconds": 0.0,
            "all_reference_seconds": 0.0,
        }
        for label in ref.labels()
    }
    reference_seconds = known_seconds = predicted_seconds = correct_seconds = overlap_seconds = 0.0
    points = sorted(events)
    for index, a in enumerate(points[:-1]):
        for group, label, delta in events[a]:
            active[group][label] += delta
            if active[group][label] == 0:
                del active[group][label]
        b = points[index + 1]
        seconds = b - a
        rs, hs = set(active["reference"]), set(active["hypothesis"])
        for label in rs:
            per[label]["all_reference_seconds"] += seconds
        if len(rs) > 1:
            overlap_seconds += seconds * len(rs)
            continue
        predicted_seconds += seconds * len(hs)
        if len(rs) != 1:
            continue
        label = next(iter(rs))
        reference_seconds += seconds
        per[label]["reference_seconds"] += seconds
        if hs:
            known_seconds += seconds
            per[label]["known_seconds"] += seconds
        if label in hs:
            correct_seconds += seconds
            per[label]["correct_seconds"] += seconds
    known = known_seconds / reference_seconds if reference_seconds else 0
    accuracy = correct_seconds / predicted_seconds if predicted_seconds else 0
    ordered = sorted(per, key=lambda label: (-per[label]["all_reference_seconds"], label))
    for label in per:
        per[label]["known_coverage"] = (
            per[label]["known_seconds"] / per[label]["reference_seconds"]
            if per[label]["reference_seconds"]
            else None
        )
        per[label]["known_accuracy"] = (
            per[label]["correct_seconds"] / per[label]["known_seconds"]
            if per[label]["known_seconds"]
            else None
        )
    top = [
        per[label]["known_coverage"] for label in ordered[:4] if per[label]["reference_seconds"] > 0
    ]
    other = [
        per[label]["known_coverage"]
        for label in ordered[4:]
        if per[label]["reference_seconds"] >= 2
    ]
    top_min, other_min = min(top, default=0), min(other, default=1)
    return {
        "scorer": "pyannote.metrics",
        "scorer_version": "4.1",
        "mapping_scope": "whole_session_once",
        "collar_seconds": 0,
        "skip_overlap": False,
        "der": float(der),
        "jer": float(jer),
        "comparable": {
            "collar_seconds": 0.25,
            "skip_overlap": True,
            "der": float(comparable),
            "mapping_scope": "same_whole_session_mapping",
        },
        "known_coverage": known,
        "known_accuracy": accuracy,
        "unknown_fraction": 1 - known,
        "known_denominator": "nonoverlap_reference_seconds",
        "reference_seconds": reference_seconds,
        "overlap_reference_speaker_seconds": overlap_seconds,
        "top_four_min_known_coverage": top_min,
        "other_min_known_coverage": other_min,
        "participants": list(per.values()),
        "participant_count": len(per),
        "short_under_two_seconds": sum(
            0 < values["reference_seconds"] < 2 for values in per.values()
        ),
        "speaker_attributed_word_error": "not_observed",
        "quality_gate": "pass"
        if known >= 0.9 and accuracy >= 0.95 and top_min >= 0.95 and other_min >= 0.8
        else "fail",
    }
