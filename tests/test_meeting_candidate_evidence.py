"""Candidate activity and ASR evidence remain independent, bounded streams."""

from __future__ import annotations

import pytest
from meeting_candidate_evidence import AttributedText, CandidateEvidence, CompletedText, SpeakerSpan

from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate, TextUnit


def update(start, end, slots=(0,), step=0, epoch="session"):
    return ActivityUpdate(
        epoch,
        step,
        SampleSpan(start, end),
        (ActivityFrame(SampleSpan(start, end), None, frozenset(slots)),) if end > start else (),
        end,
        end,
    )


def text(sequence=0, value=" hello, world!", start=0, end=16000, units=()):
    return CompletedText(sequence, value, SampleSpan(start, end), units)


def test_contiguous_activity_merges_across_chunks_and_keeps_ten_ms_interjections():
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    assert evidence.apply(update(0, 8000)) == ()
    assert evidence.apply(update(8000, 8160, (0, 7), step=1)) == ()
    events = evidence.apply(update(8160, 16000, step=2))
    assert events == (SpeakerSpan(SampleSpan(8000, 8160), "S8"),)
    assert evidence.finish() == (SpeakerSpan(SampleSpan(0, 16000), "S1"),)
    assert evidence.finish() == ()


def test_unknown_overlap_keeps_every_character_of_coarse_text():
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    assert evidence.register(text()) == ()
    events = evidence.apply(update(0, 16000, (0, 1)))
    emitted = [event for event in events if isinstance(event, AttributedText)]
    assert len(emitted) == 1
    assert emitted[0].text == " hello, world!"
    assert emitted[0].speaker == "unknown"
    assert emitted[0].reason == "insufficient_evidence"
    assert emitted[0].granularity == "utterance"


def test_word_evidence_assigns_independently_without_losing_punctuation_or_spacing():
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    evidence.apply(update(0, 8000))
    evidence.apply(update(8000, 16000, (1,), step=1))
    units = (
        TextUnit("a", 1, 6, SampleSpan(0, 8000)),
        TextUnit("b", 8, 13, SampleSpan(8000, 16000)),
    )
    events = evidence.register(text(value=" hello, world!", units=units))
    assert "".join(e.text for e in events) == " hello, world!"
    assert [e.speaker for e in events] == ["S1", "S2"]
    assert all(e.granularity == "word" for e in events)


def test_late_text_uses_retained_activity_and_missing_history_is_unknown():
    evidence = CandidateEvidence(epoch="session", retention_samples=16000)
    evidence.accept(16000)
    evidence.apply(update(0, 16000))
    evidence.accept(16000)
    evidence.apply(update(16000, 32000, step=1))
    evidence.accept(16000)
    evidence.apply(update(32000, 48000, step=2))
    events = evidence.register(text())
    assert events[0].speaker == "unknown"
    assert events[0].reason == "activity_history_evicted"


@pytest.mark.parametrize(
    "bad",
    [
        CompletedText(0, "abc", SampleSpan(0, 16001), ()),
        CompletedText(0, "abc", SampleSpan(0, 16000), (TextUnit("a", 0, 1, SampleSpan(0, 100)),)),
        CompletedText(0, "abc", SampleSpan(0, 16000), (TextUnit("a", 0, 3, None),)),
        CompletedText(0, "abc", SampleSpan(0, 16000), (TextUnit("a", 0, 4, SampleSpan(0, 100)),)),
    ],
)
def test_invalid_or_incomplete_alignment_is_not_invented_or_partially_registered(bad):
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    with pytest.raises(ValueError):
        evidence.register(bad)
    evidence.apply(update(0, 16000))
    assert evidence.register(text(value="abc"))[0].text == "abc"


def test_memory_limits_fail_before_unbounded_text_is_registered():
    evidence = CandidateEvidence(epoch="session", max_pending_characters=4, max_units=2)
    evidence.accept(16000)
    evidence.register(text(value="abc"))
    with pytest.raises(ValueError, match="budget"):
        evidence.register(text(sequence=1, value="de"))
    evidence.abort("cancelled")
    assert evidence.retained_counts["pending_units"] == 0


def test_abort_preserves_pending_text_as_unknown_and_never_invents_tail_activity():
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    evidence.register(text())
    evidence.apply(update(0, 8000))
    events = evidence.abort("finalization_incomplete")
    assert SpeakerSpan(SampleSpan(0, 8000), "S1") in events
    emitted = next(e for e in events if isinstance(e, AttributedText))
    assert emitted.text == " hello, world!"
    assert emitted.speaker == "unknown"
    assert emitted.reason == "finalization_incomplete"
    assert evidence.abort("cancelled") == ()
    assert not evidence.complete


def test_incomplete_finish_does_not_certify_full_audio_coverage():
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    evidence.register(text())
    assert evidence.finish()[0].speaker == "unknown"
    assert not evidence.complete


def test_duplicate_text_stale_epochs_gaps_and_revisions_fail_closed():
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    evidence.register(text())
    with pytest.raises(ValueError, match="sequence"):
        evidence.register(text())
    for invalid in (update(0, 8000, epoch="wrong"), update(8000, 16000), update(0, 8000, step=1)):
        with pytest.raises(ValueError):
            evidence.apply(invalid)
    evidence.apply(update(0, 16000))
    with pytest.raises(ValueError):
        evidence.apply(update(0, 16000, step=1))


def test_many_finalized_items_compact_without_retaining_full_transcript():
    evidence = CandidateEvidence(epoch="session", retention_samples=16000)
    for i in range(100):
        evidence.accept(16000)
        evidence.apply(update(i * 16000, (i + 1) * 16000, step=i))
        emitted = evidence.register(text(sequence=i, start=i * 16000, end=(i + 1) * 16000))
        assert emitted[0].speaker == "S1"
    assert evidence.retained_counts["pending_units"] == 0
    assert evidence.retained_counts["frames"] <= 2
    assert evidence.retained_counts["units"] <= 2


def test_cleanup_after_success_does_not_revoke_completed_evidence():
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    evidence.apply(update(0, 16000))
    evidence.finish()
    assert evidence.complete
    assert evidence.abort("cancelled") == ()
    assert evidence.complete


@pytest.mark.parametrize("span", [SampleSpan(0.0, 16000), SampleSpan(False, 16000)])
def test_asr_timing_requires_integer_samples(span):
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    with pytest.raises(ValueError, match="timing"):
        evidence.register(CompletedText(0, "a", span))


def test_whole_utterance_timestamp_grid_cannot_masquerade_as_word_evidence():
    evidence = CandidateEvidence(epoch="session")
    evidence.accept(16000)
    units = (TextUnit("a", 0, 1, SampleSpan(0, 16000)), TextUnit("b", 1, 2, SampleSpan(0, 16000)))
    with pytest.raises(ValueError, match="word"):
        evidence.register(text(value="ab", units=units))
    evidence.apply(update(0, 16000))
    assert evidence.register(text(value="ab"))[0].granularity == "utterance"
