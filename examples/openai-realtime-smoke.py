"""Minimal OpenAI-Realtime-compatible smoke via the official openai SDK.

Connects to SpeechRail's /v1/realtime using `client.realtime.connect()`
(the exact path a standard OpenAI client would use), streams a 16 kHz mono
PCM16 file, commits, and waits for the final transcription.

Requires: openai>=1.40, SPEECHRAIL_REALTIME_ASR_BACKEND=native on the server,
and a real s16le/16 kHz/mono PCM file. Do not run against a fake backend.
"""

from __future__ import annotations

import argparse
import base64
import os
import queue
import sys
import threading
import time
from pathlib import Path

from openai import OpenAI

PCM16: dict[str, int | str] = {
    "type": "audio/pcm",
    "rate": 16_000,
    "channels": 1,
    "sample_width": 2,
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("pcm_file", type=Path, help="s16le/16 kHz/mono PCM file")
    parser.add_argument(
        "--base-url",
        default=os.getenv("SPEECHRAIL_BASE_URL", "http://127.0.0.1:8201/v1"),
    )
    parser.add_argument("--model", default="whisper-1")
    parser.add_argument("--api-key", default=os.getenv("SPEECHRAIL_API_KEY"))
    parser.add_argument("--language", default="zh")
    parser.add_argument("--timeout", type=float, default=30.0)
    return parser.parse_args()


def run(options: argparse.Namespace) -> None:
    client = OpenAI(
        api_key=options.api_key or "local",
        base_url=options.base_url,
    )
    print(f"[openai-smoke] connecting {options.base_url}/realtime model={options.model}")
    connection = client.realtime.connect(model=options.model).enter()

    events: queue.Queue[dict] = queue.Queue()
    recv_error: list[Exception] = []

    def _get(event: object, key: str) -> object:
        """Read a field from a pydantic event model or a plain dict."""
        if isinstance(event, dict):
            return event.get(key)
        return getattr(event, key, None)

    def _recv_loop() -> None:
        try:
            while True:
                events.put(connection.recv())
        except Exception as exc:  # connection closed / transport error
            recv_error.append(exc)

    thread = threading.Thread(target=_recv_loop, daemon=True)
    thread.start()

    def recv(timeout: float) -> dict:
        try:
            return events.get(timeout=timeout)
        except queue.Empty:
            if recv_error:
                raise recv_error[0] from None
            raise TimeoutError(f"no event within {timeout:.0f}s") from None

    try:
        t_start = time.monotonic()
        deadline = t_start + options.timeout

        # session.created / conversation.created arrive on connect.
        session_created = recv(deadline - time.monotonic())
        print(f"[openai-smoke] recv {_get(session_created, 'type')}")
        if _get(session_created, "type") != "session.created":
            raise SystemExit(f"expected session.created, got {session_created}")

        connection.send(
            {
                "type": "session.update",
                "session": {
                    "model": options.model,
                    "language": options.language,
                    "input_audio_format": PCM16,
                    "turn_detection": {"type": "manual"},
                },
            }
        )

        audio = options.pcm_file.read_bytes()
        for i in range(0, len(audio), 32000):
            chunk = audio[i : i + 32000]
            connection.send(
                {
                    "type": "input_audio_buffer.append",
                    "audio": base64.b64encode(chunk).decode("ascii"),
                }
            )
        print(f"[openai-smoke] appended {len(audio) // 32000:.1f}s audio")

        connection.send({"type": "input_audio_buffer.commit"})

        transcript: str | None = None
        while time.monotonic() < deadline:
            event = recv(deadline - time.monotonic())
            kind = _get(event, "type")
            if kind == "conversation.item.input_audio_transcription.completed":
                transcript = _get(event, "transcript")
                print(f"[openai-smoke] transcription.completed transcript={transcript!r}")
                break
            if kind == "conversation.item.input_audio_transcription.failed":
                raise SystemExit(f"transcription failed: {event}")
            if kind == "error":
                raise SystemExit(f"error: {event}")
            print(f"[openai-smoke] recv {kind}")

        if transcript is None:
            raise SystemExit(f"no transcription within {options.timeout:.0f}s")

        elapsed = time.monotonic() - t_start
        print(f"[openai-smoke] total {elapsed:.2f}s, text={transcript!r}")
    finally:
        connection.close()


if __name__ == "__main__":
    try:
        run(arguments())
    except Exception as exc:  # SDK raises socket-level errors on failure
        print(f"[openai-smoke] FAILED: {exc!r}", file=sys.stderr)
        raise
