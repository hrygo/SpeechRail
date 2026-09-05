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
import math
import os
import re
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bench_asr import transcribe as transcribe_batch
from bench_tts import synthesize as synthesize_tts
from profile_metrics import ProcessIdentity

type SampleValue = tuple[float, float, float, str]
type ProcessReader = Callable[[ProcessIdentity], SampleValue | None]

FOOTPRINT_METRIC = "Footprint"
RSS_FALLBACK_METRIC = "RSS (not phys_footprint gate)"


@dataclass(slots=True)
class SamplingStats:
    """State collected by the sampler without retaining audio or raw process output."""

    process_peaks: dict[str, tuple[float, float, str]] = field(default_factory=dict)
    peak_concurrent_mb: float | None = None
    ticks: int = 0
    complete_ticks: int = 0
    incomplete_ticks: int = 0
    missing_observations: int = 0
    rss_ticks: int = 0
    sampling_span_seconds: float | None = None
    observation_seconds: float = 0.0
    max_tick_span_seconds: float = 0.0
    error: Exception | None = None

    @property
    def gate_complete(self) -> bool:
        return (
            self.ticks > 0
            and self.complete_ticks == self.ticks
            and self.rss_ticks == 0
            and self.error is None
        )


def _start_time_identity(start_time: str) -> int | None:
    """将 ps lstart 转为纳秒时间戳。原始精度为一秒。"""
    normalized = " ".join(start_time.split())
    if not normalized:
        return None
    try:
        started = datetime.strptime(normalized, "%a %b %d %H:%M:%S %Y")
    except ValueError:
        return None
    return int(started.timestamp()) * 1_000_000_000


def _read_process_start_time(pid: int) -> str | None:
    """Read a process lifetime token; missing/terminated processes return None."""
    try:
        proc = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            capture_output=True,
            text=True,
            check=False,
            timeout=1.0,
            env={"PATH": os.defpath, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    start_time = proc.stdout.strip()
    return start_time or None


def _current_process_identity(pid: int, *, start_hint: str | None = None) -> ProcessIdentity | None:
    del start_hint  # ps aux 的短时间提示不能证明同一进程生命周期。
    start_time = _read_process_start_time(pid)
    if start_time is None:
        return None
    start_time_ns = _start_time_identity(start_time)
    if start_time_ns is None:
        return None
    return ProcessIdentity(pid=pid, start_time_ns=start_time_ns)


def worker_pids() -> dict[str, ProcessIdentity]:
    """Finds PIDs for host and backend worker processes."""
    out = subprocess.run(["ps", "aux"], capture_output=True, text=True, check=True).stdout
    found: dict[str, ProcessIdentity] = {}
    seen: set[ProcessIdentity] = set()
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

        label: str | None = None
        if "speechrail serve" in line or "python -m speechrail serve" in line:
            label = "host-fastapi"
        elif "speechrail.backends.qwen3_tts_worker" in line:
            label = "tts"
        elif "--worker-role streaming" in line:
            # batch and streaming run the same worker module; attribute by the
            # self-description --worker-role tag rather than module name, which
            # is identical for both (a native streaming worker would otherwise
            # be mis-matched as batch-asr and double-count the footprint).
            label = "streaming-asr"
        elif "speechrail.backends.qwen3_worker" in line:
            label = "batch-asr"
        elif "qwen3_streaming_worker" in line or "streaming_worker" in line:
            label = "streaming-asr"
        if label is None:
            continue

        parts_start = parts[8] if len(parts) > 8 else None
        identity = _current_process_identity(pid, start_hint=parts_start)
        if identity is None or identity in seen:
            continue
        if label in found:
            label = f"{label}#{len(found) + 1}"
        found[label] = identity
        seen.add(identity)
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


def _read_ps_number(pid: int, field: str) -> float | None:
    try:
        proc = subprocess.run(
            ["ps", "-o", field, "-p", str(pid)],
            capture_output=True,
            text=True,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = proc.stdout.strip()
    if proc.returncode != 0 or not value:
        return None
    try:
        parsed = float(value)
    except ValueError:
        return None
    return parsed if math.isfinite(parsed) and parsed >= 0 else None


def sample(pid: int) -> SampleValue | None:
    """Sample CPU and memory, or return None when the process cannot be read."""
    # CPU
    cpu = _read_ps_number(pid, "%cpu=")
    if cpu is None:
        return None

    # Memory: Try macOS footprint first for true physical Unified Memory footprint
    fp = _sample_footprint_mb(pid)
    if fp is not None:
        return cpu, fp[0], fp[1], FOOTPRINT_METRIC

    # Fallback to ps rss
    rss_kb = _read_ps_number(pid, "rss=")
    if rss_kb is None:
        return None
    rss_mb = rss_kb / 1024.0
    return cpu, rss_mb, rss_mb, RSS_FALLBACK_METRIC


def _sample_process(process: ProcessIdentity) -> SampleValue | None:
    """Read one process only while its PID and lifetime identity still match."""
    current = _current_process_identity(process.pid)
    if current is None or current != process:
        return None
    observation = sample(process.pid)
    return observation if _current_process_identity(process.pid) == process else None


def _record_tick(
    pids: Mapping[str, ProcessIdentity],
    state: SamplingStats,
    reader: ProcessReader,
    *,
    clock: Callable[[], float] = time.monotonic,
) -> None:
    """Record one complete or incomplete same-time observation tick."""
    started_at = clock()
    unique: dict[ProcessIdentity, str] = {}
    for label, process in pids.items():
        unique.setdefault(process, label)

    observations: dict[ProcessIdentity, SampleValue] = {}
    try:
        for process, label in unique.items():
            observation = reader(process)
            if observation is None:
                state.missing_observations += 1
                continue
            observations[process] = observation
            cpu, current_mb, high_water_mb, metric = observation
            previous = state.process_peaks.get(label)
            if previous is None:
                state.process_peaks[label] = (cpu, max(current_mb, high_water_mb), metric)
            else:
                state.process_peaks[label] = (
                    max(previous[0], cpu),
                    max(previous[1], current_mb, high_water_mb),
                    metric,
                )
    finally:
        duration = max(0.0, clock() - started_at)
        state.observation_seconds += duration
        state.max_tick_span_seconds = max(state.max_tick_span_seconds, duration)

    state.ticks += 1
    if len(observations) != len(unique):
        state.incomplete_ticks += 1
        return

    state.complete_ticks += 1
    if all(observation[3] == FOOTPRINT_METRIC for observation in observations.values()):
        current_total = sum(observation[1] for observation in observations.values())
        state.peak_concurrent_mb = (
            current_total
            if state.peak_concurrent_mb is None
            else max(state.peak_concurrent_mb, current_total)
        )
    else:
        state.rss_ticks += 1


def _sampler_loop(
    pids: Mapping[str, ProcessIdentity],
    stop: threading.Event,
    state: SamplingStats,
    *,
    reader: ProcessReader | None = None,
    interval_seconds: float = 0.3,
    sleep_fn: Callable[[float], None] | None = None,
    clock: Callable[[], float] | None = None,
) -> None:
    reader = _sample_process if reader is None else reader
    sleep = time.sleep if sleep_fn is None else sleep_fn
    monotonic = time.monotonic if clock is None else clock
    started_at = monotonic()
    try:
        while not stop.is_set():
            _record_tick(pids, state, reader, clock=monotonic)
            sleep(interval_seconds)
    except Exception as exc:
        state.error = exc
    finally:
        state.sampling_span_seconds = max(0.0, monotonic() - started_at)


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


def _run_load(
    mode: str,
    base_host: str,
    n: int,
    audio_path: Path | None,
    model: str,
) -> int:
    """Run the requested load in a deterministic batch-then-TTS order."""
    ok_count = 0
    for i in range(n):
        if mode in ("batch", "all") and audio_path and audio_path.exists():
            status, text = transcribe_batch(
                f"{base_host}/v1/audio/transcriptions", audio_path, model
            )
            if status is not None and text is not None:
                ok_count += 1
        if mode in ("tts", "all"):
            _elapsed, nbytes = synthesize_tts(
                f"{base_host}/v1/audio/speech",
                text=f"这是第 {i + 1} 次并发性能压测样本。",
                voice="default",
                model="speechrail/qwen3-tts",
            )
            if nbytes > 0:
                ok_count += 1
        time.sleep(0.1)
    return ok_count


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

    print(f"Discovered processes: { {key: process.pid for key, process in pids.items()} }")

    # 1. Pre-warmup initial snapshot
    initial_mem: dict[str, SampleValue] = {}
    for key, process in pids.items():
        observation = _sample_process(process)
        if observation is not None:
            initial_mem[key] = observation

    # 2. Warmup if requested
    if args.warmup:
        warm_up(args.mode, args.host, audio_path)

    # 3. Post-warmup idle snapshot
    idle_mem: dict[str, SampleValue] = {}
    for key, process in pids.items():
        observation = _sample_process(process)
        if observation is not None:
            idle_mem[key] = observation
    rss_seen = any(
        observation[3] == RSS_FALLBACK_METRIC
        for observation in (*initial_mem.values(), *idle_mem.values())
    )

    # 4. Continuous background sampler during load
    state = SamplingStats()
    for key, observation in idle_mem.items():
        cpu, current_mb, high_water_mb, metric = observation
        state.process_peaks[key] = (cpu, max(current_mb, high_water_mb), metric)
    stop = threading.Event()
    t = threading.Thread(
        target=_sampler_loop,
        args=(pids, stop, state),
        daemon=True,
        name="speechrail-resource-sampler",
    )
    t.start()

    # 5. Execute load
    print(f">> Running load test ({args.n} iterations, mode={args.mode})...")
    try:
        _run_load(args.mode, args.host, args.n, audio_path, args.model)
    finally:
        stop.set()
        t.join(timeout=2.0)
    if t.is_alive():
        print("[Sampler warning] resource sampler did not stop within 2s", file=sys.stderr)
    if state.error is not None:
        print(
            f"[Sampler warning] {type(state.error).__name__}; physical peak is incomplete",
            file=sys.stderr,
        )

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

    total_idle: float | None = 0.0
    for key, process in pids.items():
        pre = initial_mem.get(key)
        post = idle_mem.get(key)
        peak = state.process_peaks.get(key)
        if pre is None or post is None or post[3] != FOOTPRINT_METRIC:
            total_idle = None
        elif total_idle is not None:
            total_idle += post[1]

        pre_text = f"{pre[1]:>7.1f} MB ({pre[3]})" if pre is not None else "N/A"
        post_text = f"{post[1]:>7.1f} MB ({post[3]})" if post is not None else "N/A"
        peak_text = f"{peak[1]:>7.1f} MB ({peak[2]})" if peak is not None else "N/A"
        cpu_text = f"{peak[0]:>6.1f} %" if peak is not None else "N/A"
        print(
            f"{key:<20} | {process.pid:<8} | {pre_text:<30} | {post_text:<30} | "
            f"{peak_text:<30} | {cpu_text}"
        )

    print("-" * 80)
    idle_total_text = f"{total_idle:>7.1f} MB" if total_idle is not None else "N/A"
    peak_total_text = (
        f"{state.peak_concurrent_mb:>7.1f} MB"
        if state.peak_concurrent_mb is not None
        else "N/A"
    )
    total_row = (
        f"{'总物理常驻 (Total)':<20} | {'--':<8} | {'--':<12} | "
        f"{idle_total_text:<20} | {peak_total_text:<20} | {'--':<10}"
    )
    print(total_row)
    print(
        "  注: Peak(Total) 是同一采样轮当前 footprint 之和的最大观测值。"
        "逐进程采样存在时间偏差, 不相加各进程历史峰值。缺样或 PID 重用标记 incomplete。"
    )
    span = state.sampling_span_seconds
    span_text = f"{span:.3f}s" if span is not None else "N/A"
    print(
        f"  Sampling span={span_text} observation_overhead={state.observation_seconds:.3f}s "
        f"ticks={state.ticks} complete={state.complete_ticks} incomplete={state.incomplete_ticks} "
        f"missing={state.missing_observations} max_tick_span={state.max_tick_span_seconds:.3f}s "
        f"gate_complete={state.gate_complete and not t.is_alive()}"
    )
    if state.rss_ticks or rss_seen:
        print(
            "  注: RSS fallback was observed; it is explicitly excluded from the "
            "phys_footprint gate."
        )
    print("=" * 80 + "\n")


if __name__ == "__main__":
    main()
