"""Evaluation-only product gates and independently implemented standard metrics.

Session-scoped labels are used in RAM for matching, never copied into reports.
Unknown is excluded from product identity mapping, but retained as a text stream
by the official cp/tcp/greedy DI-cp scorers.
"""

from __future__ import annotations

import importlib.metadata
import math
import re
import unicodedata
from collections import Counter, defaultdict
from collections.abc import Mapping, Sequence
from typing import Any

try:
    from .diarization_quality import score_diarization
    from .meeting_evaluation_identity import canonical_digest
except ImportError:  # direct CLI imports
    from diarization_quality import score_diarization
    from meeting_evaluation_identity import canonical_digest

_WORD = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]|[a-z0-9]+")
_REQUIRED_POLICY = {
    "schema_version",
    "speaker_time_recall_min",
    "speaker_time_precision_min",
    "top_four_recall_min",
    "other_recall_min",
    "other_min_duration_seconds",
    "scorer_versions",
    "tokenization",
    "collar_seconds",
    "skip_overlap",
    "tcp_collar_seconds",
    "tcp_timing",
    "legacy_nonoverlap",
}


def _validate_policy(policy: Mapping[str, object]) -> None:
    missing = _REQUIRED_POLICY - set(policy)
    if missing:
        raise ValueError(f"incomplete scorer policy: {sorted(missing)}")
    if (
        type(policy["schema_version"]) is not int
        or policy["schema_version"] != 2
        or policy["skip_overlap"] is not False
    ):
        raise ValueError("policy must use schema 2 and include overlap")
    if policy["collar_seconds"] != 0:
        raise ValueError("product policy requires zero collar")
    for key in (
        "speaker_time_recall_min",
        "speaker_time_precision_min",
        "top_four_recall_min",
        "other_recall_min",
    ):
        if type(policy[key]) not in (int, float) or not 0 <= policy[key] <= 1:
            raise ValueError(f"invalid policy threshold: {key}")
    for key in ("other_min_duration_seconds", "tcp_collar_seconds"):
        if (
            type(policy[key]) not in (int, float)
            or not math.isfinite(policy[key])
            or policy[key] < 0
        ):
            raise ValueError(f"invalid policy duration: {key}")
    if policy["scorer_versions"] != {"pyannote.metrics": "4.1", "meeteval": "0.4.3"}:
        raise ValueError("scorer versions differ from approved policy")
    if policy["tokenization"] != {
        "character": "NFKC_casefold_unicode_L_N_M_v1",
        "word": "NFKC_casefold_cjk_char_and_alnum_word_v1",
    }:
        raise ValueError("unsupported tokenization policy")
    if policy["tcp_timing"] != {
        "reference": "character_based",
        "hypothesis": "character_based_points",
    }:
        raise ValueError("unsupported tcp timing policy")
    if policy["legacy_nonoverlap"] != {
        "known_coverage_min": 0.9,
        "known_accuracy_min": 0.95,
        "top_four_min_known_coverage_min": 0.95,
        "other_min_known_coverage_min": 0.8,
    }:
        raise ValueError("legacy policy must retain the frozen gates")
    canonical_digest(policy)  # Reject NaN/non-JSON values anywhere in the policy.


def _validate_rows(rows, *, duration: float, reference: bool) -> list[dict[str, Any]]:
    if len(rows) > 100000:
        raise ValueError("too many evaluation intervals")
    result = []
    for row in rows:
        a, b, label = row.get("start"), row.get("end"), row.get("speaker")
        if (
            type(a) not in (int, float)
            or type(b) not in (int, float)
            or not math.isfinite(a + b)
            or not 0 <= a < b <= duration + 1 / 16000 + 1e-9
            or not isinstance(label, str)
            or not label
            or ("text" in row and not isinstance(row["text"], str))
        ):
            raise ValueError("invalid evaluation interval or label")
        if reference and label == "unknown":
            raise ValueError("reference identity must be independently annotated")
        result.append({**row, "end": min(b, duration)})
    return sorted(result, key=lambda r: (r["start"], r["end"], r["speaker"]))


def _speaker_time(reference, hypothesis, policy) -> dict[str, Any]:
    from scipy.optimize import linear_sum_assignment

    events = defaultdict(list)
    for group, rows in (("r", reference), ("h", hypothesis)):
        for row in rows:
            events[row["start"]].append((group, row["speaker"], 1))
            events[row["end"]].append((group, row["speaker"], -1))
    points = sorted(events)
    active = {"r": Counter(), "h": Counter()}
    ref_time, hyp_time, intersections = defaultdict(float), defaultdict(float), defaultdict(float)
    for index, start in enumerate(points[:-1]):
        for group, label, delta in events[start]:
            active[group][label] += delta
            if active[group][label] == 0:
                del active[group][label]
        seconds = points[index + 1] - start
        rs, hs = set(active["r"]), set(active["h"]) - {"unknown"}
        for r in rs:
            ref_time[r] += seconds
        for h in hs:
            hyp_time[h] += seconds
        for r in rs:
            for h in hs:
                intersections[r, h] += seconds
    rl, hl = sorted(ref_time), sorted(hyp_time)
    if len(rl) > 32 or len(hl) > 32:
        raise ValueError("evaluation speaker count exceeds bounds")
    correct = dict.fromkeys(rl, 0.0)
    if rl and hl:
        row_indices, col_indices = linear_sum_assignment(
            [[intersections[r, h] for h in hl] for r in rl],
            maximize=True,
        )
        for r, h in zip(row_indices, col_indices, strict=True):
            correct[rl[r]] = intersections[rl[r], hl[h]]
    dref, dhyp, c = sum(ref_time.values()), sum(hyp_time.values()), sum(correct.values())
    recall, precision = c / dref if dref else None, c / dhyp if dhyp else None
    ordered = sorted(rl, key=lambda r: (-ref_time[r], r))
    recalls = [correct[r] / ref_time[r] for r in ordered]
    top_min = min(recalls[:4], default=None)
    other = [
        correct[r] / ref_time[r]
        for r in ordered[4:]
        if ref_time[r] >= policy["other_min_duration_seconds"]
    ]
    other_min = min(other, default=None)
    participant_pass = (
        top_min is not None
        and top_min >= policy["top_four_recall_min"]
        and all(value >= policy["other_recall_min"] for value in other)
    )
    passed = (
        recall is not None
        and recall >= policy["speaker_time_recall_min"]
        and precision is not None
        and precision >= policy["speaker_time_precision_min"]
        and participant_pass
    )
    return {
        "availability": "observed" if dref else "not_observed",
        "mapping_scope": "whole_session_once_excluding_unknown",
        "reference_speakers_count": len(rl),
        "reference_speaker_seconds": dref,
        "hypothesis_speaker_seconds": dhyp,
        "correct_speaker_seconds": c,
        "recall": recall,
        "precision": precision,
        "top_four_min_recall": top_min,
        "other_min_recall": other_min,
        "other_gate_applicability": "observed" if other else "not_applicable",
        "participants": [
            {"reference_seconds": ref_time[r], "correct_seconds": correct[r], "recall": value}
            for r, value in zip(ordered, recalls, strict=True)
        ],
        "participant_gate": "pass" if participant_pass else "fail",
        "quality_gate": ("pass" if passed else "fail") if dref else "not_observed",
    }


def _tokens(text: str, *, char: bool) -> list[str]:
    text = unicodedata.normalize("NFKC", text).casefold()
    return (
        [c for c in text if unicodedata.category(c)[0] in {"L", "N", "M"}]
        if char
        else _WORD.findall(text)
    )


def _text_metrics(reference, hypothesis, policy) -> dict[str, Any]:
    from meeteval.io import SegLST
    from meeteval.wer import (
        cp_word_error_rate,
        greedy_di_cp_word_error_rate,
        time_constrained_minimum_permutation_word_error_rate,
    )

    results = {}
    for char, suffix in ((True, "cer"), (False, "wer")):
        missing_text = any("text" not in row for row in [*reference, *hypothesis])
        ref_count = sum(len(_tokens(row.get("text", ""), char=char)) for row in reference)
        for name in ("cp", "tcp", "greedy_di_cp"):
            results[f"{name}_{suffix}"] = {
                "availability": "not_observed",
                "error_rate": None,
                "reference_tokens": ref_count,
            }
        if missing_text or ref_count == 0:
            continue

        def seglst(rows, *, char=char):
            return SegLST(
                [
                    {
                        "speaker": row["speaker"],
                        "words": " ".join(_tokens(row["text"], char=char)),
                        "start_time": row["start"],
                        "end_time": row["end"],
                        "segment_index": i,
                    }
                    for i, row in enumerate(rows)
                ]
            )

        ref, hyp = seglst(reference), seglst(hypothesis)
        if max(ref_count, sum(len(_tokens(r["text"], char=char)) for r in hypothesis)) > 20000:
            raise ValueError("text metrics exceed token scoring bounds")
        scores = {
            "cp": cp_word_error_rate(ref, hyp),
            "tcp": time_constrained_minimum_permutation_word_error_rate(
                ref,
                hyp,
                collar=policy["tcp_collar_seconds"],
                reference_pseudo_word_level_timing=policy["tcp_timing"]["reference"],
                hypothesis_pseudo_word_level_timing=policy["tcp_timing"]["hypothesis"],
            ),
            "greedy_di_cp": greedy_di_cp_word_error_rate(ref, hyp),
        }
        for name, result in scores.items():
            results[f"{name}_{suffix}"] = {
                "availability": "observed",
                "algorithm": f"meeteval.{name}",
                "scorer_version": "0.4.3",
                "reference_tokens": result.length,
                "errors": result.errors,
                "insertions": result.insertions,
                "deletions": result.deletions,
                "substitutions": result.substitutions,
                "error_rate": result.error_rate,
                "tokenization": policy["tokenization"]["character" if char else "word"],
            }
    return results


def score_meeting_quality(
    reference_activity: Sequence[Mapping[str, Any]],
    hypothesis_activity: Sequence[Mapping[str, Any]],
    *,
    reference_text: Sequence[Mapping[str, Any]] | None,
    hypothesis_text: Sequence[Mapping[str, Any]] | None,
    duration: float,
    policy: Mapping[str, Any],
) -> dict[str, object]:
    """Score independent activity and attributed-text observations.

    Activity contains continuous speaker spans, including overlapping turns.
    Text contains actual reference/predicted transcript spans. Neither stream
    supplies the other's boundaries. Pass None for both text inputs when text
    is unobserved; an empty hypothesis instead means observed complete deletion.
    This result alone does not certify missing strata or confidence bounds.
    """
    _validate_policy(policy)
    if type(duration) not in (int, float) or not math.isfinite(duration) or duration <= 0:
        raise ValueError("invalid evaluation duration")
    for package, expected in policy["scorer_versions"].items():
        if importlib.metadata.version(package) != expected:
            raise ValueError(f"installed {package} differs from scorer policy")
    if any("text" in row for row in [*reference_activity, *hypothesis_activity]):
        raise ValueError("activity must be separate from attributed text")
    if (reference_text is None) != (hypothesis_text is None):
        raise ValueError("text reference and hypothesis must be observed together")
    ref = _validate_rows(reference_activity, duration=duration, reference=True)
    hyp = _validate_rows(hypothesis_activity, duration=duration, reference=False)
    text_ref = _validate_rows(reference_text or [], duration=duration, reference=True)
    text_hyp = _validate_rows(hypothesis_text or [], duration=duration, reference=False)
    product = _speaker_time(ref, hyp, policy)
    legacy = score_diarization(
        ref, [r for r in hyp if r["speaker"] != "unknown"], duration=duration
    )
    if not legacy["reference_seconds"]:
        for key in (
            "known_coverage",
            "known_accuracy",
            "unknown_fraction",
            "top_four_min_known_coverage",
        ):
            legacy[key] = None
        legacy["quality_gate"] = "not_observed"
    independent = score_diarization(ref, hyp, duration=duration)
    standard = _text_metrics(text_ref, text_hyp, policy)
    standard["diarization"] = {
        "availability": "observed" if ref else "not_observed",
        "scorer": "pyannote.metrics",
        "scorer_version": "4.1",
        "collar_seconds": 0,
        "skip_overlap": False,
        "der": independent["der"] if ref else None,
        "jer": independent["jer"] if ref else None,
        "components": independent["components"],
        "research_comparable": independent["research_comparable"],
    }
    char_total = sum(len(_tokens(row.get("text", ""), char=True)) for row in text_hyp)
    unknown_chars = sum(
        len(_tokens(row.get("text", ""), char=True))
        for row in text_hyp if row["speaker"] == "unknown"
    )
    return {
        "schema_version": 3,
        "policy_sha256": canonical_digest(policy),
        "legacy_nonoverlap": legacy,
        "product_all_regions": product,
        "standard_metrics": standard,
        "diagnostics": {
            "unknown_text_fraction": unknown_chars / char_total if char_total else None,
            "temporal_oracle": {
                "availability": "not_observed",
                "certification_eligible": False,
                "description": "legacy probe diagnostic; never standard DI-cp",
            },
        },
    }


def _bootstrap_indices(groups: int, policy):
    import numpy as np

    stats = policy.get("statistics", {})
    if (
        stats.get("unit") != "source_meeting_id"
        or stats.get("seed") != 1717
        or stats.get("bootstrap_draws") != 10000
        or stats.get("percentile_interval") != [0.025, 0.975]
    ):
        raise ValueError("statistics policy differs from approved group bootstrap")
    if groups > 1024:
        raise ValueError("too many independent groups for bounded bootstrap")
    return np.random.default_rng(stats["seed"]).integers(
        0,
        groups,
        size=(stats["bootstrap_draws"], groups),
    )


def paired_meeting_interval(
    baseline: Mapping[str, Sequence[float]],
    candidate: Mapping[str, Sequence[float]],
    *,
    policy: Mapping[str, Any],
) -> dict[str, Any]:
    """Candidate minus baseline, with repeats averaged before paired resampling."""
    import numpy as np

    _validate_policy(policy)
    if not baseline or set(baseline) != set(candidate):
        raise ValueError("paired metrics require the same nonempty meeting groups")
    for group in baseline:
        for values in (baseline[group], candidate[group]):
            if not values or any(
                type(v) not in (int, float) or not math.isfinite(v) for v in values
            ):
                raise ValueError("paired groups require finite observed results")
    delta = np.array(
        [
            math.fsum(candidate[group]) / len(candidate[group])
            - math.fsum(baseline[group]) / len(baseline[group])
            for group in sorted(baseline)
        ]
    )
    indices = _bootstrap_indices(len(delta), policy)
    interval = (
        np.quantile(delta[indices].mean(axis=1), [0.025, 0.975])
        if len(delta) >= 2
        else (None, None)
    )
    return {
        "difference": float(delta.mean()),
        "lower": float(interval[0]) if interval[0] is not None else None,
        "upper": float(interval[1]) if interval[1] is not None else None,
        "groups": len(delta),
        "seed": 1717,
        "draws": 10000,
        "unit": "source_meeting_id",
        "interval": "two_sided_percentile_95",
    }


def nondegradation_gate(baseline, candidate, *, policy) -> dict[str, Any]:
    results = {
        name: paired_meeting_interval(baseline[name], candidate[name], policy=policy)
        for name in ("der", "cp_cer")
    }
    passed = all(
        r["difference"] <= 0 and r["upper"] is not None and r["upper"] <= 0
        for r in results.values()
    )
    decision = (
        "point_failed" if any(r["difference"] > 0 for r in results.values())
        else "pass" if passed else "insufficient_evidence"
    )
    return {
        "metrics": results,
        "quality_gate": "pass" if passed else "fail",
        "decision": decision,
    }


def allows_latency_tiebreaker(difference, *, policy) -> bool:
    margin = policy.get("statistics", {}).get("selection_der_noninferiority_margin")
    if margin != 0.01:
        raise ValueError("selection policy differs from approved noninferiority margin")
    upper = difference.get("upper")
    return type(upper) in (int, float) and math.isfinite(upper) and upper <= margin


def summarize_meeting_quality(rows, *, required_strata, policy) -> dict[str, Any]:
    """Acoustic product evidence only; runtime/holdout certification is separate.

    Repeated observations in one source meeting are averaged first. Both pooled
    speaker-time and equal-meeting macro ratios must pass; neither substitutes
    for a failed individual participant or the frozen legacy gate.
    """
    import numpy as np

    _validate_policy(policy)
    if (
        list(required_strata) != list(range(1, len(required_strata) + 1))
        or len(required_strata) > 8
    ):
        raise ValueError("required strata must cover a continuous range starting at 1")
    if not required_strata or len(rows) > 4096:
        raise ValueError("invalid evaluation summary bounds")
    by_stratum = {count: defaultdict(list) for count in required_strata}
    observed_policy = canonical_digest(policy)
    for row in rows:
        count, group = row["speakers_count"], row["source_meeting_id"]
        if (
            type(count) is not int
            or count not in by_stratum
            or not isinstance(group, str)
            or not group
        ):
            raise ValueError("invalid evaluation stratum or source group")
        if row["quality"].get("schema_version") != 3:
            raise ValueError("score schema must separate activity and text inputs")
        if row["quality"]["policy_sha256"] != observed_policy:
            raise ValueError("mixed scorer policies cannot be pooled")
        by_stratum[count][group].append(row["quality"])
    summaries = {}
    for count, grouped in by_stratum.items():
        if not grouped:
            summaries[str(count)] = {
                "availability": "not_observed",
                "quality_gate": "fail",
                "decision": "not_observed",
                "independent_groups": 0,
            }
            continue
        point_pass = all(
            q["product_all_regions"]["participant_gate"] == "pass"
            and q["product_all_regions"]["reference_speakers_count"] == count
            and q["legacy_nonoverlap"]["quality_gate"] == "pass"
            for meetings in grouped.values()
            for q in meetings
        )
        means = np.array(
            [
                np.mean(
                    [
                        [
                            q["product_all_regions"][key]
                            for key in (
                                "correct_speaker_seconds",
                                "reference_speaker_seconds",
                                "hypothesis_speaker_seconds",
                            )
                        ]
                        for q in grouped[group]
                    ],
                    axis=0,
                )
                for group in sorted(grouped)
            ]
        )
        if not np.isfinite(means).all() or (means[:, 1:] <= 0).any():
            observed_miss = np.isfinite(means).all() and (means[:, 1] > 0).all()
            summaries[str(count)] = {
                "availability": "observed" if observed_miss else "not_observed",
                "quality_gate": "fail",
                "decision": "point_failed" if observed_miss else "not_observed",
                "independent_groups": len(grouped),
            }
            continue
        indices = _bootstrap_indices(len(grouped), policy)
        sampled = means[indices]
        totals = means.sum(axis=0)
        summary = {"availability": "observed", "independent_groups": len(grouped)}
        confidence_pass = (
            len(grouped) >= policy["statistics"]["development_checkpoints_per_stratum"][0]
        )
        for name, col in (("recall", 1), ("precision", 2)):
            ratios = means[:, 0] / means[:, col]
            distributions = {
                "pooled": sampled[:, :, 0].sum(axis=1) / sampled[:, :, col].sum(axis=1),
                "macro": (sampled[:, :, 0] / sampled[:, :, col]).mean(axis=1),
            }
            for aggregation, values in distributions.items():
                lower, upper = (
                    np.quantile(values, [0.025, 0.975]) if len(grouped) >= 2 else (None, None)
                )
                value = (
                    float(totals[0] / totals[col])
                    if aggregation == "pooled"
                    else float(ratios.mean())
                )
                summary[f"{aggregation}_{name}"] = {
                    "value": value,
                    "lower": float(lower) if lower is not None else None,
                    "upper": float(upper) if upper is not None else None,
                }
                threshold = policy[f"speaker_time_{name}_min"]
                point_pass &= value >= threshold
                confidence_pass &= lower is not None and lower >= threshold
        summary["quality_gate"] = "pass" if point_pass and confidence_pass else "fail"
        summary["decision"] = (
            "point_failed" if not point_pass
            else "pass" if confidence_pass else "insufficient_evidence"
        )
        summaries[str(count)] = summary
    decisions = {s["decision"] for s in summaries.values()}
    return {
        "strata": summaries,
        "quality_gate": "pass"
        if all(s["quality_gate"] == "pass" for s in summaries.values())
        else "fail",
        "decision": next(
            d for d in ("point_failed", "not_observed", "insufficient_evidence", "pass")
            if d in decisions
        ),
        "certified_max_speakers": None,
        "certification_scope": "product_scores_only_requires_c0_runtime_and_frozen_holdout",
    }
