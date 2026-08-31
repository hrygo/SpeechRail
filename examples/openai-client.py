"""Call SpeechRail through the standard OpenAI Python client.

Install the client in the caller's environment with ``python3 -m pip install openai``.
SpeechRail itself does not need the OpenAI SDK to serve HTTP clients.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from openai import OpenAI


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} AUDIO_FILE")

    audio_path = Path(sys.argv[1])
    client = OpenAI(
        base_url=os.getenv("SPEECHRAIL_BASE_URL", "http://127.0.0.1:8201/v1"),
        api_key=os.getenv("SPEECHRAIL_API_KEY", "local-not-used"),
    )
    with audio_path.open("rb") as audio_file:
        result = client.audio.transcriptions.create(
            model=os.getenv("SPEECHRAIL_MODEL", "speechrail/qwen3-asr-1.7b"),
            file=audio_file,
            language="zh",
            response_format="verbose_json",
        )
    print(result.text)


if __name__ == "__main__":
    main()
