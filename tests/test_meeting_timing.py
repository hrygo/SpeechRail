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


def test_stable_marker_waits_for_asr_coverage_activity_and_completed_text_delivery():
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    now = [11.]
    timing = MeetingTiming(samples=16000, clock=lambda: now[0])
    timing.source(PcmChunk(0, 0, 16000, 11., 11., bytes(32000)))
    ticket = timing.begin_delivery({
        "kind": "text", "sequence": 0, "unit_index": 0, "text": "甲",
        "start_sample": 0, "end_sample": 16000, "speaker": "S1", "granularity": "utterance",
    })
    timing.end_delivery(ticket)
    assert timing.ready_publications() == ()
    timing.end_delivery(timing.begin_delivery({
        "kind": "activity_watermark", "accepted_samples": 16000,
        "processed_samples": 16000, "stable_samples": 16000,
    }))
    assert timing.ready_publications() == ()
    now[0] = 12.
    timing.asr_terminal(0, 16000)
    rows = timing.ready_publications()
    assert len(rows) == 1 and rows[0]["kind"] == "stable_text"
    assert rows[0]["sequence"] == 0 and rows[0]["speaker"] == "S1"
    assert "text" not in rows[0]
    assert timing.ready_publications() == ()
    ticket = timing.begin_delivery(rows[0])
    now[0] = 13.
    timing.end_delivery(ticket)
    report = timing.summary({"source_origin_at": 10., "clock_source": "injected"},
                            (CompletedText(0, "甲", SampleSpan(0, 16000)),))
    assert report["stable_delivery_verified"] is True
    assert report["stable_text_sink_end_max_delay_seconds"] == 2.
    with pytest.raises(ValueError, match="stable"):
        timing.begin_delivery(rows[0])


def test_stable_markers_cannot_be_forged_before_evidence_or_delivered_twice():
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    timing = MeetingTiming(samples=160, clock=lambda: 2.)
    timing.source(PcmChunk(0, 0, 160, 1.01, 1.01, bytes(320)))
    with pytest.raises(ValueError, match="stable"):
        timing.begin_delivery({
            "kind": "stable_text", "sequence": 0, "unit_index": 0,
            "start_sample": 0, "end_sample": 160, "speaker": "S1",
            "granularity": "utterance",
        })


def test_registered_duration_weighted_percentile_keeps_missing_weight_and_exact_boundary():
    import json
    from pathlib import Path

    from meeting_latency_policy import latency_policy, weighted_p95

    policy = json.loads((Path(__file__).resolve().parents[1] /
                         "examples/perf/meeting-evaluation-policy.json").read_text())
    assert policy["latency"] == latency_policy()
    assert weighted_p95([(95, 2.), (5, None)]) == 2.
    assert weighted_p95([(94, 2.), (6, None)]) is None
    assert weighted_p95([(5, 20.), (95, 2.)]) == 2.
    assert weighted_p95([(6, 20.), (94, 2.)]) == 20.
    assert weighted_p95([]) is None


@pytest.mark.parametrize("delay,known,gate,hard", [
    (15., True, "diagnostic_pass", 0),
    (15.001, True, "no-go", 0),
    (30., True, "no-go", 0),
    (30.001, True, "no-go", 1),
    (1., False, "no-go", 1),
])
def test_registered_latency_limits_and_unknown_weight_are_not_success_filtered(
    delay, known, gate, hard,
):
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    now = [11.]
    timing = MeetingTiming(samples=16000, clock=lambda: now[0])
    timing.source(PcmChunk(0, 0, 16000, 11., 11., bytes(32000)))
    timing.asr_terminal(0, 16000)
    timing.end_delivery(timing.begin_delivery({
        "kind": "activity_watermark", "accepted_samples": 16000,
        "processed_samples": 16000, "stable_samples": 16000,
    }))
    text = timing.begin_delivery({
        "kind": "text", "sequence": 0, "unit_index": 0, "text": "甲",
        "start_sample": 0, "end_sample": 16000,
        "speaker": "S1" if known else "unknown", "granularity": "utterance",
    })
    assert timing.ready_publications() == ()
    timing.end_delivery(text)
    marker = timing.begin_delivery(timing.ready_publications()[0])
    now[0] += delay
    timing.end_delivery(marker)
    timing.mark("asr_callback_complete")
    timing.mark("dia_input_eof")
    now[0] += 1.
    timing.mark("dia_scope_closed")
    report = timing.summary({"source_origin_at": 10., "clock_source": "injected"},
                            (CompletedText(0, "甲", SampleSpan(0, 16000)),))
    diagnostics = report["latency_diagnostics"]
    assert diagnostics["stable_gate"] == gate
    assert diagnostics["stable_hard_failure_units"] == hard
    assert diagnostics["expected_weight_samples"] == 16000
    assert diagnostics["failed_weight_samples"] == (0 if known else 16000)
    assert diagnostics["stable_publication_p95_seconds"] == (
        pytest.approx(delay) if known else None
    )
    assert diagnostics["finish_seconds"] == pytest.approx(delay + 1.)
    assert report["stable_label_p95_seconds"] is None
    assert report["certification_eligible"] is False


@pytest.mark.parametrize("late", [False, True])
def test_pending_deadline_exists_before_dia_text_and_uses_sample_end_origin(late):
    from meeting_pcm_feed import PcmChunk
    from meeting_timing import MeetingTiming

    now = [11.]
    timing = MeetingTiming(samples=16000, clock=lambda: now[0])
    timing.source(PcmChunk(0, 0, 16000, 11., 11., bytes(32000)))
    timing.expect_text(CompletedText(0, "甲", SampleSpan(0, 16000)))
    assert timing.next_stable_deadline(30.) == 41.
    assert timing.finish_completed_at() is None
    timing.asr_terminal(0, 16000)
    timing.end_delivery(timing.begin_delivery({
        "kind": "activity_watermark", "accepted_samples": 16000,
        "processed_samples": 16000, "stable_samples": 16000,
    }))
    timing.end_delivery(timing.begin_delivery({
        "kind": "text", "sequence": 0, "unit_index": 0, "text": "甲",
        "start_sample": 0, "end_sample": 16000, "speaker": "S1", "granularity": "utterance",
    }))
    marker = timing.begin_delivery(timing.ready_publications()[0])
    now[0] = 41.001 if late else 41.
    timing.end_delivery(marker)
    timing.mark("asr_callback_complete")
    timing.mark("dia_input_eof")
    timing.mark("dia_scope_closed")
    assert timing.next_stable_deadline(30.) is None
    assert timing.late_stable_deadline(30.) == (41. if late else None)
    assert timing.finish_completed_at() == (41.001 if late else 41.)
    now[0] = 100.
    assert timing.next_stable_deadline(30.) is None
    assert timing.finish_completed_at() == (41.001 if late else 41.)
