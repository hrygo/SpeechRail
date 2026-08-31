from __future__ import annotations

from speechrail.domain.ports import SpeechRequest
from speechrail.domain.tts import VOICE_PROFILES, generation_token_budget, normalize_tts_text


def test_voice_registry_preserves_the_four_voice_design_profiles() -> None:
    assert tuple(VOICE_PROFILES) == ("default", "warm", "bright", "calm")
    assert VOICE_PROFILES["warm"].instruction.startswith("温暖柔和")
    assert VOICE_PROFILES["calm"].is_default is False


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
