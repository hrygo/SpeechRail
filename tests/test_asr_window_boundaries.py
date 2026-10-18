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


def test_coalesced_alignment_is_cropped_only_as_complete_units():
    units = (
        AlignmentUnit("left", 0, 4, SampleSpan(0, 80), "segment"),
        AlignmentUnit("owned", 4, 7, SampleSpan(110, 190), "segment"),
        AlignmentUnit("right", 7, 12, SampleSpan(210, 300), "segment"),
    )
    assert crop_owned_text("old 正文。 next", units, SampleSpan(100, 200)) == "正文。"


@pytest.mark.parametrize("start,end", [(90, 110), (190, 210), (90, 210)])
def test_coalesced_unit_crossing_boundary_is_never_split(start, end):
    units = (AlignmentUnit("phrase", 0, 6, SampleSpan(start, end), "segment"),)
    with pytest.raises(BoundaryEvidenceError, match="word_crosses_owned_boundary"):
        crop_owned_text("phrase", units, SampleSpan(100, 200))


async def _check_grid_tied_tokens(
    collapsed_seconds,
    expected_scope,
):
    import asyncio
    from contextlib import asynccontextmanager

    from speechrail.application.alignment import FixedTextAligner
    from speechrail.application.asr_window_boundaries import WindowBoundaryReview
    from speechrail.domain.asr_window import WindowDecodeRequest, WindowDecodeResult, WindowIdentity

    class Tokens:
        async def align_text(self, pcm, *, text, language):
            return (
                ("old", 0.0, 0.5),
                ("o", collapsed_seconds, collapsed_seconds),
                ("kay", 1.1, 1.5),
                ("next", 2.0, 2.5),
            )

    class Admission:
        @asynccontextmanager
        async def reserve(self, *args, **kwargs):
            yield

    class Decoder:
        calls = 0

        async def decode(self, request):
            self.calls += 1
            return WindowDecodeResult(
                request.identity,
                request.attempt_id,
                request.input_span,
                "okay",
                "English",
                True,
            )

    identity = WindowIdentity("session", 1, "window")
    owned = SampleSpan(16000, 32000)
    request = WindowDecodeRequest(
        identity, "initial", "review", SampleSpan(0, 48000), b"\0\0" * 48000
    )
    decoded = WindowDecodeResult(
        identity, "initial", request.input_span, "old okay next", "English", True
    )
    decoder = Decoder()
    review = WindowBoundaryReview(
        decoder=decoder,
        aligner=FixedTextAligner(Tokens()),
        admission=Admission(),
        governor=Admission(),
    )
    text, scope = await review(request, decoded, owned, asyncio.get_running_loop().time() + 1)
    assert (text, scope) == ("okay", expected_scope)
    assert decoder.calls == (0 if expected_scope == "contextual" else 1)


@pytest.mark.parametrize(
    "collapsed_seconds,expected_scope", [(1.0, "contextual"), (0.9, "owned_only")]
)
def test_grid_tied_tokens_retain_whole_text_without_unnecessary_asr_retry(
    collapsed_seconds, expected_scope
):
    import asyncio

    asyncio.run(_check_grid_tied_tokens(collapsed_seconds, expected_scope))
