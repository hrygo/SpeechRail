"""Offline, text-free triage of paired segment diagnostics; never runs inference."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

_DIGEST = re.compile(r"[0-9a-f]{64}")
_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")


def _integer(value: object, *, positive: bool = False) -> int:
    if type(value) is not int or value < int(positive):
        raise ValueError("invalid diagnostic count")
    return value


def _digest(value: object) -> str:
    if not isinstance(value, str) or _DIGEST.fullmatch(value) is None:
        raise ValueError("invalid diagnostic digest")
    return value


def _sessions(payload: Mapping[str, Any]) -> dict[tuple[str, int], dict[str, Any]]:
    if not isinstance(payload, Mapping):
        raise ValueError("diagnostic document must be an object")
    if (
        payload.get("tool") != "speechrail-asr-segment-diagnostic"
        or type(payload.get("schema_version")) is not int
        or payload["schema_version"] != 2
        or type(payload.get("diagnostic_schema_version")) is not int
        or payload["diagnostic_schema_version"] not in (1, 2)
        or type(payload.get("source_result_schema_version")) is not int
        or payload["source_result_schema_version"] != 2
        or payload.get("evidence_mode") != "real"
        or payload.get("measurement_completed") is not True
        or payload.get("failure_kind") is not None
    ):
        raise ValueError("completed real schema 2 segment diagnostics required")
    rows = payload.get("sessions")
    if not isinstance(rows, list) or not rows or len(rows) > 8192:
        raise ValueError("invalid diagnostic sessions")
    sessions = {}
    fixture_repeats: dict[str, list[int]] = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("invalid diagnostic session")
        fixture_id = row.get("id")
        if not isinstance(fixture_id, str) or _ID.fullmatch(fixture_id) is None:
            raise ValueError("invalid opaque fixture identifier")
        repeat = _integer(row.get("repeat"), positive=True)
        key = (fixture_id, repeat)
        if key in sessions:
            raise ValueError("duplicate diagnostic request")
        seconds = row.get("audio_seconds")
        if (
            type(seconds) not in (int, float)
            or not math.isfinite(seconds) or seconds <= 0
            or not isinstance(row.get("effective_policy"), dict)
        ):
            raise ValueError("invalid diagnostic duration or policy")
        quality = row.get("quality_metrics")
        if not isinstance(quality, dict) or any(
            quality.get(gate) != "pass"
            for gate in ("sample_coverage_gate", "segment_budget_gate")
        ):
            raise ValueError("diagnostic input integrity gates must pass")
        diagnostic = quality.get("segment_diagnostic")
        if not isinstance(diagnostic, dict) or (
            type(diagnostic.get("diagnostic_schema_version")) is not int
            or diagnostic["diagnostic_schema_version"] != payload["diagnostic_schema_version"]
            or diagnostic.get("acoustic_error_attribution") != "not_observed"
        ):
            raise ValueError("invalid segment diagnostic")
        for field in ("character_errors", "reference_characters", "hypothesis_characters"):
            value = _integer(quality.get(field), positive=field == "reference_characters")
            if type(diagnostic.get(field)) is not int or diagnostic[field] != value:
                raise ValueError("diagnostic disagrees with shared quality score")
        if quality.get("normalization") != diagnostic.get("normalization"):
            raise ValueError("diagnostic normalization mismatch")
        _digest(diagnostic.get("reference_normalized_sha256"))
        _digest(diagnostic.get("hypothesis_normalized_sha256"))
        if diagnostic["diagnostic_schema_version"] == 2:
            _digest(diagnostic.get("hypothesis_exact_sha256"))
        segments = diagnostic.get("segments")
        if not isinstance(segments, list) or not 1 <= len(segments) <= 64:
            raise ValueError("invalid diagnostic segments")
        cursor = 0
        for ordinal, segment in enumerate(segments):
            if not isinstance(segment, dict):
                raise ValueError("invalid diagnostic segment")
            if _integer(segment.get("ordinal")) != ordinal:
                raise ValueError("invalid diagnostic ordinal")
            start = _integer(segment.get("start_sample"))
            end = _integer(segment.get("end_sample"), positive=True)
            if start != cursor or end <= start:
                raise ValueError("invalid diagnostic sample coverage")
            _digest(segment.get("terminal_normalized_sha256"))
            if segment.get("preview_normalized_sha256") is not None:
                _digest(segment["preview_normalized_sha256"])
            if diagnostic["diagnostic_schema_version"] == 2:
                _digest(segment.get("terminal_exact_sha256"))
                if "preview_exact_sha256" not in segment:
                    raise ValueError("missing preview digest")
                if segment["preview_exact_sha256"] is not None:
                    _digest(segment["preview_exact_sha256"])
                if (segment["preview_exact_sha256"] is None) != (
                    segment.get("preview_normalized_sha256") is None
                ):
                    raise ValueError("preview digest presence disagrees")
            cursor = end
        if abs(cursor - seconds * 24_000) > 1e-6:
            raise ValueError("diagnostic duration differs from covered wire audio")
        sessions[key] = row
        fixture_repeats.setdefault(fixture_id, []).append(repeat)
    for repeats in fixture_repeats.values():
        repeats = sorted(repeats)
        if repeats != list(range(1, len(repeats) + 1)):
            raise ValueError("diagnostic repeats must be consecutive from one")
    return sessions


def _change(left: object, right: object, *, exact: bool = False) -> str:
    if left is None or right is None:
        if exact:
            return "not_observed"
        return (
            "missing_both" if left is None and right is None
            else "missing_baseline" if left is None else "missing_candidate"
        )
    return "equal" if left == right else "changed"


def _punctuation_comparison(left: Mapping, right: Mapping) -> dict:
    a, b = left.get("punctuation_metrics"), right.get("punctuation_metrics")
    if not isinstance(a, dict) or not isinstance(b, dict):
        return {"status": "not_observed"}
    gold_a = left.get("punctuation_reference_exact_sha256")
    gold_b = right.get("punctuation_reference_exact_sha256")
    if gold_a is None or gold_b is None:
        return {"status": "not_comparable", "reason": "gold_identity_not_observed"}
    if _digest(gold_a) != _digest(gold_b):
        return {"status": "not_comparable", "reason": "gold_identity_differs"}
    identity = ("gold_kind", "gold_scope", "method", "class_scope", "alignment_tie_break")
    if (
        a.get("status") != "scored" or b.get("status") != "scored"
        or any(a.get(field) != b.get(field) for field in identity)
    ):
        return {"status": "not_comparable"}

    def difference(x, y):
        if x is None or y is None:
            return None
        if (
            type(x) not in (int, float) or type(y) not in (int, float)
            or not math.isfinite(x) or not math.isfinite(y)
            or not 0 <= x <= 1 or not 0 <= y <= 1
        ):
            raise ValueError("invalid punctuation ratio")
        return y - x

    classes = ("comma", "period", "question", "exclamation")
    support_a, support_b = a.get("class_support"), b.get("class_support")
    if not isinstance(support_a, dict) or not isinstance(support_b, dict):
        raise ValueError("invalid punctuation class support")
    return {
        "status": "observed",
        "gold_identity_gate": "pass",
        "f1_delta": difference(a.get("f1"), b.get("f1")),
        "class_f1_delta": {
            key: difference(support_a[key].get("f1"), support_b[key].get("f1"))
            for key in classes
        },
        "punctuation_gate": "not_evaluated",
    }


def analyze_pair(
    baseline: Mapping[str, Any], candidate: Mapping[str, Any],
) -> dict[str, object]:
    """Localize observed changes, without deciding model cause or release acceptance."""
    before, after = _sessions(baseline), _sessions(candidate)
    if list(before) != list(after):
        raise ValueError("paired request identity and order must match")
    if baseline.get("profile") != candidate.get("profile"):
        raise ValueError("paired profiles must match")
    comparisons = []
    signatures: dict[str, set[tuple[object, ...]]] = {}
    representatives: dict[str, dict[str, object]] = {}
    for key, left in before.items():
        right = after[key]
        old = left["quality_metrics"]["segment_diagnostic"]
        new = right["quality_metrics"]["segment_diagnostic"]
        if "wire_pcm_sha256" in left or "wire_pcm_sha256" in right:
            if _digest(left.get("wire_pcm_sha256")) != _digest(right.get("wire_pcm_sha256")):
                raise ValueError("paired wire audio must match")
        if any(
            old[field] != new[field]
            for field in ("normalization", "reference_characters", "reference_normalized_sha256")
        ) or any(
            left[field] != right[field] for field in ("audio_seconds", "effective_policy")
        ):
            raise ValueError("paired reference, duration and effective policy must match")
        old_spans = [(s["start_sample"], s["end_sample"]) for s in old["segments"]]
        new_spans = [(s["start_sample"], s["end_sample"]) for s in new["segments"]]
        changed_finals = []
        segment_comparisons = []
        if old_spans == new_spans:
            for ordinal, (a, b) in enumerate(zip(old["segments"], new["segments"], strict=True)):
                preview_change = _change(
                    a.get("preview_normalized_sha256"), b.get("preview_normalized_sha256"),
                )
                preview_exact = (
                    _change(a.get("preview_exact_sha256"), b.get("preview_exact_sha256"), exact=True)
                    if preview_change not in ("missing_baseline", "missing_candidate", "missing_both")
                    else preview_change
                )
                segment_comparisons.append({
                    "ordinal": ordinal,
                    "preview_normalized_change": preview_change,
                    "preview_exact_change": preview_exact,
                    "terminal_normalized_change": _change(
                        a["terminal_normalized_sha256"], b["terminal_normalized_sha256"],
                    ),
                    "terminal_exact_change": _change(
                        a.get("terminal_exact_sha256"), b.get("terminal_exact_sha256"), exact=True,
                    ),
                })
                if (
                    a["preview_normalized_sha256"] is not None
                    and a["preview_normalized_sha256"] == b["preview_normalized_sha256"]
                    and a["terminal_normalized_sha256"] != b["terminal_normalized_sha256"]
                    and b["terminal_normalized_sha256"] != b["preview_normalized_sha256"]
                ):
                    changed_finals.append(ordinal)
        delta = new["character_errors"] - old["character_errors"]
        normalized_changed = old["hypothesis_normalized_sha256"] != new["hypothesis_normalized_sha256"]
        exact_change = _change(
            old.get("hypothesis_exact_sha256"), new.get("hypothesis_exact_sha256"), exact=True,
        )
        changed = (
            True if normalized_changed or exact_change == "changed"
            else False if exact_change == "equal" else None
        )
        preview_changed = any(
            row[field] in ("changed", "missing_baseline", "missing_candidate")
            for row in segment_comparisons
            for field in ("preview_normalized_change", "preview_exact_change")
        )
        observation = (
            "segment_boundaries_changed" if old_spans != new_spans
            else "final_changed_after_equal_previews" if changed_finals
            else "preview_or_context_path_changed" if normalized_changed
            else "exact_only_final_changed" if exact_change == "changed"
            else "preview_changed_with_same_normalized_final" if preview_changed
            else "unchanged" if exact_change == "equal"
            else "normalized_unchanged_exact_not_observed"
        )
        punctuation = _punctuation_comparison(left["quality_metrics"], right["quality_metrics"])
        row = {
            "id": key[0], "repeat": key[1],
            "baseline_errors": old["character_errors"],
            "candidate_errors": new["character_errors"],
            "error_delta": delta, "output_changed": changed,
            "final_normalized_changed": normalized_changed,
            "final_exact_change": exact_change,
            "observation": observation,
            "equal_preview_changed_final_segments": changed_finals,
            "segment_comparisons": segment_comparisons,
            "punctuation_comparison": punctuation,
            "segment_comparison_status": (
                "observed" if old_spans == new_spans else "boundaries_differ"
            ),
        }
        comparisons.append(row)
        signatures.setdefault(key[0], set()).add((
            old["hypothesis_normalized_sha256"], new["hypothesis_normalized_sha256"],
            old.get("hypothesis_exact_sha256"), new.get("hypothesis_exact_sha256"),
            delta, observation, tuple(changed_finals),
            tuple(
                (s["start_sample"], s["end_sample"], s["terminal_normalized_sha256"],
                 s.get("terminal_exact_sha256"), s.get("preview_normalized_sha256"),
                 s.get("preview_exact_sha256"))
                for diagnostic in (old, new) for s in diagnostic["segments"]
            ),
            json.dumps(punctuation, sort_keys=True),
        ))
        role = (
            "final_regression" if delta > 0 and changed_finals
            else "other_regression" if delta > 0
            else "final_improvement" if delta < 0 and changed_finals
            else "preview_path_improvement" if delta < 0
            else "changed_equal_score" if changed
            else "preview_changed_equal_score" if preview_changed
            else "zero_error_control" if old["character_errors"] == 0
            else "unchanged_error_control"
        )
        # Select one fixture per observed family for initial triage. Every
        # regression still remains in comparisons and must be checked before adoption.
        representatives.setdefault(role, {
            "id": key[0], "role": role, "audio_seconds": left["audio_seconds"],
        })
    roles = (
        "final_regression", "other_regression", "final_improvement",
        "preview_path_improvement", "changed_equal_score", "preview_changed_equal_score",
        "zero_error_control",
    )
    cases = [representatives[role] for role in roles if role in representatives]
    return {
        "schema_version": 2,
        "tool": "speechrail-asr-focus-analysis",
        "scope": "offline paired text localization and initial triage selection",
        "formal_requests_per_arm": len(before),
        "independent_fixture_count": len(signatures),
        "comparisons": comparisons,
        "repeat_consistency": {key: len(value) == 1 for key, value in signatures.items()},
        "repeat_consistency_scope": "observed digests, segment spans and score differences",
        "exact_observation_complete": all(
            row["final_exact_change"] != "not_observed"
            and all(segment["preview_exact_change"] != "not_observed"
                    for segment in row["segment_comparisons"])
            for row in comparisons
        ),
        "triage_cases": cases,
        "triage_requests_per_arm": len(cases),
        "triage_audio_seconds_per_arm": sum(row["audio_seconds"] for row in cases),
        "relative_character_error_gate": (
            "fail" if any(row["error_delta"] > 0 for row in comparisons) else "pass"
        ),
        "measurement_identity_gate": "not_evaluated",
        "mechanism_attribution": "not_proven",
        "acoustic_error_attribution": "not_observed",
        "acceptance_gate": "not_evaluated",
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        sources = {
            "baseline": args.baseline.read_bytes(), "candidate": args.candidate.read_bytes(),
        }
        report = analyze_pair(*(json.loads(sources[arm]) for arm in ("baseline", "candidate")))
        report["source_sha256"] = {
            arm: hashlib.sha256(data).hexdigest() for arm, data in sources.items()
        }
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2, ensure_ascii=False, allow_nan=False)
            stream.write("\n")
    except (OSError, ValueError, TypeError, KeyError) as exc:
        print(f"ASR focus analysis failed: {type(exc).__name__}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
