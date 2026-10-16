"""Development calibration via one native worker; not public-API acceptance.

The native worker compares candidate matchers in RAM using the same acoustic
inference. Only anonymous activity intervals cross IPC; vectors never do.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import time
import wave
from pathlib import Path

from speechrail.runtime.diarization_worker import CoreMLWorkerProcess

try:
    from .diarization_quality import score_diarization
except ImportError:  # pragma: no cover - direct CLI
    from diarization_quality import score_diarization  # type: ignore[no-redef]


def _file_digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def policy_grid(calibration_digest: str) -> list[dict[str, object]]:
    return [
        {
            "version": f"development-grid-{index}",
            "prototype_policy": "anchor_farthest_v1",
            "match_distance_max": match,
            "match_margin_min": margin,
            "update_distance_max": match * ratio,
            "minimum_new_voice_ms": 1500,
            "minimum_update_voice_ms": 2000,
            "candidate_retention_ms": 60000,
            "model_snapshot": "7eab74f3463c736418d0eb10296261ae581146c9",
            "calibration_digest": calibration_digest,
        }
        for index, (match, margin, ratio) in enumerate(
            (m, g, u)
            for m in (0.15, 0.25, 0.35, 0.45)
            for g in (0.03, 0.06, 0.10)
            for u in (0.5, 0.7)
        )
    ]


def replace_mutable(
    old: list[dict], incoming: list[dict], previous_stable: int, end: int
) -> list[dict]:
    """Auditor keeps the stable prefix and replaces exactly the mutable interval."""
    cursor = previous_stable
    for frame in incoming:
        if (
            type(frame.get("start")) is not int
            or type(frame.get("end")) is not int
            or (frame["start"] != cursor or not cursor < frame["end"] <= end)
        ):
            raise ValueError("calibration activity has a gap or overlap")
        if any(type(slot) is not int or not 0 <= slot < 32 for slot in frame["active_slots"]):
            raise ValueError("invalid calibration speaker slot")
        cursor = frame["end"]
    if cursor != end:
        raise ValueError("calibration activity omits accepted samples")
    prefix = [
        {**frame, "end": min(frame["end"], previous_stable)}
        for frame in old
        if frame["start"] < previous_stable
    ]
    return prefix + incoming


def speaker_spans(frames: list[dict]) -> list[dict]:
    return [
        {
            "start": frame["start"] / 16000,
            "end": frame["end"] / 16000,
            "speaker": "S" + str(slot + 1),
        }
        for frame in frames
        for slot in frame["active_slots"]
    ]


async def calibrate(manifest: Path, output: Path, executable: Path, models: Path) -> None:
    repository = (await asyncio.to_thread(Path(__file__).resolve)).parents[2]
    resolved_output = await asyncio.to_thread(output.resolve)
    resolved_manifest = await asyncio.to_thread(manifest.resolve)
    if (
        resolved_output.is_relative_to(repository)
        or resolved_manifest.is_relative_to(repository)
        or await asyncio.to_thread(output.exists)
    ):
        raise ValueError("use a locked external manifest and new external output directory")
    original = await asyncio.to_thread(manifest.read_bytes)
    fixtures = json.loads(original)["fixtures"]
    digest = hashlib.sha256(original).hexdigest()
    policies = policy_grid(digest)
    await asyncio.to_thread(output.mkdir, parents=True)
    grid = output / "development-policies.json"
    grid.write_text(json.dumps(policies))
    primary = output / "primary-policy.json"
    primary.write_text(json.dumps(policies[0]))
    executable_digest = await asyncio.to_thread(_file_digest, executable)
    (output / "execution-lock.json").write_text(
        json.dumps(
            {
                "manifest_sha256": digest,
                "executable_sha256": executable_digest,
                "policies_sha256": hashlib.sha256(grid.read_bytes()).hexdigest(),
                "scope": "native_development_not_formal_acceptance",
            },
            indent=2,
        )
    )
    all_results = []
    for fixture in fixtures:
        if await asyncio.to_thread(manifest.read_bytes) != original:
            raise ValueError("calibration manifest changed")
        audio = Path(fixture["path"])
        if await asyncio.to_thread(_file_digest, audio) != fixture["audio_sha256"]:
            raise ValueError("calibration audio digest differs from lock")
        reference = Path(fixture["reference_path"])
        if await asyncio.to_thread(_file_digest, reference) != fixture["reference_sha256"]:
            raise ValueError("calibration reference digest differs from lock")
        truth = json.loads(await asyncio.to_thread(reference.read_text))["speaker_spans"]
        worker = CoreMLWorkerProcess(
            executable=executable,
            model_path=models,
            protocol_version=2,
            backend="meeting_dynamic",
            policy_path=primary,
            calibration_policies_path=grid,
        )
        frames = [[] for _ in policies]
        timings = []
        peaks = [{"identities": 0, "prototypes": 0, "candidates": 0} for _ in policies]
        previous_stable = 0
        try:
            async with asyncio.timeout(120):
                await worker.start()
            with wave.open(str(audio)) as wav:
                if (wav.getnchannels(), wav.getframerate(), wav.getsampwidth()) != (1, 16000, 2):
                    raise ValueError("calibration requires 16 kHz mono PCM16")
                count = wav.getnframes()
                for end in [*range(160000, count, 160000), count]:
                    start = max(0, end - 480000)
                    wav.setpos(start)
                    pcm = wav.readframes(end - start)
                    started = time.monotonic()
                    async with asyncio.timeout(120):
                        response, payload = await worker.request(
                            {
                                "operation": "infer",
                                "epoch": fixture["id"],
                                "audio_start": start,
                                "audio_samples": end - start,
                                "previous_stable": previous_stable,
                                "final": end == count,
                            },
                            pcm,
                        )
                    if response.get("ok") is not True or response.get("epoch") != fixture["id"]:
                        raise RuntimeError("native calibration inference failed")
                    timings.append(time.monotonic() - started)
                    variants = json.loads(payload)
                    if len(variants) != len(policies) or [
                        v["candidate_index"] for v in variants
                    ] != list(range(len(policies))):
                        raise ValueError("calibration candidate identity changed")
                    for index, variant in enumerate(variants):
                        frames[index] = replace_mutable(
                            frames[index], variant["frames"], previous_stable, end
                        )
                        for field, key in (
                            ("identities", "identity_count"),
                            ("prototypes", "prototype_count"),
                            ("candidates", "candidate_count"),
                        ):
                            peaks[index][field] = max(peaks[index][field], variant[key])
                    stable = response["stable_through"]
                    if (
                        type(stable) is not int
                        or not previous_stable <= stable <= end
                        or (end == count and stable != end)
                    ):
                        raise ValueError("calibration watermark is invalid")
                    previous_stable = stable
                    (output / "progress.json").write_text(
                        json.dumps(
                            {
                                "fixture_id": fixture["id"],
                                "processed_seconds": end / 16000,
                                "total_seconds": count / 16000,
                                "completed_sessions": len(all_results),
                                "inference_count": len(timings),
                            }
                        )
                    )
        finally:
            await worker.close()
        (output / (fixture["id"] + ".activity.json")).write_text(
            json.dumps(
                {
                    "frames": frames,
                    "retained_state_peaks": peaks,
                    "duration_seconds": count / 16000,
                    "infer_seconds": timings,
                    "executable_sha256": executable_digest,
                    "manifest_sha256": digest,
                }
            )
        )
        results = [
            {
                "candidate_index": index,
                "metrics": score_diarization(
                    truth, speaker_spans(activity), duration=count / 16000
                ),
                "retained_state_peaks": peaks[index],
            }
            for index, activity in enumerate(frames)
        ]
        result = {
            "fixture_id": fixture["id"],
            "duration_seconds": count / 16000,
            "infer_seconds": timings,
            "candidates": results,
        }
        (output / (fixture["id"] + ".json")).write_text(json.dumps(result, indent=2))
        all_results.append(result)
        print(
            json.dumps(
                {
                    "completed_fixture": fixture["id"],
                    "sessions": len(all_results),
                    "passing_candidates": sum(
                        r["metrics"]["quality_gate"] == "pass" for r in results
                    ),
                }
            ),
            flush=True,
        )
    feasible = [
        i
        for i in range(len(policies))
        if all(
            session["candidates"][i]["metrics"]["known_accuracy"] >= 0.95 for session in all_results
        )
    ]

    def rank(index):
        scores = [s["candidates"][index]["metrics"] for s in all_results]
        return (
            sum(s["known_coverage"] for s in scores) / len(scores),
            min(s["other_min_known_coverage"] for s in scores),
        )

    winner = max(feasible, key=rank) if feasible else None
    best_observed = max(
        range(len(policies)),
        key=lambda i: (
            min(s["candidates"][i]["metrics"]["known_accuracy"] for s in all_results),
            *rank(i),
        ),
    )
    summary = {
        "schema_version": 1,
        "tool": "speechrail-diarization-development-calibration",
        "evidence_mode": "native_development",
        "formal_public_api_acceptance": False,
        "manifest_sha256": digest,
        "sessions": len(all_results),
        "candidates": len(policies),
        "feasible_candidates": feasible,
        "winner_index": winner,
        "best_observed_index": best_observed,
        "quality_gate": "pass"
        if winner is not None
        and all(s["candidates"][winner]["metrics"]["quality_gate"] == "pass" for s in all_results)
        else "fail",
        "production_certified": False,
    }
    if winner is not None:
        # Threshold selection is frozen before holdout; this does not grant a certificate.
        (output / "selected-policy.json").write_text(json.dumps(policies[winner], indent=2))
    (output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("manifest", "output", "executable", "models"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    asyncio.run(calibrate(args.manifest, args.output, args.executable, args.models))
