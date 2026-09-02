from __future__ import annotations

from speechrail.domain.contracts import TranscriptResult, TranscriptSegment
from speechrail.domain.diarization import DiarizationSpeaker
from speechrail.http.formatters import format_verbose


def test_verbose_response_preserves_additive_anonymous_diarization_fields() -> None:
    result = TranscriptResult(
        request_id="request",
        model_id="model",
        text="多人讲话",
        duration_ms=1000,
        segments=(
            TranscriptSegment(
                id=0,
                start_ms=0,
                end_ms=1000,
                text="多人讲话",
                speaker="spk_01",
                speakers=(DiarizationSpeaker(id="spk_01", confidence=1.0),),
                speaker_revision=1,
            ),
        ),
    )

    segment = format_verbose(result)["segments"][0]

    assert segment["speakers"] == [{"id": "spk_01", "confidence": 1.0}]
    assert segment["speaker_revision"] == 1


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
