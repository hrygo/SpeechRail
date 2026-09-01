"""SpeechRail admission-queue backpressure probe.

Fires N concurrent POST /v1/audio/transcriptions and buckets status codes to
observe 429 queue_full / Retry-After behavior under overload. Requires a
running service with a real backend.

Usage:
  python examples/perf/probe_queue.py --audio audio_30s.wav --workers 24
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import time
from collections import Counter
from pathlib import Path
from urllib import error as urlerror
from urllib import request

DEFAULT_BASE = "http://127.0.0.1:8201/v1/audio/transcriptions"


def transcribe(
    base: str, path: Path, model: str
) -> tuple[int, float, str | None, str | None]:
    boundary = "----speechrail-perf"
    body = bytearray()
    for name, value in (("model", model), ("response_format", "json")):
        body += (
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n"
            f"{value}\r\n".encode()
        )
    body += (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"{path.name}\"\r\nContent-Type: audio/wav\r\n\r\n".encode()
    )
    body += path.read_bytes()
    body += f"\r\n--{boundary}--\r\n".encode()
    req = request.Request(
        base,
        data=bytes(body),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    t0 = time.monotonic()
    try:
        with request.urlopen(req, timeout=600) as resp:
            payload = json.loads(resp.read())
        return resp.status, time.monotonic() - t0, payload.get("text"), None
    except urlerror.HTTPError as exc:
        body_bytes = exc.read()
        retry = exc.headers.get("Retry-After")
        try:
            code = json.loads(body_bytes).get("error", {}).get("code")
        except json.JSONDecodeError:
            code = None
        return exc.code, time.monotonic() - t0, code, retry


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--base", default=DEFAULT_BASE)
    parser.add_argument("--workers", type=int, default=24)
    parser.add_argument("--model", default="speechrail/qwen3-asr-1.7b")
    args = parser.parse_args()
    path = Path(args.audio)

    print(f"=== queue backpressure probe: workers={args.workers} ===")
    t0 = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        results = list(
            pool.map(lambda _: transcribe(args.base, path, args.model), range(args.workers))
        )
    wall = time.monotonic() - t0

    counts: Counter[int] = Counter(r[0] for r in results)
    retry_after = sorted({r[3] for r in results if r[0] == 429})
    ok_rt = [r[1] for r in results if r[0] == 200]
    print(f"wall={wall:.2f}s statuses={dict(counts)}")
    if ok_rt:
        print(
            f"ok: n={len(ok_rt)} mean={sum(ok_rt) / len(ok_rt):.2f}s "
            f"max={max(ok_rt):.2f}s"
        )
    if 429 in counts:
        print(f"429 queue_full: n={counts[429]} retry_after={retry_after}")
    for r in results:
        if r[0] not in (200, 429):
            print(f"  other: status={r[0]} body={r[2]!r}")


if __name__ == "__main__":
    main()
