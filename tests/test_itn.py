"""Tests for Light Inverse Text Normalization (ITN) and dynamic hotword injection."""

from __future__ import annotations

from speechrail.domain.itn import apply_light_itn, compose_hotword_prompt


def test_itn_years() -> None:
    assert apply_light_itn("二零二六年到了") == "2026年到了"
    assert apply_light_itn("诞生于一九九八年。") == "诞生于1998年。"


def test_itn_percentages() -> None:
    assert apply_light_itn("增长了百分之五十") == "增长了50%"
    assert apply_light_itn("精度达到百分之九十九点九") == "精度达到99.9%"


def test_itn_decimals() -> None:
    assert apply_light_itn("圆周率约为三点一四一五九") == "圆周率约为3.14159"
    assert apply_light_itn("温度是零点八五度") == "温度是0.85度"


def test_itn_numbers_with_units() -> None:
    assert apply_light_itn("售价一百二十五元") == "售价125元"
    assert apply_light_itn("价值五百美元") == "价值500美元"
    assert apply_light_itn("跑了三万米") == "跑了30000米"
    assert apply_light_itn("他今年二十八岁") == "他今年28岁"


def test_itn_empty_and_passthrough() -> None:
    assert apply_light_itn("") == ""
    assert apply_light_itn("Hello world 123!") == "Hello world 123!"


def test_compose_hotword_prompt() -> None:
    prompt = compose_hotword_prompt("会议纪要", ["SpeechRail", "QwenPaw", "SpeechRail"])
    assert prompt == "Key terms: SpeechRail, QwenPaw。 会议纪要"

    empty_prompt = compose_hotword_prompt("", ["FastAPI", "Uvicorn"])
    assert empty_prompt == "Key terms: FastAPI, Uvicorn。"

    no_keywords = compose_hotword_prompt("原始提示词", [])
    assert no_keywords == "原始提示词"
