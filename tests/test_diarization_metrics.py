"""Tests for speaker diarization evaluation metrics and scoring tooling (R5)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))

from tools.evaluate_diarization_e2e import (
    EvaluationRegion,
    ManifestItem,
    SpeakerTurn,
    TextAttributionUnit,
    compute_conditional_attribution_error,
    compute_cpcer,
    compute_der,
    compute_pyannote_metrics,
    compute_speaker_attribution_cer,
    evaluate_manifest,
    validate_manifest,
)


def test_custom_der_cross_checks_pyannote_der_and_jer_with_uem() -> None:
    reference = [
        SpeakerTurn(speaker="S1", start=0.0, end=4.0),
        SpeakerTurn(speaker="S2", start=4.0, end=8.0),
    ]
    hypothesis = [
        SpeakerTurn(speaker="spk_a", start=0.0, end=4.0),
        SpeakerTurn(speaker="spk_b", start=4.0, end=6.0),
    ]
    uem = (EvaluationRegion(start=0.0, end=8.0),)

    custom = compute_der(reference, hypothesis, collar=0.0, uem=uem)
    reference_metrics = compute_pyannote_metrics(reference, hypothesis, collar=0.0, uem=uem)

    assert custom.der == pytest.approx(0.25)
    assert reference_metrics.der == pytest.approx(custom.der)
    assert reference_metrics.jer == pytest.approx(0.25)


def test_der_is_zero_under_consistent_speaker_permutation() -> None:
    """Consistent renaming of speakers across the entire session results in DER = 0."""
    reference = [
        SpeakerTurn(speaker="S1", start=0.0, end=10.0),
        SpeakerTurn(speaker="S2", start=10.0, end=20.0),
    ]
    # Hypothesis swaps names consistently across the whole session.
    hypothesis = [
        SpeakerTurn(speaker="spk_beta", start=0.0, end=10.0),
        SpeakerTurn(speaker="spk_alpha", start=10.0, end=20.0),
    ]

    result = compute_der(reference, hypothesis, collar=0.0)
    assert result.der == pytest.approx(0.0)
    assert result.confusion_time == pytest.approx(0.0)
    assert result.miss_time == pytest.approx(0.0)
    assert result.fa_time == pytest.approx(0.0)
    assert result.speaker_mapping == {"spk_beta": "S1", "spk_alpha": "S2"}


def test_der_catches_segment_level_speaker_swap() -> None:
    """Segment-by-segment speaker swapping cannot be masked by local matching.

    If hypothesis in the second half swaps speakers, a global one-to-one mapping
    across the session must penalize the confusion.
    """
    reference = [
        SpeakerTurn(speaker="S1", start=0.0, end=10.0),
        SpeakerTurn(speaker="S2", start=10.0, end=20.0),
        SpeakerTurn(speaker="S1", start=20.0, end=30.0),
        SpeakerTurn(speaker="S2", start=30.0, end=40.0),
    ]
    # First half: spk_1 is S1, spk_2 is S2.
    # Second half: spk_2 is S1, spk_1 is S2 (swapped!).
    hypothesis = [
        SpeakerTurn(speaker="spk_1", start=0.0, end=10.0),
        SpeakerTurn(speaker="spk_2", start=10.0, end=20.0),
        SpeakerTurn(speaker="spk_2", start=20.0, end=30.0),
        SpeakerTurn(speaker="spk_1", start=30.0, end=40.0),
    ]

    result = compute_der(reference, hypothesis, collar=0.0)
    # Total reference speech = 40.0s. 20.0s is confused. DER = 20/40 = 50%.
    assert result.der == pytest.approx(0.50)
    assert result.confusion_time == pytest.approx(20.0)
    assert result.miss_time == pytest.approx(0.0)
    assert result.fa_time == pytest.approx(0.0)


def test_der_with_miss_and_false_alarm() -> None:
    """Missed speech and false alarm speech are correctly accumulated in DER."""
    reference = [
        SpeakerTurn(speaker="S1", start=0.0, end=10.0),
    ]
    hypothesis = [
        SpeakerTurn(speaker="spk_1", start=0.0, end=8.0),  # 2.0s miss
        SpeakerTurn(speaker="spk_1", start=12.0, end=14.0),  # 2.0s false alarm
    ]

    result = compute_der(reference, hypothesis, collar=0.0)
    assert result.total_reference_time == pytest.approx(10.0)
    assert result.miss_time == pytest.approx(2.0)
    assert result.fa_time == pytest.approx(2.0)
    assert result.confusion_time == pytest.approx(0.0)
    # DER = (miss + fa + confusion) / ref_time = (2 + 2 + 0) / 10 = 0.40
    assert result.der == pytest.approx(0.40)


def test_der_collar_tolerance() -> None:
    """Collar forgives boundary offsets within collar margin."""
    reference = [
        SpeakerTurn(speaker="S1", start=1.0, end=5.0),
    ]
    # Shifted by 0.2s on each side:
    hypothesis = [
        SpeakerTurn(speaker="spk_1", start=1.2, end=4.8),
    ]

    # Without collar: 0.4s miss out of 4.0s = 10%
    result_no_collar = compute_der(reference, hypothesis, collar=0.0)
    assert result_no_collar.der > 0.0

    # With collar=0.25s: the boundary differences are within collar
    result_with_collar = compute_der(reference, hypothesis, collar=0.25)
    assert result_with_collar.der == pytest.approx(0.0)


def test_der_evaluates_overlapping_speech() -> None:
    """Overlapping speech periods where both speakers talk are evaluated."""
    reference = [
        SpeakerTurn(speaker="S1", start=0.0, end=6.0),
        SpeakerTurn(speaker="S2", start=4.0, end=10.0),  # 2s overlap [4.0, 6.0]
    ]
    # Hypothesis only detects one speaker during overlap
    hypothesis = [
        SpeakerTurn(speaker="spk_1", start=0.0, end=10.0),
    ]

    result = compute_der(reference, hypothesis, collar=0.0)
    # Total ref time = 6 + 6 = 12.0s
    # spk_1 matches S1 (or S2). If spk_1 -> S1:
    # On [4, 6], ref has 2 speakers {S1, S2}, hyp has {S1}. Miss S2 for 2s.
    # On [6, 10], ref has S2, hyp has S1 -> confusion for 4s.
    # Miss = 2s, Confusion = 4s. Error = 6s / 12s = 50%.
    assert result.total_reference_time == pytest.approx(12.0)
    assert result.miss_time == pytest.approx(2.0)
    assert result.confusion_time == pytest.approx(4.0)
    assert result.der == pytest.approx(0.50)


def test_speaker_attribution_character_error_rate_counts_unknown_as_error() -> None:
    """Per-character speaker attribution: unknown status counts as error."""
    ref_units = [
        TextAttributionUnit(text="确认", speaker="S1"),
        TextAttributionUnit(text="同意", speaker="S2"),
    ]

    # Case 1: Perfect attribution (mapping spk_a -> S1, spk_b -> S2)
    hyp_perfect = [
        TextAttributionUnit(text="确认", speaker="spk_a", status="stable"),
        TextAttributionUnit(text="同意", speaker="spk_b", status="stable"),
    ]
    mapping = {"spk_a": "S1", "spk_b": "S2"}
    score_perfect = compute_speaker_attribution_cer(ref_units, hyp_perfect, mapping)
    assert score_perfect.attribution_cer == pytest.approx(0.0)
    assert score_perfect.unknown_ratio == pytest.approx(0.0)

    # Case 2: '同意' has status unknown and speaker=None
    hyp_unknown = [
        TextAttributionUnit(text="确认", speaker="spk_a", status="stable"),
        TextAttributionUnit(text="同意", speaker=None, status="unknown"),
    ]
    score_unknown = compute_speaker_attribution_cer(ref_units, hyp_unknown, mapping)
    # Total chars = 4 ("确认同意"). 2 chars ("同意") are unknown => counted as error!
    assert score_unknown.attribution_cer == pytest.approx(0.50)
    assert score_unknown.unknown_ratio == pytest.approx(0.50)
    assert score_unknown.total_characters == 4
    assert score_unknown.error_characters == 2

    # Case 3: '同意' is wrongly assigned to spk_a
    hyp_wrong = [
        TextAttributionUnit(text="确认", speaker="spk_a", status="stable"),
        TextAttributionUnit(text="同意", speaker="spk_a", status="stable"),
    ]
    score_wrong = compute_speaker_attribution_cer(ref_units, hyp_wrong, mapping)
    assert score_wrong.attribution_cer == pytest.approx(0.50)
    assert score_wrong.unknown_ratio == pytest.approx(0.0)


def test_manifest_validation_enforces_license_and_splits(tmp_path: Path) -> None:
    """Manifest requires non-empty license/authorized flag and valid split."""
    valid_manifest = [
        {
            "clip_id": "clip_01",
            "split": "eval",
            "license": "CC-BY-4.0",
            "reference_rttm": "ref_01.rttm",
            "hypothesis_rttm": "hyp_01.rttm",
            "uem": "eval.uem",
        }
    ]
    manifest_file = tmp_path / "manifest.json"
    (tmp_path / "ref_01.rttm").write_text(
        "SPEAKER clip 1 0.0 1.0 <NA> <NA> ref <NA> <NA>\n", encoding="utf-8"
    )
    (tmp_path / "hyp_01.rttm").write_text(
        "SPEAKER clip 1 0.0 1.0 <NA> <NA> hyp <NA> <NA>\n", encoding="utf-8"
    )
    (tmp_path / "eval.uem").write_text("clip 1 0.0 1.0\n", encoding="utf-8")
    manifest_file.write_text(json.dumps(valid_manifest), encoding="utf-8")
    items = validate_manifest(manifest_file)
    assert len(items) == 1
    assert items[0].clip_id == "clip_01"

    # Missing license
    invalid_manifest = [
        {
            "clip_id": "clip_02",
            "split": "eval",
            "reference_rttm": "ref_02.rttm",
            "hypothesis_rttm": "hyp_02.rttm",
        }
    ]
    manifest_file.write_text(json.dumps(invalid_manifest), encoding="utf-8")
    with pytest.raises(ValueError, match="license"):
        validate_manifest(manifest_file)

    # Invalid split
    invalid_split = [
        {
            "clip_id": "clip_03",
            "split": "production",
            "license": "MIT",
            "reference_rttm": "ref_03.rttm",
            "hypothesis_rttm": "hyp_03.rttm",
        }
    ]
    manifest_file.write_text(json.dumps(invalid_split), encoding="utf-8")
    with pytest.raises(ValueError, match="split"):
        validate_manifest(manifest_file)


def test_manifest_rejects_missing_rttm_and_der_rejects_empty_reference(tmp_path: Path) -> None:
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            [
                {
                    "clip_id": "missing-rttm",
                    "split": "eval",
                    "license": "authorized",
                    "reference_rttm": "missing-reference.rttm",
                    "hypothesis_rttm": "missing-hypothesis.rttm",
                    "uem": "eval.uem",
                }
            ]
        ),
        encoding="utf-8",
    )
    (tmp_path / "eval.uem").write_text("clip 1 0.0 1.0\n", encoding="utf-8")
    with pytest.raises(ValueError, match="RTTM file is missing"):
        validate_manifest(manifest)
    with pytest.raises(ValueError, match="reference speech"):
        compute_der([], [SpeakerTurn(speaker="hyp", start=0.0, end=1.0)])


def test_manifest_rejects_missing_uem(tmp_path: Path) -> None:
    manifest = tmp_path / "manifest.json"
    (tmp_path / "reference.rttm").write_text(
        "SPEAKER clip 1 0.0 1.0 <NA> <NA> ref <NA> <NA>\n", encoding="utf-8"
    )
    (tmp_path / "hypothesis.rttm").write_text(
        "SPEAKER clip 1 0.0 1.0 <NA> <NA> hyp <NA> <NA>\n", encoding="utf-8"
    )
    manifest.write_text(
        json.dumps(
            [
                {
                    "clip_id": "missing-uem",
                    "split": "eval",
                    "license": "authorized",
                    "reference_rttm": "reference.rttm",
                    "hypothesis_rttm": "hypothesis.rttm",
                }
            ]
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="requires uem"):
        validate_manifest(manifest)


def test_manifest_loads_paired_text_attribution_sidecars_and_reports_cpcer(
    tmp_path: Path,
) -> None:
    (tmp_path / "reference.rttm").write_text(
        "SPEAKER clip 1 0.0 1.0 <NA> <NA> S1 <NA> <NA>\n", encoding="utf-8"
    )
    (tmp_path / "hypothesis.rttm").write_text(
        "SPEAKER clip 1 0.0 1.0 <NA> <NA> A <NA> <NA>\n", encoding="utf-8"
    )
    (tmp_path / "eval.uem").write_text("clip 1 0.0 1.0\n", encoding="utf-8")
    (tmp_path / "reference-text.json").write_text(
        json.dumps([{"text": "确认", "speaker": "S1"}]), encoding="utf-8"
    )
    (tmp_path / "hypothesis-text.json").write_text(
        json.dumps([{"text": "确认", "speaker": "A", "status": "stable"}]),
        encoding="utf-8",
    )
    manifest = tmp_path / "manifest.json"
    manifest.write_text(
        json.dumps(
            [
                {
                    "clip_id": "anon-text",
                    "split": "eval",
                    "license": "authorized",
                    "reference_rttm": "reference.rttm",
                    "hypothesis_rttm": "hypothesis.rttm",
                    "uem": "eval.uem",
                    "reference_text_json": "reference-text.json",
                    "hypothesis_text_json": "hypothesis-text.json",
                }
            ]
        ),
        encoding="utf-8",
    )

    items = validate_manifest(manifest)
    report = evaluate_manifest(items)

    assert report["items"][0]["cpcer"] == 0.0
    assert report["aggregate"]["cpcer"] == 0.0

    manifest_data = json.loads(manifest.read_text(encoding="utf-8"))
    del manifest_data[0]["hypothesis_text_json"]
    manifest.write_text(json.dumps(manifest_data), encoding="utf-8")
    with pytest.raises(ValueError, match="text sidecars"):
        validate_manifest(manifest)


def test_speaker_attribution_cer_counts_text_substitution_and_insertion() -> None:
    reference = [TextAttributionUnit(text="同意", speaker="S1")]
    hypothesis = [TextAttributionUnit(text="不同意", speaker="spk", status="stable")]

    score = compute_speaker_attribution_cer(reference, hypothesis, {"spk": "S1"})

    assert score.error_characters >= 1
    assert score.attribution_cer > 0.0


def test_conditional_attribution_error_uses_only_exactly_aligned_characters() -> None:
    reference = [TextAttributionUnit(text="甲乙", speaker="S1")]
    hypothesis = [TextAttributionUnit(text="甲丙乙", speaker="A", status="stable")]

    score = compute_conditional_attribution_error(reference, hypothesis, {"A": "S1"})

    assert score.total_matched_characters == 2
    assert score.error_characters == 0
    assert score.error_rate == 0.0


def test_cpcer_uses_one_global_speaker_mapping_and_counts_text_edits() -> None:
    """cpCER groups each speaker's whole transcript before global matching."""
    reference = [
        TextAttributionUnit(text="甲乙", speaker="S1"),
        TextAttributionUnit(text="丙丁", speaker="S2"),
    ]
    hypothesis = [
        TextAttributionUnit(text="丙戊", speaker="B"),
        TextAttributionUnit(text="甲乙", speaker="A"),
    ]

    score = compute_cpcer(reference, hypothesis)

    assert score.speaker_mapping == {"A": "S1", "B": "S2"}
    assert score.total_characters == 4
    assert score.error_characters == 1
    assert score.cpcer == pytest.approx(0.25)


def test_cpcer_treats_unknown_as_an_unmatched_speaker_and_rejects_empty_reference() -> None:
    reference = [TextAttributionUnit(text="确认", speaker="S1")]
    hypothesis = [TextAttributionUnit(text="确认", speaker=None, status="unknown")]

    score = compute_cpcer(reference, hypothesis)

    # Unknown may not be mapped to an oracle reference speaker. Its emitted
    # text is an insertion and the reference transcript is a deletion.
    assert score.error_characters == 4
    assert score.unknown_characters == 2
    assert score.cpcer == pytest.approx(2.0)
    with pytest.raises(ValueError, match="reference text"):
        compute_cpcer([], hypothesis)


def test_evaluation_report_does_not_leak_private_data() -> None:
    """Generated evaluation summary must not contain raw audio paths, transcripts, or names."""
    ref = [SpeakerTurn(speaker="Alice_RealName", start=0.0, end=5.0)]
    hyp = [SpeakerTurn(speaker="spk_01", start=0.0, end=5.0)]

    item = ManifestItem(
        clip_id="clip_anon_001",
        split="eval",
        license="CC0",
        reference_turns=ref,
        hypothesis_turns=hyp,
        uem_regions=(EvaluationRegion(0.0, 5.0),),
    )
    report = evaluate_manifest([item], collar=0.0)

    report_json = json.dumps(report)
    assert "Alice_RealName" not in report_json
    assert "/Users/" not in report_json
    assert "clip_anon_001" in report_json
    assert "der" in report["aggregate"]
