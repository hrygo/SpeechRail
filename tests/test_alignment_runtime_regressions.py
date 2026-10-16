from __future__ import annotations

import math
import sys
from pathlib import Path
from types import ModuleType

import pytest

from speechrail.application.alignment import validate_alignment
from speechrail.backends import qwen3_alignment_worker as alignment_worker
from speechrail.backends.model_identity import SnapshotIdentity
from speechrail.config.model_catalog import QuantizationSpec
from speechrail.domain.alignment import (
    AlignmentGranularity,
    AlignmentRequest,
    AlignmentResult,
)
from speechrail.domain.audio_timeline import SampleSpan


class _VendorAlignedWord:
    """Minimal shape returned by mlx_qwen3_asr.ForcedAligner.align."""

    def __init__(self, text: object, start_time: object, end_time: object) -> None:
        self.text = text
        self.start_time = start_time
        self.end_time = end_time


class _MlxDtype:
    def __init__(self, name: str) -> None:
        self.name = name

    def __str__(self) -> str:
        return f"mlx.core.{self.name}"


def _align_with_vendor(
    monkeypatch: pytest.MonkeyPatch,
    *,
    text: str,
    vendor_words: tuple[_VendorAlignedWord, ...],
    granularity: AlignmentGranularity = "segment",
    audio_samples: int = 16_000,
    timestamp_quantum_ms: int = 80,
) -> tuple[AlignmentRequest, AlignmentResult]:
    pcm16 = b"\x00\x00" * audio_samples
    core = ModuleType("mlx.core")
    for dtype in ("float16", "float32", "bfloat16", "int8"):
        setattr(core, dtype, _MlxDtype(dtype))
    mlx = ModuleType("mlx")
    mlx.core = core  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx", mlx)
    monkeypatch.setitem(sys.modules, "mlx.core", core)

    class FakeForcedAligner:
        def __init__(self, *, model_path: str, dtype: object) -> None:
            self.dtype = dtype

        def align(
            self, audio: object, text: str, *, language: str
        ) -> tuple[_VendorAlignedWord, ...]:
            assert text == text_arg
            assert language == "zh"
            return vendor_words

    text_arg = text
    mlx_qwen3_asr = ModuleType("mlx_qwen3_asr")
    mlx_qwen3_asr.ForcedAligner = FakeForcedAligner  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx_qwen3_asr", mlx_qwen3_asr)
    monkeypatch.setattr(
        alignment_worker,
        "inspect_model",
        lambda _: SnapshotIdentity(
            family="qwen3_aligner",
            variant="aligner",
            quantization=QuantizationSpec(bits=None, group_size=None, format="none"),
            weight_fingerprint="shape:" + "b" * 64,
        ),
    )
    monkeypatch.setattr(
        alignment_worker, "_timestamp_quantum_seconds",
        lambda _: timestamp_quantum_ms / 1000, raising=False,
    )

    engine = alignment_worker.Qwen3AlignerEngine(
        model_dir=Path("/model"), device="mps", dtype="bfloat16"
    )
    raw = engine.align_text(pcm16, text=text, language="zh")
    request = AlignmentRequest(
        task_id="task-1",
        epoch="epoch-1",
        utterance_id="utterance-1",
        transcript_revision=1,
        pcm16=pcm16,
        span=SampleSpan(0, audio_samples),
        text=text,
        language="zh",
        granularity=granularity,
    )
    result = validate_alignment(
        request,
        tuple((item["text"], item["start"], item["end"]) for item in raw),
    )
    return request, result


@pytest.mark.parametrize("collapsed_tail", [False, True])
def test_model_terminal_timestamp_cell_fits_the_actual_audio_edge(
    monkeypatch: pytest.MonkeyPatch, collapsed_tail: bool,
) -> None:
    words = (
        (_VendorAlignedWord("你", 0.08, 1.52), _VendorAlignedWord("好", 1.52, 1.52))
        if collapsed_tail else
        (_VendorAlignedWord("你", 0.08, 1.44), _VendorAlignedWord("好", 1.44, 1.52))
    )
    request, result = _align_with_vendor(
        monkeypatch, text="你好", vendor_words=words, audio_samples=24_001,
    )
    assert result.failure is None
    assert validate_alignment(
        request, tuple((word.text, word.start_time, word.end_time) for word in words),
    ).failure == "alignment_out_of_bounds"
    assert result.units[-1].audio_span.end == request.span.end
    assert result.units[-1].text_end == len(request.text)
    assert all(u.audio_span.start < u.audio_span.end <= request.span.end for u in result.units)


def test_terminal_timestamp_cell_uses_the_model_declared_grid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    request, result = _align_with_vendor(
        monkeypatch, text="你好", audio_samples=23_840, timestamp_quantum_ms=100,
        vendor_words=(_VendorAlignedWord("你好", 0.1, 1.5),),
    )
    assert result.failure is None
    assert result.units[-1].audio_span.end == request.span.end


@pytest.mark.parametrize(
    "words",
    [(_VendorAlignedWord("你好", 0.08, 1.6),),
     (_VendorAlignedWord("你好", 0.08, 1.51),),
     (_VendorAlignedWord("你好", 1.52, 1.50),),
     (_VendorAlignedWord("你", 0.08, 1.52), _VendorAlignedWord("好", 1.5, 1.52))],
    ids=["next-cell", "off-grid", "reversed", "overlap-outside-audio"],
)
def test_terminal_cell_fit_does_not_hide_invalid_vendor_times(
    monkeypatch: pytest.MonkeyPatch, words: tuple[_VendorAlignedWord, ...],
) -> None:
    _, result = _align_with_vendor(
        monkeypatch, text="你好", vendor_words=words, audio_samples=24_001,
    )
    assert result.failure is not None


@pytest.mark.parametrize("value", [80, 100, 20.0])
def test_timestamp_grid_is_read_from_snapshot_config(tmp_path: Path, value: float) -> None:
    import json

    (tmp_path / "config.json").write_text(json.dumps({"timestamp_segment_time": value}))
    assert alignment_worker._timestamp_quantum_seconds(tmp_path) == value / 1000


@pytest.mark.parametrize("value", [None, True, "80", 0, -80, math.nan, math.inf])
def test_missing_or_invalid_timestamp_grid_fails_closed(tmp_path: Path, value: object) -> None:
    import json

    (tmp_path / "config.json").write_text(json.dumps({"timestamp_segment_time": value}))
    with pytest.raises(RuntimeError, match="timestamp grid"):
        alignment_worker._timestamp_quantum_seconds(tmp_path)


@pytest.mark.parametrize(
    ("text", "vendor_words", "expected_ranges", "expected_spans"),
    (
        (
            "你好",
            (_VendorAlignedWord("你", 0.0, 0.0), _VendorAlignedWord("好", 0.05, 0.3)),
            ((0, 2),),
            ((0, 4_800),),
        ),
        (
            "first middle next",
            (
                _VendorAlignedWord("first", 0.0, 0.05),
                _VendorAlignedWord("middle", 0.05, 0.05),
                _VendorAlignedWord("next", 0.1, 0.2),
            ),
            ((0, 5), (5, 17)),
            ((0, 800), (800, 3_200)),
        ),
        (
            "你好世界",
            (
                _VendorAlignedWord("你", 0.0, 0.05),
                _VendorAlignedWord("好", 0.05, 0.05),
                _VendorAlignedWord("世", 0.06, 0.06),
                _VendorAlignedWord("界", 0.1, 0.2),
            ),
            ((0, 1), (1, 4)),
            ((0, 800), (800, 3_200)),
        ),
        (
            "first last",
            (_VendorAlignedWord("first", 0.0, 0.1), _VendorAlignedWord("last", 0.15, 0.15)),
            ((0, 10),),
            ((0, 2_400),),
        ),
        (
            "你好世界",
            (
                _VendorAlignedWord("你", 0.0, 0.05),
                _VendorAlignedWord("好", 0.05, 0.1),
                _VendorAlignedWord("世", 0.1, 0.1),
                _VendorAlignedWord("界", 0.15, 0.15),
            ),
            ((0, 1), (1, 4)),
            ((0, 800), (800, 2_400)),
        ),
    ),
    ids=("leading", "internal", "consecutive-internal", "trailing", "consecutive-trailing"),
)
def test_segment_alignment_coalesces_collapsed_vendor_units_without_losing_text(
    monkeypatch: pytest.MonkeyPatch,
    text: str,
    vendor_words: tuple[_VendorAlignedWord, ...],
    expected_ranges: tuple[tuple[int, int], ...],
    expected_spans: tuple[tuple[int, int], ...],
) -> None:
    """Segment output may coarsen, but must retain exact text and valid spans."""

    request, result = _align_with_vendor(
        monkeypatch, text=text, vendor_words=vendor_words, granularity="segment"
    )

    assert result.failure is None
    assert [(unit.text_start, unit.text_end) for unit in result.units] == list(expected_ranges)
    assert [
        (unit.audio_span.start, unit.audio_span.end)
        for unit in result.units
        if unit.audio_span is not None
    ] == list(expected_spans)
    assert "".join(request.text[unit.text_start : unit.text_end] for unit in result.units) == text
    assert all(
        left.audio_span is not None
        and right.audio_span is not None
        and left.audio_span.end <= right.audio_span.start
        for left, right in zip(result.units, result.units[1:], strict=False)
    )
    assert all(
        unit.audio_span is not None
        and request.span.start <= unit.audio_span.start < unit.audio_span.end <= request.span.end
        for unit in result.units
    )


def test_all_collapsed_vendor_timestamps_fail_with_a_specific_reason(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _, result = _align_with_vendor(
        monkeypatch,
        text="你好",
        vendor_words=(
            _VendorAlignedWord("你", 0.0, 0.0),
            _VendorAlignedWord("好", 0.0, 0.0),
        ),
    )

    assert result.failure == "alignment_time_resolution_insufficient"
    assert result.units == ()


@pytest.mark.parametrize("granularity", ("word", "character"))
def test_collapsed_vendor_timestamps_do_not_claim_finer_granularity(
    monkeypatch: pytest.MonkeyPatch,
    granularity: AlignmentGranularity,
) -> None:
    _, result = _align_with_vendor(
        monkeypatch,
        text="你好",
        vendor_words=(
            _VendorAlignedWord("你", 0.0, 0.0),
            _VendorAlignedWord("好", 0.05, 0.3),
        ),
        granularity=granularity,
    )

    assert result.failure == "alignment_time_resolution_insufficient"
    assert result.units == ()


@pytest.mark.parametrize("granularity", ("word", "character"))
def test_collapsed_phrase_reports_time_resolution_before_token_shape(
    monkeypatch: pytest.MonkeyPatch,
    granularity: AlignmentGranularity,
) -> None:
    _, result = _align_with_vendor(
        monkeypatch,
        text="hello world",
        vendor_words=(_VendorAlignedWord("hello world", 0.0, 0.0),),
        granularity=granularity,
    )
    assert result.failure == "alignment_time_resolution_insufficient"


def test_invalid_vendor_fields_are_not_silently_replaced_with_empty_tokens(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with pytest.raises(ValueError, match="invalid_alignment"):
        _align_with_vendor(
            monkeypatch,
            text="hello",
            vendor_words=(_VendorAlignedWord("hello", "private malformed timestamp", 0.1),),
        )


@pytest.mark.parametrize(
    ("vendor_words", "expected_failure"),
    (
        ((_VendorAlignedWord("你好", 0.2, 0.1),), "invalid_alignment"),
        ((_VendorAlignedWord("你好", math.nan, 0.1),), "invalid_alignment"),
        ((_VendorAlignedWord("你好", 0.1, math.inf),), "invalid_alignment"),
        ((_VendorAlignedWord("你好", -0.1, 0.1),), "alignment_out_of_bounds"),
        ((_VendorAlignedWord("你好", 0.1, 1.1),), "alignment_out_of_bounds"),
        (
            (
                _VendorAlignedWord("你", 0.2, 0.4),
                _VendorAlignedWord("好", 0.3, 0.5),
            ),
            "alignment_not_monotonic",
        ),
    ),
    ids=("reversed", "nan", "infinite", "negative-start", "past-audio", "overlap"),
)
def test_invalid_vendor_timestamps_fail_closed(
    monkeypatch: pytest.MonkeyPatch,
    vendor_words: tuple[_VendorAlignedWord, ...],
    expected_failure: str,
) -> None:
    _, result = _align_with_vendor(
        monkeypatch, text="你好", vendor_words=vendor_words
    )

    assert result.failure == expected_failure
    assert result.units == ()
