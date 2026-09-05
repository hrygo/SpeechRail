"""Fake framed worker for transport fault-matrix tests; no model SDK, no network."""

from __future__ import annotations

import signal
import sys
import time

from speechrail.runtime.worker_protocol import read_frame, write_frame


def main() -> None:
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    cancel_probes: dict[str, str] = {}
    while True:
        try:
            frame = read_frame(stdin)
        except Exception:
            return
        if frame is None:
            return
        action = str(frame.get("action", ""))
        if frame.get("type") == "start" and not action:
            model_dir = str(frame.get("model_dir", ""))
            if model_dir.endswith("shared-bad-ready"):
                write_frame(
                    stdout,
                    {
                        "type": "ready",
                        "model_loaded": True,
                        "device": "mps",
                        "dtype": "float16",
                    },
                )
            else:
                write_frame(
                    stdout,
                    {
                        "type": "ready",
                        "model_loaded": True,
                        "device": frame.get("device"),
                        "dtype": frame.get("dtype"),
                    },
                )
        elif frame.get("type") == "cancel":
            session_id = frame.get("session_id")
            if isinstance(session_id, str):
                probe = cancel_probes.pop(session_id, None)
                if probe is not None:
                    write_frame(
                        stdout,
                        {
                            "type": "event",
                            "session_id": probe,
                            "text": f"cancelled:{session_id}",
                        },
                    )
        elif action == "shared_batch":
            write_frame(
                stdout,
                {
                    "type": "result",
                    "request_id": frame.get("request_id"),
                    "text": frame.get("text", ""),
                },
            )
        elif action == "shared_batch_duplicate":
            result = {
                "type": "result",
                "request_id": frame.get("request_id"),
                "text": "first",
            }
            write_frame(stdout, result)
            write_frame(stdout, {**result, "text": "duplicate"})
        elif action == "shared_stream":
            session_id = frame.get("session_id")
            phase = frame.get("phase")
            if phase == "open":
                write_frame(stdout, {"type": "session.opened", "session_id": session_id})
            elif phase == "event":
                write_frame(
                    stdout,
                    {
                        "type": "event",
                        "session_id": session_id,
                        "text": frame.get("text", ""),
                    },
                )
            elif phase == "finish":
                write_frame(stdout, {"type": "finished", "session_id": session_id})
        elif action == "shared_burst":
            session_id = frame.get("session_id")
            probe = frame.get("cancel_probe_session_id")
            if isinstance(session_id, str) and isinstance(probe, str):
                cancel_probes[session_id] = probe
            count = int(frame.get("count", 0))
            for index in range(count):
                write_frame(
                    stdout,
                    {
                        "type": "event",
                        "session_id": session_id,
                        "text": str(index),
                    },
                )
        elif action == "shared_completed_then_finish":
            session_id = frame.get("session_id")
            for index in range(63):
                write_frame(
                    stdout,
                    {
                        "type": "event",
                        "session_id": session_id,
                        "text": str(index),
                    },
                )
            write_frame(
                stdout,
                {
                    "type": "completed",
                    "session_id": session_id,
                    "text": "final",
                },
            )
            write_frame(stdout, {"type": "finished", "session_id": session_id})
        elif action == "shared_global_error":
            write_frame(stdout, {"type": "error", "code": "shared_global_failure"})
            return
        elif action == "shared_eof":
            return
        elif action == "shared_hang":
            time.sleep(30)
            return
        elif action == "shared_unknown_stream":
            write_frame(
                stdout,
                {
                    "type": "event",
                    "session_id": frame.get("session_id"),
                    "text": "unknown",
                },
            )
        elif action == "shared_trim_memory" or frame.get("type") == "trim_memory":
            continue
        elif action == "echo":
            write_frame(stdout, {"type": "echo", "text": str(frame.get("text", ""))})
        elif action == "ready":
            write_frame(stdout, {"type": "ready", "model_loaded": True})
        elif action == "malformed":
            stdout.write(b"not-a-frame")
            stdout.flush()
            return
        elif action == "hang":
            time.sleep(30)
            return
        elif action == "partial_header":
            stdout.write(b"\x00")
            stdout.flush()
            time.sleep(30)
            return
        elif action == "partial_body":
            stdout.write(b"\x00\x00\x00\x10{")
            stdout.flush()
            time.sleep(30)
            return
        elif action == "stubborn":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(30)
            return
        elif action == "exit":
            return
        elif action == "stderr_and_exit":
            sys.stderr.write("ImportError: No module named 'transformers'\n")
            sys.stderr.flush()
            return
        elif action == "error_with_stderr":
            sys.stderr.write("mlx.core: [Metal] failed to allocate model weights\n")
            sys.stderr.flush()
            write_frame(stdout, {"type": "error", "code": "worker_load_error"})
            return
        else:
            write_frame(stdout, {"type": "error", "code": "unknown_action"})


if __name__ == "__main__":
    main()
