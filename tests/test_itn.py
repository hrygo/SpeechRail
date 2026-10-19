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


@pytest.mark.parametrize("text", [
    "一点一点地积累", "一点一滴的变化", "生活两点一线", "保持三点一线",
    "五点六点再说", "七八点八九点", "七八点七八点", "二点五二点五",
    "三点一刻开始", "十二点一点左右",
])
def test_itn_does_not_read_ordinary_phrases_or_clock_lists_as_decimals(text: str) -> None:
    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("三点一四米", "3.14米"), ("零点零五元", "0.05元"),
    ("三点五。", "3.5。"), ("二点五到三点五", "2.5到3.5"),
    ("三点五万元", "3.5万元"), ("百分之三点五", "3.5%"),
    ("百分之一点一点", "百分之一点一点"),
    ("百分之五十点几", "百分之五十点几"),
])
def test_itn_preserves_explicit_decimal_contexts(text: str, expected: str) -> None:
    assert apply_light_itn(text) == expected


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


@pytest.mark.parametrize("text", [
    "统一分配", "统一人员安排", "统一人事管理", "统一号牌", "我们统一分两次处理",
])
def test_itn_preserves_unify_word_before_quantity_units(text: str) -> None:
    expected = text.replace("两次", "2次")
    assert apply_light_itn(text) == expected


@pytest.mark.parametrize(("text", "expected"), [
    ("一个人分两次", "一个人分2次"),
    ("统一一百个人", "统一一百个人"),
    ("总统三人随行", "总统3人随行"),
    ("统一，三个人分两次", "统一，3个人分2次"),
])
def test_itn_preserves_numeric_units_next_to_unify_word(text: str, expected: str) -> None:
    assert apply_light_itn(text) == expected


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


@pytest.mark.parametrize("text", [
    "五六个人", "七八天", "一两个", "两三个", "三五天", "七八十个",
    "十三四岁", "四十五六岁", "两两个", "五五个", "二三号",
    "增长了百分之五六", "增长了百分之二三十",
])
def test_itn_preserves_ambiguous_spoken_quantities(text: str) -> None:
    assert apply_light_itn(text) == text


@pytest.mark.parametrize("text", [
    "万一人家不同意呢", "万一天气不好怎么办", "五百一个", "两百一个",
    "一百万一个", "五百两天", "三千五元", "一千二百三元", "一万二元",
    "百分之一百五", "百分之3百5", "百分之３百５",
])
def test_itn_preserves_implicit_places_and_nonnumeric_phrase_boundaries(text: str) -> None:
    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("五百零一个", "501个"), ("五百一十个", "510个"),
    ("一千零三元", "1003元"), ("一千二百三十元", "1230元"),
    ("一万零二元", "10002元"), ("一万二千元", "12000元"),
    ("三千五百元", "3500元"), ("百分之一百零五", "105%"),
])
def test_itn_still_converts_explicit_places(text: str, expected: str) -> None:
    assert apply_light_itn(text) == expected


@pytest.mark.parametrize(("text", "expected"), [
    ("五十六个人", "56个人"), ("七十八天", "78天"),
    ("二零号", "20号"), ("一零八个人", "108个人"),
    ("一二三号", "123号"), ("二三四五楼", "2345楼"),
    ("一百零三个人", "103个人"), ("二零二六年", "2026年"),
    ("二三点五个", "23.5个"), ("百分之二三点五", "23.5%"),
])
def test_itn_still_converts_unambiguous_number_contexts(text: str, expected: str) -> None:
    assert apply_light_itn(text) == expected


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


def test_itn_folds_ascii_digits_inside_a_mixed_numeral_run() -> None:
    # `_PERCENT_RE` and `_DECIMAL_RE` both admit ASCII digits, so a recogniser
    # that normalises only part of a number produces a run like `2三点五`. The
    # positional fast path indexed `_DIGITS_MAP` with every character, so the
    # lookup raised `KeyError: '2'` and took the whole transcript down with it:
    # batch and realtime both call `apply_light_itn` without a guard.
    assert apply_light_itn("2三点五") == "23.5"
    assert apply_light_itn("2三点五个") == "23.5个"
    assert apply_light_itn("增长了百分之2三点五") == "增长了23.5%"
    # `1二` is the same shape in front of a unit: the ASCII digit is part of
    # the value, so the run stays 12 rather than dropping to 2.
    assert apply_light_itn("耗时1二点五秒") == "耗时12.5秒"

    # The accumulator dropped the ASCII digit without a word, so `百分之2十`
    # was reported as 10% rather than 20%.
    assert apply_light_itn("增长了百分之2十") == "增长了20%"

    # Every digit has to survive the folding, not just the ones the shapes
    # above happen to use. The zero sits in the middle on purpose, so the
    # assertion is about the mapping and not about a leading zero.
    for digit in range(1, 10):
        assert apply_light_itn(f"{digit}三点五") == f"{digit}3.5"
    assert apply_light_itn("1零三点五") == "103.5"

    # Controls: a number already written in digits is still left alone, and the
    # pure-Chinese forms keep the values the positional path was added for.
    for text in ["2.5", "23.5%", "12.5秒", "3.5", "二零二六"]:
        assert apply_light_itn(text) == text, f"{text} 不该被改写"
    assert apply_light_itn("二三点五") == "23.5"
