"""SpeechRail Realtime WS performance benchmark via the openai SDK.

Measures session setup, ASR commit->completed latency, TTS first-audio-chunk
latency, and (optionally) consecutive-session stability on /v1/realtime.
Requires the service running with SPEECHRAIL_REALTIME_ASR_BACKEND=native.

Usage:
  python examples/perf/bench_realtime.py audio_10s.pcm
  python examples/perf/bench_realtime.py audio_10s.pcm --sessions 3
"""

from __future__ import annotations

import argparse
import base64
import os
import queue
import threading
import time
from pathlib import Path

from openai import OpenAI


def recv_loop(events: queue.Queue[object], errors: list[Exception], conn: object) -> None:
    try:
        while True:
            events.put(conn.recv())
    except Exception as exc:
        errors.append(exc)


def get(key: str, event: object) -> object:
    if isinstance(event, dict):
        return event.get(key)
    return getattr(event, key, None)


def recv_until(
    events: queue.Queue[object],
    errors: list[Exception],
    target: str,
    timeout: float = 60,
) -> tuple[object, list[str]]:
    deadline = time.monotonic() + timeout
    seen: list[str] = []
    while time.monotonic() < deadline:
        try:
            ev = events.get(timeout=1)
        except queue.Empty:
            if errors:
                raise errors[0] from None
            continue
        seen.append(str(get("type", ev)))
        if get("type", ev) == target:
            return ev, seen
    raise TimeoutError(f"no {target}, saw {seen}")


def run_session(
    client: OpenAI, pcm: bytes, tts_text: str, session_no: int
) -> dict[str, float | str]:
    conn = client.realtime.connect(model="whisper-1").enter()
    events: queue.Queue[object] = queue.Queue()
    errors: list[Exception] = []
    threading.Thread(
        target=recv_loop, args=(events, errors, conn), daemon=True
    ).start()

    t0 = time.monotonic()
    recv_until(events, errors, "conversation.created", timeout=15)
    setup_ms = (time.monotonic() - t0) * 1000

    conn.send({
        "type": "session.update",
        "session": {
            "model": "whisper-1",
            "language": "zh",
            "input_audio_format": "pcm16",
            "turn_detection": {"type": "manual"},
        },
    })
    recv_until(events, errors, "session.updated", timeout=15)

    for i in range(0, len(pcm), 32000):
        chunk = pcm[i:i + 32000]
        conn.send({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(chunk).decode("ascii"),
        })
    t0 = time.monotonic()
    conn.send({"type": "input_audio_buffer.commit"})
    completed, _ = recv_until(
        events, errors, "conversation.item.input_audio_transcription.completed", timeout=60
    )
    asr_ms = (time.monotonic() - t0) * 1000
    duration = len(pcm) / 32000
    transcript = str(get("transcript", completed))

    conn.send({
        "type": "conversation.item.create",
        "item": {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": tts_text}],
        },
    })
    recv_until(events, errors, "conversation.item.created", timeout=15)
    t0 = time.monotonic()
    conn.send({"type": "response.create"})
    recv_until(events, errors, "response.audio.delta", timeout=60)
    first_delta_ms = (time.monotonic() - t0) * 1000

    kinds: list[str] = []
    total_bytes = 0
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            ev = events.get(timeout=1)
        except queue.Empty:
            if errors:
                raise errors[0] from None
            continue
        k = str(get("type", ev))
        kinds.append(k)
        if k == "response.audio.delta":
            total_bytes += len(get("delta", ev) or b"")
        if k == "response.done":
            break

    conn.close()
    return {
        "session": session_no,
        "setup_ms": setup_ms,
        "asr_ms": asr_ms,
        "audio_s": duration,
        "asr_rtf": asr_ms / 1000 / duration,
        "tts_first_delta_ms": first_delta_ms,
        "tts_bytes": total_bytes,
        "transcript": transcript,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pcm_file", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--tts-text", default="本地实时语音合成性能测试。")
    parser.add_argument("--sessions", type=int, default=2)
    args = parser.parse_args()

    client = OpenAI(
        api_key=os.environ.get("SPEECHRAIL_API_KEY", "local"), base_url=args.base_url
    )
    pcm = args.pcm_file.read_bytes()

    for i in range(1, args.sessions + 1):
        print(f"--- session {i} ---")
        try:
            result = run_session(client, pcm, args.tts_text, i)
            print(
                f"[session {i}] setup={result['setup_ms']:.0f}ms "
                f"asr={result['asr_ms']:.0f}ms rtf={result['asr_rtf']:.2f}x "
                f"tts_first_delta={result['tts_first_delta_ms']:.0f}ms "
                f"tts_bytes={result['tts_bytes']} transcript={result['transcript']!r}"
            )
        except Exception as exc:
            print(f"[session {i}] FAILED: {type(exc).__name__}: {exc}")
            print("  -> consecutive-session stability issue (busy backend?)")


if __name__ == "__main__":
    main()
