#!/usr/bin/env python3
"""Read-only local A/V metadata and optional decoded-audio loudness checks."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any


class InspectionError(Exception):
    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        # Do not echo arbitrary paths or other supplied values into reports.
        raise InspectionError("input", "Invalid arguments; use --help for usage.")


def finite(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return result if math.isfinite(result) else None


def arguments() -> argparse.Namespace:
    parser = Parser(description=__doc__)
    parser.add_argument("media", type=Path)
    parser.add_argument("--loudness", action="store_true")
    for name, default in [
        ("expected-duration", None),
        ("duration-tolerance", 0.1),
        ("target-lufs", None),
        ("lufs-tolerance", 1.0),
        ("max-true-peak", None),
        ("av-tolerance", 0.1),
        ("timeout", 300.0),
    ]:
        parser.add_argument(f"--{name}", type=float, default=default)
    parser.add_argument("--video-index", type=int)
    parser.add_argument("--audio-index", type=int)
    args = parser.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, float) and finite(value) is None:
            raise InspectionError("input", f"{name} must be finite.")
    for name in [
        "duration_tolerance",
        "lufs_tolerance",
        "av_tolerance",
        "video_index",
        "audio_index",
    ]:
        value = getattr(args, name)
        if value is not None and value < 0:
            raise InspectionError("input", f"{name} must be nonnegative.")
    for name in ["timeout", "expected_duration"]:
        value = getattr(args, name)
        if value is not None and value <= 0:
            raise InspectionError("input", f"{name} must be positive.")
    return args


def run(command: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            stdin=subprocess.DEVNULL,
            check=False,
        )
    except FileNotFoundError as exc:
        raise InspectionError("dependency", f"{command[0]} is unavailable.") from exc
    except subprocess.TimeoutExpired as exc:
        raise InspectionError("timeout", f"{command[0]} exceeded --timeout.") from exc
    if result.returncode:
        # FFmpeg stderr may contain private metadata and source paths.
        raise InspectionError("media", f"{command[0]} could not inspect the selected media.")
    return result


def select_stream(streams: list[dict], kind: str, index: int | None) -> dict | None:
    candidates = [stream for stream in streams if stream.get("codec_type") == kind]
    if kind == "video":
        candidates = [s for s in candidates if not s.get("disposition", {}).get("attached_pic")]
    if index is not None:
        candidates = [s for s in candidates if s.get("index") == index]
        if not candidates:
            raise InspectionError("input", f"Selected {kind} index is absent or has wrong type.")
    return candidates[0] if candidates else None


def interval(stream: dict | None) -> tuple[float | None, float | None]:
    if stream is None:
        return None, None
    start, duration = finite(stream.get("start_time")), finite(stream.get("duration"))
    return start, duration if duration is not None and duration > 0 else None


def difference(left: float | None, right: float | None, tolerance: float) -> dict:
    if left is None or right is None:
        return {"status": "unknown", "reason": "Required timing metadata unavailable."}
    delta = abs(left - right)
    return {
        "status": "pass" if delta <= tolerance else "fail",
        "difference_seconds": delta,
        "tolerance_seconds": tolerance,
    }


def measure_loudness(path: Path, audio: dict, timeout: float) -> dict:
    result = run(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-nostdin",
            "-v",
            "info",
            "-xerror",
            "-protocol_whitelist",
            "file",
            "-i",
            str(path),
            "-map",
            f"0:{audio['index']}",
            "-vn",
            "-sn",
            "-dn",
            "-af",
            "loudnorm=print_format=json",
            "-f",
            "null",
            "-",
        ],
        timeout,
    )
    # Only the filter's input_* values describe the original decoded audio;
    # the normalized output is discarded and is never written over the input.
    start, end = result.stderr.rfind("{"), result.stderr.rfind("}")
    if start < 0 or end < start:
        raise InspectionError("measurement", "No loudness measurement was returned.")
    data = json.loads(result.stderr[start : end + 1])
    return {
        name: finite(data.get(key))
        for name, key in [
            ("integrated_lufs", "input_i"),
            ("true_peak_dbtp", "input_tp"),
            ("lra_lu", "input_lra"),
            ("threshold_lufs", "input_thresh"),
        ]
    }


def inspect(args: argparse.Namespace) -> dict:
    path = args.media.resolve()
    if not path.is_file():
        raise InspectionError("input", "Input must be an existing local media file.")
    before = path.stat()
    with path.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    probe = json.loads(
        run(
            [
                "ffprobe",
                "-v",
                "error",
                "-protocol_whitelist",
                "file",
                "-show_entries",
                "format=format_name,duration:stream=index,codec_name,codec_type,width,height,"
                "pix_fmt,r_frame_rate,avg_frame_rate,sample_rate,channels,channel_layout,"
                "start_time,duration:stream_disposition=attached_pic",
                "-of",
                "json",
                str(path),
            ],
            args.timeout,
        ).stdout
    )
    streams = probe.get("streams", [])
    video = select_stream(streams, "video", args.video_index)
    audio = select_stream(streams, "audio", args.audio_index)
    vs, vd = interval(video)
    aus, ad = interval(audio)
    ve = vs + vd if vs is not None and vd is not None else None
    ae = aus + ad if aus is not None and ad is not None else None
    checks: dict[str, dict] = {
        "required_streams": {"status": "pass" if video and audio else "fail"},
        "audio_video_duration": difference(vd, ad, args.av_tolerance),
        "audio_video_start": difference(vs, aus, args.av_tolerance),
        "audio_video_end": difference(ve, ae, args.av_tolerance),
        "loudness": {"status": "not_requested"},
    }
    if args.expected_duration is not None:
        checks["expected_duration"] = difference(
            finite(probe.get("format", {}).get("duration")),
            args.expected_duration,
            args.duration_tolerance,
        )
    if args.loudness or args.target_lufs is not None or args.max_true_peak is not None:
        if audio is None:
            checks["loudness"] = {"status": "unknown", "reason": "No selected audio stream."}
        else:
            measured = measure_loudness(path, audio, args.timeout)
            checks["loudness"] = {
                "status": "pass" if all(v is not None for v in measured.values()) else "unknown",
                "measured": measured,
            }
            for name, value, target, tolerance in [
                (
                    "integrated_loudness",
                    measured["integrated_lufs"],
                    args.target_lufs,
                    args.lufs_tolerance,
                ),
                ("true_peak", measured["true_peak_dbtp"], args.max_true_peak, None),
            ]:
                if target is not None:
                    passed = (
                        (value <= target if tolerance is None else abs(value - target) <= tolerance)
                        if value is not None
                        else False
                    )
                    checks[name] = {
                        "status": "unknown" if value is None else "pass" if passed else "fail",
                        "measured": value,
                        "target": target,
                        "tolerance": tolerance,
                    }
    after = path.stat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    ):
        raise InspectionError("input_changed", "Input changed during inspection; inspect again.")
    states = {check["status"] for check in checks.values()}
    return {
        "status": "fail" if "fail" in states else "unknown" if "unknown" in states else "pass",
        "sha256": digest,
        "media": {"format": probe.get("format", {}), "video": video, "audio": audio},
        "checks": checks,
    }


def main() -> int:
    try:
        report = inspect(arguments())
    except InspectionError as exc:
        report = {"status": "error", "error": {"kind": exc.kind, "message": str(exc)}}
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        report = {
            "status": "error",
            "error": {"kind": "operation", "message": "Unable to read media or measurement data."},
        }
    report["human_review_required"] = True
    report["checked_at"] = datetime.now(UTC).isoformat()
    print(json.dumps(report, ensure_ascii=False, allow_nan=False, indent=2))
    return {"pass": 0, "fail": 1}.get(report["status"], 2)


if __name__ == "__main__":
    raise SystemExit(main())
