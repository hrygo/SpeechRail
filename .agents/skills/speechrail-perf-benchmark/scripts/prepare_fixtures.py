#!/usr/bin/env python3
"""Generates standard benchmark audio fixtures (3s, 10s, 30s, 60s) via SpeechRail TTS.

Outputs 16kHz mono WAV and PCM files into /tmp for ASR and Realtime benchmarking.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import urllib.request
import wave
from pathlib import Path

DEFAULT_BASE = "http://127.0.0.1:8201/v1/audio/speech"

FIXTURE_TEXTS = {
    "audio_3s": "你好，这是本地语音识别与合成。",
    "audio_10s": "你好，这是本地语音识别与合成服务的性能基准测试。SpeechRail 能够快速高效地输出高品质语音。",
    "audio_30s": (
        "SpeechRail 是一个本地优先的语音识别与合成服务。它为各种本地智能体和对话应用提供稳定可靠的 ASR 与 TTS 接口。"
        "在单人使用场景下，它具备极低的延迟与极致的资源控制能力。"
    ),
    "audio_60s": (
        "SpeechRail 是一个本地优先的语音识别与合成服务。它为各种本地智能体和对话应用提供稳定可靠的 ASR 与 TTS 接口。"
        "在单人使用场景下，它具备极低的延迟与极致的资源控制能力。通过模块化设计与细粒度显存治理，"
        "SpeechRail 可以在 macOS 苹果芯片设备上长时间稳定运行，无需担心内存泄漏或显存溢出。"
        "无论长音频转写还是极速流式交互，都能游刃有余。"
    ),
}


def auth_headers() -> dict[str, str]:
    """Return an Authorization header when SPEECHRAIL_API_KEY is configured.

    Matches the auth_headers() convention used by the benchmark scripts so a
    service enabled with API-key auth (e.g. bound to 0.0.0.0) can be driven by
    passing the key via the environment without editing this script.
    """
    key = os.environ.get("SPEECHRAIL_API_KEY")
    return {"Authorization": f"Bearer {key}"} if key else {}


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate benchmark audio fixtures.")
    parser.add_argument("--base", default=DEFAULT_BASE, help="TTS endpoint URL")
    parser.add_argument("--output-dir", default="/tmp", help="Directory to save generated fixtures")
    args = parser.parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f">> Generating standard benchmark audio fixtures via {args.base}...")
    for name, text in FIXTURE_TEXTS.items():
        body = json.dumps(
            {
                "model": "speechrail/qwen3-tts",
                "input": text,
                "voice": "default",
                "response_format": "pcm",
            }
        ).encode()
        req = urllib.request.Request(
            args.base,
            data=body,
            headers={"Content-Type": "application/json", **auth_headers()},
        )
        with urllib.request.urlopen(req) as resp:
            pcm_data = resp.read()

        wav24_path = out_dir / f"{name}_24k.wav"
        with wave.open(str(wav24_path), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(24000)
            wf.writeframes(pcm_data)

        wav16_path = out_dir / f"{name}.wav"
        pcm16_path = out_dir / f"{name}_16k.pcm"

        subprocess.run(
            ["ffmpeg", "-y", "-i", str(wav24_path), "-ar", "16000", "-ac", "1", str(wav16_path)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(wav16_path), "-f", "s16le", "-ac", "1", "-ar", "16000", str(pcm16_path)],
            check=True,
            capture_output=True,
        )

        dur = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(wav16_path)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        print(f"  [✓] {name}: duration={float(dur):.2f}s | wav={wav16_path} | pcm={pcm16_path}")

    print(">> All benchmark fixtures successfully generated.")


if __name__ == "__main__":
    main()
