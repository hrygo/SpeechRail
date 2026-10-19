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


@pytest.mark.parametrize("text", [
    "增长了百分之五十几",
    "增长了百分之五十多",
    "增长了百分之五十余",
    "增长了百分之二十来",
    "增长了百分之五十来个",
    "大约百分之五十几左右",
    "完成度三点五几",
    "完成度三点五多",
])
def test_itn_preserves_approximate_values(text: str) -> None:
    """A trailing 几/多/余/来 makes the value a bound, not a closed number."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize("text", [
    "他一次次地尝试",
    "一天天过去",
    "一秒秒地数",
    "一次又一次",
    "一次一次地确认",
    "一天一天地等",
    "一次一个地处理",
    "三次五次",
])
def test_itn_preserves_repeated_units(text: str) -> None:
    """一次次 / 一次又一次 repeat a classifier; neither copy is a count."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize("text", [
    "一次性",
    "一次性用品",
    "一次函数",
    "一次能源",
    "一次设备",
    "一次成型",
    "二次开发",
    "二次加工",
    "二次分配",
    "二次验证",
    "二次编码",
    "二次采样",
])
def test_itn_preserves_ci_lexical_compounds(text: str) -> None:
    """次 is a lexical or ordinal morpheme in these technical phrases."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize("text", [
    "二分法",
    "三分法",
    "四分卫",
    "五分制",
    "四分五裂",
    "一分为二",
    "三分球",
    "五分裤",
    "七分袖",
])
def test_itn_preserves_fen_lexical_compounds(text: str) -> None:
    """分 is a morpheme in these words, not a minute/cent/score unit."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize("text", [
    "万岁",
    "中华人民共和国万岁",
    "万岁爷",
    "千岁",
])
def test_itn_preserves_wan_sui_titles(text: str) -> None:
    """A bare 万/千 before 岁 is a title or exclamation, not an age."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize("text", [
    "一日三秋",
    "一日千里",
    "一日为师",
    "一日不见",
    "一日之计在于晨",
    "三天两头",
    "一天一个样",
    "五月天",
    "五月花",
    "二月河",
    "三月天",
    "七月流火",
    "十月围城",
    "三月期",
    "十日谈",
    "二人转",
    "三人行必有我师",
    "三人成虎",
    "一元复始",
    "一元二次方程",
])
def test_itn_preserves_unit_idioms(text: str) -> None:
    """The unit is part of an idiom or term, so the phrase is left as spoken."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("耗时三分钟", "耗时3分钟"),
    ("五分钱", "5分钱"),
    ("三分的差距", "3分的差距"),
    ("得了三分。", "得了3分。"),
    ("他今年百岁", "他今年100岁"),
    ("三月五日", "3月5日"),
    ("三月份", "3月份"),
    ("三月初", "3月初"),
    ("三月中旬", "3月中旬"),
    ("三月里", "3月里"),
    ("三月", "3月"),
    ("三月前", "3月前"),
    ("三天后", "3天后"),
    ("一次会议", "1次会议"),
    ("第一次开始", "第1次开始"),
    ("第二次又被拒绝", "第2次又被拒绝"),
    ("连续两次一致", "连续2次一致"),
    ("两天一次", "2天1次"),
    ("两天一致", "2天一致"),
    ("五月五号", "5月5号"),
    ("三日游", "3日游"),
    ("二人世界", "2人世界"),
    ("三人随行", "3人随行"),
    ("十五日之前", "15日之前"),
    ("其中百分之五十来自学校", "其中50%来自学校"),
])
def test_itn_still_converts_closed_quantities(text: str, expected: str) -> None:
    """Narrowing the rules must not drop unambiguous measurement contexts."""

    assert apply_light_itn(text) == expected


@pytest.mark.parametrize("text", [
    "十点零五",
    "十点零五分",
    "七点四十",
    "七点四十分",
    "十二点三十分",
    "五点零五分",
    "三点十五分",
    "九点九分",
])
def test_itn_preserves_clock_times(text: str) -> None:
    """NUM点NUM分 is a clock, and a partial numeral run must never be rewritten."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize("text", [
    "三点一四",
    "百分之七点四十",
    "百分之三点十五",
])
def test_itn_preserves_two_digit_decimals_that_could_be_clock_minutes(
    text: str,
) -> None:
    """Two fractional digits can be minutes; only a closed context disambiguates."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("三点一四一五九", "3.14159"),
    ("三点一四米", "3.14米"),
    ("三点十四秒", "3.14秒"),
    ("三点十四米", "3.14米"),
    ("十点零五秒", "10.05秒"),
    ("百分之三点一四", "3.14%"),
    ("三点五。", "3.5。"),
])
def test_itn_still_converts_decimals_with_a_closed_context(
    text: str, expected: str
) -> None:
    assert apply_light_itn(text) == expected


@pytest.mark.parametrize("text", [
    "三点十四秒",
    "十点零五秒",
    "三点一四米",
    "七点四十万",
])
def test_itn_is_idempotent_on_closed_decimals(text: str) -> None:
    once = apply_light_itn(text)
    assert apply_light_itn(once) == once


@pytest.mark.parametrize("text", [
    "二元组",
    "三元组",
    "一元论",
    "一元化",
    "同一元素",
    "三元式",
    "三元里",
])
def test_itn_preserves_yuan_lexical_compounds(text: str) -> None:
    """A bare 元 after a single digit is often a term, not a currency amount."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("一元钱", "1元钱"),
    ("十元", "10元"),
    ("五百元", "500元"),
    ("两万元", "20000元"),
    ("二零元", "20元"),
    ("价值五百美元", "价值500美元"),
])
def test_itn_still_converts_currency_with_an_explicit_context(
    text: str, expected: str
) -> None:
    assert apply_light_itn(text) == expected


@pytest.mark.parametrize("text", [
    "二分",
    "anchor 二分、匹配输出一致",
    "九点九分",
    "十分的好",
    "百分之三点五分",
])
def test_itn_preserves_non_measure_fen(text: str) -> None:
    """A bare 分 at a boundary is not enough evidence for a score."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("得了三分。", "得了3分。"),
    ("他考了九十分", "他考了90分"),
    ("三分的差距", "3分的差距"),
    ("五分钟", "5分钟"),
    ("十分钟后", "10分钟后"),
    ("五分钱", "5分钱"),
    ("十分钱", "10分钱"),
    ("满分一百分。", "满分100分。"),
])
def test_itn_still_converts_closed_fen_contexts(
    text: str, expected: str
) -> None:
    assert apply_light_itn(text) == expected


@pytest.mark.parametrize("text", [
    "下一次请求",
    "每一次人机对话",
    "这一次的失败",
    "上一次成功",
    "前一次",
    "后一次",
    "同一次复发",
    "另一次",
    "任何一次失败",
    "一次只运行一个服务",
    "二次量化",
    "二次根式",
    "二次幂",
    "三次产业",
    "二次感染",
    "二次伤害",
    "二次事故",
    "二次销售",
    "二次传播",
    "二次回归",
    "二次压缩",
    "二次排序",
    "二次启动",
    "二次加载",
    "二次处理",
    "二次训练",
])
def test_itn_preserves_determiner_and_lexical_ci(text: str) -> None:
    """一次 in a determiner phrase or a degree term is not a count."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("第一次开始", "第1次开始"),
    ("第二次又被拒绝", "第2次又被拒绝"),
    ("一次会议", "1次会议"),
    ("连续两次一致", "连续2次一致"),
    ("两天一次", "2天1次"),
])
def test_itn_still_converts_closed_ci_counts(text: str, expected: str) -> None:
    assert apply_light_itn(text) == expected


@pytest.mark.parametrize(("text", "expected"), [
    ("一次请求", "1次请求"),
    ("两次独立", "2次独立"),
    ("三次重复", "3次重复"),
    ("一次失败", "1次失败"),
    ("一次成功", "1次成功"),
    ("一次运行", "1次运行"),
    ("一次处理", "1次处理"),
    ("一次机会", "1次机会"),
    ("一次测试", "1次测试"),
])
def test_itn_still_converts_count_continuations(
    text: str, expected: str
) -> None:
    assert apply_light_itn(text) == expected


@pytest.mark.parametrize("text", [
    "前一天",
    "后一天",
    "同一天",
    "每一天",
    "这一天",
    "那一天",
    "某一天",
    "哪一天",
    "一天到晚",
    "一天比一天",
])
def test_itn_preserves_determiner_and_idiomatic_tian(text: str) -> None:
    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("三天前", "3天前"),
    ("两天", "2天"),
    ("一天时间", "1天时间"),
    ("第二天", "第2天"),
])
def test_itn_still_converts_closed_tian_counts(
    text: str, expected: str
) -> None:
    assert apply_light_itn(text) == expected


@pytest.mark.parametrize("text", [
    "同一人",
    "另一人",
    "同一个人",
    "另一个人",
    "小一号",
    "大一号",
    "前一日",
    "后一日",
    "这一日",
    "下一秒",
    "这一秒",
    "每一秒",
])
def test_itn_preserves_determiner_units(text: str) -> None:
    """Determiner phrases such as 同一人 or 下一秒 are not closed counts."""

    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("五号交付", "5号交付"),
    ("二零号座位", "20号座位"),
    ("十三号", "13号"),
    ("十五日之前", "15日之前"),
    ("三秒", "3秒"),
    ("五秒", "5秒"),
    ("总统三人随行", "总统3人随行"),
    ("由一人写入", "由1人写入"),
])
def test_itn_still_converts_closed_unit_counts(
    text: str, expected: str
) -> None:
    assert apply_light_itn(text) == expected
