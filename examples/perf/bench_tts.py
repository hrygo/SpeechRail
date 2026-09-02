"""SpeechRail REST TTS performance benchmark.

Measures end-to-end latency and output-vs-generation time for
POST /v1/audio/speech. Requires a running service with TTS backend ready;
do not run against a fake backend.

Usage:
  python examples/perf/bench_tts.py --text "你好, 性能测试."
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import time
from urllib import request

DEFAULT_BASE = "http://127.0.0.1:8201/v1/audio/speech"
PCM_BYTES_PER_SECOND = 48_000  # 24 kHz * 16-bit stereo? no: mono 16-bit = 48000 B/s


def auth_headers() -> dict[str, str]:
    """Return an Authorization header when SPEECHRAIL_API_KEY is configured."""
    key = os.environ.get("SPEECHRAIL_API_KEY")
    return {"Authorization": f"Bearer {key}"} if key else {}


def synthesize(
    base: str, text: str, voice: str, model: str
) -> tuple[float, int]:
    body = json.dumps(
        {
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "pcm",
        }
    ).encode()
    headers = {"Content-Type": "application/json", **auth_headers()}
    req = request.Request(base, data=body, headers=headers)
    t0 = time.monotonic()
    with request.urlopen(req, timeout=600) as resp:
        audio = resp.read()
    return time.monotonic() - t0, len(audio)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", default="你好, 这是本地语音合成服务的性能测试。")
    parser.add_argument("--voice", default="default")
    parser.add_argument("--model", default="speechrail/qwen3-tts")
    parser.add_argument("--base", default=DEFAULT_BASE)
    parser.add_argument("--repeat", type=int, default=3)
    args = parser.parse_args()

    print(
        f"=== REST TTS latency (voice={args.voice}, chars={len(args.text)}, "
        f"n={args.repeat}) ==="
    )
    latencies: list[float] = []
    out_seconds_list: list[float] = []
    for i in range(args.repeat):
        elapsed, nbytes = synthesize(args.base, args.text, args.voice, args.model)
        latencies.append(elapsed)
        out_seconds = nbytes / PCM_BYTES_PER_SECOND
        out_seconds_list.append(out_seconds)
        print(
            f"  run {i + 1}: {elapsed:.2f}s output={out_seconds:.2f}s audio "
            f"({nbytes} bytes)"
        )
    mean = statistics.mean(latencies)
    mean_out = statistics.mean(out_seconds_list)
    print(
        f"  => mean={mean:.2f}s min={min(latencies):.2f}s max={max(latencies):.2f}s "
        f"rtf={mean / (mean_out or 1):.2f}x"
    )


if __name__ == "__main__":
    main()
