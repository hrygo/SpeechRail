"""SpeechRail REST ASR performance benchmark.

Measures end-to-end latency, RTF and concurrent throughput for
POST /v1/audio/transcriptions. Requires a running service with a real
backend (asr_ready=true); do not run against a fake backend.

Usage:
  python examples/perf/bench_asr.py --audio audio_10s.wav audio_30s.wav
  python examples/perf/bench_asr.py --audio audio_10s.wav --workers 4 --n 8
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import statistics
import subprocess
import time
from pathlib import Path
from urllib import request

DEFAULT_BASE = "http://127.0.0.1:8201/v1/audio/transcriptions"


def audio_duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return float(out)


def transcribe(base: str, path: Path, model: str) -> tuple[float, str | None]:
    boundary = "----speechrail-perf"
    body = bytearray()
    for name, value in (("model", model), ("response_format", "json")):
        body += (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
            f"{value}\r\n".encode()
        )
    body += (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"{path.name}\"\r\nContent-Type: audio/wav\r\n\r\n".encode()
    )
    body += path.read_bytes()
    body += f"\r\n--{boundary}--\r\n".encode()
    req = request.Request(
        base,
        data=bytes(body),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    t0 = time.monotonic()
    with request.urlopen(req, timeout=600) as resp:
        payload = json.loads(resp.read())
    return time.monotonic() - t0, payload.get("text")


def run_single(args: argparse.Namespace) -> None:
    print(f"=== REST ASR single-request latency (model={args.model}, n={args.n}) ===")
    for audio in args.audio:
        path = Path(audio)
        duration = audio_duration(path)
        latencies: list[float] = []
        for _ in range(args.n):
            elapsed, text = transcribe(args.base, path, args.model)
            latencies.append(elapsed)
            print(f"  {path.name}: {elapsed:.2f}s text={text!r}")
        mean = statistics.mean(latencies)
        print(
            f"  => {path.name}: duration={duration:.1f}s mean={mean:.2f}s "
            f"rtf={mean / duration:.2f}x min={min(latencies):.2f}s max={max(latencies):.2f}s"
        )


def run_concurrent(args: argparse.Namespace) -> None:
    print(f"=== REST ASR concurrent throughput (workers={args.workers}, n={args.n}) ===")
    path = Path(args.audio[0])
    duration = audio_duration(path)
    t0 = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(
            pool.map(lambda _: transcribe(args.base, path, args.model), range(args.n))
        )
    wall = time.monotonic() - t0
    latencies = [r[0] for r in results]
    ok = sum(1 for r in results if r[1] is not None)
    p95 = sorted(latencies)[int(len(latencies) * 0.95) - 1]
    print(
        f"  workers={args.workers} n={args.n} wall={wall:.2f}s "
        f"ok={ok}/{args.n} mean={statistics.mean(latencies):.2f}s p95={p95:.2f}s "
        f"throughput={args.n / wall:.2f} req/s rtf_total={wall / (duration * args.n):.2f}x"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", nargs="+", required=True)
    parser.add_argument("--model", default="speechrail/qwen3-asr-1.7b")
    parser.add_argument("--base", default=DEFAULT_BASE)
    parser.add_argument("--n", type=int, default=3)
    parser.add_argument("--workers", type=int, default=0, help="0=sequential single")
    args = parser.parse_args()
    if args.workers:
        run_concurrent(args)
    else:
        run_single(args)


if __name__ == "__main__":
    main()
