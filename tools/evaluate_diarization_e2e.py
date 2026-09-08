"""End-to-end evaluation tool and scoring metrics for speaker diarization (R5).

Calculates:
- Diarization Error Rate (DER = Miss + False Alarm + Speaker Confusion)
  with global optimal bipartite speaker matching (avoiding per-segment gaming)
  and collar / overlap handling.
- Speaker Attribution Character Error Rate (SACER) where 'unknown' status
  strictly counts as an attribution error.
- Privacy-preserving aggregated reporting (no raw paths, audio, transcripts,
  or real speaker names logged).

Usage:
    uv run python tools/evaluate_diarization_e2e.py --manifest <path> [--collar <sec>]
"""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class SpeakerTurn:
    speaker: str
    start: float
    end: float


@dataclass(frozen=True)
class Segment:
    start: float
    end: float


@dataclass(frozen=True)
class EvaluationRegion:
    """One scored interval from an external UEM file."""

    start: float
    end: float

    def __post_init__(self) -> None:
        if self.start < 0.0 or self.end <= self.start:
            raise ValueError("UEM regions must be non-negative, non-empty intervals")


@dataclass(frozen=True)
class TextAttributionUnit:
    text: str
    speaker: str | None
    status: str = "stable"


@dataclass(frozen=True)
class DerResult:
    der: float
    total_reference_time: float
    miss_time: float
    fa_time: float
    confusion_time: float
    speaker_mapping: dict[str, str]


@dataclass(frozen=True)
class PyannoteMetricsResult:
    der: float
    jer: float
    miss_time: float
    fa_time: float
    confusion_time: float
    total_reference_time: float


@dataclass(frozen=True)
class SpeakerAttributionCerResult:
    attribution_cer: float
    unknown_ratio: float
    total_characters: int
    error_characters: int
    unknown_characters: int


@dataclass(frozen=True)
class ConditionalAttributionResult:
    error_rate: float | None
    total_matched_characters: int
    error_characters: int


@dataclass(frozen=True)
class CpCerResult:
    """Conversation-level, speaker-attributed character error rate.

    Each speaker's text is concatenated in timeline order, then hypothesis
    labels are mapped to reference labels exactly once for the whole clip.
    """

    cpcer: float
    total_characters: int
    error_characters: int
    unknown_characters: int
    speaker_mapping: dict[str, str]


@dataclass
class ManifestItem:
    clip_id: str
    split: str
    license: str
    reference_turns: list[SpeakerTurn] = field(default_factory=list)
    hypothesis_turns: list[SpeakerTurn] = field(default_factory=list)
    uem_regions: tuple[EvaluationRegion, ...] = ()
    reference_text_units: list[TextAttributionUnit] = field(default_factory=list)
    hypothesis_text_units: list[TextAttributionUnit] = field(default_factory=list)
    text_attribution_present: bool = False


def parse_rttm(content: str) -> list[SpeakerTurn]:
    """Parse an RTTM string into SpeakerTurns."""
    turns: list[SpeakerTurn] = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 8 and parts[0] == "SPEAKER":
            start = float(parts[3])
            duration = float(parts[4])
            speaker = parts[7]
            turns.append(SpeakerTurn(speaker=speaker, start=start, end=start + duration))
    return sorted(turns, key=lambda t: (t.start, t.end))


def parse_uem(content: str) -> tuple[EvaluationRegion, ...]:
    """Parse standard ``<uri> <channel> <start> <end>`` UEM entries."""

    regions: list[EvaluationRegion] = []
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 4:
            raise ValueError("UEM entry must contain uri, channel, start and end")
        try:
            regions.append(EvaluationRegion(start=float(parts[2]), end=float(parts[3])))
        except ValueError as exc:
            raise ValueError("UEM entry has invalid start or end") from exc
    if not regions:
        raise ValueError("UEM must contain at least one evaluation region")
    return tuple(regions)


def parse_text_attribution_units(
    content: str, *, reference: bool
) -> list[TextAttributionUnit]:
    """Parse an external JSON text-attribution sidecar without logging its text."""

    try:
        payload = json.loads(content)
    except json.JSONDecodeError as exc:
        raise ValueError("text attribution sidecar is invalid JSON") from exc
    if not isinstance(payload, list):
        raise ValueError("text attribution sidecar must be a list")
    units: list[TextAttributionUnit] = []
    for entry in payload:
        if not isinstance(entry, dict) or not isinstance(entry.get("text"), str):
            raise ValueError("text attribution unit requires string text")
        speaker = entry.get("speaker")
        if speaker is not None and not isinstance(speaker, str):
            raise ValueError("text attribution speaker must be string or null")
        if reference and not speaker:
            raise ValueError("reference text attribution unit requires speaker")
        status = entry.get("status", "stable")
        if status not in {"stable", "final", "degraded", "unknown"}:
            raise ValueError("text attribution status is invalid")
        units.append(TextAttributionUnit(text=entry["text"], speaker=speaker, status=status))
    return units


def _build_collar_regions(reference: list[SpeakerTurn], collar: float) -> list[tuple[float, float]]:
    if collar <= 0.0:
        return []
    boundaries: set[float] = set()
    for turn in reference:
        boundaries.add(turn.start)
        boundaries.add(turn.end)
    raw_collars = [(b - collar, b + collar) for b in boundaries]
    raw_collars.sort()
    merged: list[tuple[float, float]] = []
    for start, end in raw_collars:
        if not merged:
            merged.append((start, end))
        else:
            prev_s, prev_e = merged[-1]
            if start <= prev_e:
                merged[-1] = (prev_s, max(prev_e, end))
            else:
                merged.append((start, end))
    return merged


def _is_in_collar(midpoint: float, collar_regions: list[tuple[float, float]]) -> bool:
    for start, end in collar_regions:
        if start <= midpoint <= end:
            return True
        if start > midpoint:
            break
    return False


def _find_optimal_mapping(
    ref_speakers: list[str],
    hyp_speakers: list[str],
    intervals: list[tuple[float, float, set[str], set[str]]],
) -> dict[str, str]:
    """Find a 1-to-1 mapping from hyp_speaker to ref_speaker maximizing co-occurrence."""
    if not hyp_speakers or not ref_speakers:
        return {}

    cooc: dict[tuple[str, str], float] = {}
    for r in ref_speakers:
        for h in hyp_speakers:
            cooc[(r, h)] = 0.0

    for start, end, ref_set, hyp_set in intervals:
        dur = end - start
        for r in ref_set:
            for h in hyp_set:
                cooc[(r, h)] += dur

    # For small number of speakers (typically <= 6 in meetings), exhaustive permutation search
    best_score = -1.0
    best_mapping: dict[str, str] = {}

    num_hyp = len(hyp_speakers)
    num_ref = len(ref_speakers)

    if num_hyp <= num_ref:
        for ref_perm in itertools.permutations(ref_speakers, num_hyp):
            score = 0.0
            mapping: dict[str, str] = {}
            for h, r in zip(hyp_speakers, ref_perm, strict=True):
                score += cooc.get((r, h), 0.0)
                mapping[h] = r
            if score > best_score:
                best_score = score
                best_mapping = mapping
    else:
        for hyp_perm in itertools.permutations(hyp_speakers, num_ref):
            score = 0.0
            mapping = {}
            for r, h in zip(ref_speakers, hyp_perm, strict=True):
                score += cooc.get((r, h), 0.0)
                mapping[h] = r
            if score > best_score:
                best_score = score
                best_mapping = mapping

    return best_mapping


def compute_der(
    reference: list[SpeakerTurn],
    hypothesis: list[SpeakerTurn],
    *,
    collar: float = 0.0,
    uem: tuple[EvaluationRegion, ...] = (),
) -> DerResult:
    """Compute Diarization Error Rate with optimal global speaker matching."""
    collar_regions = _build_collar_regions(reference, collar)

    time_points: set[float] = {0.0}
    for t in reference:
        time_points.add(t.start)
        time_points.add(t.end)
    for t in hypothesis:
        time_points.add(t.start)
        time_points.add(t.end)
    for s, e in collar_regions:
        time_points.add(s)
        time_points.add(e)
    for region in uem:
        time_points.add(region.start)
        time_points.add(region.end)

    sorted_times = sorted(time_points)

    intervals: list[tuple[float, float, set[str], set[str]]] = []
    for i in range(len(sorted_times) - 1):
        t0 = sorted_times[i]
        t1 = sorted_times[i + 1]
        if t1 - t0 <= 1e-9:
            continue
        mid = (t0 + t1) / 2.0
        if uem and not any(region.start <= mid < region.end for region in uem):
            continue
        if _is_in_collar(mid, collar_regions):
            continue

        ref_active = {t.speaker for t in reference if t.start <= mid <= t.end}
        hyp_active = {t.speaker for t in hypothesis if t.start <= mid <= t.end}
        intervals.append((t0, t1, ref_active, hyp_active))

    all_ref_speakers = sorted({t.speaker for t in reference})
    all_hyp_speakers = sorted({t.speaker for t in hypothesis})

    speaker_mapping = _find_optimal_mapping(all_ref_speakers, all_hyp_speakers, intervals)

    total_ref_time = 0.0
    miss_time = 0.0
    fa_time = 0.0
    confusion_time = 0.0

    for start, end, ref_set, hyp_set in intervals:
        dur = end - start
        n_ref = len(ref_set)
        n_hyp = len(hyp_set)
        total_ref_time += n_ref * dur

        # Count correctly matched speakers
        mapped_hyp = {speaker_mapping[h] for h in hyp_set if h in speaker_mapping}
        n_corr = len(ref_set.intersection(mapped_hyp))

        n_miss = max(0, n_ref - n_hyp)
        n_fa = max(0, n_hyp - n_ref)
        n_conf = min(n_ref, n_hyp) - n_corr

        miss_time += n_miss * dur
        fa_time += n_fa * dur
        confusion_time += n_conf * dur

    total_error = miss_time + fa_time + confusion_time
    if total_ref_time <= 0.0:
        raise ValueError("DER is undefined without reference speech time")
    der = total_error / total_ref_time

    return DerResult(
        der=der,
        total_reference_time=total_ref_time,
        miss_time=miss_time,
        fa_time=fa_time,
        confusion_time=confusion_time,
        speaker_mapping=speaker_mapping,
    )


def compute_pyannote_metrics(
    reference: list[SpeakerTurn],
    hypothesis: list[SpeakerTurn],
    *,
    collar: float,
    uem: tuple[EvaluationRegion, ...],
) -> PyannoteMetricsResult:
    """Score DER/JER with the pinned reference implementation and explicit UEM."""

    if not reference:
        raise ValueError("DER/JER are undefined without reference speech time")
    if not uem:
        raise ValueError("DER/JER require explicit UEM regions")
    from pyannote.core import Annotation, Timeline
    from pyannote.core import Segment as PyannoteSegment
    from pyannote.metrics.diarization import DiarizationErrorRate, JaccardErrorRate

    def annotation_from(turns: list[SpeakerTurn]) -> Annotation:
        annotation = Annotation()
        for index, turn in enumerate(turns):
            if turn.end > turn.start:
                annotation[PyannoteSegment(turn.start, turn.end), str(index)] = turn.speaker
        return annotation

    reference_annotation = annotation_from(reference)
    hypothesis_annotation = annotation_from(hypothesis)
    evaluation_map = Timeline(
        segments=[PyannoteSegment(region.start, region.end) for region in uem]
    )
    der_details = DiarizationErrorRate(collar=collar, skip_overlap=False)(
        reference_annotation,
        hypothesis_annotation,
        uem=evaluation_map,
        detailed=True,
    )
    jer_details = JaccardErrorRate(collar=collar, skip_overlap=False)(
        reference_annotation,
        hypothesis_annotation,
        uem=evaluation_map,
        detailed=True,
    )
    return PyannoteMetricsResult(
        der=float(der_details["diarization error rate"]),
        jer=float(jer_details["jaccard error rate"]),
        miss_time=float(der_details["missed detection"]),
        fa_time=float(der_details["false alarm"]),
        confusion_time=float(der_details["confusion"]),
        total_reference_time=float(der_details["total"]),
    )


def compute_speaker_attribution_cer(
    reference: list[TextAttributionUnit],
    hypothesis: list[TextAttributionUnit],
    speaker_mapping: dict[str, str],
) -> SpeakerAttributionCerResult:
    """Compute Speaker Attribution Character Error Rate (SACER).

    Unknown status or unassigned speaker counts strictly as an error.
    """
    ref_chars: list[tuple[str, str | None]] = []
    for unit in reference:
        for char in unit.text:
            ref_chars.append((char, unit.speaker))

    hyp_chars: list[tuple[str, str | None, str]] = []
    for unit in hypothesis:
        for char in unit.text:
            hyp_chars.append((char, unit.speaker, unit.status))

    total = len(ref_chars)
    if total == 0:
        return SpeakerAttributionCerResult(
            attribution_cer=0.0,
            unknown_ratio=0.0,
            total_characters=0,
            error_characters=0,
            unknown_characters=0,
        )

    errors = 0
    unknowns = 0

    for idx in range(total):
        ref_char, ref_spk = ref_chars[idx]
        if idx < len(hyp_chars):
            hyp_char, hyp_spk, status = hyp_chars[idx]
        else:
            hyp_char, hyp_spk, status = "", None, "unknown"

        if hyp_char != ref_char or status == "unknown" or hyp_spk is None:
            if status == "unknown" or hyp_spk is None:
                unknowns += 1
            errors += 1
        else:
            mapped = speaker_mapping.get(hyp_spk, hyp_spk)
            if mapped != ref_spk:
                errors += 1
    errors += max(0, len(hyp_chars) - total)

    return SpeakerAttributionCerResult(
        attribution_cer=errors / total,
        unknown_ratio=unknowns / total,
        total_characters=total,
        error_characters=errors,
        unknown_characters=unknowns,
    )


def compute_conditional_attribution_error(
    reference: list[TextAttributionUnit],
    hypothesis: list[TextAttributionUnit],
    speaker_mapping: dict[str, str],
) -> ConditionalAttributionResult:
    """Score speakers only where a character is aligned identically in text."""

    ref = [(char, unit.speaker) for unit in reference for char in unit.text]
    hyp = [
        (char, unit.speaker, unit.status)
        for unit in hypothesis
        for char in unit.text
    ]
    # LCS preserves ordered, exact character matches while excluding ASR edits
    # from the attribution denominator.
    rows = len(ref) + 1
    cols = len(hyp) + 1
    lengths = [[0] * cols for _ in range(rows)]
    for i, (ref_char, _) in enumerate(ref, 1):
        for j, (hyp_char, _, _) in enumerate(hyp, 1):
            lengths[i][j] = (
                lengths[i - 1][j - 1] + 1
                if ref_char == hyp_char
                else max(lengths[i - 1][j], lengths[i][j - 1])
            )
    matched: list[tuple[tuple[str, str | None], tuple[str, str | None, str]]] = []
    i, j = len(ref), len(hyp)
    while i and j:
        if ref[i - 1][0] == hyp[j - 1][0]:
            matched.append((ref[i - 1], hyp[j - 1]))
            i -= 1
            j -= 1
        elif lengths[i - 1][j] >= lengths[i][j - 1]:
            i -= 1
        else:
            j -= 1
    errors = sum(
        status == "unknown"
        or speaker is None
        or speaker_mapping.get(speaker, speaker) != ref_speaker
        for (__, ref_speaker), (_, speaker, status) in matched
    )
    total = len(matched)
    return ConditionalAttributionResult(
        error_rate=(errors / total) if total else None,
        total_matched_characters=total,
        error_characters=errors,
    )


def _character_edit_distance(reference: str, hypothesis: str) -> int:
    """Return the Unicode code-point Levenshtein distance with bounded rows."""

    if len(reference) < len(hypothesis):
        reference, hypothesis = hypothesis, reference
    previous = list(range(len(hypothesis) + 1))
    for ref_index, ref_char in enumerate(reference, start=1):
        current = [ref_index]
        for hyp_index, hyp_char in enumerate(hypothesis, start=1):
            current.append(
                min(
                    current[hyp_index - 1] + 1,
                    previous[hyp_index] + 1,
                    previous[hyp_index - 1] + (ref_char != hyp_char),
                )
            )
        previous = current
    return previous[-1]


def _speaker_transcripts(
    units: list[TextAttributionUnit], *, reference: bool
) -> tuple[dict[str, str], str]:
    """Concatenate timeline text per speaker and isolate unknown hypothesis text."""

    grouped: dict[str, list[str]] = {}
    unknown: list[str] = []
    for unit in units:
        if not unit.text:
            continue
        if reference:
            if unit.speaker is None:
                raise ValueError("reference text units require a speaker")
            grouped.setdefault(unit.speaker, []).append(unit.text)
        elif unit.status == "unknown" or unit.speaker is None:
            unknown.append(unit.text)
        else:
            grouped.setdefault(unit.speaker, []).append(unit.text)
    return {speaker: "".join(parts) for speaker, parts in grouped.items()}, "".join(unknown)


def compute_cpcer(
    reference: list[TextAttributionUnit], hypothesis: list[TextAttributionUnit]
) -> CpCerResult:
    """Compute cpCER using a single optimal mapping for the whole conversation.

    A hypothesis label can map to at most one reference label. Unknown output
    is deliberately excluded from that assignment: it is scored as unmatched
    hypothesis text, while the absent reference text is scored as deletion.
    """

    reference_texts, _ = _speaker_transcripts(reference, reference=True)
    hypothesis_texts, unknown_text = _speaker_transcripts(hypothesis, reference=False)
    total = sum(len(text) for text in reference_texts.values())
    if total == 0:
        raise ValueError("cpCER is undefined without reference text")

    reference_speakers = tuple(reference_texts)
    hypothesis_speakers = tuple(hypothesis_texts)
    memo: dict[tuple[int, int], tuple[int, dict[str, str]]] = {}

    def solve(hypothesis_index: int, used_references: int) -> tuple[int, dict[str, str]]:
        key = (hypothesis_index, used_references)
        if key in memo:
            return memo[key]
        if hypothesis_index == len(hypothesis_speakers):
            unmatched = sum(
                len(reference_texts[speaker])
                for index, speaker in enumerate(reference_speakers)
                if not used_references & (1 << index)
            )
            result: tuple[int, dict[str, str]] = (unmatched, {})
            memo[key] = result
            return result

        hyp_speaker = hypothesis_speakers[hypothesis_index]
        hyp_text = hypothesis_texts[hyp_speaker]
        remainder_cost, remainder_mapping = solve(hypothesis_index + 1, used_references)
        best: tuple[int, dict[str, str]] = (
            len(hyp_text) + remainder_cost,
            dict(remainder_mapping),
        )
        for reference_index, reference_speaker in enumerate(reference_speakers):
            if used_references & (1 << reference_index):
                continue
            remainder_cost, remainder_mapping = solve(
                hypothesis_index + 1, used_references | (1 << reference_index)
            )
            candidate_mapping = dict(remainder_mapping)
            candidate_mapping[hyp_speaker] = reference_speaker
            candidate = (
                _character_edit_distance(reference_texts[reference_speaker], hyp_text)
                + remainder_cost,
                candidate_mapping,
            )
            if candidate[0] < best[0]:
                best = candidate
        memo[key] = best
        return best

    error_characters, speaker_mapping = solve(0, 0)
    unknown_characters = len(unknown_text)
    return CpCerResult(
        cpcer=(error_characters + unknown_characters) / total,
        total_characters=total,
        error_characters=error_characters + unknown_characters,
        unknown_characters=unknown_characters,
        speaker_mapping=speaker_mapping,
    )


def validate_manifest(manifest_path: Path) -> list[ManifestItem]:
    """Load and validate manifest file for training/evaluation splits and license."""
    content = manifest_path.read_text(encoding="utf-8")
    data = json.loads(content)
    if not isinstance(data, list):
        raise ValueError("manifest must be a list of clip entries")

    items: list[ManifestItem] = []
    base_dir = manifest_path.parent

    for entry in data:
        if not isinstance(entry, dict):
            raise ValueError("each manifest entry must be a dictionary")
        clip_id = entry.get("clip_id")
        if not clip_id or not isinstance(clip_id, str):
            raise ValueError("clip_id must be a non-empty string")
        split = entry.get("split")
        if split not in {"tune", "eval"}:
            raise ValueError(f"split must be 'tune' or 'eval', got {split!r}")
        lic = entry.get("license") or ("authorized" if entry.get("authorized") is True else None)
        if not lic:
            raise ValueError(f"entry {clip_id} is missing license / authorization verification")

        reference_rttm = entry.get("reference_rttm")
        hypothesis_rttm = entry.get("hypothesis_rttm")
        uem = entry.get("uem")
        if not isinstance(reference_rttm, str) or not isinstance(hypothesis_rttm, str):
            raise ValueError(f"entry {clip_id} requires reference_rttm and hypothesis_rttm")
        if not isinstance(uem, str):
            raise ValueError(f"entry {clip_id} requires uem")
        reference_path = base_dir / reference_rttm
        hypothesis_path = base_dir / hypothesis_rttm
        uem_path = base_dir / uem
        if not reference_path.is_file() or not hypothesis_path.is_file() or not uem_path.is_file():
            raise ValueError(f"entry {clip_id} RTTM file is missing")
        reference_text_json = entry.get("reference_text_json")
        hypothesis_text_json = entry.get("hypothesis_text_json")
        if (reference_text_json is None) != (hypothesis_text_json is None):
            raise ValueError(f"entry {clip_id} requires paired text sidecars")
        if reference_text_json is not None and (
            not isinstance(reference_text_json, str)
            or not isinstance(hypothesis_text_json, str)
        ):
            raise ValueError(f"entry {clip_id} text sidecars must be relative paths")
        reference_text_units: list[TextAttributionUnit] = []
        hypothesis_text_units: list[TextAttributionUnit] = []
        text_attribution_present = reference_text_json is not None
        if text_attribution_present:
            reference_text_path = base_dir / reference_text_json
            hypothesis_text_path = base_dir / hypothesis_text_json
            if not reference_text_path.is_file() or not hypothesis_text_path.is_file():
                raise ValueError(f"entry {clip_id} text attribution sidecar is missing")
            reference_text_units = parse_text_attribution_units(
                reference_text_path.read_text(encoding="utf-8"), reference=True
            )
            hypothesis_text_units = parse_text_attribution_units(
                hypothesis_text_path.read_text(encoding="utf-8"), reference=False
            )
        ref_turns = parse_rttm(reference_path.read_text(encoding="utf-8"))
        hyp_turns = parse_rttm(hypothesis_path.read_text(encoding="utf-8"))

        items.append(
            ManifestItem(
                clip_id=clip_id,
                split=split,
                license=str(lic),
                reference_turns=ref_turns,
                hypothesis_turns=hyp_turns,
                uem_regions=parse_uem(uem_path.read_text(encoding="utf-8")),
                reference_text_units=reference_text_units,
                hypothesis_text_units=hypothesis_text_units,
                text_attribution_present=text_attribution_present,
            )
        )

    return items


def evaluate_manifest(
    items: list[ManifestItem],
    *,
    collar: float = 0.0,
    split_filter: str | None = None,
) -> dict[str, Any]:
    """Evaluate manifest items and return an anonymized aggregated summary report."""
    filtered = [i for i in items if split_filter is None or i.split == split_filter]
    if not filtered:
        return {"aggregate": {"total_clips": 0, "der": 0.0}, "items": []}

    total_ref_time = 0.0
    total_miss = 0.0
    total_fa = 0.0
    total_conf = 0.0
    total_text_characters = 0
    total_cpcer_errors = 0
    item_reports: list[dict[str, Any]] = []

    for item in filtered:
        res = compute_der(
            item.reference_turns,
            item.hypothesis_turns,
            collar=collar,
            uem=item.uem_regions,
        )
        reference_metrics = compute_pyannote_metrics(
            item.reference_turns,
            item.hypothesis_turns,
            collar=collar,
            uem=item.uem_regions,
        )
        if not math.isclose(res.der, reference_metrics.der, abs_tol=1e-9):
            raise RuntimeError(
                f"custom DER disagrees with pyannote.metrics for anonymous clip {item.clip_id}"
            )
        total_ref_time += reference_metrics.total_reference_time
        total_miss += reference_metrics.miss_time
        total_fa += reference_metrics.fa_time
        total_conf += reference_metrics.confusion_time

        item_report: dict[str, Any] = {
            "clip_id": item.clip_id,
            "split": item.split,
            "reference_seconds": round(reference_metrics.total_reference_time, 2),
            "der": round(reference_metrics.der, 4),
            "jer": round(reference_metrics.jer, 4),
            "miss": round(reference_metrics.miss_time, 2),
            "false_alarm": round(reference_metrics.fa_time, 2),
            "confusion": round(reference_metrics.confusion_time, 2),
        }
        if item.text_attribution_present:
            cpcer = compute_cpcer(item.reference_text_units, item.hypothesis_text_units)
            item_report["cpcer"] = round(cpcer.cpcer, 4)
            item_report["cpcer_unknown_characters"] = cpcer.unknown_characters
            total_text_characters += cpcer.total_characters
            total_cpcer_errors += cpcer.error_characters
        item_reports.append(item_report)

    agg_error = total_miss + total_fa + total_conf
    agg_der = (agg_error / total_ref_time) if total_ref_time > 0.0 else 0.0

    return {
        "aggregate": {
            "total_clips": len(filtered),
            "total_reference_seconds": round(total_ref_time, 2),
            "der": round(agg_der, 4),
            "miss_ratio": round(total_miss / total_ref_time, 4) if total_ref_time > 0 else 0.0,
            "fa_ratio": round(total_fa / total_ref_time, 4) if total_ref_time > 0 else 0.0,
            "confusion_ratio": round(total_conf / total_ref_time, 4) if total_ref_time > 0 else 0.0,
            "collar": collar,
            "scorer": "pyannote.metrics==4.1",
            "cpcer": (
                round(total_cpcer_errors / total_text_characters, 4)
                if total_text_characters
                else None
            ),
            "cpcer_reference_characters": total_text_characters or None,
        },
        "items": item_reports,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate speaker diarization e2e manifest")
    parser.add_argument("--manifest", type=Path, required=True, help="Path to manifest JSON")
    parser.add_argument("--collar", type=float, default=0.0, help="Collar in seconds (default 0.0)")
    parser.add_argument("--split", type=str, choices=["tune", "eval"], default=None)
    parser.add_argument(
        "--output", type=Path, default=None, help="Optional output JSON report path"
    )
    args = parser.parse_args()

    items = validate_manifest(args.manifest)
    manifest_hash = hashlib.sha256(args.manifest.read_bytes()).hexdigest()
    report = evaluate_manifest(items, collar=args.collar, split_filter=args.split)
    report["manifest_sha256"] = manifest_hash

    output_text = json.dumps(report, indent=2)
    if args.output:
        args.output.write_text(output_text, encoding="utf-8")
        print(f"Evaluation report written to {args.output}")
    else:
        print(output_text)


if __name__ == "__main__":
    main()
