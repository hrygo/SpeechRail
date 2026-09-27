"""Default voice-preview metadata is one server-side projection, not a client guess."""

from __future__ import annotations

import json
import wave
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

import speechrail.domain.tts as voices
from speechrail.app import create_app
from speechrail.config import Settings
from speechrail.domain.voice_preview import (
    PREVIEW_TEMPLATES,
    SUPPORTED_PREVIEW_LOCALES,
    normalize_preview_locale,
    preview_for_profile,
    preview_text_for_locale,
)

# The plan fixes these per Qwen's speaker table.  Accented Mandarin voices are
# Chinese sample voices, not English ones.
EXPECTED_SYSTEM_PREVIEW_LOCALES = {
    "serena": "zh",
    "vivian": "zh",
    "uncle_fu": "zh",
    "dylan": "zh",
    "eric": "zh",
    "ryan": "en",
    "aiden": "en",
    "ono_anna": "ja",
    "sohee": "ko",
}

_HANGUL = range(0xAC00, 0xD7A4)
_KANA = range(0x3040, 0x30FF)


def _script_of(text: str) -> str:
    # Japanese mixes kana with kanji, so the distinguishing script wins first.
    if any(ord(char) in _HANGUL for char in text):
        return "hangul"
    if any(ord(char) in _KANA for char in text):
        return "kana"
    if any(0x4E00 <= ord(char) <= 0x9FFF for char in text):
        return "han"
    if text.isascii():
        return "latin"
    return "other"


_EXPECTED_SCRIPT = {"zh": "han", "ja": "kana", "ko": "hangul", "en": "latin"}


def _client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> TestClient:
    monkeypatch.setattr(
        voices, "_GLOBAL_VOICE_REGISTRY", voices.VoiceRegistry(tmp_path / "voices.json")
    )
    return TestClient(
        create_app(Settings(api_key=None, qwen3_model_dir=None, qwen3_python=None))
    )


def test_every_system_voice_declares_its_maintained_sample_locale() -> None:
    assert set(voices.SYSTEM_VOICE_PROFILES) == set(EXPECTED_SYSTEM_PREVIEW_LOCALES)

    for voice_id, locale in EXPECTED_SYSTEM_PREVIEW_LOCALES.items():
        preview = preview_for_profile(voices.SYSTEM_VOICE_PROFILES[voice_id])

        assert preview is not None, voice_id
        assert preview["locale"] == locale
        assert preview["text"] == PREVIEW_TEMPLATES[locale]
        assert _script_of(preview["text"]) == _EXPECTED_SCRIPT[locale]


def test_preview_carries_no_language_capability_claim() -> None:
    for voice_id, profile in voices.SYSTEM_VOICE_PROFILES.items():
        preview = preview_for_profile(profile)

        assert preview is not None, voice_id
        # A preview describes one sample, never what the voice may speak.
        assert set(preview) == {"locale", "text"}


def test_unknown_or_malformed_locale_never_guesses_a_language() -> None:
    assert normalize_preview_locale(None) is None
    assert normalize_preview_locale("") is None
    assert normalize_preview_locale("  ") is None
    assert normalize_preview_locale("klingon") is None
    assert normalize_preview_locale(42) is None
    assert normalize_preview_locale("en-US") is None
    assert preview_text_for_locale("klingon") is None
    assert normalize_preview_locale(" EN ") == "en"
    assert {"zh", "en", "ja", "ko"} == SUPPORTED_PREVIEW_LOCALES


def test_voice_without_a_declared_sample_has_no_preview() -> None:
    unsourced = voices.VoiceProfile(id="custom", name="Custom", mode="clone")

    assert preview_for_profile(unsourced) is None
    assert "preview_locale" not in unsourced.to_dict()


def test_preview_is_projected_consistently_by_catalog_and_capability(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client = _client(tmp_path, monkeypatch)

    catalog = {
        voice["id"]: voice.get("preview")
        for voice in client.get("/v1/voices").json()["data"]
    }
    snapshot = client.get("/v1/speechrail/capabilities").json()
    effective = {
        voice["id"]: voice.get("preview")
        for voice in snapshot["voices"]
    }

    for voice_id, locale in EXPECTED_SYSTEM_PREVIEW_LOCALES.items():
        expected = {"locale": locale, "text": PREVIEW_TEMPLATES[locale]}
        assert catalog[voice_id] == expected, voice_id
        assert effective[voice_id] == expected, voice_id


@pytest.mark.parametrize("stored", [None, "klingon", 7, ""])
def test_legacy_or_invalid_stored_locale_loads_without_a_preview(
    tmp_path: Path, stored: object
) -> None:
    registry = voices.VoiceRegistry(tmp_path / "voices.json")
    # Keep the reference audio inside this test's own voices directory; the
    # registry refuses paths that escape it.
    registry._voices_dir = tmp_path / "voice-audio"
    registry._voices_dir.mkdir(parents=True, exist_ok=True)
    reference = registry._voices_dir / "legacy_clone.wav"
    with wave.open(str(reference), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(24_000)
        handle.writeframes(b"\x00\x00" * 24_000)
    record: dict[str, object] = {
        "id": "legacy_clone",
        "name": "Legacy Clone",
        "mode": "clone",
        "ref_text": "这是一段用于克隆的参考文本，长度足够通过基本校验。",
        "audio_path": str(reference),
        "created_at": 1.0,
    }
    if stored is not None:
        record["preview_locale"] = stored

    loaded = registry._profile_from_record(record)

    assert loaded.preview_locale is None
    assert preview_for_profile(loaded) is None
    # Loading display metadata must not disturb the acoustic identity.
    assert loaded.mode == "clone"
    assert loaded.revision is None
    assert "preview_locale" not in loaded.to_dict()


def test_declared_locale_round_trips_without_changing_identity(tmp_path: Path) -> None:
    profile = voices.VoiceProfile(
        id="declared_clone",
        name="Declared Clone",
        mode="clone",
        revision="vr_" + "0" * 32,
        preview_locale="ja",
    )

    restored = voices.VoiceProfile(**{
        key: value
        for key, value in json.loads(json.dumps(profile.to_dict())).items()
        if key in voices.VoiceProfile.__dataclass_fields__
    })

    assert restored.preview_locale == "ja"
    assert restored.revision == profile.revision
    assert restored.to_dict() == profile.to_dict()
