"""Tests for Light Inverse Text Normalization (ITN) and dynamic hotword injection."""

from __future__ import annotations

import pytest

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


@pytest.mark.parametrize(
    ("source", "expected"),
    [
        ("售价一百二十五元", "售价125元"),
        ("价值五百美元", "价值500美元"),
        ("跑了三万米", "跑了30000米"),
        ("他今年二十八岁", "他今年28岁"),
        ("二零号座位", "20号座位"),
    ],
)
def test_itn_numbers_with_units(source: str, expected: str) -> None:
    assert apply_light_itn(source) == expected


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


def test_itn_does_not_corrupt_magnitude_words() -> None:
    # 757k lines of repo corpus produced 165 matches where a bare magnitude
    # collapsed to 0: `百分之` -> `0分百`, `万元` -> `0元`, `零点` -> `0点`.
    assert apply_light_itn("这是百分百的努力") == "这是百分百的努力"
    assert apply_light_itn("我万分感激") == "我万分感激"
    assert apply_light_itn("增长百分之五十") == "增长50%"


def test_itn_converts_bare_magnitude_with_a_real_unit() -> None:
    assert apply_light_itn("融资额以万元为单位") == "融资额以10000元为单位"
    assert apply_light_itn("规模是万亿元") == "规模是1000000000000元"
    assert apply_light_itn("他今年二十八岁") == "他今年28岁"


def test_itn_scales_the_accumulated_total_at_yi() -> None:
    # The old 亿 branch only scaled the current section, so 万亿 came out as
    # 100010000 instead of 1e12.
    assert apply_light_itn("一亿二千万元") == "120000000元"
    assert apply_light_itn("十二万三千四百五十六元") == "123456元"
    # 十万亿 must scale once, not twice: the magnitude rule cannot fire again
    # after a magnitude has already been seen.
    assert apply_light_itn("规模是十万亿元") == "规模是10000000000000元"


def test_itn_leaves_quantity_words_alone() -> None:
    assert apply_light_itn("他有十分满意") == "他有十分满意"
    assert apply_light_itn("短一点") == "短一点"
    assert apply_light_itn("这一点很重要") == "这一点很重要"


def test_itn_leaves_fractions_alone() -> None:
    assert apply_light_itn("十分之一") == "十分之一"
    assert apply_light_itn("二分之一") == "二分之一"
    assert apply_light_itn("四分之三") == "四分之三"


def test_itn_does_not_read_an_approximate_magnitude_as_a_value() -> None:
    # 数十秒 / 几十秒 / 数十万个 used to become 10秒 / 10个.
    assert apply_light_itn("可能要等数十秒") == "可能要等数十秒"
    assert apply_light_itn("首次启动可能要等几十秒") == "首次启动可能要等几十秒"
    assert apply_light_itn("支持数十万个并发会话") == "支持数十万个并发会话"


def test_itn_still_converts_minutes_and_bare_ten_with_a_measure_word() -> None:
    assert apply_light_itn("耗时三分钟") == "耗时3分钟"
    assert apply_light_itn("一共十个人") == "一共10个人"


def test_itn_does_not_glue_an_ascii_magnitude_onto_the_digits_before_it() -> None:
    # `50万元` came back as `5010000元`. `_UNIT_RE`'s lookbehind excluded
    # Chinese numerals and 数/几 but never ASCII digits, so a Chinese magnitude
    # sitting directly after an already-written number matched on its own:
    # `万元` -> `10000元` was concatenated in front of the `50` in front of it.
    # A recogniser that normalises speech to digits emits exactly this shape, so
    # a number two orders of magnitude off reached the transcript, the batch and
    # realtime payloads, and every text comparison built on them.
    # 9 and 7 are here on purpose: a lookbehind written as [0-8] would still let
    # `9亿元` and `7万吨` through, and the first three digits are not special.
    for text in ["50万元", "2万元", "3万个", "10亿元", "5万美元", "30亿人",
                 "9亿元", "7万吨", "8千万个"]:
        assert apply_light_itn(text) == text, f"{text} 不该被改写"

    # Reverse controls: the number written out in Chinese is still converted.
    for spoken, written in [
        ("五十万元", "500000元"),
        ("三万个", "30000个"),
        ("十亿元", "1000000000元"),
        ("五万美元", "50000美元"),
    ]:
        assert apply_light_itn(spoken) == written, f"{spoken} 应读成 {written}"

    # Already-correct digits, and digit+unit with no Chinese magnitude, were
    # never affected and must stay that way. `1000万台` is here for a different
    # reason: 台 is not in the server's unit list at all.
    for text in ["3小时", "8吨", "1000公里", "20万台", "1000万台", "两万五千"]:
        assert apply_light_itn(text) == text, f"{text} 本来就不该被改写"
