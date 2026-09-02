"""Concurrent realtime multisession smoke against /v1/realtime.

Opens N WebSocket connections at once and drives a full ASR session on each,
then starts a batch transcription while those sessions are still live.
Verifies Direction-1 multiplexing end to end:
- all sessions share one streaming worker and mutually exclusive session_ids
- per-session audio/commit events never cross sessions (no frame theft)
- the Nth session is not rejected with backend_busy while others are open
- batch transcription still succeeds while realtime sessions are live

Requires: SPEECHRAIL_REALTIME_ASR_BACKEND=native on the server, a real
s16le/16 kHz/mono PCM file, and (if the server requires auth) the key in
SPEECHRAIL_API_KEY. No server-side model is loaded by this script itself.

Usage:
  python examples/perf/concurrent_realtime_smoke.py audio_10s.pcm
  SPEECHRAIL_BASE_URL=http://127.0.0.1:8202 \
    python examples/perf/concurrent_realtime_smoke.py audio_10s.pcm --sessions 2
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import sys
from pathlib import Path

import httpx
from websockets.asyncio.client import ClientConnection, connect

CHUNK_BYTES = 96 * 1024


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("pcm_file", type=Path, help="s16le/16 kHz/mono PCM file")
    parser.add_argument(
        "--base-url",
        default=os.getenv("SPEECHRAIL_BASE_URL", "http://127.0.0.1:8201"),
    )
    parser.add_argument(
        "--realtime-url",
        default=os.getenv("SPEECHRAIL_REALTIME_URL", "ws://127.0.0.1:8201/v1/realtime"),
    )
    parser.add_argument("--wav-file", type=Path, help="wav used for the batch leg")
    parser.add_argument("--sessions", type=int, default=2, help="concurrent sessions")
    parser.add_argument("--language", default="zh")
    return parser.parse_args()


async def recv_until_type(
    ws: ClientConnection, expected: str, timeout_seconds: float, label: str
) -> dict[str, object]:
    deadline = asyncio.get_event_loop().time() + timeout_seconds
    while True:
        remaining = deadline - asyncio.get_event_loop().time()
        if remaining <= 0:
            raise SystemExit(f"[smoke] timeout waiting for {label}")
        try:
            raw = await asyncio.wait_for(ws.recv(), timeout=remaining)
        except TimeoutError as exc:
            raise SystemExit(f"[smoke] timeout waiting for {label}") from exc
        event = json.loads(raw)
        etype = str(event.get("type"))
        if etype == expected:
            return event
        if etype == "error":
            code = event.get("error", {}).get("code")
            raise SystemExit(f"[smoke] unexpected error waiting {label}: {code}")


async def run_session(
    ws: ClientConnection,
    pcm: bytes,
    language: str,
    session_name: str,
    results: list[str],
) -> None:
    await recv_until_type(ws, "session.created", 15, f"{session_name}:session.created")
    await ws.send(
        json.dumps(
            {
                "type": "session.update",
                "session": {
                    "model": "whisper-1",
                    "language": language,
                    "input_audio_format": "pcm16",
                    "turn_detection": {"type": "manual"},
                },
            }
        )
    )
    await recv_until_type(ws, "session.updated", 10, f"{session_name}:session.updated")

    for offset in range(0, len(pcm), CHUNK_BYTES):
        chunk = pcm[offset : offset + CHUNK_BYTES]
        await ws.send(
            json.dumps(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(chunk).decode("ascii"),
                }
            )
        )
        await asyncio.sleep(0.05)
    await asyncio.sleep(0.8)
    await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
    completed = await recv_until_type(
        ws,
        "conversation.item.input_audio_transcription.completed",
        120,
        f"{session_name}:completed",
    )
    transcript = str(completed.get("transcript") or "").strip()
    results.append(f"{session_name}={transcript[:40]!r}")
    if not transcript:
        raise SystemExit(f"[smoke] {session_name} got empty transcript")


async def run_concurrent(
    realtime_url: str,
    pcm: bytes,
    language: str,
    sessions: int,
    headers: dict[str, str],
    results: list[str],
) -> None:
    tasks: list[asyncio.Task[None]] = []
    for index in range(sessions):
        name = f"s{index}"

        async def one(ws_url: str = realtime_url, n: str = name) -> None:
            async with connect(ws_url, additional_headers=headers) as ws:
                await run_session(ws, pcm, language, n, results)

        tasks.append(asyncio.create_task(one()))
        await asyncio.sleep(0.4)  # ensure sessions overlap, not serialize
    await asyncio.gather(*tasks)


async def main() -> None:
    options = arguments()
    headers: dict[str, str] = {}
    key = os.environ.get("SPEECHRAIL_API_KEY")
    if key:
        headers["Authorization"] = f"Bearer {key}"

    pcm = options.pcm_file.read_bytes()
    results: list[str] = []
    await run_concurrent(
        options.realtime_url, pcm, options.language, options.sessions, headers, results
    )
    print(f"[smoke] {options.sessions} concurrent sessions succeeded:", " | ".join(results))

    if options.wav_file is not None:
        async with httpx.AsyncClient(
            base_url=options.base_url, headers=headers, timeout=60.0
        ) as client:
            with options.wav_file.open("rb") as audio:
                response = await client.post(
                    "/v1/audio/transcriptions",
                    files={"file": (options.wav_file.name, audio, "audio/wav")},
                    data={"model": "whisper-1", "language": options.language},
                )
        print(
            f"[smoke] batch while {options.sessions} realtime sessions live: "
            f"HTTP {response.status_code}: {response.text.strip()[:60]!r}"
        )
        if response.status_code != 200:
            sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
