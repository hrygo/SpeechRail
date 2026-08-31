"""Minimal SpeechRail Realtime transcription client for raw 16 kHz mono PCM."""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
from pathlib import Path

from websockets.asyncio.client import connect


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("pcm_file", type=Path, help="s16le/16 kHz/mono PCM file")
    parser.add_argument(
        "--url", default=os.getenv("SPEECHRAIL_REALTIME_URL", "ws://127.0.0.1:8201/v1/realtime")
    )
    parser.add_argument("--model", default="speechrail/qwen3-asr-1.7b")
    parser.add_argument("--language", default="zh")
    parser.add_argument("--api-key", default=os.getenv("SPEECHRAIL_API_KEY"))
    return parser.parse_args()


async def run(options: argparse.Namespace) -> None:
    headers = {}
    if options.api_key:
        headers["Authorization"] = f"Bearer {options.api_key}"

    async with connect(options.url, additional_headers=headers) as websocket:
        await websocket.send(
            json.dumps(
                {
                    "type": "transcription_session.update",
                    "session": {
                        "model": options.model,
                        "language": options.language,
                        "audio_format": {
                            "type": "audio/pcm",
                            "rate": 16000,
                            "channels": 1,
                            "sample_width": 2,
                        },
                    },
                }
            )
        )
        print(await websocket.recv())

        with options.pcm_file.open("rb") as pcm_file:
            while chunk := pcm_file.read(6400):
                await websocket.send(
                    json.dumps(
                        {
                            "type": "input_audio_buffer.append",
                            "audio": base64.b64encode(chunk).decode("ascii"),
                        }
                    )
                )
        await websocket.send(json.dumps({"type": "input_audio_buffer.commit"}))

        async for message in websocket:
            print(message)
            if json.loads(message).get("type") in {
                "conversation.item.input_audio_transcription.completed",
                "error",
            }:
                break


if __name__ == "__main__":
    asyncio.run(run(arguments()))
