import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "examples/perf"))

from asr_segment_error_diagnostics import segment_error_diagnostics


def segment(start, end, text, preview=None):
    return {
        "start_sample": start, "end_sample": end, "terminal_text": text,
        "preview_text": text if preview is None else preview,
    }


def run(reference, segments, *, samples=6, budget=1):
    return segment_error_diagnostics(
        reference, segments, expected_wire_samples=samples,
        max_segment_ms=budget,
    )


def test_exact_digests_preserve_punctuation_whitespace_and_missing_preview():
    result = run("abc", [
        segment(0, 3, "a b,", "ab"),
        {"start_sample": 3, "end_sample": 6, "terminal_text": "c."},
    ])
    def digest(text):
        return hashlib.sha256(text.encode()).hexdigest()
    assert result["diagnostic_schema_version"] == 2
    assert result["hypothesis_exact_sha256"] == digest("a b,c.")
    assert result["hypothesis_normalized_sha256"] == digest("abc")
    assert result["segments"][0]["terminal_exact_sha256"] == digest("a b,")
    assert result["segments"][0]["preview_exact_sha256"] == digest("ab")
    assert result["segments"][1]["preview_exact_sha256"] is None
    assert "a b," not in json.dumps(result)


def test_substitutions_are_localized_without_retaining_text():
    result = run("甲乙丙丁戊己", [
        segment(0, 3, "甲山丙", "甲山"),
        segment(3, 6, "丁水己"),
    ])
    assert result["character_errors"] == 2
    assert [row["chosen_alignment_edit_counts"]["substitution"]
            for row in result["segments"]] == [1, 1]
    assert [(row["reference_range"], row["hypothesis_range"])
            for row in result["edits"]] == [([1, 2], [1, 2]), ([4, 5], [4, 5])]
    encoded = json.dumps(result, ensure_ascii=False)
    for private_text in ["甲乙丙丁戊己", "甲山丙", "丁水己", "甲山"]:
        assert private_text not in encoded
    assert all("terminal_text" not in row and "preview_text" not in row
               for row in result["segments"])


def test_insertion_and_deletion_counts_match_shared_cer():
    result = run("abcde", [segment(0, 3, "axbc"), segment(3, 6, "e")])
    assert result["character_errors"] == 2
    assert sum(row["kind"] == "insertion" for row in result["edits"]) == 1
    assert sum(row["kind"] == "deletion" for row in result["edits"]) == 1


def test_boundary_deletion_is_marked_as_text_alignment_ambiguity():
    result = run("abxcd", [segment(0, 3, "ab"), segment(3, 6, "cd")])
    assert result["character_errors"] == 1
    edit = result["edits"][0]
    assert edit["kind"] == "deletion"
    assert edit["reference_range"] == [2, 3]
    assert edit["hypothesis_range"] == [2, 2]
    assert edit["possible_segment_ordinals"] == [0, 1]
    assert result["acoustic_error_attribution"] == "not_observed"


def test_repeated_word_alignment_reports_optimal_path_ties():
    result = run("aa", [segment(0, 3, "a"), segment(3, 6, "")])
    assert result["character_errors"] == 1
    assert result["chosen_alignment_tied_steps"] > 0
    assert result["alignment_policy"] == "one_optimal_text_alignment"


def test_cross_segment_normalization_cannot_silently_shift_positions():
    with pytest.raises(ValueError, match="normalization crosses a segment boundary"):
        run("é", [segment(0, 3, "e"), segment(3, 6, "\u0301")])


@pytest.mark.parametrize("segments,samples,budget", [
    ([segment(1, 6, "abc")], 6, 1),
    ([segment(0, 3, "a"), segment(4, 6, "b")], 6, 1),
    ([segment(0, 7, "abc")], 6, 1),
    ([segment(False, 6, "abc")], 6, 1),
    ([segment(0, 6, "abc")], True, 1),
    ([segment(0, 6, "abc")], 6, True),
    ([segment(0, 26, "abc")], 26, 1),
])
def test_invalid_coverage_and_budget_are_rejected(segments, samples, budget):
    with pytest.raises(ValueError):
        run("abc", segments, samples=samples, budget=budget)


def test_zero_errors_preserve_lexical_normalization_and_missing_preview():
    result = run("Ａ b，Ｃ", [segment(0, 6, "aB c")])
    assert result["character_errors"] == 0
    assert result["reference_characters"] == 3
    assert result["hypothesis_characters"] == 3
    assert result["edits"] == []


def test_bounds_are_checked_before_quadratic_alignment():
    with pytest.raises(ValueError, match="diagnostic text exceeds"):
        run("a" * 1025, [segment(0, 6, "b" * 1025)])


def event_evidence(*, require_boundaries=True, resource_only=False):
    from asr_segment_error_diagnostics import DiagnosticASREvidence
    evidence = DiagnosticASREvidence(
        require_boundaries=require_boundaries, resource_only=resource_only,
    )
    for ordinal, start, end, text in [(0, 0, 3, "甲山丙"), (1, 3, 6, "丁水己")]:
        item = f"synthetic-item-{ordinal}"
        evidence.consume({
            "type": "speechrail.transcription.hypothesis", "utterance_id": item,
            "text": text,
        }, float(ordinal))
        evidence.consume({
            "type": "speechrail.transcription.segment_closed", "item_id": item,
            "sample_span": {"start": start, "end": end},
        }, float(ordinal))
        evidence.consume({
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": item, "transcript": text,
        }, float(ordinal))
    evidence.consume({
        "type": "speechrail.input_audio_buffer.committed",
        "commit_event_id": "benchmark-final", "accepted_samples": 6,
    }, 2.0)
    return evidence


def test_public_event_scoring_preserves_gates_and_adds_private_alignment():
    evidence = event_evidence()
    report = evidence.score(
        "甲乙丙丁戊己", expected_wire_samples=6, effective_max_segment_ms=1,
    )
    assert report["sample_coverage_gate"] == report["segment_budget_gate"] == "pass"
    assert report["terminal_count"] == report["boundary_count"] == 2
    assert report["character_errors"] == report["segment_diagnostic"]["character_errors"] == 2
    assert len(report["segment_diagnostic"]["segments"]) == 2
    assert "甲山丙" not in json.dumps(report, ensure_ascii=False)


def test_punctuation_gold_exact_digest_is_recorded_without_gold_text():
    gold = "甲乙丙，丁戊己。"
    report = event_evidence().score(
        "甲乙丙丁戊己", expected_wire_samples=6, effective_max_segment_ms=1,
        punctuation_reference_text=gold,
        punctuation_reference_kind="human_punctuation_annotation",
    )
    assert report["punctuation_reference_exact_sha256"] == hashlib.sha256(
        gold.encode()
    ).hexdigest()
    assert gold not in json.dumps(report, ensure_ascii=False)


def write_policy_manifest(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"asr_policy": {
        "preview_interval_ms": 500, "max_segment_ms": 8000,
        "finalization": "streaming_finalize", "rollback_tokens": 5,
    }}))
    return path


@pytest.mark.parametrize("override", [
    {"resource_only": True}, {"resource_only": 1},
    {"sessions": True}, {"sessions": 0}, {"warmup": 1},
])
def test_invalid_probe_mode_is_rejected_before_runner(monkeypatch, tmp_path, override):
    import asr_segment_error_diagnostics as diagnostic
    called = []
    monkeypatch.setattr(
        diagnostic.benchmark, "run_manifest_asr_benchmark",
        lambda *_args, **_kwargs: called.append(True),
    )
    with pytest.raises(ValueError):
        diagnostic.run_diagnostic_probe(
            tmp_path / "missing.json", **({"sessions": 1, "warmup": True} | override),
        )
    assert called == []


@pytest.mark.parametrize("policy", [None, {}, {"max_segment_ms": True}])
def test_missing_or_invalid_explicit_budget_is_rejected_before_runner(
    monkeypatch, tmp_path, policy
):
    import asr_segment_error_diagnostics as diagnostic
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps({"asr_policy": policy}))
    called = []
    monkeypatch.setattr(
        diagnostic.benchmark, "run_manifest_asr_benchmark",
        lambda *_args, **_kwargs: called.append(True),
    )
    with pytest.raises(ValueError):
        diagnostic.run_diagnostic_probe(path, sessions=1, warmup=True)
    assert called == []


def test_diagnostic_requires_bounded_public_spans():
    evidence = event_evidence(require_boundaries=False)
    with pytest.raises(ValueError, match="requires bounded quality evidence"):
        evidence.score("甲乙丙丁戊己", expected_wire_samples=6, effective_max_segment_ms=1)


def test_resource_only_never_gets_a_quality_diagnostic():
    evidence = event_evidence(resource_only=True)
    with pytest.raises(ValueError, match="requires bounded quality evidence"):
        evidence.score(None, expected_wire_samples=6, effective_max_segment_ms=1)


def test_diagnostic_context_restores_collector_on_exception():
    import realtime_asr_benchmark as benchmark
    from asr_segment_error_diagnostics import (
        DiagnosticASREvidence,
        diagnostic_evidence_context,
    )
    before = benchmark.ASREvidence
    with (
        pytest.raises(RuntimeError, match="synthetic interrupted probe"),
        diagnostic_evidence_context(),
    ):
        assert benchmark.ASREvidence is DiagnosticASREvidence
        raise RuntimeError("synthetic interrupted probe")
    assert benchmark.ASREvidence is before


def test_probe_tag_cannot_turn_fake_or_failed_input_into_real_success(monkeypatch, tmp_path):
    import realtime_asr_benchmark as benchmark
    from asr_segment_error_diagnostics import run_diagnostic_probe
    original_writer = benchmark.write_result
    original_collector = benchmark.ASREvidence
    raw = {
        "schema_version": 1, "tool": "speechrail-bench-realtime-asr",
        "evidence_mode": "fake", "measurement_completed": False,
        "failure_kind": "SyntheticFailure", "sessions": [], "resources": {},
    }
    output = tmp_path / "probe.json"

    def fake_runner(*args, **kwargs):
        benchmark.write_result(raw, kwargs["output"])
        return raw

    monkeypatch.setattr(benchmark, "run_manifest_asr_benchmark", fake_runner)
    report = run_diagnostic_probe(
        write_policy_manifest(tmp_path), profile="quality", output=output,
        sessions=3, warmup=True, app_home=None, base_url="http://127.0.0.1:8201/v1",
    )
    saved = json.loads(output.read_text())
    assert saved == report
    assert report["tool"] == "speechrail-asr-segment-diagnostic"
    assert report["source_result_tool"] == raw["tool"]
    assert report["source_result_schema_version"] == 1
    assert report["evidence_mode"] == "fake"
    assert report["measurement_completed"] is False
    assert report["failure_kind"] == "SyntheticFailure"
    assert report["frozen_v4_matrix_scope"] is False
    assert report["acoustic_latency_gate"] == "not_evaluated"
    assert raw["tool"] == "speechrail-bench-realtime-asr"
    assert benchmark.write_result is original_writer
    assert benchmark.ASREvidence is original_collector


def test_probe_failure_restores_writer_and_collector(monkeypatch, tmp_path):
    import realtime_asr_benchmark as benchmark
    from asr_segment_error_diagnostics import run_diagnostic_probe
    writer, collector = benchmark.write_result, benchmark.ASREvidence

    def fail(*args, **kwargs):
        raise RuntimeError("synthetic transport failure")

    monkeypatch.setattr(benchmark, "run_manifest_asr_benchmark", fail)
    with pytest.raises(RuntimeError, match="synthetic transport failure"):
        run_diagnostic_probe(
            write_policy_manifest(tmp_path), profile="quality",
            output=tmp_path / "probe.json", sessions=3, warmup=True,
            app_home=None, base_url="http://127.0.0.1:8201/v1",
        )
    assert benchmark.write_result is writer
    assert benchmark.ASREvidence is collector
