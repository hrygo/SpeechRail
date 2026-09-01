"""SpeechRail worker resource sampling during concurrent ASR load.

Samples all qwen3 worker processes (batch/streaming/tts) for CPU% and RSS
peaks while a concurrent load test runs. Requires a running service.

Usage:
  python examples/perf/sample_resources.py --audio audio_30s.wav --n 6
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_asr import transcribe


def worker_pids() -> dict[str, int]:
    out = subprocess.run(["ps", "aux"], capture_output=True, text=True, check=True).stdout
    found: dict[str, int] = {}
    for line in out.splitlines():
        if "speechrail.backends.qwen3" not in line or "resource_tracker" in line:
            continue
        parts = line.split()
        pid = int(parts[1])
        if "qwen3_worker" in line and "streaming" not in line:
            found["batch-asr"] = pid
        elif "qwen3_streaming_worker" in line:
            found["streaming-asr"] = pid
        elif "qwen3_tts_worker" in line:
            found["tts"] = pid
    return found


def sample(pid: int) -> tuple[float, float]:
    out = subprocess.run(
        ["ps", "-o", "%cpu=,rss=", "-p", str(pid)],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    cpu_s, rss_kb = out.split()
    return float(cpu_s), float(rss_kb) / 1024


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--n", type=int, default=6)
    parser.add_argument("--model", default="speechrail/qwen3-asr-1.7b")
    parser.add_argument("--base", default="http://127.0.0.1:8201/v1/audio/transcriptions")
    args = parser.parse_args()

    pids = worker_pids()
    print(f"workers: {pids}")
    peaks: dict[str, tuple[float, float]] = dict.fromkeys(pids, (0.0, 0.0))
    stop = threading.Event()

    def sampler() -> None:
        while not stop.is_set():
            for key, pid in pids.items():
                try:
                    cpu, mb = sample(pid)
                except subprocess.CalledProcessError:
                    continue
                p = peaks[key]
                peaks[key] = (max(p[0], cpu), max(p[1], mb))
            time.sleep(0.5)

    t = threading.Thread(target=sampler, daemon=True)
    t.start()

    path = Path(args.audio)
    statuses = []
    for _ in range(args.n):
        status, text = transcribe(args.base, path, args.model)
        statuses.append(200 if status is not None and text is not None else status)
    stop.set()

    print(f"load: {args.n}x transcribe, ok={sum(1 for s in statuses if s == 200)}/{args.n}")
    for key, (cpu, mb) in peaks.items():
        print(f"peak {key}: {cpu:.0f}% cpu, {mb:.0f}MB rss")


if __name__ == "__main__":
    main()
