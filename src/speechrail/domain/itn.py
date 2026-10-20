"""Light Inverse Text Normalization (ITN) and dynamic hotword prompt composition."""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Sequence

_DIGITS_MAP = {
    "零": 0,
    "一": 1,
    "二": 2,
    "两": 2,
    "三": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
}

# The ASCII half of `_DIGITS_MAP`, inverted. `两` is deliberately absent: `二`
# is the positional spelling of 2.
_DIGIT_SPELLINGS = {str(value): char for value, char in enumerate("零一二三四五六七八九")}

_YEAR_RE = re.compile(r"([零一二三四五六七八九]{4})年")
_PERCENT_RE = re.compile(r"百分之([零一二两三四五六七八九十百千万点\d]+)")
_DECIMAL_RE = re.compile(
    r"([零一二两三四五六七八九十百千万\d]+)点([零一二两三四五六七八九十\d]+)"
)
_CN_NUM_RE = re.compile(r"[零一二两三四五六七八九十百千万亿]+")
_NUMERAL_CHARS = frozenset("零一二两三四五六七八九十百千万亿")
# These suffixes make a spoken value approximate: 百分之五十几 / 二十来 percent.
# The digits before them are a bound, not the value, so they are left as words.
_APPROXIMATE_SUFFIXES = frozenset("几多余")
# 来 is approximate in 二十来个 / 五十来岁, but it starts the ordinary verb
# 来自 / 来看 / 来说 in 百分之五十来自学校. Only the former is approximate.
_LAI_VERB_CONTINUATIONS = frozenset("自看说讲源到回临")
# A decimal followed by these characters is an idiom, a clock expression or an
# approximation, not a closed decimal value: 一点一点, 三点一刻, 三点五几,
# 九点九分. 分 is included because NUM点NUM分 is a clock reading.
_DECIMAL_BLOCKERS = frozenset("点滴刻线几多余分")
# The fractional part is normally digit-by-digit. A fraction containing 十 can
# be either a clock (七点四十) or a closed decimal with a unit (三点十四秒);
# the callback decides from the right context instead of truncating the run.
_DECIMAL_DIGIT_CHARS = frozenset("零一二三四五六七八九0123456789")
# Exactly two fractional digits can be clock minutes (十点零五). Only one of
# these continuations proves that the run is a measurement rather than a time.
_DECIMAL_MEASURE_CONTINUATIONS = frozenset(
    "元美米公厘毫英平立岁号楼倍秒度克升吨瓦伏安欧焦卡帕赫牛字位个次天月日万%％到至~-—"
)
_UNIT_BOUNDARIES = frozenset("，。！？；：、,.!?;: \n\t”’）)】》")
# A length or duration unit followed by another numeral is an implicit
# decimal: 一米八 is 1.8 m, 五公里二 is 5.2 km, 三秒五 is 3.5 s. The unit rule
# only sees the first half and would emit 1米八 / 5公里二 / 3秒五, which is
# worse than leaving the spoken form untouched. 号 and 楼 are excluded because
# 五号楼三单元 is two noun phrases, not one measurement.
_IMPLICIT_DECIMAL_UNITS = frozenset({"米", "公里", "秒"})
# 三番五次 / 三回五次 / 三遍五次 enumerate the same count with a classifier;
# converting only the 次 half leaves a mixed 三番5次.
_COUNT_IDIOM_PRECEDERS = frozenset("番回遍趟遭")
# 次 is a count in 一次会议 / 连续两次一致, but a lexical or ordinal morpheme
# in these closed technical phrases. Keeping the spoken form is the safe
# failure mode: a missed conversion loses digits, while 1次性 / 2次开发
# corrupts the sentence. These exact prefixes are an explicit blacklist; the
# positive count list below decides the remaining cases.
_CI_LEXICAL_TERMS = frozenset({
    "一次性",
    "一次函数",
    "一次方程",
    "一次项",
    "一次型",
    "一次能源",
    "一次电池",
    "一次设备",
    "一次回路",
    "一次系统",
    "一次文献",
    "一次信息",
    "一次成型",
    "二次开发",
    "二次加工",
    "二次分配",
    "二次污染",
    "二次创业",
    "二次利用",
    "二次封装",
    "二次验证",
    "二次确认",
    "二次排序",
    "二次压缩",
    "二次编码",
    "二次解码",
    "二次采样",
    "二次回归",
    "二次规划",
    "二次曲线",
    "二次项",
    "二次型",
    "二次判断",
    "二次绑定",
    "二次量化",
    "二次根式",
    "二次幂",
    "三次产业",
    "二次启动",
    "二次加载",
    "二次构建",
    "二次写入",
    "二次训练",
    "二次推理",
    "二次转写",
    "二次处理",
})
# 次 is a count in 第一次, at a boundary (执行一次。), or before a closed count
# continuation (一次会议 / 两次独立). 二次感染 / 二次伤害 / 二次销售 are
# secondary-event compounds, not "two times"; an unseen continuation is kept.
_CI_COUNT_CONTINUATIONS = frozenset({
    "一致",
    "会议",
    "请求",
    "提交",
    "调用",
    "重试",
    "重复",
    "尝试",
    "独立",
    "真实",
    "失败",
    "成功",
    "运行",
    "审查",
    "复核",
    "维护",
    "迭代",
    "采样",
    "训练",
    "推理",
    "转写",
    "机会",
    "面试",
    "比赛",
    "回答",
    "回声",
    "有界",
    "有效",
    "完成",
    "处理",
    "测试",
    "试读",
    "试运行",
    "发送",
    "读取",
    "写入",
    "启动",
    "关闭",
    "加载",
    "部署",
    "构建",
})
# 人 is a count unit in ordinary speech, but these continuations close a
# lexical idiom or title: 万人空巷 / 千人一面 / 一人得道 / 两人三足. A partial
# rewrite corrupts the phrase, so the closed set keeps the spoken form.
_REN_IDIOM_SUFFIXES = frozenset({
    "空巷",
    "迷",
    "坑",
    "敌",
    "一面",
    "一首",
    "得道",
    "做事",
    "当",
    "之下",
    "之上",
    "三足",
    "九志",
})
# Determiners and deictic prefixes turn 一+unit into a phrase (`下一次`,
# `每一天`, `同一人`), not a closed count. `比` covers 一天比一天.
_DETERMINER_PREFIXES = frozenset("每这那某哪同上前后下另何比")
_DETERMINER_UNITS = frozenset({"次", "天", "号", "日", "秒"})
# A bare month is a date label only when it ends the phrase or is followed by
# an explicit month/date continuation. A following numeral alone is ambiguous:
# 二月二/九月九 are festival names, and a partial rewrite such as 2月二 is
# worse than leaving the spoken form untouched.
_MONTH_CONTINUATIONS = frozenset("份初底中末尾半里前上下之到起间")
# 日 is a duration/date unit only with an explicit continuation or after a
# month/ordinal. 五日京兆 / 十日终焉 are lexical titles, not five/ten days.
_DAY_CONTINUATIONS = frozenset("游内之前后到起间")
_DAY_NUM_RE = re.compile(r"[零一二两三四五六七八九十百千万亿\d]+")
# A bare 分 at a boundary is only a score when the left context says so.
# `anchor 二分` and `二分、匹配` are the method, not two points.
_SCORE_CONTEXT_RE = re.compile(
    r"(?:得了|得|考了|考|拿了|拿|扣了|扣|加了|加|减了|减|评了|评|打了|打|进了|进|赢了|赢|输了|输|满分|得分|比分|总分)$"
)
# Adjacent digits can be an approximation or stutter. A trailing digit after
# 百 or a larger magnitude can omit a place (三千五元), cross a price boundary
# (五百一个), or belong to ordinary words (万一人家). Preserve these matches
# rather than inventing a precise value. Explicit decimal/year rules below
# retain their positional digit handling.
_AMBIGUOUS_QUANTITY_RE = re.compile(
    r"(?<![零一二两三四五六七八九])[一二两三四五六七八九]{2}(?![零一二两三四五六七八九])"
    r"|[百千万亿][一二两三四五六七八九1-9]\Z"
)

# `点` is deliberately absent. In the repository corpus 46 of the 86 `X点`
# matches are ordinary words (`这一点`, `短一点`, `有一点`), while the numeric
# ones are ambiguous (`三点开会` is a clock time, `十点` is either 10:00 or
# "ten points"). Dropping a unit only loses conversions; keeping it corrupts
# sentences. `分` survives behind the guard in `_convert_with_unit` because
# `三分钟` is a duration while `十分满意` / `百分百` / `百分之` are not numbers.
# `分之` is a fraction marker, so 分 is excluded in front of it. The leading
# lookbehind keeps 数十秒 / 几十秒 / 数十万个 out: 数 and 几 are not numerals,
# so the match used to start at the magnitude and report 10. The numeral
# characters are in the lookbehind too, so a blocked run cannot restart at a
# later magnitude (`数十万个` used to fall through to `万个` -> 10000个).
_UNIT_RE = re.compile(
    # The lookbehind keeps the numeral run from starting where one already
    # precedes it. It has to exclude **Unicode decimal digits too**: a recogniser that
    # normalises speech to digits emits `50万元`, and without a digit guard here the
    # `万元` matched on its own -- `chinese_to_int("万")` is 10000, and that was
    # concatenated in front of the `50`, so the transcript read `5010000元`,
    # two orders of magnitude off. A number that is already written needs no
    # conversion, which is also what `20万台` and `1000公里` already relied on.
    r"(?<![\d数几零一二两三四五六七八九十百千万亿])([零一二两三四五六七八九十百千万亿]+)"
    r"(元|美元|米|公里|岁|号|楼|月|日|倍|个|人|次|天|秒|分(?![之]))"
)

# A Chinese numeral run that contains at least one magnitude word is *arithmetic*:
# 二十二 is 22 and 五千三百 is 5300. A run with no magnitude word is a positional
# digit sequence instead -- 三六九 is the digit string 369, 二零二六 is 2026 -- and
# must be transliterated digit by digit rather than summed. `_chinese_to_int`
# already draws exactly this line, so the split belongs next to it.
_CN_MAGNITUDE_RE = re.compile(
    r"[零一二两三四五六七八九十百千万亿]*[十百千万亿](?![分之])[零一二两三四五六七八九十百千万亿]*"
    # `分之` is a fraction marker, not a magnitude in front of a unit: 百分之九十九
    # is 99%, so matching the leading 百 rewrote it to `100分之99`. Same reason
    # `_UNIT_RE` withholds 分 behind a digit guard.
)


def _chinese_year_to_arabic(match: re.Match[str]) -> str:
    digits = match.group(1)
    arabic = "".join(str(_DIGITS_MAP.get(d, d)) for d in digits)
    return f"{arabic}年"


def _chinese_to_int(cn_str: str) -> int:
    """Convert Chinese numeral string to integer (supports up to 亿)."""
    if not cn_str:
        return 0
    cn_str = _fold_decimal_digits(cn_str)
    # If already all digits
    if cn_str.isdigit():
        return int(cn_str)

    # Both callers reach this function through `_PERCENT_RE` / `_DECIMAL_RE`,
    # whose character classes admit decimal digits, so a recogniser that
    # normalises only part of a number hands us a mixed run such as `2三点五`
    # or `百分之2十`. Everything below is written against Chinese numerals, so
    # the digits are folded into their Chinese spelling first. Indexing
    # `_DIGITS_MAP` with them raised `KeyError` and aborted normalisation for
    # every batch and realtime transcript of that shape, and the accumulator
    # dropped them without a word (`百分之2十` -> `10%`).
    cn_str = "".join(_DIGIT_SPELLINGS.get(char, char) for char in cn_str)

    # Spoken digit sequences such as ``二零`` are positional, not additive.  The
    # unit-based accumulator below would otherwise keep only the final digit.
    if not any(char in cn_str for char in "十百千万亿"):
        return int("".join(str(_DIGITS_MAP[char]) for char in cn_str))

    units = {"十": 10, "百": 100, "千": 1000, "万": 10000, "亿": 100000000}
    total = 0
    section = 0
    num = 0
    # A magnitude with no digit in front of it stands for one: 十个人 is 10
    # people, 百分之 is 100 percent. Only 十 had this rule, so 百/千/万/亿
    # evaluated to 0 on their own and rewrote 百分之 to 0分百. `seen_any`
    # stops the rule from firing a second time inside one numeral, which is
    # what made 万亿 come out as 1000100000000.
    seen_any = False

    for char in cn_str:
        if char in _DIGITS_MAP:
            num = _DIGITS_MAP[char]
            seen_any = True
        elif char in units:
            if num == 0 and not seen_any:
                num = 1
            if char == "亿":
                # 亿 scales everything accumulated so far, not just the open
                # section. Scaling only the section made 万亿 come out as
                # 100010000 instead of 1e12.
                total = (total + section + num) * units[char]
                section = 0
            else:
                if char == "万":
                    section = (section + num) * units[char]
                    total += section
                    section = 0
                else:
                    section += num * units[char]
            seen_any = True
            num = 0

    return total + section + num


def _fold_decimal_digits(text: str) -> str:
    """Fold decimal digits accepted by Unicode digit regexes without rewriting other text."""
    return "".join(
        str(unicodedata.decimal(char)) if char.isdecimal() else char for char in text
    )


def _is_approximate_suffix(text: str, end: int) -> bool:
    suffix = text[end : end + 1]
    if suffix in _APPROXIMATE_SUFFIXES:
        return True
    return suffix == "来" and text[end + 1 : end + 2] not in _LAI_VERB_CONTINUATIONS


def _month_follows_explicit_day(text: str, end: int) -> bool:
    day = _DAY_NUM_RE.match(text, end)
    return day is not None and text[day.end() : day.end() + 1] in {"号", "日"}


def _percent_to_arabic(match: re.Match[str]) -> str:
    raw = _fold_decimal_digits(match.group(1))
    # 百分之五十几 / 百分之二十来 name an approximate range. Rewriting the
    # closed prefix to 50% / 20% and leaving 几 / 来 behind corrupts the phrase.
    if _is_approximate_suffix(match.string, match.end()):
        return match.group(0)
    if "点" in raw:
        if raw.count("点") != 1 or raw.endswith("点"):
            return match.group(0)
        parts = raw.split("点", 1)
        if not set(parts[1]) <= _DECIMAL_DIGIT_CHARS:
            return match.group(0)
        if match.string[match.end() : match.end() + 1] == "分":
            return match.group(0)
        int_part = _chinese_to_int(parts[0])
        dec_part = "".join(str(_DIGITS_MAP.get(c, c)) for c in parts[1])
        return f"{int_part}.{dec_part}%"
    if _AMBIGUOUS_QUANTITY_RE.search(raw):
        return match.group(0)
    try:
        val = _chinese_to_int(raw)
        return f"{val}%"
    except Exception:
        return match.group(0)


def _decimal_to_arabic(match: re.Match[str]) -> str:
    # 点 can join ordinary phrases or clock alternatives: 一点一点,
    # 三点一线, 五点六点. Inspect the complete greedy match's boundary in
    # the callback so rejection cannot backtrack into a shorter decimal.
    tail = match.string[match.end() : match.end() + 1]
    if tail in _DECIMAL_BLOCKERS or _is_approximate_suffix(match.string, match.end()):
        return match.group(0)
    # A magnitude character directly after the match means it stopped in the
    # middle of a spoken numeral: 三点一百 is not 3.1 plus a loose 百. 万/亿
    # are the exception, because 三点五万元 is a decimal quantity followed by
    # its magnitude. 十 is consumed by the regex and validated below.
    if (
        tail in _NUMERAL_CHARS
        and tail not in {"万", "亿"}
        and not (
            tail in {"十", "百", "千"}
            and match.string[match.end() + 1 : match.end() + 2] in {"万", "亿"}
        )
    ):
        return match.group(0)
    int_str, dec_str = (_fold_decimal_digits(part) for part in match.group(1, 2))
    if not set(dec_str) <= _DECIMAL_DIGIT_CHARS:
        # A magnitude word inside the fraction can only be a closed decimal
        # when an explicit unit follows: 三点十四秒 is 3.14秒, while 七点四十
        # and 七点四十分 are clock readings.
        if tail not in _DECIMAL_MEASURE_CONTINUATIONS:
            return match.group(0)
        try:
            dec_digits = str(_chinese_to_int(dec_str))
        except (KeyError, ValueError):
            return match.group(0)
    else:
        dec_digits = "".join(str(_DIGITS_MAP.get(c, c)) for c in dec_str)
    int_val = _chinese_to_int(int_str) if not int_str.isdigit() else int(int_str)
    # 10.05 and 10:05 are the same string in speech. A two-digit fraction is
    # only a decimal when the right side proves it (单位, %, 万, a range).
    if (
        len(dec_digits) == 2
        and int(dec_digits) <= 59
        and tail not in _DECIMAL_MEASURE_CONTINUATIONS
    ):
        return match.group(0)
    return f"{int_val}.{dec_digits}"


def apply_light_itn(text: str) -> str:
    """Apply rule-based lightweight Inverse Text Normalization (ITN) to transcript text."""
    if not text:
        return text

    # 1. Years: 二零二六年 -> 2026年
    text = _YEAR_RE.sub(_chinese_year_to_arabic, text)

    # 2. Percentages: 百分之五十 -> 50%, 百分之三点五 -> 3.5%
    text = _PERCENT_RE.sub(_percent_to_arabic, text)

    # 3. Decimals: 三点一四 -> 3.14
    text = _DECIMAL_RE.sub(_decimal_to_arabic, text)

    # 4. Standard Chinese numbers with unit contexts (元, 美元, 米, 公里, 岁, 号, 楼, 月, 日)
    def _convert_with_unit(m: re.Match[str]) -> str:
        cn_num = m.group(1)
        unit = m.group(2)
        next_char = m.string[m.end() : m.end() + 1]
        previous_char = m.string[m.start() - 1 : m.start()] if m.start() else ""
        # An implicit decimal keeps its whole spoken form: only rewriting the
        # 米/公里/秒 half turns 一米八 into 1米八.
        if unit in _IMPLICIT_DECIMAL_UNITS and next_char in _NUMERAL_CHARS:
            return m.group(0)
        # 三次 in 三番五次 belongs to an enumeration, not to an isolated count.
        # The classifier has to follow a numeral: 返回一次 is the verb 返回 plus
        # an ordinary count and still converts.
        if unit == "次" and previous_char in _COUNT_IDIOM_PRECEDERS:
            before_classifier = (
                m.string[m.start() - 2 : m.start() - 1] if m.start() >= 2 else ""
            )
            if before_classifier in _NUMERAL_CHARS or before_classifier == "几":
                return m.group(0)
        # 上百人 / 上万人 bound an approximate quantity from above; 上100人 and
        # 上10000人 state a different thing. 三 in 上三楼 is a real count and
        # still converts.
        if previous_char == "上" and all(char in "百千万亿" for char in cn_num):
            return m.group(0)
        # Preserve the natural classifier phrase 一个 (有一个 / 每一个).
        # Larger explicit quantities such as 十一个 still become 11个.
        if cn_num == "一" and unit == "个":
            return m.group(0)
        # 统一 is an ordinary word, including before 分配 or 人员.
        if cn_num == "一" and previous_char == "统":
            return m.group(0)
        if _AMBIGUOUS_QUANTITY_RE.search(cn_num):
            return m.group(0)
        if unit == "次" and any(
            m.string.startswith(term, m.start()) for term in _CI_LEXICAL_TERMS
        ):
            return m.group(0)
        # 下一次 / 每一次 / 这一次 / 同一次 are determiner phrases; 一次只 is
        # an adverb ("at a time"). Neither is a closed count.
        if (
            cn_num == "一"
            and unit in _DETERMINER_UNITS
            and (
                previous_char in _DETERMINER_PREFIXES
                or (unit == "号" and previous_char in {"小", "大"})
            )
        ):
            return m.group(0)
        if cn_num == "一" and unit == "次" and next_char == "只":
            return m.group(0)
        # Outside an ordinal, a boundary, or a closed count continuation, 次
        # is more likely a technical prefix (二次感染/二次伤害/二次销售).
        if unit == "次":
            count = (
                previous_char == "第"
                or not next_char
                or next_char in _UNIT_BOUNDARIES
                or any(
                    m.string.startswith(term, m.end())
                    for term in _CI_COUNT_CONTINUATIONS
                )
            )
            if not count:
                return m.group(0)
        if cn_num == "一" and unit == "人" and previous_char in {"同", "另"}:
            return m.group(0)
        if unit == "人" and any(
            m.string.startswith(suffix, m.end()) for suffix in _REN_IDIOM_SUFFIXES
        ):
            return m.group(0)
        # 二人转 / 三人行 / 三人成虎 are lexical or idiomatic, not counts.
        if unit == "人" and (
            (cn_num == "二" and next_char == "转")
            or (cn_num == "三" and next_char in {"行", "成"})
        ):
            return m.group(0)
        # A single digit before 元 is usually a term (二元组/一元论/同一元素).
        # Currency needs either an explicit place or a money continuation.
        if (
            unit == "元"
            and len(cn_num) == 1
            and cn_num not in "十百千万亿"
            and next_char not in {"钱", "整", "块"}
        ):
            return m.group(0)
        # 一次次 / 一天天 / 一秒秒 repeat the classifier as an adverb; the
        # first unit is not a separate count.
        if next_char == unit:
            return m.group(0)
        # 万岁 / 千岁 are titles or exclamations, not ages.
        if unit == "岁" and cn_num in {"万", "千"}:
            return m.group(0)
        # 一日三秋 / 一日千里 / 一日为师 / 一日不见 use 日 inside an idiom.
        if unit == "日" and (
            next_char in _NUMERAL_CHARS
            or next_char in {"为", "不", "谈"}
            or (cn_num == "一" and next_char == "之")
        ):
            return m.group(0)
        # 三天两头 / 一天一个样 / 一天一天 use 天 inside an idiom or repeat it.
        if unit == "天":
            tail = m.string[m.end() : m.end() + 2]
            if tail in {"两头", "一个", "到晚", "比一"} or (
                cn_num == "一" and tail == "一天"
            ):
                return m.group(0)
        # 一次又一次 / 一次一次 / 一次一个 / 两次三番 / 三次五次 use 次
        # inside an adverb or an approximate list. 两次一致 is a real count
        # and must still convert.
        if unit == "次":
            tail = m.string[m.end() : m.end() + 2]
            previous = m.string[max(0, m.start() - 2) : m.start()]
            if (
                (cn_num == "一" and next_char == "又")
                or tail in {"一次", "一个", "一步", "一遍", "一人", "三番"}
                or (
                    len(tail) == 2
                    and tail[1] == "次"
                    and tail[0] in _NUMERAL_CHARS
                )
                or (
                    len(previous) == 2
                    and previous[1] == "次"
                    and previous[0] in _NUMERAL_CHARS
                )
            ):
                return m.group(0)
        # 一次又一次 / 一次一次 / 一天一天 repeat a one-off count; the second
        # copy is not a separate measurement.
        if (
            cn_num == "一"
            and unit in {"日", "天", "次"}
            and (
                m.string[max(0, m.start() - 2) : m.start()] == cn_num + unit
                or m.string[max(0, m.start() - 1) : m.start()] == "又"
            )
        ):
            return m.group(0)
        # 二次方程 / 二次函数 / 二次元 use 次 as a degree or ordinal prefix.
        if unit == "次" and next_char in {"方", "函", "元"}:
            return m.group(0)
        # A month followed by ordinary text can be a title or idiom (六月飞雪,
        # 八月未央, 五月花). Convert only an explicit month/date continuation,
        # a complete date such as 三月二十三日, or a phrase boundary.
        if unit == "月" and next_char:
            numeral_next = next_char in _NUMERAL_CHARS or next_char.isdecimal()
            if (
                next_char not in _MONTH_CONTINUATIONS
                and next_char not in _UNIT_BOUNDARIES
                and not (
                    numeral_next and _month_follows_explicit_day(m.string, m.end())
                )
            ):
                return m.group(0)
        # 日 likewise needs a closed duration/date context. In particular,
        # 二月二 must not become 2月二 and then imply an invented day.
        if (
            unit == "日"
            and previous_char not in {"月", "第"}
            and next_char not in _DAY_CONTINUATIONS
        ):
            return m.group(0)
        # 一元复始 is an idiom, and 一元二次方程 uses 元 as a degree marker.
        if unit == "元" and (next_char == "复" or next_char in _NUMERAL_CHARS):
            return m.group(0)
        # 分 is a lexical morpheme unless a measurement continuation or a
        # score context shows that it is the unit. A bare boundary is not
        # enough: 二分 alone is the bisection method. NUM点NUM分 is a clock.
        if unit == "分":
            if previous_char == "点":
                return m.group(0)
            measurement = next_char in {"钟", "钱"} or (
                next_char == "的" and cn_num != "十"
            )
            if not measurement:
                boundary = not next_char or next_char in _UNIT_BOUNDARIES
                if not boundary or not _SCORE_CONTEXT_RE.search(
                    m.string[: m.start()]
                ):
                    return m.group(0)
            # 十分满意 / 百分百 / 百分之 / 百分点 are quantity words. 分钟 and
            # 分钱 are measurements even when the numeral is a bare magnitude.
            if (
                not any(char in _DIGITS_MAP for char in cn_num)
                and next_char not in {"钟", "钱"}
            ):
                return m.group(0)
        num = _chinese_to_int(cn_num)
        return f"{num}{unit}"

    return _UNIT_RE.sub(_convert_with_unit, text)


def resolve_chinese_magnitudes(text: str) -> str:
    """Rewrite magnitude-bearing Chinese numerals as arabic integers.

    ``apply_light_itn`` deliberately leaves a bare magnitude run alone: outside a
    unit or decimal context, `十点` may be a clock time and `十分` is an ordinary
    word, so guessing there corrupts transcripts. Probe comparison has no such
    ambiguity -- both sides of the comparison are the same sentence, one written
    with arabic digits and one spelled out by the ASR -- so a magnitude run there
    is unambiguously a number and must be evaluated before it can be compared.

    Only the magnitude run is rewritten; surrounding text is returned unchanged.
    """
    if not text:
        return text

    def _replace(match: re.Match[str]) -> str:
        run = _fold_decimal_digits(match.group(0))
        try:
            return str(_chinese_to_int(run))
        except (KeyError, ValueError):
            return match.group(0)

    return _CN_MAGNITUDE_RE.sub(_replace, text)


def compose_hotword_prompt(prompt: str, keywords: Sequence[str] | None) -> str:
    """Compose dynamic hotwords/keywords prefix into the transcription prompt."""
    if not keywords:
        return prompt or ""

    clean_keywords = [k.strip() for k in keywords if isinstance(k, str) and k.strip()]
    if not clean_keywords:
        return prompt or ""

    # Deduplicate while preserving order
    seen = set()
    unique_keywords = []
    for k in clean_keywords:
        if k not in seen:
            seen.add(k)
            unique_keywords.append(k)

    hotword_prefix = "Key terms: " + ", ".join(unique_keywords) + "。"
    if prompt and prompt.strip():
        combined = hotword_prefix + " " + prompt.strip()
    else:
        combined = hotword_prefix

    # Bound prompt to safe max length (2000 chars)
    return combined[:2000]


__all__ = ["apply_light_itn", "compose_hotword_prompt", "resolve_chinese_magnitudes"]
