"""SpeechRail Realtime WS performance benchmark via the openai SDK.

Measures session setup, ASR commit->completed latency, TTS first-audio-chunk
latency, and (optionally) consecutive-session stability on /v1/realtime.
Requires the service running with SPEECHRAIL_REALTIME_ASR_BACKEND=native.

Usage:
  uv run python examples/perf/bench_realtime.py audio_10s.pcm
  uv run python examples/perf/bench_realtime.py audio_10s.pcm --sessions 3 \
    --app-home "$HOME/Library/Application Support/SpeechRail"
"""

from __future__ import annotations

import argparse
import base64
import queue
import threading
import time
from contextlib import suppress
from pathlib import Path
from typing import Any

from openai import OpenAI

from speechrail.config.auth import resolve_api_key

_SERVER_VAD_SILENCE_TAIL_BYTES = 32_000  # 1 second of 16 kHz mono PCM16


class RealtimeEventError(RuntimeError):
    """A stable server error received while waiting for a benchmark event."""

    def __init__(self, code: str) -> None:
        self.code = code[:64] or "unknown"
        super().__init__(f"realtime_error:{self.code}")


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
    event_log: list[str] | None = None,
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
        event_type = str(get("type", ev))
        seen.append(event_type)
        if event_log is not None:
            event_log.append(event_type)
        if event_type == "error":
            error = get("error", ev)
            code = get("code", error)
            raise RealtimeEventError(str(code) if code is not None else "unknown")
        if event_type == target:
            return ev, seen
    raise TimeoutError(f"no {target}, saw {seen}")


def drain_until_quiet(
    events: queue.Queue[object],
    errors: list[Exception],
    *,
    quiet_seconds: float = 1.0,
    timeout: float = 60,
    event_log: list[str] | None = None,
) -> list[str]:
    """Drain delayed VAD/ASR events before a benchmark finalization step."""

    deadline = time.monotonic() + timeout
    seen: list[str] = []
    while time.monotonic() < deadline:
        if errors:
            raise errors[0] from None
        wait_seconds = min(quiet_seconds, max(0.0, deadline - time.monotonic()))
        try:
            ev = events.get(timeout=wait_seconds)
        except queue.Empty:
            if errors:
                raise errors[0] from None
            return seen
        event_type = str(get("type", ev))
        seen.append(event_type)
        if event_log is not None:
            event_log.append(event_type)
        if event_type == "error":
            error = get("error", ev)
            code = get("code", error)
            raise RealtimeEventError(str(code) if code is not None else "unknown")
    raise TimeoutError("event stream did not become quiet")


def run_session(
    client: OpenAI,
    pcm: bytes,
    tts_text: str,
    session_no: int,
    *,
    turn_detection: str = "manual",
    diarization: bool = False,
) -> dict[str, object]:
    conn = client.realtime.connect(model="whisper-1").enter()
    try:
        return _run_connected_session(
            conn,
            pcm,
            tts_text,
            session_no,
            turn_detection=turn_detection,
            diarization=diarization,
        )
    finally:
        with suppress(Exception):
            conn.close()


def _run_connected_session(
    conn: Any,
    pcm: bytes,
    tts_text: str,
    session_no: int,
    *,
    turn_detection: str = "manual",
    diarization: bool = False,
) -> dict[str, object]:
    if turn_detection not in {"manual", "server_vad"}:
        raise ValueError("turn_detection must be manual or server_vad")
    events: queue.Queue[object] = queue.Queue()
    errors: list[Exception] = []
    event_log: list[str] = []
    threading.Thread(
        target=recv_loop, args=(events, errors, conn), daemon=True
    ).start()

    t0 = time.monotonic()
    recv_until(events, errors, "conversation.created", timeout=15, event_log=event_log)
    setup_ms = (time.monotonic() - t0) * 1000

    session: dict[str, object] = {
        "model": "whisper-1",
        "language": "zh",
        "input_audio_format": "pcm16",
        "turn_detection": (
            {"type": "manual"}
            if turn_detection == "manual"
            else {
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 400,
            }
        ),
    }
    if diarization:
        session["speechrail"] = {"diarization": {"enabled": True}}
    conn.send({
        "type": "session.update",
        "session": session,
    })
    recv_until(events, errors, "session.updated", timeout=15, event_log=event_log)

    input_pcm = (
        pcm + b"\x00" * _SERVER_VAD_SILENCE_TAIL_BYTES
        if turn_detection == "server_vad"
        else pcm
    )
    upload_started = time.monotonic()
    for i in range(0, len(input_pcm), 32000):
        chunk = input_pcm[i:i + 32000]
        conn.send({
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(chunk).decode("ascii"),
        })
    upload_ms = (time.monotonic() - upload_started) * 1000
    if turn_detection == "manual":
        t0 = time.monotonic()
        conn.send({"type": "input_audio_buffer.commit"})
    else:
        stopped_at = time.monotonic()
        recv_until(
            events,
            errors,
            "input_audio_buffer.speech_stopped",
            timeout=60,
            event_log=event_log,
        )
        t0 = time.monotonic()
        vad_to_asr_started_ms = (t0 - stopped_at) * 1000
    completed, _ = recv_until(
        events,
        errors,
        "conversation.item.input_audio_transcription.completed",
        timeout=60,
        event_log=event_log,
    )
    asr_ms = (time.monotonic() - t0) * 1000
    duration = len(input_pcm) / 32000
    transcript = str(get("transcript", completed))
    if turn_detection == "server_vad":
        drain_until_quiet(events, errors, event_log=event_log)

    diarization_done = False
    if diarization:
        conn.send(
            {
                "type": "speechrail.diarization.finish",
                "event_id": f"benchmark-{session_no}",
            }
        )
        recv_until(
            events,
            errors,
            "speechrail.diarization.done",
            timeout=60,
            event_log=event_log,
        )
        diarization_done = True

    conn.send({
        "type": "conversation.item.create",
        "item": {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": tts_text}],
        },
    })
    recv_until(
        events,
        errors,
        "conversation.item.created",
        timeout=15,
        event_log=event_log,
    )
    t0 = time.monotonic()
    conn.send({"type": "response.create"})
    recv_until(
        events,
        errors,
        "response.audio.delta",
        timeout=60,
        event_log=event_log,
    )
    first_delta_ms = (time.monotonic() - t0) * 1000

    kinds: list[str] = []
    total_bytes = 0
    response_done = False
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
        event_log.append(k)
        if k == "response.audio.delta":
            total_bytes += len(get("delta", ev) or b"")
        if k == "response.done":
            response_done = True
            break
    if not response_done:
        raise TimeoutError("no response.done")

    return {
        "session": session_no,
        "turn_detection": turn_detection,
        "diarization_requested": diarization,
        "setup_ms": setup_ms,
        "upload_ms": upload_ms,
        "asr_ms": asr_ms,
        "audio_s": duration,
        "asr_rtf": asr_ms / 1000 / duration,
        "tts_first_delta_ms": first_delta_ms,
        "tts_bytes": total_bytes,
        "transcript_present": bool(transcript.strip()),
        "transcript_chars": len(transcript),
        "response_done": response_done,
        "vad_started": "input_audio_buffer.speech_started" in event_log,
        "vad_stopped": "input_audio_buffer.speech_stopped" in event_log,
        "diarization_updated": "speechrail.diarization.updated" in event_log,
        "diarization_done": diarization_done,
        "event_types": event_log,
        **(
            {"vad_to_asr_started_ms": vad_to_asr_started_ms}
            if turn_detection == "server_vad"
            else {}
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pcm_file", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:8201/v1")
    parser.add_argument("--tts-text", default="本地实时语音合成性能测试。")
    parser.add_argument("--sessions", type=int, default=2)
    parser.add_argument(
        "--turn-detection", choices=("manual", "server_vad"), default="manual"
    )
    parser.add_argument("--diarization", action="store_true")
    parser.add_argument("--app-home", type=Path, help="managed app home for API-key discovery")
    args = parser.parse_args()

    api_key = resolve_api_key(app_home=args.app_home) or "local"
    client = OpenAI(
        api_key=api_key, base_url=args.base_url
    )
    pcm = args.pcm_file.read_bytes()

    for i in range(1, args.sessions + 1):
        print(f"--- session {i} ---")
        try:
            result = run_session(
                client,
                pcm,
                args.tts_text,
                i,
                turn_detection=args.turn_detection,
                diarization=args.diarization,
            )
            print(
                f"[session {i}] setup={result['setup_ms']:.0f}ms "
                f"asr={result['asr_ms']:.0f}ms rtf={result['asr_rtf']:.2f}x "
                f"tts_first_delta={result['tts_first_delta_ms']:.0f}ms "
                f"tts_bytes={result['tts_bytes']} "
                f"transcript_present={result['transcript_present']} "
                f"transcript_chars={result['transcript_chars']}"
            )
        except Exception as exc:
            print(f"[session {i}] FAILED: {type(exc).__name__}: {exc}")
            print("  -> consecutive-session stability issue (busy backend?)")


if __name__ == "__main__":
    main()
