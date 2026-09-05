from __future__ import annotations

from speechrail.config import Settings
from speechrail.domain.ports import SpeechRequest
from speechrail.domain.tts import VOICE_PROFILES, generation_token_budget, normalize_tts_text


def test_voice_registry_exposes_nine_one_to_one_speaker_roles() -> None:
    assert tuple(VOICE_PROFILES) == (
        "serena",
        "vivian",
        "uncle_fu",
        "dylan",
        "eric",
        "ryan",
        "aiden",
        "ono_anna",
        "sohee",
    )
    assert VOICE_PROFILES["serena"].instruction.startswith("温暖柔和")
    assert VOICE_PROFILES["serena"].is_default is True
    assert VOICE_PROFILES["uncle_fu"].is_default is False


def test_normalize_tts_text_closes_cjk_text_and_removes_markup() -> None:
    assert normalize_tts_text(" **你好**\uFF0C\U0001F642") == "你好。"
    assert normalize_tts_text("hello") == "hello."
    assert normalize_tts_text("   **🙂**   ") == ""


def test_generation_token_budget_is_bounded_and_scales_with_text() -> None:
    assert generation_token_budget("") == 32
    assert generation_token_budget("好") == 32
    assert generation_token_budget("好" * 10) == 74
    assert generation_token_budget("字" * 5000) == 1200


def test_speech_request_defaults_language_without_breaking_existing_callers() -> None:
    request = SpeechRequest(text="你好", voice="default")

    assert request.language == "auto"


def test_settings_normalize_legacy_voice_ids_to_canonical_roles() -> None:
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        tts_voice_ids=("default", "warm", "bright", "calm"),
    )

    assert settings.tts_voice_ids == tuple(VOICE_PROFILES)


def test_settings_preserve_an_explicit_voice_subset_after_alias_normalization() -> None:
    settings = Settings(
        qwen3_model_dir=None,
        qwen3_python=None,
        tts_voice_ids=("default", "bright"),
    )

    assert settings.tts_voice_ids == ("serena", "vivian")
