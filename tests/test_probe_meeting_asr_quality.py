"""Synthetic PCM and fake ASR only; no model or corpus access."""

from __future__ import annotations

import asyncio
import json
from dataclasses import replace
from pathlib import Path

import pytest
from meeting_evaluation_identity import MeetingCandidateSpec, canonical_digest
from probe_meeting_asr_quality import (
    ASR_SCORER,
    AsrAdmission,
    AsrCase,
    RuntimeObservation,
    compare_asr_runs,
    replay_long_blocks,
    replay_production_windows,
)

from speechrail.domain.asr_window import WindowDecodeObservation, WindowDecodeResult, WindowPolicy
from speechrail.realtime.speech_admission import AdmissionDecision


def admit_all(span, pcm):
    return AsrAdmission((AdmissionDecision("audio", span.start, span.end, pcm),), span.end)


def spec():
    return MeetingCandidateSpec(
        implementation_id="synthetic-asr",
        adapter_sha256="a" * 64,
        sdk_revision="fixture",
        worker_sha256="b" * 64,
        model_revision="fixture",
        model_files_sha256={"weights.bin": "c" * 64},
        dtype="fixture",
        preset={
            "window_policy": WindowPolicy.for_scene("meeting").to_wire_dict(),
            "vad": "synthetic-all-admitted",
            "language": None,
            "context": "empty",
        },
        compute_units="fixture",
        decoder={"max_tokens": 128, "timestamps": False},
        attribution={"algorithm": "none"},
        scorer=ASR_SCORER,
    )


def case(group="source-1", reference="甲乙丙丁", seconds=1):
    return AsrCase(group, "d" * 64, bytes(seconds * 16000 * 2), reference, "unambiguous")


class Decoder:
    def __init__(self, text="甲乙", *, complete=True, failure=None, observe_decode=True):
        self.observe_decode = observe_decode
        self.text, self.complete, self.failure = text, complete, failure
        self.calls = []
        self.closed = False

    async def decode(self, request):
        self.calls.append(request)
        if self.failure:
            raise self.failure("private transcript and /private/model")
        return WindowDecodeResult(
            request.identity,
            request.attempt_id,
            request.input_span,
            self.text,
            None,
            self.complete,
            WindowDecodeObservation(request.kind, 32, finish_reason="eos", truncated=False)
            if self.observe_decode
            else None,
        )

    async def close(self):
        self.closed = True


def observation(candidate=None, origin="fake"):
    return lambda: RuntimeObservation((candidate or spec()).as_dict(), origin)


def run(data=None, text="甲乙", *, candidate=None, origin="fake", **kwargs):
    decoder = Decoder(text, **kwargs)
    result = asyncio.run(
        replay_long_blocks(
            data or case(),
            candidate or spec(),
            decoder,
            observe=observation(candidate, origin),
        )
    )
    return result, decoder


def policy():
    return json.loads(
        (Path(__file__).parents[1] / "examples/perf/meeting-evaluation-policy.json").read_text()
    )


def test_calls_current_session_with_identical_pcm_without_reference_in_context():
    data = case()
    result, decoder = run(data)
    assert decoder.calls[0].pcm16 == data.pcm16
    assert decoder.calls[0].context == ""
    assert decoder.calls[0].kind == "review"
    assert decoder.closed
    assert result["actual_decode_calls"] == 1
    assert result["metrics"]["normalized"]["cer"] == 0.5
    assert result["certification_eligible"] is False
    assert result["execution_origin"] == "fake"


def test_actual_identity_mismatch_fails_before_decode_and_closes_session():
    decoder = Decoder()
    observed = replace(spec(), dtype="wrong")
    with pytest.raises(ValueError, match="dtype"):
        asyncio.run(replay_long_blocks(case(), spec(), decoder, observe=observation(observed)))
    assert decoder.calls == []
    assert decoder.closed


def test_observed_identity_is_checked_after_calls_too():
    decoder = Decoder()
    observations = iter(
        [
            RuntimeObservation(spec().as_dict()),
            RuntimeObservation(replace(spec(), dtype="changed").as_dict()),
        ]
    )
    with pytest.raises(ValueError, match="dtype"):
        asyncio.run(replay_long_blocks(case(), spec(), decoder, observe=lambda: next(observations)))
    assert len(decoder.calls) == 1
    assert decoder.closed


def test_long_blocks_are_fixed_audio_chunks_and_never_production_candidates():
    result, decoder = run(case(seconds=61))
    assert [r.input_span.length for r in decoder.calls] == [480000, 480000, 16000]
    assert result["mode"] == "bounded_long_block_diagnostic"
    assert result["certification_eligible"] is False
    with pytest.raises(ValueError, match="30"):
        asyncio.run(
            replay_long_blocks(case(), spec(), Decoder(), observe=observation(), block_seconds=31)
        )


@pytest.mark.parametrize(
    "reference,order", [(None, "unambiguous"), ("甲乙", "ambiguous"), ("!!!", "unambiguous")]
)
def test_missing_main_reference_or_overlap_order_has_no_primary_denominator(reference, order):
    result, _ = run(replace(case(), main_reference=reference, overlap_order=order))
    assert result["metrics"]["normalized"]["cer"] is None
    assert result["metrics"]["availability"] == "not_observed"
    assert result["quality_evidence_valid"] is False


def test_raw_and_normalized_metrics_are_distinct_and_do_not_rewrite_facts():
    result, _ = run(case(reference="Ａ，乙1"), "a乙2")
    assert result["metrics"]["raw"]["cer"] == 0.75
    assert result["metrics"]["normalized"]["cer"] == pytest.approx(1 / 3)
    assert result["metrics"]["normalized"]["wer"] == pytest.approx(1 / 3)
    assert result["diagnostics"]["key_facts_review"] == "not_observed"
    serialized = json.dumps(result, ensure_ascii=False)
    assert "Ａ" not in serialized and "a乙2" not in serialized
    assert "source-1" not in serialized and "/private/" not in serialized


@pytest.mark.parametrize(
    "options,reason",
    [
        ({"complete": False}, "incomplete_decode"),
        ({"failure": TimeoutError}, "decode_timeout"),
        ({"failure": RuntimeError}, "decode_failed"),
    ],
)
def test_incomplete_timeout_and_failed_calls_cannot_pass(options, reason):
    result, _ = run(**options)
    assert reason in result["failures"]
    assert result["quality_evidence_valid"] is False


def test_incomplete_observation_does_not_replace_production_recovery_policy():
    from probe_meeting_asr_quality import _RecordedSession

    from speechrail.domain.asr_window import WindowDecodeRequest, WindowIdentity
    from speechrail.domain.audio_timeline import SampleSpan

    async def run_recorded():
        data = case()
        decoder = Decoder(complete=False)
        recorded = _RecordedSession(decoder, data, 30, 128)
        request = WindowDecodeRequest(
            WindowIdentity("s", 0, "w"), "attempt", "review", SampleSpan(0, 16000),
            data.pcm16, None, "",
        )
        result = await recorded.decode(request)
        assert result.complete is False
        assert recorded.failures == {"incomplete_decode"}
        assert recorded.calls == 1

    asyncio.run(run_recorded())


def test_unobserved_decode_limit_and_caller_report_are_not_certified():
    result = asyncio.run(
        replay_long_blocks(
            case(),
            spec(),
            Decoder(observe_decode=False),
            observe=lambda: RuntimeObservation(spec().as_dict(), "runtime_observed"),
        )
    )
    assert "decode_limit_not_observed" in result["failures"]
    assert result["certification_eligible"] is False
    assert RuntimeObservation(spec().as_dict()).origin == "caller_reported"


def test_bounded_diagnostic_requires_same_weights_for_comparison():
    old, _ = run()
    new, _ = run(candidate=replace(spec(), model_revision="different"))
    with pytest.raises(ValueError, match="weights"):
        compare_asr_runs([old], [new], policy=policy())


@pytest.mark.parametrize(
    "field", ["pcm_sha256", "reference_sha256", "manifest_sha256", "scorer_sha256", "case_sha256"]
)
def test_paired_runs_require_same_audio_reference_and_policy(field):
    old, _ = run()
    new = {**old, field: "e" * 64}
    with pytest.raises(ValueError, match="paired"):
        compare_asr_runs([old], [new], policy=policy())


def test_a0_zero_cer_relative_improvement_is_null_not_infinity():
    old, _ = run(text="甲乙丙丁")
    result = compare_asr_runs([old], [old], policy=policy())
    assert result["relative_cer_improvement"] is None
    assert result["quality_gate"] == "fail"


def test_repeats_stay_in_the_same_source_group_and_ci_needs_independent_groups():
    old, _ = run()
    new, _ = run(text="甲乙丙丁")
    result = compare_asr_runs([old, old], [new, new], policy=policy())
    assert result["paired_cer"]["groups"] == 1
    assert result["paired_cer"]["upper"] is None
    assert result["quality_gate"] == "fail"


def test_ten_percent_and_strict_negative_ci_and_manual_facts_are_separate():
    old, _ = run()
    new, _ = run(text="甲乙丙丁")
    old2, _ = run(case("source-2"))
    new2, _ = run(case("source-2"), text="甲乙丙丁")
    result = compare_asr_runs([old, old2], [new, new2], policy=policy())
    assert result["relative_cer_improvement"] == 1
    assert result["paired_cer"]["upper"] < 0
    assert result["development_text_gate"] == "pass"
    assert result["quality_gate"] == "fail"
    assert result["key_facts_review"] == "not_observed"
    assert result["certification_eligible"] is False


def test_production_coordinator_is_exercised_and_fakeclock_exposes_long_final_wait():
    async def exercise():
        now = [0.0]
        decoder = Decoder("甲乙丙丁")

        async def pace(seconds):
            now[0] += seconds

        result = await replay_production_windows(
            case(seconds=23),
            spec(),
            decoder,
            observe=observation(),
            admission=lambda span, pcm: (
                admit_all(span, pcm) if span.end <= 320000 else AsrAdmission((), span.end)
            ),
            pace=pace,
            clock=lambda: now[0],
        )
        return result, decoder

    result, decoder = asyncio.run(exercise())
    assert result["mode"] == "production_window"
    assert result["actual_decode_calls"] > 1
    assert decoder.closed
    assert result["coverage_samples"] == 23 * 16000
    assert result["quality_evidence_valid"] is True
    assert result["diagnostics"]["first_final_seconds"] >= 22
    assert result["diagnostics"]["final_timing_scope"] == "synthetic_or_runtime_replay_not_p95"


def test_production_replay_rejects_input_gap_and_duplicate_admission():
    async def exercise():
        async def pace(seconds):
            pass

        return await replay_production_windows(
            case(),
            spec(),
            Decoder(),
            observe=observation(),
            pace=pace,
            admission=lambda span, pcm: AsrAdmission(
                (AdmissionDecision("audio", span.start, span.end, pcm),) * 2, span.end
            ),
        )

    with pytest.raises(ValueError, match="admission"):
        asyncio.run(exercise())


def test_frozen_case_and_policy_hashes_are_canonical():
    data = case()
    assert data.reference_sha256 == canonical_digest(
        {"main_reference": "甲乙丙丁", "overlap_order": "unambiguous"}
    )
    assert spec().scorer == ASR_SCORER


def test_hung_decode_has_explicit_timeout_without_vendor_message():
    class HungDecoder(Decoder):
        async def decode(self, request):
            await asyncio.Event().wait()

    result = asyncio.run(
        replay_long_blocks(
            case(), spec(), HungDecoder(), observe=observation(), decode_timeout_seconds=0.001
        )
    )
    assert "decode_timeout" in result["failures"]
    assert result["quality_evidence_valid"] is False


def test_frozen_candidate_cannot_change_between_source_groups():
    old, _ = run()
    new, _ = run(text="甲乙丙丁")
    old2, _ = run(case("source-2"))
    new2, _ = run(
        case("source-2"), text="甲乙丙丁", candidate=replace(spec(), adapter_sha256="e" * 64)
    )
    with pytest.raises(ValueError, match="frozen candidate"):
        compare_asr_runs([old, old2], [new, new2], policy=policy())


def test_zero_actual_calls_or_invalid_coverage_cannot_pass_even_with_good_cer():
    old, _ = run()
    new, _ = run(text="甲乙丙丁")
    for mutation in (
        {"actual_decode_calls": 0},
        {"actual_decode_calls": True},
        {"coverage_samples": 0},
        {"failures": ["decode_timeout"]},
    ):
        result = compare_asr_runs([old], [{**new, **mutation}], policy=policy())
        assert result["paired_cer"] is None
        assert result["development_text_gate"] == "fail"
        assert result["quality_gate"] == "fail"


def test_token_limit_hit_and_changed_normalization_remain_fail_closed():
    result = asyncio.run(
        replay_long_blocks(
            case(),
            spec(),
            ObservedDecoder(
                WindowDecodeObservation("review", 32, finish_reason="length", truncated=True)
            ),
            observe=lambda: RuntimeObservation(spec().as_dict(), "fake"),
        )
    )
    assert "decode_limit_hit" in result["failures"]
    assert result["quality_evidence_valid"] is False
    changed = replace(spec(), scorer={**ASR_SCORER, "character": "delete_difficult_facts"})
    with pytest.raises(ValueError, match="scorer"):
        run(candidate=changed)


def test_forced_aligner_only_change_cannot_produce_body_improvement():
    old, _ = run()
    new, _ = run(candidate=replace(spec(), attribution={"algorithm": "forced-aligner"}))
    result = compare_asr_runs([old], [new], policy=policy())
    assert result["relative_cer_improvement"] == 0
    assert result["development_text_gate"] == "fail"


def test_error_category_does_not_call_a_timeout_acoustic_or_truncation_evidence():
    result, _ = run(failure=TimeoutError)
    categories = result["diagnostics"]["error_categories"]
    assert categories["truncation_or_repetition"] == "not_proven"
    assert categories["acoustic_substitution"] == "not_proven"


def test_multiple_production_terminals_score_sealed_text_in_sample_order():
    async def exercise():
        now = [0.0]

        async def pace(seconds):
            now[0] += seconds

        return await replay_production_windows(
            case(reference="甲乙甲乙甲乙", seconds=41),
            spec(),
            Decoder("甲乙"),
            observe=observation(),
            admission=admit_all,
            pace=pace,
            clock=lambda: now[0],
        )

    result = asyncio.run(exercise())
    assert result["metrics"]["normalized"]["cer"] == 0
    assert result["quality_evidence_valid"] is True


def test_delayed_vad_preroll_uses_explicit_retained_frontier_and_eof_drain():
    from speechrail.realtime.speech_admission import SpeechAdmission

    async def exercise():
        now = [0.0]
        vad = SpeechAdmission(start_frames=3, frame_samples=512, prefix_samples=512)

        async def pace(seconds):
            now[0] += seconds

        def admit(span, pcm):
            decisions = vad.push(pcm, start_sample=span.start, probability=1)
            return AsrAdmission(decisions, vad.retained_from_sample)

        def finish():
            return AsrAdmission(vad.finish(), len(data.pcm16) // 2)

        data = case()
        return await replay_production_windows(
            data,
            spec(),
            Decoder("甲乙丙丁"),
            observe=observation(),
            admission=admit,
            finish_admission=finish,
            feed_samples=512,
            pace=pace,
            clock=lambda: now[0],
        )

    result = asyncio.run(exercise())
    assert result["quality_evidence_valid"] is True
    assert result["metrics"]["normalized"]["cer"] == 0


def test_unknown_vad_tail_cannot_be_scored_as_confirmed_silence():
    async def exercise():
        async def pace(seconds):
            pass

        return await replay_production_windows(
            case(),
            spec(),
            Decoder(),
            observe=observation(),
            admission=lambda span, pcm: AsrAdmission((), 0),
            pace=pace,
        )

    result = asyncio.run(exercise())
    assert "vad_tail_not_drained" in result["failures"]
    assert result["quality_evidence_valid"] is False


def test_scorer_constant_is_immutable_and_fake_baseline_is_not_actual_a0():
    with pytest.raises(TypeError):
        ASR_SCORER["character"] = "delete-facts"
    old, _ = run()
    result = compare_asr_runs([old], [old], policy=policy())
    assert result["a0_execution"] == "not_observed"
    assert result["baseline"] == "unverified_replay"


def test_replay_grid_is_recorded_and_cannot_change_inside_an_arm():
    old, _ = run()
    old2, _ = run(case("source-2"))
    new, _ = run(text="甲乙丙丁")
    new2 = asyncio.run(
        replay_long_blocks(
            case("source-2"), spec(), Decoder("甲乙丙丁"), observe=observation(), block_seconds=20
        )
    )
    assert new["replay_policy_sha256"] != new2["replay_policy_sha256"]
    with pytest.raises(ValueError, match="frozen replay"):
        compare_asr_runs([old, old2], [new, new2], policy=policy())


def test_zero_ci_upper_cannot_satisfy_positive_improvement_gate():
    old, _ = run()
    new, _ = run(text="甲乙丙丁")
    old2, _ = run(case("source-2"), text="甲乙丙丁")
    result = compare_asr_runs([old, old2], [new, old2], policy=policy())
    assert result["relative_cer_improvement"] == 1
    assert result["paired_cer"]["upper"] == 0
    assert result["development_text_gate"] == "fail"


def test_five_percent_point_improvement_cannot_satisfy_ten_percent_gate():
    old, new = [], []
    for source in ("source-1", "source-2"):
        data = case(source, reference="甲" * 100)
        old.append(run(data, text="甲" * 80)[0])
        new.append(run(data, text="甲" * 81)[0])
    result = compare_asr_runs(old, new, policy=policy(), key_facts_review="pass")
    assert result["relative_cer_improvement"] == pytest.approx(0.05)
    assert result["paired_cer"]["upper"] < 0
    assert result["development_text_gate"] == "fail"
    assert result["quality_gate"] == "fail"


def test_self_reported_runtime_origin_cannot_certify_injected_adapters_or_clock():
    async def exercise():
        async def pace(seconds):
            pass

        return await replay_production_windows(
            case(),
            spec(),
            Decoder(),
            observe=observation(origin="runtime_observed"),
            admission=admit_all,
            pace=pace,
            clock=lambda: 0,
        )

    result = asyncio.run(exercise())
    assert result["execution_identity_matches"] is True
    assert result["runtime_identity_verified"] is False
    assert result["certification_eligible"] is False


def test_cancelled_replay_joins_close_even_with_repeated_cancellation():
    async def exercise():
        entered, closing, release = asyncio.Event(), asyncio.Event(), asyncio.Event()

        class DelayedDecoder(Decoder):
            async def decode(self, request):
                entered.set()
                await asyncio.Event().wait()

            async def close(self):
                closing.set()
                await release.wait()
                self.closed = True

        decoder = DelayedDecoder()
        task = asyncio.create_task(
            replay_long_blocks(case(), spec(), decoder, observe=observation())
        )
        await entered.wait()
        task.cancel()
        await closing.wait()
        task.cancel()
        await asyncio.sleep(0)
        assert not task.done()
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert decoder.closed

    asyncio.run(exercise())


def test_case_memory_bound_and_close_errors_do_not_expose_vendor_content():
    with pytest.raises(ValueError, match="memory"):
        case(seconds=601)

    class BrokenClose(Decoder):
        async def close(self):
            raise RuntimeError("private text /private/model")

    with pytest.raises(RuntimeError) as exc:
        asyncio.run(replay_long_blocks(case(), spec(), BrokenClose(), observe=observation()))
    assert str(exc.value) == "ASR session cleanup failed"


@pytest.mark.parametrize("boundary", ["observer", "admission"])
def test_external_callback_error_is_finite_and_private_text_is_not_propagated(boundary):
    def broken(*args):
        raise RuntimeError("private transcript /private/model")

    async def exercise():
        async def pace(seconds):
            pass

        return await replay_production_windows(
            case(),
            spec(),
            Decoder(),
            observe=broken if boundary == "observer" else observation(),
            admission=broken if boundary == "admission" else admit_all,
            pace=pace,
        )

    with pytest.raises(RuntimeError) as exc:
        asyncio.run(exercise())
    assert "private" not in str(exc.value)


@pytest.mark.parametrize(
    "hypothesis,expected",
    [
        ("甲丁丙", (1, 0, 0)),
        ("甲丙", (0, 1, 0)),
        ("甲乙丙丁", (0, 0, 1)),
    ],
)
def test_edit_operations_are_separate_and_sum_to_distance(hypothesis, expected):
    result, _ = run(case(reference="甲乙丙"), text=hypothesis)
    for variant in ("raw", "normalized"):
        values = result["metrics"][variant]["characters"]
        assert (values["substitutions"], values["deletions"], values["insertions"]) == expected
        assert sum(expected) == values["errors"]
        assert values["acoustic_attribution"] == "not_proven"


def test_edit_alignment_tie_uses_diagonal_before_delete_and_insert():
    result, _ = run(case(reference="甲乙"), text="乙甲")
    values = result["metrics"]["normalized"]["characters"]
    assert values["substitutions"] == 2
    assert values["insertions"] == values["deletions"] == 0


def test_primary_cer_and_ci_use_equal_source_groups_and_repeats_do_not_weight():
    short = case("short", reference="甲" * 10)
    long = case("long", reference="甲" * 100)
    old_short, _ = run(short, text="")
    old_long, _ = run(long, text="甲" * 90)
    new_short, _ = run(short, text="甲" * 10)
    new_long, _ = run(long, text="甲" * 90)
    result = compare_asr_runs(
        [old_short, old_short, old_long], [new_short, new_short, new_long], policy=policy()
    )
    assert result["baseline_pooled_cer"] == pytest.approx(20 / 110)
    assert result["candidate_pooled_cer"] == pytest.approx(10 / 110)
    assert result["baseline_macro_cer"] == pytest.approx(0.55)
    assert result["paired_cer"]["difference"] == pytest.approx(-0.5)
    assert result["paired_cer"]["groups"] == 2
    assert result["relative_cer_improvement"] == pytest.approx(10 / 11)


@pytest.mark.parametrize("value", [float("nan"), float("inf"), True])
def test_invalid_replay_clock_is_rejected_and_session_is_closed(value):
    decoder = Decoder()
    with pytest.raises(ValueError, match="clock"):
        asyncio.run(
            replay_production_windows(
                case(),
                spec(),
                decoder,
                observe=observation(),
                admission=admit_all,
                clock=lambda: value,
            )
        )
    assert decoder.closed


def test_caller_limit_claim_cannot_replace_missing_per_attempt_observation():
    with pytest.raises(TypeError):
        RuntimeObservation(spec().as_dict(), token_limit_hit=False)
    report = asyncio.run(
        replay_long_blocks(case(), spec(), Decoder(observe_decode=False), observe=observation())
    )
    assert report["quality_evidence_valid"] is False
    assert "decode_limit_not_observed" in report["failures"]
    assert report["decode_evidence"]["attempts_without_observation"] == 1


class ObservedDecoder(Decoder):
    def __init__(self, metadata, **kwargs):
        super().__init__(**kwargs)
        self.metadata = metadata

    async def decode(self, request):
        result = await super().decode(request)
        metadata = self.metadata(request) if callable(self.metadata) else self.metadata
        return replace(result, observation=metadata)


def test_actual_attempt_metadata_enables_diagnostic_evidence_without_runtime_claim():
    from speechrail.domain.asr_window import WindowDecodeObservation

    decoder = ObservedDecoder(
        lambda request: WindowDecodeObservation(
            request.kind, 32, finish_reason="eos", truncated=False
        )
    )
    report = asyncio.run(
        replay_long_blocks(
            case(), spec(), decoder, observe=lambda: RuntimeObservation(spec().as_dict())
        )
    )
    assert report["quality_evidence_valid"] is True
    assert report["decode_evidence"]["token_limit_hit"] is False
    assert report["decode_evidence"]["attempts_with_observation"] == 1
    assert report["decode_evidence"]["attempts"][0]["generation_max_new_tokens"] is None
    assert report["runtime_identity_verified"] is False
    assert report["certification_eligible"] is False


@pytest.mark.parametrize(
    "metadata,reason",
    [
        ({"finish_reason": "length", "truncated": False}, "decode_limit_hit"),
        ({"finish_reason": "eos", "truncated": True}, "decode_limit_hit"),
        ({"finish_reason": "eos", "truncated": None}, "decode_limit_not_observed"),
        ({"finish_reason": None, "truncated": False}, "decode_limit_not_observed"),
        (
            {"decode_max_new_tokens": 129, "finish_reason": "eos", "truncated": False},
            "decode_budget_exceeds_frozen_limit",
        ),
    ],
)
def test_each_attempt_must_observe_limit_status_and_respect_frozen_cap(metadata, reason):
    from speechrail.domain.asr_window import WindowDecodeObservation

    values = {"kind": "review", "decode_max_new_tokens": 32, **metadata}
    report = asyncio.run(
        replay_long_blocks(
            case(),
            spec(),
            ObservedDecoder(WindowDecodeObservation(**values)),
            observe=observation(),
        )
    )
    assert reason in report["failures"]
    assert not report["quality_evidence_valid"]


def test_unknown_finish_reason_is_redacted_and_kind_mismatch_cannot_advance():
    from speechrail.domain.asr_window import WindowDecodeObservation

    metadata = WindowDecodeObservation(
        "review", 32, finish_reason="/private/model-or-text", truncated=False
    )
    report = asyncio.run(
        replay_long_blocks(case(), spec(), ObservedDecoder(metadata), observe=observation())
    )
    assert "/private/model-or-text" not in json.dumps(report)
    assert report["decode_evidence"]["attempts"][0]["finish_reason"] == "other"
    assert report["quality_evidence_valid"] is False
    metadata = replace(metadata, kind="preview")
    report = asyncio.run(
        replay_long_blocks(case(), spec(), ObservedDecoder(metadata), observe=observation())
    )
    assert "decode_observation_kind_mismatch" in report["failures"]
    assert report["coverage_samples"] == 0


def test_missing_attempt_cannot_be_hidden_by_later_complete_decode():
    decoder = ObservedDecoder(
        lambda request: (
            None
            if request.input_span.start == 0
            else WindowDecodeObservation(request.kind, 32, finish_reason="eos", truncated=False)
        )
    )
    report = asyncio.run(
        replay_long_blocks(case(seconds=2), spec(), decoder, observe=observation(), block_seconds=1)
    )
    assert report["actual_decode_calls"] == 2
    assert report["decode_evidence"]["attempts_with_observation"] == 1
    assert report["decode_evidence"]["attempts_with_unknown_limit"] == 1
    assert report["decode_evidence"]["token_limit_hit"] is None
    assert not report["quality_evidence_valid"]


def test_comparison_revalidates_per_attempt_evidence_not_only_summary_boolean():
    from copy import deepcopy

    old, _ = run()
    new, _ = run(text="甲乙丙丁")
    for mutation in ("missing", "count", "unknown", "budget", "digest"):
        changed = deepcopy(new)
        if mutation == "missing":
            changed.pop("decode_evidence")
        elif mutation == "count":
            changed["decode_evidence"]["attempts_with_observation"] = 0
        elif mutation == "unknown":
            changed["decode_evidence"]["attempts"][0]["truncated"] = None
        elif mutation == "budget":
            changed["decode_evidence"]["attempts"][0]["decode_max_new_tokens"] = 129
        else:
            changed["decode_evidence"]["attempts_sha256"] = "a" * 64
        result = compare_asr_runs([old], [changed], policy=policy())
        assert result["development_text_gate"] == "fail"
        assert result["paired_cer"] is None


def test_attempt_budget_is_bounded_and_does_not_start_an_extra_decode():
    from probe_meeting_asr_quality import _RecordedSession

    from speechrail.domain.asr_window import WindowDecodeRequest, WindowIdentity
    from speechrail.domain.audio_timeline import SampleSpan

    async def exercise():
        decoder = Decoder()
        recorded = _RecordedSession(decoder, case(), 1, 128)
        recorded.calls = 4096
        request = WindowDecodeRequest(
            WindowIdentity("s", 0, "w"), "extra", "review", SampleSpan(0, 1), bytes(2), None, ""
        )
        with pytest.raises(ValueError, match="attempt budget"):
            await recorded.decode(request)
        assert decoder.calls == []
        assert "decode_attempt_budget_exceeded" in recorded.failures
        assert recorded.decode_attempts == []

    asyncio.run(exercise())


def test_preview_limit_evidence_cannot_be_hidden_by_successful_final_review():
    async def exercise():
        now = [0.0]

        async def pace(seconds):
            now[0] += seconds

        decoder = ObservedDecoder(
            lambda request: WindowDecodeObservation(
                request.kind,
                32,
                finish_reason="length" if request.kind == "preview" else "eos",
                truncated=request.kind == "preview",
            )
        )
        return await replay_production_windows(
            case(seconds=23),
            spec(),
            decoder,
            observe=observation(),
            admission=admit_all,
            pace=pace,
            clock=lambda: now[0],
        )

    report = asyncio.run(exercise())
    attempts = report["decode_evidence"]["attempts"]
    assert {row["kind"] for row in attempts} == {"preview", "review"}
    assert any(row["kind"] == "review" and row["token_limit_hit"] is False for row in attempts)
    assert report["decode_evidence"]["token_limit_hit"] is True
    assert "decode_limit_hit" in report["failures"]
    assert report["quality_evidence_valid"] is False


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("reference_tokens", True), ("reference_tokens", 0),
        ("reference_tokens", -1), ("reference_tokens", 1.5),
        ("reference_tokens", 10001), ("errors", -1), ("errors", False),
        ("errors", float("nan")), ("errors", float("inf")),
        ("errors", 0), ("substitutions", -1), ("deletions", 5),
        ("insertions", 10001), ("error_rate", 0),
    ],
)
def test_comparison_rejects_inconsistent_character_counts(field, value):
    from copy import deepcopy

    old, _ = run()
    new = deepcopy(old)
    new["metrics"]["normalized"]["characters"][field] = value
    with pytest.raises(ValueError, match="ASR character"):
        compare_asr_runs([old], [new], policy=policy())


def test_comparison_rejects_cer_disagreeing_with_character_counts():
    from copy import deepcopy

    old, _ = run()
    new = deepcopy(old)
    new["metrics"]["normalized"]["cer"] = 0
    with pytest.raises(ValueError, match="ASR character"):
        compare_asr_runs([old], [new], policy=policy())


@pytest.mark.parametrize("repeat_only", [False, True])
def test_comparison_requires_same_reference_count_for_paired_and_repeat_cases(repeat_only):
    from copy import deepcopy

    old, _ = run()
    altered = deepcopy(old)
    counts = altered["metrics"]["normalized"]["characters"]
    counts["reference_tokens"] = 5
    counts["error_rate"] = 2 / 5
    altered["metrics"]["normalized"]["cer"] = 2 / 5
    baseline = [old, altered] if repeat_only else [old]
    candidate = [old, altered] if repeat_only else [altered]
    with pytest.raises(ValueError, match="ASR character"):
        compare_asr_runs(baseline, candidate, policy=policy())


def test_comparison_preserves_valid_cer_above_one_and_missing_reference_failure():
    old, _ = run(case(reference="甲"), text="甲乙丙丁")
    new, _ = run(case(reference="甲"), text="甲乙")
    result = compare_asr_runs([old], [new], policy=policy())
    assert result["baseline_macro_cer"] == 3
    assert result["candidate_macro_cer"] == 1
    missing, _ = run(case(reference=None))
    result = compare_asr_runs([missing], [missing], policy=policy())
    assert result["baseline_macro_cer"] is None
    assert result["development_text_gate"] == "fail"
