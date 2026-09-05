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
from dataclasses import dataclass
from urllib import request

try:
    from .profile_metrics import rtf  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover - exercised when run as a script
    from profile_metrics import rtf


DEFAULT_BASE = "http://127.0.0.1:8201/v1/audio/speech"
PCM_BYTES_PER_SECOND = 24_000 * 2  # 24 kHz, mono, signed 16-bit PCM
READ_CHUNK_BYTES = 64 * 1024


@dataclass(frozen=True, slots=True)
class SynthesisMetrics:
    """Timing and byte counters collected without retaining response audio."""

    elapsed_seconds: float
    audio_bytes: int
    actual_audio_seconds: float
    ttfa_seconds: float | None
    continuous_rtf: float | None
    block_intervals_seconds: tuple[float, ...]

    @property
    def ttfa(self) -> float | None:
        """Compatibility alias for the TTFA value in seconds."""
        return self.ttfa_seconds

    @property
    def rtf(self) -> float | None:
        """Compatibility alias for the continuous synthesis RTF."""
        return self.continuous_rtf

    @property
    def block_intervals(self) -> tuple[float, ...]:
        """Compatibility alias for intervals between non-empty response blocks."""
        return self.block_intervals_seconds


def auth_headers() -> dict[str, str]:
    """Return an Authorization header when SPEECHRAIL_API_KEY is configured."""
    key = os.environ.get("SPEECHRAIL_API_KEY")
    return {"Authorization": f"Bearer {key}"} if key else {}


def synthesize_with_metrics(
    base: str, text: str, voice: str, model: str
) -> SynthesisMetrics:
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
    started_at = time.monotonic()
    first_audio_at: float | None = None
    previous_audio_at: float | None = None
    block_intervals: list[float] = []
    audio_bytes = 0
    with request.urlopen(req, timeout=600) as resp:
        while True:
            # read1 返回当前可用数据。避免 read 等待填满 64 KiB 后高估 TTFA。
            chunk = resp.read1(READ_CHUNK_BYTES)
            if not chunk:
                break
            if not isinstance(chunk, bytes):
                raise TypeError("TTS response chunks must be bytes")
            now = time.monotonic()
            if first_audio_at is None:
                first_audio_at = now
            elif previous_audio_at is not None:
                block_intervals.append(now - previous_audio_at)
            previous_audio_at = now
            audio_bytes += len(chunk)

    if audio_bytes % 2:
        raise ValueError("TTS response contains truncated PCM16 audio")
    elapsed_seconds = time.monotonic() - started_at
    actual_audio_seconds = audio_bytes / PCM_BYTES_PER_SECOND
    continuous_rtf = (
        rtf(elapsed_seconds, actual_audio_seconds) if actual_audio_seconds > 0 else None
    )
    ttfa_seconds = (
        first_audio_at - started_at if first_audio_at is not None else None
    )
    return SynthesisMetrics(
        elapsed_seconds=elapsed_seconds,
        audio_bytes=audio_bytes,
        actual_audio_seconds=actual_audio_seconds,
        ttfa_seconds=ttfa_seconds,
        continuous_rtf=continuous_rtf,
        block_intervals_seconds=tuple(block_intervals),
    )


def synthesize(
    base: str, text: str, voice: str, model: str
) -> tuple[float, int]:
    """Synthesize audio while preserving the original tuple return contract."""
    metrics = synthesize_with_metrics(base, text, voice, model)
    return metrics.elapsed_seconds, metrics.audio_bytes


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
    metrics_list: list[SynthesisMetrics] = []
    for i in range(args.repeat):
        metrics = synthesize_with_metrics(args.base, args.text, args.voice, args.model)
        metrics_list.append(metrics)
        latencies.append(metrics.elapsed_seconds)
        out_seconds_list.append(metrics.actual_audio_seconds)
        ttfa = f"{metrics.ttfa_seconds:.3f}s" if metrics.ttfa_seconds is not None else "n/a"
        continuous_rtf = (
            f"{metrics.continuous_rtf:.2f}x" if metrics.continuous_rtf is not None else "n/a"
        )
        interval_mean = (
            statistics.mean(metrics.block_intervals_seconds)
            if metrics.block_intervals_seconds
            else None
        )
        interval_text = f"{interval_mean:.3f}s" if interval_mean is not None else "n/a"
        print(
            f"  run {i + 1}: {metrics.elapsed_seconds:.2f}s "
            f"output={metrics.actual_audio_seconds:.2f}s "
            f"audio ({metrics.audio_bytes} bytes) "
            f"actual_audio_seconds={metrics.actual_audio_seconds:.6f} "
            f"ttfa={ttfa} continuous_rtf={continuous_rtf} "
            f"block_interval_mean={interval_text} blocks={len(metrics.block_intervals_seconds)}"
        )
    mean = statistics.mean(latencies)
    mean_out = statistics.mean(out_seconds_list)
    mean_rtf = rtf(mean, mean_out) if mean_out > 0 else None
    ttfa_values = [
        metric.ttfa_seconds for metric in metrics_list if metric.ttfa_seconds is not None
    ]
    mean_ttfa = statistics.mean(ttfa_values) if ttfa_values else None
    intervals = [
        interval
        for metric in metrics_list
        for interval in metric.block_intervals_seconds
    ]
    mean_interval = statistics.mean(intervals) if intervals else None
    mean_rtf_text = f"{mean_rtf:.2f}x" if mean_rtf is not None else "n/a"
    mean_ttfa_text = f"{mean_ttfa:.3f}s" if mean_ttfa is not None else "n/a"
    mean_interval_text = f"{mean_interval:.3f}s" if mean_interval is not None else "n/a"
    print(
        f"  => mean={mean:.2f}s min={min(latencies):.2f}s max={max(latencies):.2f}s "
        f"rtf={mean_rtf_text} ttfa_mean={mean_ttfa_text} "
        f"block_interval_mean={mean_interval_text}"
    )


if __name__ == "__main__":
    main()
