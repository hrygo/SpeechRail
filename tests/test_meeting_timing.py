"""Common-clock observations only; no models, audio files or latency acceptance."""

import pytest
from meeting_candidate_evidence import CompletedText

from speechrail.domain.audio_timeline import SampleSpan


def test_common_clock_records_coverage_and_sink_completion_without_claiming_p95():
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    now = [11.]
    timing = MeetingTiming(samples=16000, clock=lambda: now[0])
    timing.source(PcmChunk(0, 0, 16000, 11., 11., bytes(32000)))
    now[0] = 12.
    timing.asr_terminal(0, 16000)
    ticket = timing.begin_delivery({
        "kind": "activity_watermark", "accepted_samples": 16000,
        "processed_samples": 16000, "stable_samples": 16000,
    })
    now[0] = 13.
    timing.end_delivery(ticket)
    ticket = timing.begin_delivery({
        "kind": "text", "sequence": 0, "unit_index": 0, "text": "甲",
        "start_sample": 0, "end_sample": 16000, "speaker": "S1", "granularity": "utterance",
    })
    now[0] = 14.
    timing.end_delivery(ticket)
    expected = (CompletedText(0, "甲", SampleSpan(0, 16000)),)
    report = timing.summary({"source_origin_at": 10., "clock_source": "injected"}, expected)
    assert report["asr_sealed_through"] == report["dia_stable_through"] == 16000
    assert report["text_delivery_verified"] is True
    assert report["source_samples_observed"] == 16000
    assert report["stable_label_p95_seconds"] is None
    assert report["latency_gate"] == "not_evaluated"
    assert report["clock_source"] == "injected"
    assert report["text_sink_end_max_delay_seconds"] == 3.
    assert "甲" not in str(report)


@pytest.mark.parametrize("fault", ["missing", "different_text", "different_span", "duplicate"])
def test_missing_or_wrong_sink_units_remain_explicit_failures(fault):
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    timing = MeetingTiming(samples=160, clock=lambda: 2.)
    timing.source(PcmChunk(0, 0, 160, 1.01, 1.01, bytes(320)))
    row = {
        "kind": "text", "sequence": 0, "unit_index": 0,
        "text": "乙" if fault == "different_text" else "甲",
        "start_sample": 1 if fault == "different_span" else 0, "end_sample": 160,
        "speaker": "unknown", "granularity": "utterance",
    }
    if fault != "missing":
        timing.end_delivery(timing.begin_delivery(row))
    if fault == "duplicate":
        timing.end_delivery(timing.begin_delivery(row))
    expected = (CompletedText(0, "甲", SampleSpan(0, 160)),)
    report = timing.summary({"source_origin_at": 1., "clock_source": "injected"}, expected)
    assert report["text_delivery_verified"] is False
    assert report["latency_gate"] == "not_evaluated"
    assert report["missing_or_invalid_text_units"] == 1


def test_incomplete_sink_and_clock_mismatch_do_not_disappear_from_observations():
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    timing = MeetingTiming(samples=160, clock=lambda: 2.)
    timing.source(PcmChunk(0, 0, 160, 1.01, 1.01, bytes(320)))
    timing.begin_delivery({
        "kind": "text", "sequence": 0, "unit_index": 0, "text": "甲",
        "start_sample": 0, "end_sample": 160, "speaker": "S1", "granularity": "utterance",
    })
    expected = (CompletedText(0, "甲", SampleSpan(0, 160)),)
    report = timing.summary({"source_origin_at": 1., "clock_source": "injected"}, expected)
    assert report["open_sink_deliveries"] == 1
    assert report["text_delivery_verified"] is False
    with pytest.raises(ValueError, match="origin"):
        timing.summary({"source_origin_at": 10., "clock_source": "injected"}, expected)


def test_dia_record_budget_cannot_consume_asr_or_final_snapshot_reservation(monkeypatch):
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    monkeypatch.setattr(MeetingTiming, "MAX_PUBLICATION_RECORDS", 1)
    timing = MeetingTiming(samples=160, clock=lambda: 2.)
    timing.source(PcmChunk(0, 0, 160, 1.01, 1.01, bytes(320)))
    watermark = {
        "kind": "activity_watermark", "accepted_samples": 160,
        "processed_samples": 160, "stable_samples": 160,
    }
    timing.end_delivery(timing.begin_delivery(watermark))
    with pytest.raises(ValueError, match="budget"):
        timing.begin_delivery(watermark)
    timing.asr_terminal(0, 160)
    timing.end_delivery(timing.begin_delivery({"kind": "asr_body_snapshot"}))
    report = timing.summary({"source_origin_at": 1., "clock_source": "injected"}, ())
    assert report["asr_sealed_through"] == 160
    assert report["completed_by_kind"]["asr_body_snapshot"] == 1


def test_sink_completion_is_later_than_entry_and_failed_attempts_are_retained():
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    now = [2.]
    timing = MeetingTiming(samples=160, clock=lambda: now[0])
    timing.source(PcmChunk(0, 0, 160, 1.01, 1.01, bytes(320)))
    row = {
        "kind": "text", "sequence": 0, "unit_index": 0, "text": "甲",
        "start_sample": 0, "end_sample": 160, "speaker": "unknown",
        "granularity": "utterance",
    }
    ticket = timing.begin_delivery(row)
    now[0] = 3.
    timing.fail_delivery(ticket)
    ticket = timing.begin_delivery(row)
    now[0] = 4.
    timing.end_delivery(ticket)
    report = timing.summary({"source_origin_at": 1., "clock_source": "injected"},
                            (CompletedText(0, "甲", SampleSpan(0, 160)),))
    assert report["failed_sink_deliveries"] == {"text": 1}
    assert report["entered_by_kind"]["text"] == 2
    assert report["completed_by_kind"]["text"] == 1
    assert report["records"][0][-1] is None
    assert report["records"][1][-2:] == [3., 4.]
    assert report["max_sink_seconds"] == 1.
