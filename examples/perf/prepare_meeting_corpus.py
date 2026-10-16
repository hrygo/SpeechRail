"""Prepare local AISHELL-4 excerpts and immutable evaluation manifests.

No download or inference. Audio, annotation text and source speaker IDs stay
outside the repository. TextGrid labels are utterance intervals, not word times.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import subprocess
from pathlib import Path


def textgrid_intervals(text: str) -> list[tuple[float, float, str, str]]:
    result = []
    tiers = re.split(r"(?m)^\s*item \[\d+\]:\s*$", text)[1:]
    for tier in tiers:
        name = re.search(r'(?m)^\s*name = "((?:[^"]|"")*)"\s*$', tier)
        if name is None or 'class = "IntervalTier"' not in tier:
            raise ValueError("unsupported TextGrid tier")
        intervals = re.split(r"(?m)^\s*intervals \[\d+\]:\s*$", tier)[1:]
        for interval in intervals:
            match = re.fullmatch(
                r'\s*xmin = ([\d.eE+-]+)\s+xmax = ([\d.eE+-]+)\s+text = "((?:[^"]|"")*)"\s*',
                interval,
            )
            if match is None:
                raise ValueError("invalid TextGrid interval")
            start, end = float(match[1]), float(match[2])
            if not all(math.isfinite(x) for x in (start, end)) or not 0 <= start <= end:
                raise ValueError("invalid TextGrid timestamp")
            value = match[3].replace('""', '"').strip()
            if value and end > start:
                result.append((start, end, name[1], value))
    if not result:
        raise ValueError("TextGrid contains no utterance intervals")
    return sorted(result)


def rttm_intervals(text: str) -> list[tuple[float, float, str]]:
    result = []
    for line in text.splitlines():
        if not line.strip():
            continue
        columns = line.split()
        if len(columns) != 10 or columns[0] != "SPEAKER":
            raise ValueError("invalid RTTM annotation")
        start, duration = float(columns[3]), float(columns[4])
        if not math.isfinite(start + duration) or start < 0 or duration <= 0:
            raise ValueError("invalid RTTM timestamp")
        result.append((start, start + duration, columns[7]))
    return sorted(set(result))


def excerpt_end(intervals: list[tuple[float, float]], minimum: float = 600) -> float:
    """First 400 ms all-speaker gap after the fixed minimum, capped at +120 s."""
    cursor = minimum
    for start, end in sorted(intervals):
        if end <= cursor:
            continue
        if start >= cursor + 0.4:
            return round(cursor, 4)
        cursor = max(cursor, end)
        if cursor > minimum + 120:
            raise ValueError("no safe excerpt end within budget")
    return round(cursor, 4)


def _hash(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def asr_reference(utterances: list[tuple[float, float, str, str]]) -> str:
    """Speech text only; keep raw event annotations in the external reference."""
    text = "".join(row[3] for row in utterances)
    tags = set(re.findall(r"<[^>]+>", text))
    if tags - {"<sil>", "<%>", "<#>", "<$>", "<->"}:
        raise ValueError("unknown corpus event marker requires annotation-policy review")
    for tag in tags:
        text = text.replace(tag, "")
    return text


def prepare(source: Path, output: Path) -> dict[str, object]:
    repository = Path(__file__).resolve().parents[2]
    source, output = source.resolve(), output.resolve()
    if output.is_relative_to(repository) or source.is_relative_to(repository) or output.exists():
        raise ValueError("use a new external output directory and external source")
    metadata = json.loads((source / "source-manifest.json").read_text())
    selected = metadata["files"]
    if len(selected) < 12:
        raise ValueError("at least twelve natural meetings required")
    # Freeze the split by file ID before any model inference, independent of quality.
    output.mkdir(parents=True)
    entries = {"development": [], "holdout": []}
    lock = {
        "dataset": metadata["dataset"],
        "source_revision": metadata["revision"],
        "license": metadata["license"],
        "source_manifest_sha256": _hash(source / "source-manifest.json"),
        "channel_index": 0,
        "word_timing": "not_observed",
        "cross_session_person_disjointness": "not_observed",
        "person_disjoint_gate": "unset",
        "split_rule": "R004 holdout, all other selected sessions development",
        "annotation_speaker_ids": "session_local; no cross-session person identity inference",
    }
    for item in selected:
        identifier = item["id"]
        audio, tg, rttm = (
            source / (identifier + suffix) for suffix in (".flac", ".TextGrid", ".rttm")
        )
        for path, key in ((audio, "audio_sha256"), (tg, "TextGrid_sha256"), (rttm, "rttm_sha256")):
            if _hash(path) != item[key]:
                raise ValueError("corpus source digest mismatch")
        words = textgrid_intervals(tg.read_text())
        reference = rttm_intervals(rttm.read_text())
        end = excerpt_end([(a, b) for a, b, _, _ in words] + [(a, b) for a, b, _ in reference])
        utterances = [entry for entry in words if entry[1] <= end + 0.0001]
        spans = [(a, min(b, end), speaker) for a, b, speaker in reference if a < end]
        speakers = sorted({speaker for _, _, speaker in spans})
        anonymous = {speaker: "R" + str(index + 1) for index, speaker in enumerate(speakers)}
        wav = output / (identifier + ".wav")
        completed = subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-i",
                str(audio),
                "-t",
                str(end),
                "-af",
                "pan=mono|c0=c0",
                "-ar",
                "16000",
                "-c:a",
                "pcm_s16le",
                str(wav),
            ],
            capture_output=True,
            timeout=120,
            check=False,
        )
        if completed.returncode:
            raise RuntimeError("audio channel conversion failed")
        transcript = asr_reference(utterances)
        path = output / (identifier + ".reference.json")
        path.write_text(
            json.dumps(
                {
                    "utterances": [
                        {"start": a, "end": b, "text": text} for a, b, _, text in utterances
                    ],
                    "speaker_spans": [
                        {"start": a, "end": b, "speaker": anonymous[s]} for a, b, s in spans
                    ],
                },
                ensure_ascii=False,
            )
        )
        entry = {
            "id": identifier,
            "path": str(wav),
            "kind": "asr",
            "language": "zh",
            "reference_text": transcript,
            "reference_path": str(path),
            "reference_sha256": _hash(path),
            "audio_sha256": _hash(wav),
            "duration_seconds": end,
            "speakers_count": len(speakers),
        }
        entries["holdout" if "R004" in identifier else "development"].append(entry)
    lock["splits"] = {}
    for group, fixtures in entries.items():
        path = output / (group + ".json")
        path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "fixtures": fixtures,
                    "annotation_policy": (
                        "TextGrid utterance text, chronological start order; overlap retained"
                        "; non-speech event markers excluded from speech-text reference"
                    ),
                    "word_timing": "not_observed",
                },
                ensure_ascii=False,
            )
        )
        lock["splits"][group] = {
            "manifest_sha256": _hash(path),
            "sessions": len(fixtures),
            "minutes": sum(float(f["duration_seconds"]) for f in fixtures) / 60,
            "speaker_counts": [f["speakers_count"] for f in fixtures],
        }
    (output / "split-lock.json").write_text(json.dumps(lock, indent=2))
    return lock


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source_dir, args.output_dir)))
