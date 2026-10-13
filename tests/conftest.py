"""Temporary storage defaults for app composition; no production locator patches."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pytest

from speechrail.infrastructure.voice_registry import FileVoiceRegistry

# Test modules import the default ASGI app during collection, before fixtures run.
_collection_voice_home = tempfile.TemporaryDirectory(prefix="speechrail-test-voices-")
_collection_voice_root = Path(_collection_voice_home.name)
os.environ["SPEECHRAIL_VOICE_STORE_PATH"] = str(_collection_voice_root / "custom_voices.json")
os.environ["SPEECHRAIL_VOICE_AUDIO_DIR"] = str(_collection_voice_root / "audio")


@pytest.fixture(autouse=True)
def isolated_voice_store_paths(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Settings created by a test must never open the real user's voice directory."""
    monkeypatch.setenv(
        "SPEECHRAIL_VOICE_STORE_PATH", str(tmp_path / "voice-store" / "custom_voices.json")
    )
    monkeypatch.setenv("SPEECHRAIL_VOICE_AUDIO_DIR", str(tmp_path / "voice-store" / "audio"))


@pytest.fixture(autouse=True)
def isolated_user_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Default service paths must never touch the real user's home."""
    monkeypatch.setenv("HOME", str(tmp_path / "user-home"))


@pytest.fixture
def voice_store(tmp_path: Path) -> FileVoiceRegistry:
    return FileVoiceRegistry.open(
        tmp_path / "voice-store" / "custom_voices.json", tmp_path / "voice-store" / "audio"
    )
