"""Deterministic evidence replay; never acoustic quality certification."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speechrail.backends.diarization import meeting
from speechrail.domain.audio_timeline import SampleSpan
from speechrail.domain.diarization.attribution import AttributionLedger, bracket_fill_speaker_labels
from speechrail.domain.diarization.types import ActivityFrame, ActivityUpdate, TextUnit
from speechrail.domain.resource_limits import GovernorLimits
from speechrail.runtime.resource_governor import ResourceGovernor


def replay(frames, units):
    ledger = AttributionLedger(accepted_samples=lambda: 16000, label_mode="meeting_dynamic")
    ledger.apply(ActivityUpdate("epoch", 1, SampleSpan(0, 16000), tuple(frames), 16000, 16000))
    return ledger.register("item", tuple(units))


@pytest.mark.parametrize("reason", ["identity_uncertain", "speaker_capacity", "activity_gap"])
def test_unknown_evidence_cannot_be_swallowed_by_majority_known_speech(reason):
    frames = [
        ActivityFrame(SampleSpan(0, 14400), None, frozenset({0})),
        ActivityFrame(SampleSpan(14400, 16000), None, frozenset(), reason),
    ]
    (result,) = replay(frames, [TextUnit("unit", 0, 2, SampleSpan(0, 16000))])
    assert result.speaker is None and result.reason == reason


def test_unknown_overlap_is_not_resolved_by_known_speaker_probability():
    (result,) = replay(
        [ActivityFrame(SampleSpan(0, 16000), None, frozenset({0}), "identity_uncertain")],
        [TextUnit("unit", 0, 2, SampleSpan(0, 16000))],
    )
    assert result.speaker is None and result.reason == "identity_uncertain"


def test_two_known_speakers_talking_together_have_no_primary_speaker():
    (result,) = replay(
        [ActivityFrame(SampleSpan(0, 16000), None, frozenset({0, 1}))],
        [TextUnit("unit", 0, 2, SampleSpan(0, 16000))],
    )
    assert result.speaker is None and result.reason == "identity_uncertain"


def test_word_straddling_two_identities_is_not_assigned_by_majority():
    (result,) = replay(
        [
            ActivityFrame(SampleSpan(0, 14400), None, frozenset({0})),
            ActivityFrame(SampleSpan(14400, 16000), None, frozenset({1})),
        ],
        [TextUnit("boundary", 0, 2, SampleSpan(0, 16000))],
    )
    assert result.speaker is None and result.reason == "identity_uncertain"


def test_fifth_identity_cannot_enter_the_stable_four_ledger():
    (result,) = replay(
        [ActivityFrame(SampleSpan(0, 16000), None, frozenset({4}))],
        [TextUnit("unit", 0, 2, SampleSpan(0, 16000))],
    )
    assert result.speaker is None and result.reason == "speaker_capacity"


def test_unknown_short_interjection_is_not_filled_from_neighbors():
    frames = [
        ActivityFrame(SampleSpan(0, 6400), None, frozenset({0})),
        ActivityFrame(SampleSpan(6400, 8000), None, frozenset()),
        ActivityFrame(SampleSpan(8000, 16000), None, frozenset({0})),
    ]
    results = replay(
        frames,
        [
            TextUnit("a", 0, 1, SampleSpan(0, 6400)),
            TextUnit("short", 1, 2, SampleSpan(6400, 8000)),
            TextUnit("b", 2, 3, SampleSpan(8000, 16000)),
        ],
    )
    assert results[0].speaker == results[2].speaker == "S1"
    assert results[1].speaker is None and results[1].reason == "identity_uncertain"
    assert bracket_fill_speaker_labels(results)["short"] is None


def test_four_identity_certification_remains_required(tmp_path, monkeypatch):
    monkeypatch.setattr(meeting, "inspect_meeting_dynamic_assets", lambda _: True)
    executable = tmp_path / "worker"
    executable.touch()
    executable.chmod(0o700)
    policy = {"certified_max_speakers": 4, "validation_digest": "a" * 64}
    monkeypatch.setattr(meeting, "read_matching_policy", lambda _: policy)
    engine = meeting.MeetingDiarizationEngine(
        model_dir=tmp_path,
        policy_path=tmp_path / "policy",
        executable=executable,
        governor=ResourceGovernor(GovernorLimits(2, 1, 8)),
    )
    assert engine.system_cap == engine.max_speakers == 4
    assert engine.readiness.ready
    policy["validation_digest"] = None
    unavailable = meeting.MeetingDiarizationEngine(
        model_dir=tmp_path,
        policy_path=tmp_path / "policy",
        executable=executable,
        governor=ResourceGovernor(GovernorLimits(2, 1, 8)),
    )
    assert not unavailable.readiness.ready and unavailable.max_speakers is None


def test_native_four_identity_policy_is_required_before_accepting_embeddings():
    from speechrail.runtime.diarization_worker import validate_meeting_identity_policy

    validate_meeting_identity_policy({"identity_policy": "stable_four_v1", "identity_capacity": 4})
    for response in (
        {},
        {"identity_policy": "stable_four_v1", "identity_capacity": 32},
        {"identity_policy": "old", "identity_capacity": 4},
    ):
        with pytest.raises(RuntimeError, match="identity policy"):
            validate_meeting_identity_policy(response)


def test_six_voice_evidence_replay_keeps_unknown_and_later_identity_stable():
    from examples.perf.stable_speaker_metrics import score_stable_speakers

    # Synthetic verified identity evidence, not audio or model predictions.
    cases = [
        (32000, "R1", 0, None),
        (32000, "R2", 1, None),
        (32000, "R3", 2, None),
        (32000, "R4", 3, None),
        (32000, "R5", None, "speaker_capacity"),
        (6400, "R6", None, "speaker_capacity"),
        (32000, "R1", 0, None),
        (6400, "R1", None, "identity_uncertain"),
        (32000, "R1", 0, None),
    ]
    frames, units, reference = [], [], []
    cursor = 0
    for index, (length, identity, slot, reason) in enumerate(cases):
        span = SampleSpan(cursor, cursor + length)
        frames.append(
            ActivityFrame(span, None, frozenset() if slot is None else frozenset({slot}), reason)
        )
        units.append(TextUnit(f"unit-{index}", index, index + 1, span))
        reference.append({"start": cursor / 16000, "end": span.end / 16000, "speaker": identity})
        cursor = span.end
    ledger = AttributionLedger(accepted_samples=lambda: cursor, label_mode="meeting_dynamic")
    ledger.apply(ActivityUpdate("epoch", 1, SampleSpan(0, cursor), tuple(frames), cursor, cursor))
    results = ledger.register("item", tuple(units))
    assert [r.speaker for r in results] == ["S1", "S2", "S3", "S4", None, None, "S1", None, "S1"]
    hypothesis = [
        {**ref, "speaker": result.speaker} for ref, result in zip(reference, results, strict=True)
    ]
    score = score_stable_speakers(
        reference,
        hypothesis,
        duration=cursor / 16000,
        speaker_mapping={f"S{i}": f"R{i}" for i in range(1, 5)},
    )
    assert score["known_precision"] == 1
    assert score["out_of_set_false_accept_rate"] == 0
    assert score["unknown_fraction"] == pytest.approx(2.8 / 14.8)
    assert score["per_speaker"]["R1"]["correct_seconds"] == pytest.approx(6)
    assert score["short_turns"]["misattributed_count"] == 0
