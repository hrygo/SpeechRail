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
_PERCENT_RE = re.compile(r"百分之([零一二三四五六七八九十百千万点\d]+)")
_DECIMAL_RE = re.compile(r"([零一二三四五六七八九十百千万\d]+)点([零一二三四五六七八九\d]+)")
_CN_NUM_RE = re.compile(r"[零一二两三四五六七八九十百千万亿]+")

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


def _percent_to_arabic(match: re.Match[str]) -> str:
    raw = _fold_decimal_digits(match.group(1))
    if "点" in raw:
        parts = raw.split("点", 1)
        int_part = _chinese_to_int(parts[0])
        dec_part = "".join(str(_DIGITS_MAP.get(c, c)) for c in parts[1])
        return f"{int_part}.{dec_part}%"
    try:
        val = _chinese_to_int(raw)
        return f"{val}%"
    except Exception:
        return match.group(0)


def _decimal_to_arabic(match: re.Match[str]) -> str:
    int_str, dec_str = (_fold_decimal_digits(part) for part in match.group(1, 2))
    int_val = _chinese_to_int(int_str) if not int_str.isdigit() else int(int_str)
    dec_val = "".join(str(_DIGITS_MAP.get(c, c)) for c in dec_str)
    return f"{int_val}.{dec_val}"


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
        # A bare magnitude in front of 分 is a quantity word, not a number:
        # 十分满意, 百分百, 百分之, 百分点. `三分钟` still converts because 三
        # carries a digit.
        if unit == "分" and not any(char in _DIGITS_MAP for char in cn_num):
            return m.group(0)
        num = _chinese_to_int(cn_num)
        return f"{num}{unit}"

    return _UNIT_RE.sub(_convert_with_unit, text)


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


__all__ = ["apply_light_itn", "compose_hotword_prompt"]
