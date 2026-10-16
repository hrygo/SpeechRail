
import pytest

from speechrail.application.asr_window_boundaries import BoundaryEvidenceError, crop_owned_text
from speechrail.domain.alignment import AlignmentUnit
from speechrail.domain.audio_timeline import SampleSpan


def word(a, b, x, y):
    return AlignmentUnit(str(a), a, b, SampleSpan(x, y), "word")


def test_context_crop_uses_actual_word_spans_and_keeps_punctuation():
    assert (
        crop_owned_text(
            "old 正文。 next",
            (word(0, 3, 0, 100), word(4, 6, 100, 200), word(8, 12, 200, 300)),
            SampleSpan(100, 200),
        )
        == "正文。"
    )


def test_word_crossing_owned_boundary_cannot_be_cut():
    with pytest.raises(BoundaryEvidenceError):
        crop_owned_text("crossing", (word(0, 8, 90, 110),), SampleSpan(100, 200))


@pytest.mark.parametrize(
    "units", [(), (word(0, 1, 10, 20), word(1, 2, 10, 20)), (word(0, 1, 10, 20),)]
)
def test_incomplete_or_collapsed_evidence_is_rejected(units):
    with pytest.raises(BoundaryEvidenceError):
        crop_owned_text("中文", units, SampleSpan(0, 100))
