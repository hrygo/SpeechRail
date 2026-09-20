from __future__ import annotations

import pytest

from speechrail.domain.tts_request import (
    TtsParameterError,
    normalize_tts_language,
    validate_tts_parameters,
)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("auto", "auto"),
        (" zh ", "chinese"),
        ("zh-CN", "chinese"),
        ("en", "english"),
        ("Japanese", "japanese"),
    ],
)
def test_normalize_tts_language_maps_codes_to_vendor_names(
    raw: str, expected: str
) -> None:
    assert normalize_tts_language(raw) == expected


def test_unknown_tts_language_is_rejected_with_stable_code() -> None:
    with pytest.raises(TtsParameterError) as exc_info:
        normalize_tts_language("xx-QQ")

    assert exc_info.value.code == "unsupported_language"
    assert exc_info.value.param == "language"


def test_base_clone_requires_fixed_speed_and_forbids_design_controls() -> None:
    with pytest.raises(TtsParameterError) as exc_info:
        validate_tts_parameters(
            model_variant="base",
            is_clone=True,
            speed=1.25,
            language="zh",
            instruction=None,
            seed=None,
        )
    assert exc_info.value.code == "clone_speed_unsupported"

    with pytest.raises(TtsParameterError) as exc_info:
        validate_tts_parameters(
            model_variant="base",
            is_clone=True,
            speed=1.0,
            language="zh",
            instruction="warm",
            seed=None,
        )
    assert exc_info.value.code == "clone_instruction_unsupported"


def test_validation_returns_canonical_language_for_voice_design() -> None:
    result = validate_tts_parameters(
        model_variant="voice_design",
        is_clone=False,
        speed=1.25,
        language="en",
        instruction="a calm narrator",
        seed=7,
    )

    assert result.language == "english"
    assert result.speed == 1.25
