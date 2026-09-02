"""Light Inverse Text Normalization (ITN) and dynamic hotword prompt composition."""

from __future__ import annotations

import re
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

_YEAR_RE = re.compile(r"([零一二三四五六七八九]{4})年")
_PERCENT_RE = re.compile(r"百分之([零一二三四五六七八九十百千万点\d]+)")
_DECIMAL_RE = re.compile(r"([零一二三四五六七八九十百千万\d]+)点([零一二三四五六七八九\d]+)")
_CN_NUM_RE = re.compile(r"[零一二两三四五六七八九十百千万亿]+")


def _chinese_year_to_arabic(match: re.Match[str]) -> str:
    digits = match.group(1)
    arabic = "".join(str(_DIGITS_MAP.get(d, d)) for d in digits)
    return f"{arabic}年"


def _chinese_to_int(cn_str: str) -> int:
    """Convert Chinese numeral string to integer (supports up to 亿)."""
    if not cn_str:
        return 0
    # If already all digits
    if cn_str.isdigit():
        return int(cn_str)

    units = {"十": 10, "百": 100, "千": 1000, "万": 10000, "亿": 100000000}
    total = 0
    section = 0
    num = 0

    for char in cn_str:
        if char in _DIGITS_MAP:
            num = _DIGITS_MAP[char]
        elif char == "十":
            if num == 0:
                num = 1
            section += num * 10
            num = 0
        elif char in ("百", "千"):
            section += num * units[char]
            num = 0
        elif char == "万":
            section = (section + num) * 10000
            total += section
            section = 0
            num = 0
        elif char == "亿":
            section = (section + num) * 100000000
            total += section
            section = 0
            num = 0

    return total + section + num


def _percent_to_arabic(match: re.Match[str]) -> str:
    raw = match.group(1)
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
    int_str, dec_str = match.group(1), match.group(2)
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
        try:
            num = _chinese_to_int(cn_num)
            return f"{num}{unit}"
        except Exception:
            return m.group(0)

    unit_pattern = re.compile(
        r"([零一二两三四五六七八九十百千万亿]+)(元|美元|米|公里|岁|号|楼|月|日|倍|个|人|次|天|分|秒|点)"
    )
    return unit_pattern.sub(_convert_with_unit, text)


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
