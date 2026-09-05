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
class SpeakerAttributionCerResult:
    attribution_cer: float
    unknown_ratio: float
    total_characters: int
    error_characters: int
    unknown_characters: int


@dataclass
class ManifestItem:
    clip_id: str
    split: str
    license: str
    reference_turns: list[SpeakerTurn] = field(default_factory=list)
    hypothesis_turns: list[SpeakerTurn] = field(default_factory=list)
    reference_text_units: list[TextAttributionUnit] = field(default_factory=list)
    hypothesis_text_units: list[TextAttributionUnit] = field(default_factory=list)


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

    sorted_times = sorted(time_points)

    intervals: list[tuple[float, float, set[str], set[str]]] = []
    for i in range(len(sorted_times) - 1):
        t0 = sorted_times[i]
        t1 = sorted_times[i + 1]
        if t1 - t0 <= 1e-9:
            continue
        mid = (t0 + t1) / 2.0
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
    der = (total_error / total_ref_time) if total_ref_time > 0.0 else 0.0

    return DerResult(
        der=der,
        total_reference_time=total_ref_time,
        miss_time=miss_time,
        fa_time=fa_time,
        confusion_time=confusion_time,
        speaker_mapping=speaker_mapping,
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
        _, ref_spk = ref_chars[idx]
        if idx < len(hyp_chars):
            _, hyp_spk, status = hyp_chars[idx]
        else:
            hyp_spk, status = None, "unknown"

        if status == "unknown" or hyp_spk is None:
            unknowns += 1
            errors += 1
        else:
            mapped = speaker_mapping.get(hyp_spk, hyp_spk)
            if mapped != ref_spk:
                errors += 1

    return SpeakerAttributionCerResult(
        attribution_cer=errors / total,
        unknown_ratio=unknowns / total,
        total_characters=total,
        error_characters=errors,
        unknown_characters=unknowns,
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

        ref_turns: list[SpeakerTurn] = []
        if "reference_rttm" in entry:
            rttm_path = base_dir / entry["reference_rttm"]
            if rttm_path.exists():
                ref_turns = parse_rttm(rttm_path.read_text(encoding="utf-8"))

        hyp_turns: list[SpeakerTurn] = []
        if "hypothesis_rttm" in entry:
            rttm_path = base_dir / entry["hypothesis_rttm"]
            if rttm_path.exists():
                hyp_turns = parse_rttm(rttm_path.read_text(encoding="utf-8"))

        items.append(
            ManifestItem(
                clip_id=clip_id,
                split=split,
                license=str(lic),
                reference_turns=ref_turns,
                hypothesis_turns=hyp_turns,
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
    item_reports: list[dict[str, Any]] = []

    for item in filtered:
        res = compute_der(item.reference_turns, item.hypothesis_turns, collar=collar)
        total_ref_time += res.total_reference_time
        total_miss += res.miss_time
        total_fa += res.fa_time
        total_conf += res.confusion_time

        item_reports.append(
            {
                "clip_id": item.clip_id,
                "split": item.split,
                "reference_seconds": round(res.total_reference_time, 2),
                "der": round(res.der, 4),
                "miss": round(res.miss_time, 2),
                "false_alarm": round(res.fa_time, 2),
                "confusion": round(res.confusion_time, 2),
            }
        )

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
