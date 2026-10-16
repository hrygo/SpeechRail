"""Compare immutable external ASR evidence without treating repeats as people."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from collections import defaultdict
from pathlib import Path

try:
    from .asr_window_evidence import paired_bootstrap
    from .benchmark_runner import validate_output_path, write_result
except ImportError:  # pragma: no cover - direct CLI
    from asr_window_evidence import paired_bootstrap
    from benchmark_runner import validate_output_path, write_result


def compare_results(baseline: dict, candidate: dict, *, draws: int = 10000) -> dict:
    def rows(payload):
        if (
            payload.get("evidence_mode") != "real"
            or payload.get("measurement_completed") is not True
        ):
            raise ValueError("paired comparison requires complete real measurements")
        result = {}
        for row in payload.get("sessions", []):
            identity, repeat = row.get("id"), row.get("repeat")
            if (
                not isinstance(identity, str)
                or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", identity) is None
                or type(repeat) is not int
                or not 1 <= repeat <= 100
            ):
                raise ValueError("invalid paired session identity")
            key = identity, repeat
            if key in result:
                raise ValueError("duplicate paired run")
            for field in ("wire_pcm_sha256", "reference_text_sha256"):
                if re.fullmatch(r"[0-9a-f]{64}", str(row.get(field))) is None:
                    raise ValueError("paired measurements need audio and reference digests")
            metrics = row.get("quality_metrics", {})
            metrics = metrics.get("normalized", metrics)
            count, errors = metrics.get("reference_characters"), metrics.get("character_errors")
            if type(count) is not int or count <= 0 or type(errors) is not int or errors < 0:
                raise ValueError(
                    "paired CER needs independent nonempty references and error counts"
                )
            cer = metrics.get("cer")
            if (
                type(cer) not in (int, float)
                or not math.isfinite(cer)
                or not math.isclose(cer, errors / count)
            ):
                raise ValueError("paired CER differs from its counts")
            result[key] = row, count, errors
        if not result:
            raise ValueError("paired measurements are empty")
        return result

    old, new = rows(baseline), rows(candidate)
    if old.keys() != new.keys() or baseline.get("profile") != candidate.get("profile"):
        raise ValueError("paired measurements must use the same sessions, repeats and profile")
    sessions = defaultdict(list)
    for key, (before, count, errors) in old.items():
        after, new_count, new_errors = new[key]
        if count != new_count or any(
            before[field] != after[field] for field in ("wire_pcm_sha256", "reference_text_sha256")
        ):
            raise ValueError("paired measurements differ in audio or human reference")
        sessions[key[0]].append((errors, new_errors, count))
    pairs, observations = [], []
    for identity in sorted(sessions):
        group = sessions[identity]
        # Average repeats within each meeting before resampling meetings.
        count = sum(row[2] for row in group) / len(group)
        before = sum(row[0] for row in group) / len(group)
        after = sum(row[1] for row in group) / len(group)
        pairs.append((before / count, after / count))
        observations.append(
            {
                "fixture_id": identity,
                "repeats": len(group),
                "reference_characters": count,
                "baseline_errors_mean": before,
                "candidate_errors_mean": after,
                "delta": (after - before) / count,
            }
        )
    denominator = sum(row["reference_characters"] for row in observations)
    matching_models = bool(baseline.get("model_identity")) and baseline.get(
        "model_identity"
    ) == candidate.get("model_identity")
    warm = baseline.get("warmup_completed") is True and candidate.get("warmup_completed") is True
    return {
        "schema_version": 1,
        "tool": "speechrail-asr-window-comparison",
        "pairing_gate": "pass",
        "quality_enable_gate": "unset",
        "independent_sessions": len(sessions),
        "paired_runs": len(old),
        "model_and_warm_state_gate": "pass" if matching_models and warm else "unset",
        "normalized_cer": {
            "baseline_micro": sum(row["baseline_errors_mean"] for row in observations)
            / denominator,
            "candidate_micro": sum(row["candidate_errors_mean"] for row in observations)
            / denominator,
            "sessions": observations,
            "paired": paired_bootstrap(pairs, draws=draws)
            if len(pairs) >= 2
            else "insufficient_independent_sessions",
        },
        "unobserved_gates": [
            "corpus_person_disjointness",
            "fact_accuracy",
            "ui_latency",
            "long_stability",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    payloads, digests = [], []
    for path in (args.baseline, args.candidate):
        resolved = path.resolve(strict=True)
        if not path.is_absolute() or resolved.is_relative_to(root):
            raise ValueError("comparison inputs must be external absolute evidence paths")
        raw = resolved.read_bytes()
        if len(raw) > 64 * 1024 * 1024:
            raise ValueError("comparison evidence exceeds its size bound")
        payloads.append(json.loads(raw))
        digests.append(hashlib.sha256(raw).hexdigest())
    result = compare_results(*payloads)
    result["input_sha256"] = {"baseline": digests[0], "candidate": digests[1]}
    write_result(result, validate_output_path(args.output))


if __name__ == "__main__":
    main()
