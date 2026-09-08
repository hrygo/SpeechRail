from __future__ import annotations

from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.http.formatters import format_diarized, format_verbose


def test_verbose_segment_matches_openai_schema_with_honest_null_confidence_fields() -> None:
    result = TranscriptResult(
        request_id="request",
        model_id="model",
        text="你好",
        language="Chinese",
        duration_ms=1000,
        segments=(TranscriptSegment(id=0, start_ms=0, end_ms=1000, text="你好"),),
    )

    payload = format_verbose(result)
    segment = payload["segments"][0]

    assert segment["id"] == 0
    assert segment["start"] == 0.0
    assert segment["end"] == 1.0
    for key in (
        "seek",
        "tokens",
        "temperature",
        "avg_logprob",
        "compression_ratio",
        "no_speech_prob",
    ):
        assert key in segment, key
        assert segment[key] is None, key
    assert payload["language"] == "chinese"


def test_diarized_response_uses_the_native_openai_segment_shape() -> None:
    result = TranscriptResult(
        request_id="r1",
        model_id="speechrail/qwen3-asr-1.7b",
        text="你好。再见。",
        language="zh",
        duration_ms=1600,
        segments=(
            TranscriptSegment(
                id=0, start_ms=0, end_ms=800, text="你好。", speaker="A"
            ),
            TranscriptSegment(
                id=1, start_ms=800, end_ms=1600, text="再见。", speaker="B"
            ),
        ),
    )

    assert format_diarized(result) == {
        "task": "transcribe",
        "duration": 1.6,
        "text": "你好。再见。",
        "segments": [
            {
                "id": "seg_0",
                "type": "transcript.text.segment",
                "start": 0.0,
                "end": 0.8,
                "speaker": "A",
                "text": "你好。",
            },
            {
                "id": "seg_1",
                "type": "transcript.text.segment",
                "start": 0.8,
                "end": 1.6,
                "speaker": "B",
                "text": "再见。",
            },
        ],
    }


def test_diarized_response_preserves_frozen_text_gaps_and_merges_same_speaker() -> None:
    result = TranscriptResult(
        request_id="r2",
        model_id="speechrail/qwen3-asr-1.7b",
        text="你好 世界。",
        duration_ms=1200,
        segments=(
            TranscriptSegment(id=0, start_ms=0, end_ms=400, text="你好", speaker="spk_01"),
            TranscriptSegment(id=1, start_ms=400, end_ms=800, text="世界", speaker="spk_01"),
            TranscriptSegment(id=2, start_ms=800, end_ms=1200, text="。", speaker="spk_02"),
        ),
    )

    payload = format_diarized(result)

    assert payload["segments"] == [
        {
            "id": "seg_0",
            "type": "transcript.text.segment",
            "start": 0.0,
            "end": 0.8,
            "speaker": "A",
            "text": "你好 世界",
        },
        {
            "id": "seg_1",
            "type": "transcript.text.segment",
            "start": 0.8,
            "end": 1.2,
            "speaker": "B",
            "text": "。",
        },
    ]
    assert "".join(segment["text"] for segment in payload["segments"]) == payload["text"]
