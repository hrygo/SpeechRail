#!/usr/bin/env python3
"""SpeechRail All-in-One Automated Performance Benchmark Runner.

Executes:
1. Service Health & Readiness check
2. Benchmark fixture generation (via prepare_fixtures.py)
3. TTS Latency & RTF Benchmark (short & long sentences)
4. REST ASR Single-request latency (3s, 10s, 30s, 60s)
5. REST ASR Concurrent throughput (4 workers, 8 requests)
6. Realtime WebSocket latency (session setup, ASR commit, TTFA)
7. Full resource footprint & peak memory monitoring under load

Usage:
  python3 .agents/skills/speechrail-perf-benchmark/scripts/run_all_benchmarks.py
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = SKILL_DIR.parent.parent
EXAMPLES_PERF = REPO_ROOT / "examples" / "perf"


def check_service(base_url: str) -> bool:
    print(f">> [1/7] Probing service health at {base_url}...")
    try:
        with urllib.request.urlopen(f"{base_url}/health", timeout=5) as resp:
            health = json.loads(resp.read())
        with urllib.request.urlopen(f"{base_url}/readyz", timeout=5) as resp:
            readyz = json.loads(resp.read())
    except Exception as exc:
        print(f"Error: Unable to reach SpeechRail service: {exc}", file=sys.stderr)
        return False

    asr_ok = health.get("asr_ready", False)
    tts_ok = health.get("tts_ready", False)
    is_ready = readyz.get("ready", False)
    print(f"  Health: version={health.get('version')} asr_ready={asr_ok} tts_ready={tts_ok} ready={is_ready}")

    if not (asr_ok and tts_ok and is_ready):
        print("Error: Service is not fully ready (ASR & TTS required).", file=sys.stderr)
        return False
    return True


def find_python_with_openai() -> str:
    """Locates a Python binary that has the 'openai' package installed."""
    candidates = [
        sys.executable,
        str(Path.home() / ".qwenpaw" / "venv" / "bin" / "python"),
        str(REPO_ROOT / ".venv" / "bin" / "python"),
        shutil.which("python3") or "python3",
    ]
    for py in candidates:
        if not py or not Path(py).exists():
            continue
        proc = subprocess.run([py, "-c", "import openai"], capture_output=True)
        if proc.returncode == 0:
            return py
    return sys.executable


def main() -> None:
    parser = argparse.ArgumentParser(description="Run complete SpeechRail performance benchmark suite.")
    parser.add_argument("--host", default="http://127.0.0.1:8201", help="SpeechRail base URL")
    args = parser.parse_args()

    if not check_service(args.host):
        sys.exit(1)

    # 2. Prepare fixtures
    print("\n>> [2/7] Generating audio fixtures...")
    prep_script = Path(__file__).resolve().parent / "prepare_fixtures.py"
    subprocess.run([sys.executable, str(prep_script), "--base", f"{args.host}/v1/audio/speech"], check=True)

    # 3. TTS Latency
    print("\n>> [3/7] Running TTS latency benchmark...")
    tts_script = EXAMPLES_PERF / "bench_tts.py"
    subprocess.run([
        sys.executable, str(tts_script),
        "--base", f"{args.host}/v1/audio/speech",
        "--text", "你好, 这是本地语音合成服务的性能测试。",
        "--repeat", "3"
    ], check=True)
    subprocess.run([
        sys.executable, str(tts_script),
        "--base", f"{args.host}/v1/audio/speech",
        "--text", "你好，这是本地语音识别与合成服务的性能基准测试。SpeechRail 能够快速高效地输出高品质语音。",
        "--repeat", "3"
    ], check=True)

    # 4. REST ASR Single Latency
    print("\n>> [4/7] Running REST ASR single-request latency benchmark...")
    asr_script = EXAMPLES_PERF / "bench_asr.py"
    subprocess.run([
        sys.executable, str(asr_script),
        "--base", f"{args.host}/v1/audio/transcriptions",
        "--audio", "/tmp/audio_3s.wav", "/tmp/audio_10s.wav", "/tmp/audio_30s.wav", "/tmp/audio_60s.wav",
        "--n", "3"
    ], check=True)

    # 5. REST ASR Concurrency
    print("\n>> [5/7] Running REST ASR concurrent throughput benchmark...")
    subprocess.run([
        sys.executable, str(asr_script),
        "--base", f"{args.host}/v1/audio/transcriptions",
        "--audio", "/tmp/audio_10s.wav",
        "--workers", "4",
        "--n", "8"
    ], check=True)

    # 6. Realtime WS
    print("\n>> [6/7] Running Realtime WebSocket benchmark...")
    openai_py = find_python_with_openai()
    realtime_script = EXAMPLES_PERF / "bench_realtime.py"
    try:
        subprocess.run([
            openai_py, str(realtime_script),
            "/tmp/audio_10s_16k.pcm",
            "--sessions", "3"
        ], check=True)
    except Exception as exc:
        print(f"Warning: Realtime WS benchmark failed or skipped: {exc}")

    # 7. Resource Sampling
    print("\n>> [7/7] Sampling resource memory footprint & CPU under load...")
    sample_script = EXAMPLES_PERF / "sample_resources.py"
    subprocess.run([
        sys.executable, str(sample_script),
        "--host", args.host,
        "--audio", "/tmp/audio_30s.wav",
        "--mode", "all",
        "--n", "5",
        "--warmup"
    ], check=True)

    print("\n============================================================")
    print(" [✓] Full SpeechRail Performance Benchmark Suite Completed!")
    print("============================================================")


if __name__ == "__main__":
    main()
