"""Unicode decimal digits accepted by ITN must remain safe and accurate."""
import unicodedata

import pytest

from speechrail.domain.itn import apply_light_itn
from speechrail.domain.voice_quality import transcript_match_score


@pytest.mark.parametrize(("source", "expected"), [
    ("２三点五", "23.5"), ("二３点五", "23.5"), ("٢三点五", "23.5"),
    ("२三点五", "23.5"), ("百分之２十", "20%"), ("百分之٢十", "20%"),
    ("百分之२十", "20%"), ("百分之２三点五", "23.5%"),
    ("二十二点５", "22.5"), ("百分之三点٥", "3.5%"),
    ("５０万元", "５０万元"), ("٥٠万元", "٥٠万元"),
    ("ＡＢＣ １２３ 电话", "ＡＢＣ １２３ 电话"),
])
def test_unicode_number_boundaries(source: str, expected: str) -> None:
    assert apply_light_itn(source) == expected


def test_all_unicode_decimal_digits() -> None:
    for codepoint in range(0x110000):
        char = chr(codepoint)
        if char.isdecimal():
            digit = unicodedata.decimal(char)
            assert apply_light_itn(f"{char}三点五") == f"{digit * 10 + 3}.5"
            assert apply_light_itn(f"百分之三点{char}") == f"3.{digit}%"


def test_quality_match_accepts_unicode_mixed_itn() -> None:
    assert transcript_match_score("23.5", "２三点五") == 1.0
