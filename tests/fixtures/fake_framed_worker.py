"""Fake framed worker for transport fault-matrix tests; no model SDK, no network."""

from __future__ import annotations

import signal
import sys
import time

from speechrail.runtime.worker_protocol import read_frame, write_frame


def main() -> None:
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer
    while True:
        try:
            frame = read_frame(stdin)
        except Exception:
            return
        if frame is None:
            return
        action = str(frame.get("action", ""))
        if action == "echo":
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
