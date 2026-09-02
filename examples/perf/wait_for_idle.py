"""Wait until the local Mac is idle enough to run SpeechRail benchmarks.

Samples three signals at a fixed interval and exits 0 once all stay under
thresholds for N consecutive samples:

* CPU utilization (user+system, core-aggregated) via ``ps``;
* available memory (free + inactive + speculative) via ``vm_stat``;
* GPU silence via ``ioreg`` AGXAccelerator: the ``busy (X ms)`` cumulative
  clock only advances when the GPU actually runs work, so "no advance across
  samples" plus zero new submissions plus Idle work queues means the GPU is
  quiet. This is a silence detector, not a percent-utilization meter (macOS
  exposes no unprivileged GPU-utilization counter).

Exits 2 on timeout so callers can tell "idle" from "gave up waiting".
Relies only on macOS built-ins (`ps`, `sysctl`, `vm_stat`, `ioreg`) so it
runs on a bare system without psutil. Usage:

  python examples/perf/wait_for_idle.py \
      --cpu-max 25 --mem-free-gb 24 --interval 15 --stable 4 --timeout 600

Designed to gate heavy resource benchmarks so they don't pollute their own
latency/RTF numbers by fighting an unrelated busy machine.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from dataclasses import dataclass

PAGE_SIZE = 4096  # vm_stat pages; macOS defaults to 16 KiB but 4 KiB stays valid


@dataclass
class GpuState:
    busy_ms: int | None
    submissions: int | None
    busy_count: int | None
    queue_busy: bool
    available: bool = True


@dataclass
class Snapshot:
    cpu_pct: float
    free_gb: float
    num_cpus: int
    gpu: GpuState

    COEFFICIENT_WARNING = (
        "\nGPU signal unavailable (ioreg missing AGXAccelerator) -- "
        "continuing with CPU+memory only\n"
    )

    def idle(
        self, cpu_max: float, mem_free_gb: float
    ) -> tuple[bool, str]:
        reason = ""
        ok = True
        if self.cpu_pct > cpu_max:
            ok = False
            reason = f"cpu {self.cpu_pct:.1f}% > {cpu_max:.0f}%"
        elif self.free_gb < mem_free_gb:
            ok = False
            reason = f"free {self.free_gb:.1f}GB < {mem_free_gb:.0f}GB"
        elif self.gpu.queue_busy:
            ok = False
            reason = "gpu queue busy"
        return ok, reason or "idle"


def num_cpus() -> int:
    raw = subprocess.run(
        ["sysctl", "-n", "hw.ncpu"], capture_output=True, text=True, check=True
    ).stdout.strip()
    return int(raw)


def cpu_pct() -> float:
    """Aggregated %cpu across all processes normalized by core count."""
    out = subprocess.run(
        ["ps", "-Ao", "%cpu"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    total = 0.0
    for line in out[1:]:  # header first
        try:
            total += float(line.strip())
        except ValueError:
            continue
    return min(100.0, total / num_cpus())


def free_gb() -> float:
    raw = subprocess.run(
        ["vm_stat"], capture_output=True, text=True, check=True
    ).stdout
    fields: dict[str, int] = {}
    for line in raw.splitlines():
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip().rstrip(".")
        if value:
            try:
                fields[key.lower()] = int(value)
            except ValueError:
                continue
    free = fields.get("pages free", 0)
    inactive = fields.get("pages inactive", 0)
    speculative = fields.get("pages speculative", 0)
    return (free + inactive + speculative) * PAGE_SIZE / (1024**3)


def gpu_state() -> GpuState:
    """Read AGXAccelerator counters; degrade gracefully on any error."""
    try:
        out = subprocess.run(
            ["ioreg", "-rc", "AGXAccelerator", "-l"],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if out.returncode != 0:
            return GpuState(None, None, None, False, available=False)
        text = out.stdout
        busy = re.search(r"busy (\d+) \((\d+) ms\)", text)
        sub = re.search(r'"fSubmissionsSinceLastCheck"\s*=\s*(\d+)', text)
        cnt = re.search(r'"fBusyCount"\s*=\s*(\d+)', text)
        queue_busy = any(
            state != "Idle" and state != "Ready"
            for state in re.findall(r'"state"\s*=\s*"(\w+)"', text)
        )
        return GpuState(
            busy_ms=int(busy.group(2)) if busy else None,
            submissions=int(sub.group(1)) if sub else None,
            busy_count=int(cnt.group(1)) if cnt else None,
            queue_busy=queue_busy,
        )
    except (OSError, subprocess.SubprocessError, ValueError):
        return GpuState(None, None, None, False, available=False)


class GpuQuiescence:
    """Gauge whether the GPU has been silent across consecutive samples.

    The ioreg busy clock only advances while the GPU actually executes work,
    so "no advance between consecutive samples, no new submissions, and zero
    busy count" is a reliable *idle* signal even though it is not a live
    utilization percentage. Misses brief bursts between samples, which is
    acceptable for a pre-benchmark gate.
    """

    def __init__(self, stable: int) -> None:
        self._stable = stable
        self._quiet_streak = 0
        self._last_busy_ms: int | None = None

    def observe(self, gpu: GpuState) -> bool:
        if not gpu.available or gpu.busy_ms is None:
            # No signal => can't prove quiescence; caller keeps CPU+memory gate.
            return True
        advanced = (
            self._last_busy_ms is not None and gpu.busy_ms > self._last_busy_ms
        )
        self._last_busy_ms = gpu.busy_ms
        new_work = (gpu.submissions or 0) > 0 or (gpu.busy_count or 0) > 0
        if advanced or new_work:
            self._quiet_streak = 0
            return False
        self._quiet_streak += 1
        return self._quiet_streak >= self._stable


def snapshot() -> Snapshot:
    return Snapshot(cpu_pct=cpu_pct(), free_gb=free_gb(), num_cpus=num_cpus(), gpu=gpu_state())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpu-max", type=float, default=25.0, help="CPU %% max (default 25)")
    parser.add_argument("--mem-free-gb", type=float, default=24.0, help="min free GB (default 24)")
    parser.add_argument("--interval", type=float, default=15.0, help="sample interval seconds")
    parser.add_argument("--stable", type=int, default=4, help="consecutive idle/quiet samples")
    parser.add_argument("--timeout", type=float, default=1800.0, help="give up after seconds")
    args = parser.parse_args(argv)

    if args.interval <= 0 or args.stable < 1 or args.timeout <= 0:
        parser.error("interval/stable/timeout must be positive")

    print(
        f"waiting for idle: cpu<={args.cpu_max:.0f}% mem-free>={args.mem_free_gb:.0f}GB "
        f"gpu-silent>={args.stable} samples interval={args.interval:.0f}s "
        f"timeout={args.timeout:.0f}s",
        flush=True,
    )
    gpu_gauge = GpuQuiescence(args.stable)
    start = time.monotonic()
    stable = 0
    samples = 0
    warned_gpu = False
    while True:
        snap = snapshot()
        if not snap.gpu.available and not warned_gpu:
            print(Snapshot.COEFFICIENT_WARNING, flush=True)
            warned_gpu = True
        gpu_quiet = gpu_gauge.observe(snap.gpu)
        idle, reason = snap.idle(args.cpu_max, args.mem_free_gb)
        if idle and gpu_quiet:
            stable += 1
            state = "idle"
        else:
            stable = 0
            state = "busy"
            if not gpu_quiet:
                reason = "gpu not yet silent"
        samples += 1
        gpu_desc = (
            "-"
            if snap.gpu.busy_ms is None
            else f"{snap.gpu.busy_ms}ms"
        )
        print(
            f"[{state:4s}] #{samples:3d} cpu={snap.cpu_pct:5.1f}% "
            f"free={snap.free_gb:6.1f}GB gpu={gpu_desc:>10s} ({snap.num_cpus} cores) ... {reason}",
            flush=True,
        )
        if stable >= args.stable:
            print(f"machine idle for {stable} samples; proceeding", flush=True)
            return 0
        elapsed = time.monotonic() - start
        if elapsed >= args.timeout:
            print(
                f"timeout after {elapsed:.0f}s; machine still busy, giving up",
                file=sys.stderr,
                flush=True,
            )
            return 2
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
