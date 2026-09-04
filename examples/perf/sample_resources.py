"""SpeechRail worker resource sampling during concurrent load.

Samples all qwen3 worker processes (batch/streaming/tts/host) for CPU% and Physical
Memory Footprint (using macOS ``footprint`` tool or ``ps rss`` fallback) while a load
test runs. Requires a running service.

Usage:
  python examples/perf/sample_resources.py --audio audio_30s.wav --n 6 --warmup
  python examples/perf/sample_resources.py --audio audio_10s.wav --mode all --warmup
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_asr import transcribe as transcribe_batch
from bench_tts import synthesize as synthesize_tts


def worker_pids() -> dict[str, int]:
    """Finds PIDs for host and backend worker processes."""
    out = subprocess.run(["ps", "aux"], capture_output=True, text=True, check=True).stdout
    found: dict[str, int] = {}
    for line in out.splitlines():
        if "resource_tracker" in line or "sample_resources" in line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[1])
        except ValueError:
            continue

        if "speechrail serve" in line or "python -m speechrail serve" in line:
            found["host-fastapi"] = pid
        elif "speechrail.backends.qwen3_tts_worker" in line:
            found["tts"] = pid
        elif "--worker-role streaming" in line:
            # batch and streaming run the same worker module; attribute by the
            # self-description --worker-role tag rather than module name, which
            # is identical for both (a native streaming worker would otherwise
            # be mis-matched as batch-asr and double-count the footprint).
            found["streaming-asr"] = pid
        elif "speechrail.backends.qwen3_worker" in line:
            found["batch-asr"] = pid
        elif "qwen3_streaming_worker" in line or "streaming_worker" in line:
            found["streaming-asr"] = pid
    return found


def _sample_footprint_mb(pid: int) -> tuple[float, float] | None:
    """Attempts to read (phys_footprint_mb, phys_footprint_peak_mb) on macOS using footprint."""
    if sys.platform != "darwin":
        return None
    try:
        proc = subprocess.run(
            ["footprint", "-p", str(pid), "-f", "bytes", "--noCategories"],
            capture_output=True,
            text=True,
            timeout=3.0,
        )
        if proc.returncode == 0:
            m_cur = re.search(r"phys_footprint:\s+(\d+)\s+B", proc.stdout)
            m_peak = re.search(r"phys_footprint_peak:\s+(\d+)\s+B", proc.stdout)
            if m_cur:
                cur_mb = float(m_cur.group(1)) / (1024.0 * 1024.0)
                peak_mb = float(m_peak.group(1)) / (1024.0 * 1024.0) if m_peak else cur_mb
                return cur_mb, peak_mb
    except Exception:
        pass
    return None


def sample(pid: int) -> tuple[float, float, float, str]:
    """Samples CPU%, Current Memory MB, Peak Memory MB. Returns (cpu%, cur_mb, peak_mb, metric)."""
    # CPU
    out_cpu = subprocess.run(
        ["ps", "-o", "%cpu=", "-p", str(pid)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    cpu = float(out_cpu) if out_cpu else 0.0

    # Memory: Try macOS footprint first for true physical Unified Memory footprint
    fp = _sample_footprint_mb(pid)
    if fp is not None:
        return cpu, fp[0], fp[1], "Footprint"

    # Fallback to ps rss
    out_rss = subprocess.run(
        ["ps", "-o", "rss=", "-p", str(pid)],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    rss_mb = (float(out_rss) if out_rss else 0.0) / 1024.0
    return cpu, rss_mb, rss_mb, "RSS"


def warm_up(mode: str, base_host: str, audio_path: Path | None) -> None:
    """Sends warm-up requests to ensure model tensors are faulted into physical memory."""
    print(">> Warming up workers (forcing model weights fault-in)...")
    if mode in ("batch", "all") and audio_path and audio_path.exists():
        try:
            transcribe_batch(
                f"{base_host}/v1/audio/transcriptions",
                audio_path,
                "speechrail/qwen3-asr-1.7b",
            )
        except Exception as exc:
            print(f"   [Warmup Batch ASR warning]: {exc}", file=sys.stderr)

    if mode in ("tts", "all"):
        try:
            synthesize_tts(
                f"{base_host}/v1/audio/speech",
                text="预热语音合成。",
                voice="default",
                model="speechrail/qwen3-tts",
            )
        except Exception as exc:
            print(f"   [Warmup TTS warning]: {exc}", file=sys.stderr)
    time.sleep(1.0)


def check_sanity(key: str, memory_mb: float, metric: str) -> None:
    """Verifies that 1.7B parameter models have physically plausible memory footprints."""
    if key in ("batch-asr", "streaming-asr", "tts") and memory_mb < 1500:
        msg = (
            f"   [SANITY_WARNING] {key} memory is only {memory_mb:.1f} MB ({metric})! "
            f"A 1.7B model should typically occupy ≥ 1,800 MB (INT8) or ≥ 3,400 MB (FP16). "
            f"The worker may be uninitialized, using a fake backend, "
            f"or weights are not yet resident."
        )
        print(msg, file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description="SpeechRail Worker Resource Sampler")
    parser.add_argument("--audio", help="Audio file path for ASR load testing")
    parser.add_argument("--n", type=int, default=6, help="Number of load requests")
    parser.add_argument("--mode", choices=("batch", "tts", "all"), default="batch")
    parser.add_argument("--host", default="http://127.0.0.1:8201", help="SpeechRail base URL")
    parser.add_argument("--model", default="speechrail/qwen3-asr-1.7b")
    parser.add_argument(
        "--warmup", action="store_true", help="Perform 1 warm-up round before sampling"
    )
    args = parser.parse_args()

    audio_path = Path(args.audio) if args.audio else None

    pids = worker_pids()
    if not pids:
        print("Error: No SpeechRail worker or host processes found.", file=sys.stderr)
        sys.exit(1)

    print(f"Discovered processes: {pids}")

    # 1. Pre-warmup initial snapshot
    initial_mem: dict[str, tuple[float, str]] = {}
    for key, pid in pids.items():
        try:
            _, cur_mb, _, metric = sample(pid)
            initial_mem[key] = (cur_mb, metric)
        except Exception:
            initial_mem[key] = (0.0, "N/A")

    # 2. Warmup if requested
    if args.warmup:
        warm_up(args.mode, args.host, audio_path)

    # 3. Post-warmup idle snapshot
    idle_mem: dict[str, tuple[float, str]] = {}
    for key, pid in pids.items():
        try:
            _, cur_mb, _, metric = sample(pid)
            idle_mem[key] = (cur_mb, metric)
            check_sanity(key, cur_mb, metric)
        except Exception:
            idle_mem[key] = (0.0, "N/A")

    # 4. Continuous background sampler during load
    peaks: dict[str, tuple[float, float, str]] = {
        key: (
            0.0,
            idle_mem.get(key, (0.0, "Footprint"))[0],
            idle_mem.get(key, (0.0, "Footprint"))[1],
        )
        for key in pids
    }
    # True CONCURRENT peak = max per-tick sum of CURRENT footprints (an all-time
    # phys_footprint_peak is monotonic, so summing per-process peaks over-states the
    # real simultaneous footprint when ASR/TTS run serially).
    peak_concurrent = [0.0]
    stop = threading.Event()

    def sampler_thread() -> None:
        while not stop.is_set():
            tick_cur: list[float] = []
            for key, pid in pids.items():
                try:
                    cpu, cur_mb, peak_mb, metric = sample(pid)
                except subprocess.CalledProcessError:
                    continue
                tick_cur.append(cur_mb)
                p = peaks[key]
                observed_peak = max(p[1], cur_mb, peak_mb)
                peaks[key] = (max(p[0], cpu), observed_peak, metric)
            if tick_cur:
                peak_concurrent[0] = max(peak_concurrent[0], float(sum(tick_cur)))
            time.sleep(0.3)

    t = threading.Thread(target=sampler_thread, daemon=True)
    t.start()

    # 5. Execute load
    print(f">> Running load test ({args.n} iterations, mode={args.mode})...")
    ok_count = 0
    for i in range(args.n):
        if args.mode in ("batch", "all") and audio_path and audio_path.exists():
            status, text = transcribe_batch(
                f"{args.host}/v1/audio/transcriptions", audio_path, args.model
            )
            if status is not None and text is not None:
                ok_count += 1
        elif args.mode == "tts":
            _elapsed, nbytes = synthesize_tts(
                f"{args.host}/v1/audio/speech",
                text=f"这是第 {i + 1} 次并发性能压测样本。",
                voice="default",
                model="speechrail/qwen3-tts",
            )
            if nbytes > 0:
                ok_count += 1
        time.sleep(0.1)

    stop.set()
    t.join(timeout=2.0)

    # 6. Report summary table
    print("\n" + "=" * 80)
    print(" SpeechRail 真实资源占用与压测基线汇总 (Resource Baseline Summary)")
    print("=" * 80)
    hdr = (
        f"{'组件 (Component)':<20} | {'PID':<8} | {'冷启待机':<12} | "
        f"{'预热常驻 (Idle)':<16} | {'压测峰值 (Peak)':<16} | {'峰值 CPU':<10}"
    )
    print(hdr)
    print("-" * 80)

    total_idle = 0.0
    for key, pid in pids.items():
        pre_mb = initial_mem.get(key, (0.0, ""))[0]
        post_mb, metric = idle_mem.get(key, (0.0, "MB"))
        peak_cpu, peak_mb, _ = peaks[key]
        peak_mb = max(peak_mb, post_mb)
        total_idle += post_mb

        print(
            f"{key:<20} | {pid:<8} | {pre_mb:>7.1f} MB   | {post_mb:>7.1f} MB ({metric[:4]}) | "
            f"{peak_mb:>7.1f} MB ({metric[:4]}) | {peak_cpu:>6.1f} %"
        )

    print("-" * 80)
    total_row = (
        f"{'总物理常驻 (Total)':<20} | {'--':<8} | {'--':<12} | "
        f"{total_idle:>7.1f} MB        | {peak_concurrent[0]:>7.1f} MB        | {'--':<10}"
    )
    print(total_row)
    print(
        "  注: Peak(Total) = 真同时峰值, 即逐采样tick的(当前footprint之和)的最大值; "
        "不为逐进程 all-time high-water 之和。"
    )
    print("=" * 80 + "\n")


if __name__ == "__main__":
    main()
