"""Regression: time-boxed ASR debug PCM tap stays off unless armed."""

from __future__ import annotations

import asyncio
import struct
import time
from pathlib import Path

from speechrail.application.realtime_openai import OpenAIRealtimeSession
from speechrail.application.services import AppOverrides, build_app_services
from speechrail.config import Settings
from speechrail.runtime.asr_debug_tap import (
    CAPTURE_UNTIL_ENV_VAR,
    AsrDebugTap,
    capture_armed,
)


class _Session:
    async def append_audio(self, audio: bytes) -> None:
        return None

    async def flush(self) -> None:
        return None

    async def commit(self, want_segments: bool = False) -> None:
        return None

    def events(self):  # pragma: no cover - never iterated in these tests
        raise AssertionError("no events expected")

    async def close(self) -> None:
        return None


class _Factory:
    def create(self, **kwargs):  # type: ignore[no-untyped-def]
        return _Session()

    def release(self, session) -> None:  # type: ignore[no-untyped-def]
        return None


def _scenario(monkeypatch, tmp_path: Path, *, armed: bool) -> Path | None:
    now = time.time()
    monkeypatch.setenv(
        CAPTURE_UNTIL_ENV_VAR, str(now + 1200) if armed else str(now - 1)
    )
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
    )
    services = build_app_services(
        settings, AppOverrides(realtime_asr_factory=_Factory())
    )

    async def send(event: dict) -> None:
        return None

    async def run() -> Path | None:
        session = OpenAIRealtimeSession(
            services, session_id="tap-test", send=send
        )
        # Redirect the tap into the test tmp dir, bypassing the log dir.
        session._asr_debug_tap = AsrDebugTap(
            "tap-test", log_dir=tmp_path, max_bytes=1_000_000
        )
        await session.start()
        await session.handle(
            {"type": "input_audio_buffer.append", "audio": "AAA="}
        )
        await session.handle({"type": "input_audio_buffer.commit"})
        path = session._asr_debug_tap.path
        await session.close()
        return path

    return asyncio.run(run())


def test_debug_tap_off_by_default_writes_nothing(
    monkeypatch, tmp_path: Path
) -> None:
    monkeypatch.delenv(CAPTURE_UNTIL_ENV_VAR, raising=False)
    assert not capture_armed()
    path = _scenario(monkeypatch, tmp_path, armed=False)
    assert path is None
    assert list(tmp_path.rglob("*.wav")) == []


def test_debug_tap_armed_writes_playable_wav(
    monkeypatch, tmp_path: Path
) -> None:
    path = _scenario(monkeypatch, tmp_path, armed=True)
    assert path is not None
    raw = path.read_bytes()
    assert len(raw) > 44
    riff, _size, wave, fmt, _, audio_fmt, channels, rate, _, _, bits, data, n = (
        struct.unpack("<4sI4s4sIHHIIHH4sI", raw[:44])
    )
    assert riff == b"RIFF" and wave == b"WAVE" and fmt == b"fmt "
    assert (audio_fmt, channels, rate, bits, data) == (1, 1, 16000, 16, b"data")
    assert n == len(raw) - 44


def test_debug_tap_invalid_env_stays_off(monkeypatch) -> None:
    monkeypatch.setenv(CAPTURE_UNTIL_ENV_VAR, "not-a-timestamp")
    assert not capture_armed()
    tap = AsrDebugTap("x")
    tap.append(b"\x00\x00")
    assert tap.path is None
    tap.close()
