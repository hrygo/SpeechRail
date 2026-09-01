"""Generate SpeechRail performance-test audio assets.

Creates 16 kHz mono PCM16 WAV files of speech-like content at several
durations, plus pink-noise controls, into an output directory.

Usage: python examples/perf/generate_audio.py [--out DIR] [--base BASE_WAV]
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

DURATIONS = (3, 10, 30, 60)


def wav_duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return float(out)


def generate(args: argparse.Namespace) -> None:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for seconds in DURATIONS:
        noise = out / f"noise_{seconds}s.wav"
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i",
             f"anoisesrc=d={seconds}:c=pink:r=16000:a=0.02",
             "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(noise)],
            check=True,
        )

    base = Path(args.base)
    if base.exists():
        base_duration = wav_duration(base)
        print(f"base={base.name} duration={base_duration:.1f}s")
        for seconds in DURATIONS:
            target = out / f"speech_{seconds}s.wav"
            if seconds <= base_duration:
                subprocess.run(
                    ["ffmpeg", "-y", "-v", "error", "-i", str(base),
                     "-t", str(seconds), "-c:a", "pcm_s16le", str(target)],
                    check=True,
                )
            else:
                loops = seconds // int(base_duration) + 1
                subprocess.run(
                    ["ffmpeg", "-y", "-v", "error", "-stream_loop", str(loops),
                     "-i", str(base), "-t", str(seconds),
                     "-c:a", "pcm_s16le", str(target)],
                    check=True,
                )
    else:
        print(f"base {args.base} not found; speech samples skipped")

    for path in sorted(out.glob("*.wav")):
        print(f"  {path.name}: {wav_duration(path):.1f}s")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="/tmp/speechrail-perf")
    parser.add_argument("--base", default="/tmp/qwenpaw-voice-smoke-20260831.wav")
    args = parser.parse_args()
    try:
        generate(args)
    except subprocess.CalledProcessError as exc:
        print(f"ffmpeg failed: {exc}", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
