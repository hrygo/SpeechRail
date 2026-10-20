"""Preserve natural Chinese classifier spelling without changing numeric values."""

import pytest

from speechrail.domain.itn import apply_light_itn


@pytest.mark.parametrize("text", ["有一个问题", "还有一个", "没有一个", "每一个人"])
def test_preserves_chinese_one_with_generic_classifier(text: str) -> None:
    assert apply_light_itn(text) == text


@pytest.mark.parametrize(("text", "expected"), [
    ("有十一个问题", "有11个问题"),
    ("有一百零一个", "有101个"),
    ("有1个问题", "有1个问题"),
    ("一元钱和一月", "1元钱和1月"),
])
def test_preserves_explicit_numeric_conversion(text: str, expected: str) -> None:
    assert apply_light_itn(text) == expected
