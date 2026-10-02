"""Unit tests for the ``voice_quality_v1`` reference-audio grading policy.

Covers the S4.2 metric matrix (just-pass / just-warn / just-reject boundaries),
overall severity aggregation, ``VoiceQualityReport`` serialization round-trip,
and ``VoiceProfile`` backward compatibility when ``quality`` is missing.
"""

from __future__ import annotations

import io
import math
import struct
import wave
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from speechrail.domain.tts import (
    VoiceProfile,
    VoiceRegistry,
    VoiceUpdateUnsupportedError,
    transcode_and_validate_clone_audio,
)
from speechrail.domain.voice_quality import (
    POLICY_VERSION,
    VOICE_QUALITY_V1_ZH_PROBES,
    VoiceQualityProbeScore,
    VoiceQualityReference,
    VoiceQualityReport,
    VoiceQualityStatus,
    VoiceQualitySynthesis,
    clipping_ratio,
    duration_seconds,
    estimated_snr_db,
    grade_reference_quality,
    leading_trailing_silence_seconds,
    make_quality_report,
    noise_floor_dbfs,
    normalize_transcript_for_match,
    probe_carries_digits,
    speech_active_ratio,
    transcript_match_score,
    transcript_numbers_match,
)

# ---------------------------------------------------------------------------
# Fixtures / builders
# ---------------------------------------------------------------------------


def _pcm16(samples: list[int]) -> bytes:
    return struct.pack(f"<{len(samples)}h", *samples)


def _sine_pcm16(
    duration_seconds: float,
    sample_rate: int = 24_000,
    *,
    frequency_hz: float = 440.0,
    amplitude: float = 0.5,
) -> bytes:
    count = int(duration_seconds * sample_rate)
    samples: list[int] = []
    for index in range(count):
        value = round(
            amplitude * 32767.0 * math.sin(2.0 * math.pi * frequency_hz * index / sample_rate)
        )
        samples.append(max(-32767, min(32767, value)))
    return _pcm16(samples)


def _wav_bytes(duration_seconds: float = 3.0, sample_rate: int = 24_000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(b"\x00\x00" * int(duration_seconds * sample_rate))
    return buf.getvalue()


def _passing_reference() -> VoiceQualityReference:
    return VoiceQualityReference(
        duration_seconds=10.0,
        sample_rate=24_000,
        channels=1,
        speech_active_ratio=0.8,
        noise_floor_dbfs=-60.0,
        estimated_snr_db=30.0,
        clipping_ratio=0.0,
        leading_silence_seconds=0.1,
        trailing_silence_seconds=0.1,
        transcript_match=None,
    )


def _synthesis() -> VoiceQualitySynthesis:
    return VoiceQualitySynthesis(
        probe_count=3,
        successful_probe_count=3,
        active_rms_dbfs=-20.8,
        peak_dbfs=-3.2,
        chunk_jump_p95_db=4.6,
        clipping_ratio=0.0,
        deterministic=True,
    )


# ---------------------------------------------------------------------------
# S4.2 grading matrix — per metric boundaries
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("field", "value", "expected_status", "expected_code"),
    [
        # 有效时长: 4-30 pass / 2-4|30-45 warn / else reject
        ("duration_seconds", 4.0, VoiceQualityStatus.PASS, None),
        ("duration_seconds", 30.0, VoiceQualityStatus.PASS, None),
        ("duration_seconds", 2.0, VoiceQualityStatus.WARN, "audio_too_short"),
        ("duration_seconds", 45.0, VoiceQualityStatus.WARN, "audio_too_short"),
        ("duration_seconds", 1.9, VoiceQualityStatus.REJECT, "audio_too_short"),
        ("duration_seconds", 45.1, VoiceQualityStatus.REJECT, "audio_too_short"),
        # noise_floor_dbfs: <= -45 pass / -45~-35 warn / > -35 reject
        ("noise_floor_dbfs", -45.0, VoiceQualityStatus.PASS, None),
        ("noise_floor_dbfs", -60.0, VoiceQualityStatus.PASS, None),
        ("noise_floor_dbfs", -44.9, VoiceQualityStatus.WARN, "high_noise_floor"),
        ("noise_floor_dbfs", -35.0, VoiceQualityStatus.WARN, "high_noise_floor"),
        ("noise_floor_dbfs", -34.9, VoiceQualityStatus.REJECT, "high_noise_floor"),
        # estimated_snr_db: >= 20 pass / 15-20 warn / < 15 reject
        ("estimated_snr_db", 20.0, VoiceQualityStatus.PASS, None),
        ("estimated_snr_db", 15.0, VoiceQualityStatus.WARN, "low_snr"),
        ("estimated_snr_db", 14.9, VoiceQualityStatus.REJECT, "low_snr"),
        # clipping_ratio: < 0.01% pass / 0.01-0.1% warn / > 0.1% reject
        ("clipping_ratio", 0.0, VoiceQualityStatus.PASS, None),
        ("clipping_ratio", 0.0000999, VoiceQualityStatus.PASS, None),
        ("clipping_ratio", 0.0001, VoiceQualityStatus.WARN, "clipping"),
        ("clipping_ratio", 0.001, VoiceQualityStatus.WARN, "clipping"),
        ("clipping_ratio", 0.0011, VoiceQualityStatus.REJECT, "clipping"),
        # 首/尾静音 (max of leading/trailing): <= 0.8 pass / 0.8-1.5 warn / > 1.5 reject
        ("leading_silence_seconds", 0.8, VoiceQualityStatus.PASS, None),
        ("leading_silence_seconds", 1.5, VoiceQualityStatus.WARN, "audio_too_short"),
        ("leading_silence_seconds", 1.5001, VoiceQualityStatus.REJECT, "audio_too_short"),
        # speech_active_ratio: >= 0.55 pass / 0.35-0.55 warn / < 0.35 reject
        ("speech_active_ratio", 0.55, VoiceQualityStatus.PASS, None),
        ("speech_active_ratio", 0.35, VoiceQualityStatus.WARN, "audio_too_short"),
        ("speech_active_ratio", 0.3499, VoiceQualityStatus.REJECT, "audio_too_short"),
    ],
)
def test_grade_reference_metric_boundaries(
    field: str,
    value: float,
    expected_status: VoiceQualityStatus,
    expected_code: str | None,
) -> None:
    reference = replace(_passing_reference(), **{field: value})
    status, codes = grade_reference_quality(reference)

    assert status == expected_status.value
    if expected_code is None:
        assert codes == []
    else:
        assert codes == [expected_code]


@pytest.mark.parametrize(
    ("transcript_match", "expected_status", "expected_code"),
    [
        (0.98, VoiceQualityStatus.PASS, None),
        (0.90, VoiceQualityStatus.WARN, "transcript_mismatch"),
        (0.8999, VoiceQualityStatus.REJECT, "transcript_mismatch"),
    ],
)
def test_grade_transcript_match_boundaries(
    transcript_match: float,
    expected_status: VoiceQualityStatus,
    expected_code: str | None,
) -> None:
    reference = replace(_passing_reference(), transcript_match=transcript_match)
    status, codes = grade_reference_quality(reference)

    assert status == expected_status.value
    assert codes == ([] if expected_code is None else [expected_code])


def test_transcript_match_none_is_skipped_without_code() -> None:
    # transcript_match=None is "unavailable", never auto-passed and never coded.
    status, codes = grade_reference_quality(_passing_reference())
    assert status == VoiceQualityStatus.PASS.value
    assert "transcript_mismatch" not in codes


def test_transcript_match_injected_param_overrides_reference_field() -> None:
    reference = replace(_passing_reference(), transcript_match=0.99)  # field says pass
    status, codes = grade_reference_quality(reference, transcript_match=0.5)
    assert status == VoiceQualityStatus.REJECT.value
    assert codes == ["transcript_mismatch"]


# ---------------------------------------------------------------------------
# Overall severity + code aggregation
# ---------------------------------------------------------------------------


def test_overall_status_is_most_severe_and_collects_all_codes() -> None:
    reference = replace(
        _passing_reference(),
        duration_seconds=3.0,  # warn  -> audio_too_short
        noise_floor_dbfs=-30.0,  # reject -> high_noise_floor
        clipping_ratio=0.0005,  # warn  -> clipping
        estimated_snr_db=10.0,  # reject -> low_snr
    )
    status, codes = grade_reference_quality(reference)

    assert status == VoiceQualityStatus.REJECT.value
    assert set(codes) == {"audio_too_short", "high_noise_floor", "clipping", "low_snr"}


def test_all_pass_yields_pass_and_empty_codes() -> None:
    status, codes = grade_reference_quality(_passing_reference())
    assert status == VoiceQualityStatus.PASS.value
    assert codes == []


def test_failure_codes_are_deduplicated_preserving_order() -> None:
    reference = replace(
        _passing_reference(),
        duration_seconds=3.0,  # warn -> audio_too_short
        leading_silence_seconds=1.5,  # warn -> audio_too_short
    )
    status, codes = grade_reference_quality(reference)

    assert status == VoiceQualityStatus.WARN.value
    assert codes == ["audio_too_short"]


# ---------------------------------------------------------------------------
# VoiceQualityReport serialization
# ---------------------------------------------------------------------------


def test_transcript_match_normalizes_itn_punctuation_and_case() -> None:
    assert normalize_transcript_for_match("精度达到百分之九十九点九。") == "精度达到99.9%"
    assert transcript_match_score("Hello，World!", "hello world") == pytest.approx(1.0)
    assert transcript_match_score(
        "精度达到百分之九十九点九。", "精度达到99.9%"
    ) == pytest.approx(1.0)
    assert transcript_match_score(
        "请按 3、6、9 的顺序读。", "请按三六九的顺序读"
    ) == pytest.approx(1.0)
    assert transcript_match_score("温度是22.5℃", "温度是225℃") < 1.0


def test_transcript_match_equates_celsius_symbol_with_spoken_unit() -> None:
    # A TTS reads `℃` aloud, so a word-for-word synthesis comes back from the
    # ASR as 摄氏度. Notation alone must not cost the probe enough to sink the
    # gate: `22.5℃` previously capped at 0.9091, under the 0.92 the output gate
    # needs for `pass`, so no voice could ever reach `production_ready`.
    assert (
        transcript_match_score("温度是22.5℃", "温度是二十二点五摄氏度")
        == pytest.approx(1.0)
    )
    assert (
        transcript_match_score("温度是22.5℃", "温度是22.5℃") == pytest.approx(1.0)
    )
    assert normalize_transcript_for_match("二十二点五摄氏度") == "22.5°c"
    # The fold is a notation equivalence, not a licence to ignore a wrong unit.
    assert transcript_match_score("温度是22.5℃", "温度是二十二度") < 0.98


@pytest.mark.parametrize(
    ("probe_id", "asr_text"),
    [
        ("self_intro", "请进行自我介绍。"),
        ("short_sentence", "今天天气真好，我们开个会吧。"),
        (
            "long_paragraph",
            "请先简要介绍你的工作经历和目前关注的项目，并告诉我你今天希望达成的目标，"
            "以及在执行过程中你会采用哪些优先级策略。",
        ),
        (
            "question_prompt",
            "你认为人工智能能否真正提升我们的工作效率？为什么？",
        ),
        (
            "numbers_punct",
            "今天是2026年9月9日，温度是22.5摄氏度，请你告诉我三、六、九的顺序。",
        ),
        (
            "pause_markers",
            "我们先来先说第一点，然后我们再讨论第二点。",
        ),
    ],
)
def test_every_fixed_probe_survives_a_real_asr_round_trip(
    probe_id: str, asr_text: str
) -> None:
    # Regression guard for issue #126. `asr_text` is what the real local ASR
    # actually returned for each probe (voice wom-d2888cc51194ee2e, 3.4.2
    # runtime), not a hand-written idealisation -- an earlier version of this
    # test used invented text and so cleared a probe the real ASR never passes.
    #
    # A probe whose own text cannot survive the round trip caps the `min()`
    # aggregate for every voice, so no voice can pass however good it is. Both
    # offenders were notation the TTS never voices: `℃` comes back as 摄氏度,
    # and `……` is not pronounced at all, so the ASR drops it entirely.
    probe = next(p for p in VOICE_QUALITY_V1_ZH_PROBES if p["id"] == probe_id)
    assert transcript_match_score(probe["text"], asr_text) == pytest.approx(1.0)


def test_transcript_match_drops_ellipsis_but_keeps_decimals() -> None:
    # `……` must not score as six missing characters; `22.5` must not lose its
    # separator. Both are single dots vs a run of them.
    assert normalize_transcript_for_match("我们先来……然后") == "我们先来然后"
    assert normalize_transcript_for_match("温度是22.5℃") == "温度是22.5°c"
    assert normalize_transcript_for_match("wait... what") == "waitwhat"
    # A genuinely dropped phrase still costs proportionally.
    assert transcript_match_score("我们先来——先说第一点", "我们先来说第一点") < 1.0


@pytest.mark.parametrize(
    ("spoken", "normalized"),
    [
        # A magnitude word is arithmetic, not a syllable: `二十二` is 22 and
        # `五千三百` is 5300. Left as characters they scored as edit distance
        # against the arabic probe text, so a word-for-word synthesis was
        # penalised for spelling a number the long way round.
        ("二十二度", "22度"),
        ("五千三百", "5300"),
        ("一万两千", "12000"),
        ("十", "10"),
        # `百分之` is a fraction marker, not a magnitude before a unit:
        # 百分之九十九 is 99%, and matching the leading 百 would read it as
        # `100分之99` and lose the value the percent rule had just computed.
        ("百分之九十九点九", "99.9%"),
        # A positional digit sequence carries no magnitude and must stay
        # positional: `三六九` is the digit string 369, not 3+6+9 arithmetic.
        ("三六九", "369"),
        ("二零二六", "2026"),
    ],
)
def test_normalization_resolves_chinese_magnitudes_to_arabic(
    spoken: str, normalized: str
) -> None:
    assert normalize_transcript_for_match(spoken) == normalized


def test_chinese_magnitude_spelling_scores_like_the_arabic_spelling() -> None:
    # `numbers_punct` exists to catch misread digits, so its own reference text
    # has to compare equal to the way an ASR spells those digits back. Before
    # magnitudes were resolved, a correct synthesis that said `二十二度` instead
    # of `22度` lost every character of that number to edit distance.
    assert transcript_match_score("温度是二十二度", "温度是22度") == pytest.approx(1)
    assert transcript_match_score("来了五千三百人", "来了5300人") == pytest.approx(1)


def test_magnitude_normalization_still_catches_a_misread_number() -> None:
    # Resolving magnitudes must not become a rubber stamp: 25 and 22 are
    # different numbers and have to stay different numbers.
    assert transcript_match_score("温度是22.5℃", "温度是二十五摄氏度") < 0.98
    assert transcript_match_score("五千三百人", "五千三百人") == pytest.approx(1)
    assert transcript_match_score("五千三百人", "五千三百二十人") < 1


@pytest.mark.parametrize(
    ("expected", "actual", "matches"),
    [
        # The whole point of the numbers probe: a misread digit must not survive
        # as a small edit distance. `22.5` read as `25` is one character off in
        # a 44-character probe -- comfortably `pass` -- while the number itself
        # is simply wrong.
        ("温度是22.5℃", "温度是25℃", False),
        ("今天是9月9日", "今天是9月19日", False),
        ("温度是22.5℃", "温度是22.5℃", True),
        # Equivalent spellings normalize to the same digits before comparison.
        ("温度是22.5℃", "温度是二十二点五摄氏度", True),
        ("来了五千三百人", "来了5300人", True),
        # A dropped or invented digit is a mismatch too, even though the
        # surrounding sentence is intact.
        ("请按3、6、9的顺序", "请按3、6的顺序", False),
    ],
)
def test_transcript_numbers_match_compares_digits_exactly(
    expected: str, actual: str, matches: bool
) -> None:
    assert transcript_numbers_match(expected, actual) is matches


def test_transcript_numbers_match_ignores_probes_without_digits() -> None:
    # Nothing to compare must not read as "matched" or "mismatched"; callers
    # decide applicability from whether the probe text carries digits at all.
    assert transcript_numbers_match("今天天气真好", "今天天气真好") is True
    assert probe_carries_digits("今天天气真好，我们开个会吧。") is False
    assert probe_carries_digits("温度是22.5℃") is True


@pytest.mark.parametrize(
    ("expected", "actual", "matches"),
    [
        # A speaker reading a long digit string swaps in the clarification
        # characters so 1/7 and 0/O stay apart, and the ASR hands them back
        # verbatim. `幺幺零` and `110` are the same number; before the fold the
        # clarifiers were dropped as non-numeric and the run compared as `0`
        # against `110`, rejecting a voice that said the right thing.
        ("报警电话是110", "报警电话是幺幺零", True),
        ("我的号码是13800138000", "我的号码是一三八零零一三八零零零", True),
        # Folding is not a rubber stamp: the clarification characters carry
        # their own digits, so a wrong one is still a wrong number.
        ("我的号码是13800138000", "我的号码是一三八零零幺三八丁", False),
    ],
)
def test_digit_clarifiers_fold_inside_a_digit_run(
    expected: str, actual: str, matches: bool
) -> None:
    assert transcript_numbers_match(expected, actual) is matches


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("园丁在浇水", "园丁在浇水"),
        ("幺妹回来了", "幺妹回来了"),
        ("尜尖货", "尜尖货"),
        # The quantifier in `一点丁点` is two digit characters next to each
        # other. Reading a run of two as a digit string turned it into `13`.
        ("这是一丁点", "这是1丁点"),
    ],
)
def test_digit_clarifiers_never_touch_ordinary_words(
    text: str, expected: str
) -> None:
    assert normalize_transcript_for_match(text) == expected


@pytest.mark.parametrize(
    ("expected", "actual", "matches"),
    [
        # `09` and `9` are the same number, so a date spoken with zero padding
        # has to match one heard without it.
        ("编号是07", "编号是七", True),
        ("值是09.5", "值是9.5", True),
        # Only the integer part loses its padding: these two really differ.
        ("占比是0.05%", "占比是0.5%", False),
    ],
)
def test_leading_zeros_are_compared_by_value(
    expected: str, actual: str, matches: bool
) -> None:
    assert transcript_numbers_match(expected, actual) is matches


@pytest.mark.parametrize(
    ("misread", "edit_distance"),
    [
        # Both numbers below are the exact readings issue #127 tabulated: a
        # wrong temperature and a wrong day, each clearing the 0.92 `pass` bar
        # on character distance alone while the number itself is wrong.
        ("今天是2026年9月9日，温度是25℃，请你告诉我 3、6、9 的顺序。", 0.9375),
        ("今天是2026年9月19日，温度是22.5℃，请你告诉我 3、6、9 的顺序。", 0.96969),
    ],
)
def test_a_misread_number_survives_edit_distance_but_not_the_digit_check(
    misread: str, edit_distance: float
) -> None:
    probe = next(p for p in VOICE_QUALITY_V1_ZH_PROBES if p["id"] == "numbers_punct")
    assert transcript_match_score(probe["text"], misread) == pytest.approx(
        edit_distance, abs=1e-4
    )
    assert transcript_match_score(probe["text"], misread) >= 0.92  # would pass today
    assert transcript_numbers_match(probe["text"], misread) is False


def test_every_fixed_probe_applies_the_digit_check_when_it_carries_digits() -> None:
    # `pause_markers` reads 第一点 / 第二点, which normalization renders with
    # digits, so it is covered too: a swapped ordinal is just as wrong as a
    # swapped temperature. Applicability is derived from the text rather than
    # from a probe id so a future numeric probe is covered without edits.
    covered = {
        probe["id"] for probe in VOICE_QUALITY_V1_ZH_PROBES if probe_carries_digits(probe["text"])
    }
    assert "numbers_punct" in covered
    assert covered == {"numbers_punct", "pause_markers"}


def test_transcript_match_rejects_unrelated_text() -> None:
    assert transcript_match_score("今天天气真好，我们开个会吧。", "完全错误的内容") < 0.5


def test_report_to_dict_matches_openapi_shape_field_for_field() -> None:
    report = VoiceQualityReport(
        policy_version=POLICY_VERSION,
        status=VoiceQualityStatus.PASS.value,
        run_id="vqr_0123456789abcdef0123456789abcdef",
        tested_at="2026-09-09T12:00:00Z",
        reference=VoiceQualityReference(
            duration_seconds=8.4,
            sample_rate=24_000,
            channels=1,
            speech_active_ratio=0.78,
            noise_floor_dbfs=-52.1,
            estimated_snr_db=28.4,
            clipping_ratio=0.0,
            leading_silence_seconds=0.21,
            trailing_silence_seconds=0.34,
            transcript_match=0.998,
        ),
        synthesis=VoiceQualitySynthesis(
            probe_count=3,
            successful_probe_count=3,
            active_rms_dbfs=-20.8,
            peak_dbfs=-3.2,
            chunk_jump_p95_db=4.6,
            clipping_ratio=0.0,
            deterministic=True,
        ),
        failure_codes=[],
    )

    data = report.to_dict()

    assert set(data.keys()) == {
        "policy_version",
        "status",
        "run_id",
        "tested_at",
        "reference",
        "synthesis",
        "failure_codes",
    }
    assert set(data["reference"].keys()) == {
        "duration_seconds",
        "sample_rate",
        "channels",
        "speech_active_ratio",
        "noise_floor_dbfs",
        "estimated_snr_db",
        "clipping_ratio",
        "leading_silence_seconds",
        "trailing_silence_seconds",
        "transcript_match",
    }
    assert set(data["synthesis"].keys()) == {
        "probe_count",
        "successful_probe_count",
        "active_rms_dbfs",
        "peak_dbfs",
        "chunk_jump_p95_db",
        "clipping_ratio",
        "deterministic",
        "transcript_match",
        "intelligibility_evaluated",
        "probe_scores",
    }
    assert data["reference"]["transcript_match"] == 0.998


def test_report_from_dict_round_trips_and_ignores_unknown_fields() -> None:
    reference = replace(_passing_reference(), transcript_match=0.998)
    report = make_quality_report(reference, _synthesis(), transcript_match=0.998)

    payload = report.to_dict()
    payload["extra_top_level"] = "ignored"
    payload["reference"]["extra_reference"] = 123
    payload["synthesis"]["extra_synthesis"] = True
    payload["failure_codes"].append("unknown_code")

    restored = VoiceQualityReport.from_dict(payload)

    assert restored.policy_version == report.policy_version
    assert restored.status == report.status
    assert restored.run_id == report.run_id
    assert restored.tested_at == report.tested_at
    assert restored.reference == report.reference
    assert restored.synthesis == report.synthesis
    # unknown failure codes are filtered out by the fixed enum
    assert restored.failure_codes == report.failure_codes


def test_probe_scores_round_trip_and_default_to_empty() -> None:
    # The aggregate `transcript_match` is a `min()`, so the per-probe breakdown
    # is the only way to attribute a rejection to one probe. It must survive
    # serialization and must stay optional for reports built without it.
    assert VoiceQualitySynthesis(
        probe_count=0,
        successful_probe_count=0,
        active_rms_dbfs=0.0,
        peak_dbfs=0.0,
        chunk_jump_p95_db=0.0,
        clipping_ratio=0.0,
        deterministic=False,
    ).to_dict()["probe_scores"] == []

    synthesis = VoiceQualitySynthesis(
        probe_count=6,
        successful_probe_count=6,
        active_rms_dbfs=-20.8,
        peak_dbfs=-3.2,
        chunk_jump_p95_db=4.6,
        clipping_ratio=0.0,
        deterministic=True,
        transcript_match=0.9091,
        intelligibility_evaluated=True,
        probe_scores=[
            # A numeric probe carries a digit verdict; one without digits stays
            # `None`, which is a different thing from "checked and mismatched".
            VoiceQualityProbeScore(
                probe_id="numbers_punct", transcript_match=0.9375, numbers_exact=False
            ),
            VoiceQualityProbeScore(
                probe_id="short_sentence", transcript_match=1.0, numbers_exact=None
            ),
        ],
    )

    payload = synthesis.to_dict()
    assert payload["probe_scores"] == [
        {"probe_id": "numbers_punct", "transcript_match": 0.9375, "numbers_exact": False},
        {"probe_id": "short_sentence", "transcript_match": 1.0, "numbers_exact": None},
    ]
    assert VoiceQualitySynthesis.from_dict(payload) == synthesis

    # A payload written before `probe_scores` existed must still load.
    legacy = dict(payload)
    del legacy["probe_scores"]
    assert VoiceQualitySynthesis.from_dict(legacy).probe_scores == []

    # A payload written before `numbers_exact` existed must load too, and must
    # not silently claim a digit verdict that was never made.
    assert VoiceQualityProbeScore.from_dict(
        {"probe_id": "numbers_punct", "transcript_match": 0.9375}
    ).numbers_exact is None


def test_report_from_dict_round_trips_synthesis_failure_codes() -> None:
    reference = replace(_passing_reference(), transcript_match=0.998)
    report = make_quality_report(reference, _synthesis(), transcript_match=0.998)

    payload = report.to_dict()
    payload["failure_codes"] = ["clone_speed_unsupported", "output_invalid"]

    restored = VoiceQualityReport.from_dict(payload)

    # Both synthesis-side codes belong to the 9-code OpenAPI failure_codes enum
    # and must survive the round-trip instead of being dropped by the filter.
    assert restored.failure_codes == ["clone_speed_unsupported", "output_invalid"]


def test_make_quality_report_run_id_and_tested_at_formats() -> None:
    report = make_quality_report(_passing_reference(), _synthesis())

    assert report.policy_version == "voice_quality_v1"
    assert report.status == VoiceQualityStatus.PASS.value
    assert report.run_id.startswith("vqr_")
    assert len(report.run_id) == 36  # "vqr_" + 32 hex chars
    assert all(c in "0123456789abcdef" for c in report.run_id[4:])
    assert report.tested_at.endswith("Z")
    parsed = datetime.fromisoformat(report.tested_at.replace("Z", "+00:00"))
    assert parsed.tzinfo is not None


def test_make_quality_report_grades_into_failure_codes() -> None:
    reference = replace(_passing_reference(), clipping_ratio=0.002)  # reject
    report = make_quality_report(reference, _synthesis())
    assert report.status == VoiceQualityStatus.REJECT.value
    assert report.failure_codes == ["clipping"]


def test_output_gate_report_carries_no_reference_block() -> None:
    # `POST /v1/voices/{id}/quality-runs` is an output gate: it never grades the
    # reference audio. It used to fill the block with all-zero placeholders, and
    # every one of those zeros is the *worst* reading for its metric, so the report
    # said "reference is 0s long at 0 dB SNR" for a run that measured nothing.
    # Reporting `null` says the honest thing: not evaluated on this path. The
    # reference side is graded separately, at clone time, into the profile.
    report = VoiceQualityReport(
        policy_version=POLICY_VERSION,
        status=VoiceQualityStatus.PASS.value,
        run_id="vqr_0123456789abcdef0123456789abcdef",
        tested_at="2026-10-02T00:00:00Z",
        reference=None,
        synthesis=_synthesis(),
        failure_codes=[],
    )

    payload = report.to_dict()

    assert "reference" in payload
    assert payload["reference"] is None
    assert VoiceQualityReport.from_dict(payload).reference is None


# ---------------------------------------------------------------------------
# Signal metrics (mono PCM16) sanity checks
# ---------------------------------------------------------------------------


def test_duration_seconds() -> None:
    sample_rate = 24_000
    seconds = 2.0
    pcm = b"\x00\x00" * int(sample_rate * seconds)
    assert duration_seconds(pcm, sample_rate) == pytest.approx(seconds)


def test_clipping_ratio_detects_full_scale_and_clean_signal() -> None:
    assert clipping_ratio(_pcm16([0, 1000, -1000, 500])) == 0.0
    assert clipping_ratio(_pcm16([32767, -32768, 0, 32767])) == 0.75


def test_speech_active_ratio_silence_vs_speech() -> None:
    sample_rate = 24_000
    assert speech_active_ratio(b"\x00\x00" * sample_rate, sample_rate) == 0.0
    assert speech_active_ratio(_sine_pcm16(1.0, sample_rate), sample_rate) == 1.0


def test_leading_trailing_silence_seconds() -> None:
    sample_rate = 24_000
    half_second = sample_rate // 2
    pcm = (
        b"\x00\x00" * half_second
        + _sine_pcm16(1.0, sample_rate)
        + b"\x00\x00" * half_second
    )
    leading, trailing = leading_trailing_silence_seconds(pcm, sample_rate)
    assert leading == pytest.approx(0.5, abs=0.02)
    assert trailing == pytest.approx(0.5, abs=0.02)


def test_noise_floor_and_snr_for_silence_and_speech() -> None:
    sample_rate = 24_000
    assert noise_floor_dbfs(b"\x00\x00" * sample_rate) == -120.0
    loud = _sine_pcm16(1.0, sample_rate)
    assert noise_floor_dbfs(loud) < -20.0
    assert estimated_snr_db(loud, sample_rate) > 5.0


# ---------------------------------------------------------------------------
# Fixed probe set
# ---------------------------------------------------------------------------


def test_voice_quality_v1_zh_probes_are_fixed_six_entry_set() -> None:
    assert len(VOICE_QUALITY_V1_ZH_PROBES) == 6

    probes = list(VOICE_QUALITY_V1_ZH_PROBES)
    ids = [probe["id"] for probe in probes]
    texts = [probe["text"] for probe in probes]
    categories = {probe["category"] for probe in probes}

    assert len(set(ids)) == 6
    assert "请进行自我介绍" in texts
    assert {"short", "long", "question", "numbers_punct", "pauses"}.issubset(categories)
    for probe in probes:
        assert set(probe.keys()) == {"id", "category", "text"}


# ---------------------------------------------------------------------------
# VoiceProfile backward compatibility (missing quality == unevaluated)
# ---------------------------------------------------------------------------


def test_voice_profile_to_dict_omits_quality_when_missing() -> None:
    profile = VoiceProfile(id="v1", name="voice one")
    assert "quality" not in profile.to_dict()


def test_voice_profile_to_dict_includes_quality_when_present() -> None:
    quality: dict[str, object] = {
        "policy_version": "voice_quality_v1",
        "status": VoiceQualityStatus.UNEVALUATED.value,
    }
    profile = VoiceProfile(id="v1", name="voice one", quality=quality)
    assert profile.to_dict()["quality"] == quality


def test_profile_from_record_parses_optional_quality(tmp_path: Path) -> None:
    registry = VoiceRegistry(
        storage_path=tmp_path / "registry.json",
        voices_dir=tmp_path / "voices",
    )
    quality: dict[str, object] = {
        "policy_version": "voice_quality_v1",
        "status": VoiceQualityStatus.WARN.value,
    }
    record: dict[str, object] = {
        "id": "myvoice",
        "name": "My Voice",
        "instruction": "test",
        "mode": "instruction",
        "quality": quality,
    }
    profile = registry._profile_from_record(record)
    assert profile.quality == quality

    without_quality = dict(record)
    del without_quality["quality"]
    profile_missing = registry._profile_from_record(without_quality)
    assert profile_missing.quality is None


def test_create_cloned_profile_accepts_and_persists_quality(tmp_path: Path) -> None:
    storage_path = tmp_path / "registry.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)

    quality: dict[str, object] = {
        "policy_version": "voice_quality_v1",
        "status": VoiceQualityStatus.PASS.value,
        "run_id": "vqr_test",
    }
    profile = registry.create_cloned_profile(
        name="clone",
        ref_text="你好，世界。",
        audio_bytes=_wav_bytes(3.0),
        voice_id="clone_with_quality",
        duration_seconds=3.0,
        quality=quality,
    )
    assert profile.quality == quality

    reloaded_registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)
    reloaded = reloaded_registry.get_profile("clone_with_quality")
    assert reloaded.quality == quality


def _clipped_wav_bytes(
    duration_seconds: float = 4.0, sample_rate: int = 24_000, clip_ratio: float = 0.01
) -> bytes:
    """Speech-like WAV with a controlled fraction of full-scale (clipped) samples."""
    count = int(duration_seconds * sample_rate)
    samples: list[int] = []
    for index in range(count):
        value = round(
            0.5 * 32767.0 * math.sin(2.0 * math.pi * 440.0 * index / sample_rate)
        )
        samples.append(max(-32767, min(32767, value)))
    step = max(1, int(1.0 / clip_ratio))
    for index in range(0, count, step):
        samples[index] = 32767
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(_pcm16(samples))
    return buf.getvalue()


def test_transcode_skip_signal_validation_param() -> None:
    # 1% clipping exceeds the 0.5% signal-validation rail, so the default path
    # rejects; skip_signal_validation=True must bypass that rail entirely.
    clipped = _clipped_wav_bytes(4.0, clip_ratio=0.01)
    with patch("subprocess.run") as mock_run:
        mock_run.return_value = SimpleNamespace(returncode=0, stdout=clipped, stderr=b"")
        with pytest.raises(ValueError, match="clipped"):
            transcode_and_validate_clone_audio(b"raw")
        wav_out, duration = transcode_and_validate_clone_audio(
            b"raw", skip_signal_validation=True
        )
    assert duration == pytest.approx(4.0, abs=0.1)
    assert len(wav_out) == len(clipped)


def test_create_cloned_profile_quality_defaults_to_none(tmp_path: Path) -> None:
    registry = VoiceRegistry(
        storage_path=tmp_path / "registry.json",
        voices_dir=tmp_path / "voices",
    )
    profile = registry.create_cloned_profile(
        name="clone",
        ref_text="你好，世界。",
        audio_bytes=_wav_bytes(3.0),
        voice_id="clone_no_quality",
        duration_seconds=3.0,
    )
    assert profile.quality is None


def test_voice_registry_updates_instruction_profile_and_persists_it(tmp_path: Path) -> None:
    storage_path = tmp_path / "registry.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)
    registry.create_custom_profile(
        name="原始名称",
        instruction="自然清晰",
        voice_id="update_instruction",
        seed=123,
    )

    updated = registry.update_custom_profile(
        "update_instruction",
        name="更新名称",
        instruction="沉稳温暖",
        seed=2026,
    )

    assert updated.name == "更新名称"
    assert updated.instruction == "沉稳温暖"
    assert updated.seed == 2026
    reloaded = VoiceRegistry(storage_path=storage_path, voices_dir=voices_dir)
    assert reloaded.get_profile("update_instruction") == updated


def test_voice_registry_only_allows_name_update_for_clone_profile(tmp_path: Path) -> None:
    registry = VoiceRegistry(
        storage_path=tmp_path / "registry.json",
        voices_dir=tmp_path / "voices",
    )
    clone = registry.create_cloned_profile(
        name="参考音色",
        ref_text="你好，世界。",
        audio_bytes=_wav_bytes(3.0),
        voice_id="update_clone",
        duration_seconds=3.0,
    )

    renamed = registry.update_custom_profile("update_clone", name="新的参考音色")

    assert renamed.name == "新的参考音色"
    assert renamed.ref_text == clone.ref_text
    with pytest.raises(VoiceUpdateUnsupportedError):
        registry.update_custom_profile("update_clone", instruction="不应替换来源")
