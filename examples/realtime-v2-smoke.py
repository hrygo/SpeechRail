"""Minimal SpeechRail Realtime v2 streaming-ASR smoke client (raw 16 kHz mono PCM).

Verifies the native Qwen3 streaming backend end-to-end through the public
/v2/realtime protocol: session.update -> append* -> flush -> commit ->
delta/completed -> session.completed.

Windowed-backend note: the Qwen3 streaming processor paces decodes and may
emit no delta for a manual flush (its commit policy holds back unstable
words); the client must always send `input_audio_buffer.commit` to force the
final result. This script therefore drains any delta after flush and then
commits, matching the contract's manual endpointing mode.

Requires SPEECHRAIL_REALTIME_ASR_BACKEND=native on the server and a real
16 kHz / mono / s16le PCM file. Do not run against a fake-backend instance.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import time
from pathlib import Path

from websockets.asyncio.client import connect

PCM16: dict[str, int | str] = {
    "type": "audio/pcm",
    "rate": 16_000,
    "channels": 1,
    "sample_width": 2,
}

_DELTA_DRAIN_SECONDS = 3.0


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("pcm_file", type=Path, help="s16le/16 kHz/mono PCM file")
    parser.add_argument(
        "--url",
        default=os.getenv("SPEECHRAIL_REALTIME_URL", "ws://127.0.0.1:8201/v2/realtime"),
    )
    parser.add_argument("--model", default="speechrail/qwen3-asr-1.7b")
    parser.add_argument("--language", default="zh")
    parser.add_argument("--api-key", default=os.getenv("SPEECHRAIL_API_KEY"))
    return parser.parse_args()


async def _drain(websocket, deadline: float, seen: list[dict]) -> dict | None:
    """Receive frames until one matches `stop` kinds or the deadline passes.

    Returns the first non-delta frame seen (or None on deadline), so the
    caller can break out of a manual flush that produced no delta.
    """
    while time.monotonic() < deadline:
        try:
            message = json.loads(await asyncio.wait_for(websocket.recv(), timeout=0.5))
        except TimeoutError:
            continue
        seen.append(message)
        kind = message.get("type")
        if kind == "transcription.completed":
            return message
        if kind == "error":
            return message
    return None


async def run(options: argparse.Namespace) -> None:
    headers = {}
    if options.api_key:
        headers["Authorization"] = f"Bearer {options.api_key}"

    async with connect(options.url, additional_headers=headers) as websocket:
        await websocket.send(
            json.dumps(
                {
                    "type": "session.update",
                    "session": {
                        "type": "transcription",
                        "model": options.model,
                        "language": options.language,
                        "audio_format": PCM16,
                        "endpointing": {"mode": "manual"},
                    },
                }
            )
        )
        created = json.loads(await websocket.recv())
        print(f"[v2-smoke] {created['type']} sequence={created.get('sequence')}")
        if created["type"] != "session.created":
            raise SystemExit(f"expected session.created, got {created}")

        audio = options.pcm_file.read_bytes()
        t_start = time.monotonic()
        for i in range(0, len(audio), 32000):
            chunk = audio[i : i + 32000]
            await websocket.send(
                json.dumps(
                    {
                        "type": "input_audio_buffer.append",
                        "audio": base64.b64encode(chunk).decode("ascii"),
                    }
                )
            )
            ack = json.loads(await websocket.recv())
            print(f"[v2-smoke] {ack['type']} sequence={ack.get('sequence')}")

        await websocket.send(json.dumps({"type": "input_audio_buffer.flush"}))
        drained: list[dict] = []
        stopped = await _drain(
            websocket, time.monotonic() + _DELTA_DRAIN_SECONDS, drained
        )
        for message in drained:
            kind = message.get("type")
            if kind == "transcription.delta":
                print(f"[v2-smoke] delta text={message.get('text')!r}")
            elif kind == "transcription.completed":
                print(f"[v2-smoke] completed text={message.get('text')!r}")

        if stopped is not None and stopped.get("type") in (
            "transcription.completed",
            "error",
        ):
            print(f"[v2-smoke] flush drain stopped at {stopped.get('type')}")
        else:
            print(
                "[v2-smoke] no delta/completed after flush "
                f"({_DELTA_DRAIN_SECONDS:.0f}s) - committing to force final"
            )

        await websocket.send(json.dumps({"type": "input_audio_buffer.commit"}))
        while True:
            message = json.loads(await websocket.recv())
            kind = message.get("type")
            if kind == "transcription.delta":
                print(f"[v2-smoke] delta text={message.get('text')!r}")
            elif kind == "transcription.completed":
                print(f"[v2-smoke] final completed text={message.get('text')!r}")
            elif kind == "session.completed":
                print("[v2-smoke] session.completed")
                break
            elif kind == "error":
                raise SystemExit(f"error: {message}")

        elapsed = time.monotonic() - t_start
        print(f"[v2-smoke] total {elapsed:.2f}s for {len(audio) // 32000:.1f}s audio")


if __name__ == "__main__":
    asyncio.run(run(arguments()))
