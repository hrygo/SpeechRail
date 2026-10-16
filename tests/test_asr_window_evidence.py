"""Independent window evidence cannot pass by ignoring failed or missing input."""

import json
import queue
import sys
from copy import deepcopy
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from examples.perf import realtime_asr_benchmark
from examples.perf.asr_window_evidence import ASRWindowEvidence, paired_bootstrap
from examples.perf.realtime_asr_benchmark import ASREvidence


def fixture(name):
    return json.loads(
        (Path(__file__).parent / "fixtures/realtime-current/server" / name).read_text()
    )


def mirror(item, end, text=None, failed=False):
    return [
        {
            "type": "speechrail.transcription.segment_closed",
            "item_id": item,
            "sample_span": {"start": 0 if item == "item-1" else 96000, "end": end},
        },
        {
            "type": "conversation.item.input_audio_transcription."
            + ("failed" if failed else "completed"),
            "item_id": item,
            **({"error": {"code": "decode_failed"}} if failed else {"transcript": text}),
        },
    ]


def receipt(end, revision, failed=0):
    return {
        "type": "speechrail.input_audio_buffer.committed",
        "commit_event_id": "benchmark-final",
        "accepted_samples": end,
        "sealed_through_sample": end,
        "window_revision": revision,
        "failed_items_count": failed,
    }


def test_preview_loss_and_terminal_mirrors_do_not_change_quality():
    evidence = ASRWindowEvidence()
    sealed = fixture("window-sealed-r6.json")
    evidence.consume(sealed, 1)
    evidence.consume(fixture("window-sealed-replay.json"), 1.1)
    for event in mirror("item-1", 96000, sealed["final_units"][0]["text"]):
        evidence.consume(event, 1.2)
    evidence.consume(receipt(96000, 6), 1.3)
    result = evidence.score(sealed["final_units"][0]["text"], expected_wire_samples=96000)
    assert result["normalized"]["cer"] == 0
    assert result["terminal_count"] == 1 and result["preview_count"] == 0


def test_failed_text_stays_in_denominator_and_recovery_is_not_scored_as_final():
    evidence = ASRWindowEvidence()
    first = fixture("window-sealed-r6.json")
    evidence.consume(first, 1)
    for event in mirror("item-1", 96000, first["final_units"][0]["text"]):
        evidence.consume(event, 2)
    evidence.consume(fixture("window-failed-r7.json"), 3)
    for event in mirror("item-2", 192000, failed=True):
        evidence.consume(event, 4)
    evidence.consume(receipt(192000, 7, 1), 5)
    result = evidence.score(
        first["final_units"][0]["text"] + "缺失句", expected_wire_samples=192000
    )
    assert result["failed_items_count"] == 1 and result["normalized"]["cer"] > 0
    assert result["failure_gate"] == "fail"


@pytest.mark.parametrize("change", ["gap", "overlap", "changed_replay", "wrong_mirror", "unclosed"])
def test_broken_ownership_is_rejected(change):
    e = ASRWindowEvidence()
    event = fixture("window-sealed-r6.json")
    if change == "gap":
        event["coverage"][0]["span"]["start"] = 1
    if change == "overlap":
        event["coverage"].append(deepcopy(event["coverage"][0]))
    with pytest.raises(ValueError):
        e.consume(event, 1)
        if change == "changed_replay":
            event["final_units"][0]["text"] += "篡改"
            e.consume(event, 2)
        elif change == "wrong_mirror":
            for m in mirror("item-1", 96000, "篡改"):
                e.consume(m, 2)
        elif change == "unclosed":
            e.consume(receipt(96000, 6), 3)
            e.score("参考", expected_wire_samples=96000)


def test_legacy_evidence_explicitly_refuses_window_events():
    with pytest.raises(ValueError, match="window"):
        ASREvidence(require_boundaries=True).consume(fixture("window-sealed-r6.json"), 1)


def test_bootstrap_pairs_whole_sessions_and_is_reproducible():
    rows = [(0.2, 0.1), (0.4, 0.3), (0.3, 0.2)]
    result = paired_bootstrap(rows, seed=1717, draws=100)
    assert result == paired_bootstrap(rows, seed=1717, draws=100)
    assert result["session_count"] == 3
    assert result["mean_delta"] == pytest.approx(-0.1)
    assert result["ci95"][1] < 0


def test_empty_reference_reports_insertions_without_dividing_by_zero():
    evidence = ASRWindowEvidence()
    sealed = fixture("window-sealed-r6.json")
    evidence.consume(sealed, 1)
    for event in mirror("item-1", 96000, sealed["final_units"][0]["text"]):
        evidence.consume(event, 2)
    evidence.consume(receipt(96000, 6), 3)
    result = evidence.score("", expected_wire_samples=96000)
    assert result["raw"]["cer"] is None and result["normalized"]["cer"] is None
    assert result["raw"]["character_errors"] > 0
    assert result["normalized"]["character_errors"] > 0


def test_legacy_hypothesis_is_not_silently_ignored():
    with pytest.raises(ValueError, match="legacy"):
        ASRWindowEvidence().consume(
            {"type": "speechrail.transcription.hypothesis", "text": "合成"}, 1
        )


def test_public_error_preserves_protocol_code_without_sensitive_message():
    from examples.perf.asr_window_evidence import PublicASRError

    with pytest.raises(PublicASRError) as caught:
        ASRWindowEvidence().consume(
            {
                "type": "error",
                "error": {"code": "backend_busy", "message": "private transcript /model/path"},
            },
            1,
        )
    assert caught.value.code == "backend_busy" and caught.value.stage == "stream"
    assert "private" not in str(caught.value) and "/model" not in str(caught.value)


def test_local_revision_conflict_has_a_stable_diagnostic_without_transcript():
    from examples.perf.asr_window_evidence import WindowEvidenceError

    evidence = ASRWindowEvidence()
    first = fixture("window-updated-r2.json")
    evidence.consume(first, 1)
    changed = {**first, "falling_behind": not first["falling_behind"]}
    with pytest.raises(WindowEvidenceError) as caught:
        evidence.consume(changed, 2)
    assert caught.value.stage == "evidence"
    assert caught.value.code == "window_revision_conflict"
    assert first["units"][0]["text"] not in str(caught.value)


def test_empty_reviewed_speech_is_counted_without_inventing_a_protocol_outcome():
    evidence = ASRWindowEvidence()
    sealed = fixture("window-sealed-r6.json")
    sealed["final_units"][0]["text"] = ""
    evidence.consume(sealed, 1)
    for event in mirror("item-1", 96000, ""):
        evidence.consume(event, 2)
    evidence.consume(receipt(96000, 6), 3)
    result = evidence.score("漏识别", expected_wire_samples=96000)
    assert result["normalized"]["cer"] == 1
    assert result["coverage_samples"]["empty"] == 96000
    assert result["coverage_samples"]["speech"] == 0


def test_english_word_boundaries_survive_separate_sealed_units():
    evidence = ASRWindowEvidence()
    for number, text in enumerate(("hello", "world"), 1):
        sealed = fixture("window-sealed-r6.json")
        start, end = (number - 1) * 96000, number * 96000
        item = f"item-{number}"
        span = {"start": start, "end": end}
        sealed.update(
            window_revision=5 + number,
            transaction_id=f"tx-{number}",
            closed_span=span,
            audio_span=span,
            sealed_through_sample=end,
        )
        sealed["final_units"][0].update(
            unit_id=f"unit-{number}", item_id=item, text=text, owned_span=span
        )
        sealed["coverage"][0].update(span=span, item_id=item)
        evidence.consume(sealed, number)
        for event in mirror(item, end, text):
            evidence.consume(event, number + 0.1)
    evidence.consume(receipt(192000, 7), 3)
    assert evidence.score("hello world", expected_wire_samples=192000, language="en")["wer"] == 0


def test_mixed_language_wer_scores_only_human_marked_english_spans():
    evidence = ASRWindowEvidence()
    sealed = fixture("window-sealed-r6.json")
    sealed["final_units"][0]["text"] = "前文有错 hello brave world 后文也错"
    evidence.consume(sealed, 1)
    for event in mirror("item-1", 96000, sealed["final_units"][0]["text"]):
        evidence.consume(event, 2)
    evidence.consume(receipt(96000, 6), 3)
    reference = "前文正确 hello world 后文正确"
    start = reference.index("hello")
    result = evidence.score(
        reference,
        expected_wire_samples=96000,
        language="zh-en",
        annotations={
            "kind": "independent_human_annotation",
            "english_spans": [{"start": start, "end": start + len("hello world")}],
        },
    )
    assert result["english_spans"]["reference_words"] == 2
    assert result["english_spans"]["word_errors"] == 1
    assert result["wer"] == 0.5
    assert result["normalized"]["cer"] > 0


def test_mixed_language_wer_refuses_unmarked_or_invalid_reference_spans():
    from examples.perf.asr_window_annotations import annotated_quality_metrics

    reference = "中文 hello world 中文"
    for spans in (
        [{"start": True, "end": 14}],
        [{"start": 0, "end": 14}],
        [{"start": 3, "end": 8}, {"start": 4, "end": 14}],
    ):
        with pytest.raises(ValueError):
            annotated_quality_metrics(
                reference,
                reference,
                {"kind": "independent_human_annotation", "english_spans": spans},
            )
    assert annotated_quality_metrics(reference, reference, None)["wer"] == "not_observed"


def test_independent_fact_and_negative_control_counts_do_not_echo_terms():
    from examples.perf.asr_window_annotations import annotated_quality_metrics

    result = annotated_quality_metrics(
        "金额三万明天到账",
        "金额五万明天到账虚构术语",
        {
            "kind": "independent_human_annotation",
            "facts": [{"start": 2, "end": 4, "category": "amount"}],
            "vocabulary_negative_controls": ["虚构术语", "不存在词"],
        },
    )
    assert result["facts"]["reference_count"] == 1
    assert result["facts"]["correct_count"] == 0
    assert result["facts"]["by_category"]["amount"]["error_count"] == 1
    assert result["vocabulary_negative_control"]["false_positive_count"] == 1
    assert "虚构术语" not in json.dumps(result, ensure_ascii=False)


def test_negative_controls_match_english_whole_tokens_and_chinese_character_sequences():
    from examples.perf.asr_window_annotations import annotated_quality_metrics

    annotations = {
        "kind": "independent_human_annotation",
        "vocabulary_negative_controls": ["cat", "虚构词"],
    }
    result = annotated_quality_metrics("concatenate 中文", "concatenate 中文虚构词", annotations)
    assert result["vocabulary_negative_control"]["false_positive_count"] == 1
    result = annotated_quality_metrics("concatenate 中文", "a CAT 中文", annotations)
    assert result["vocabulary_negative_control"]["false_positive_count"] == 1
    with pytest.raises(ValueError, match="absent"):
        annotated_quality_metrics("a cat", "", annotations)


def test_english_annotation_normalizes_composed_and_combining_words_without_losing_offsets():
    from examples.perf.asr_window_annotations import annotated_quality_metrics

    for reference, hypothesis, end in (
        ("café 中文", "cafe\u0301 中文", 4),
        ("cafe\u0301 中文", "café 中文", 5),
    ):
        result = annotated_quality_metrics(
            reference,
            hypothesis,
            {"kind": "independent_human_annotation", "english_spans": [{"start": 0, "end": end}]},
        )
        assert result["wer"] == 0


@pytest.mark.parametrize("category", [None, "unknown", True, ["amount"]])
def test_fact_annotations_require_a_finite_human_category(category):
    from examples.perf.asr_window_annotations import annotated_quality_metrics

    with pytest.raises(ValueError, match="category"):
        annotated_quality_metrics(
            "三万",
            "三万",
            {
                "kind": "independent_human_annotation",
                "facts": [{"start": 0, "end": 2, "category": category}],
            },
        )


@pytest.mark.parametrize("scene,task", [("caption", "caption"), ("meeting", "transcription")])
def test_public_runner_routes_window_request_and_scores_sealed_only(monkeypatch, scene, task):
    class Connection:
        def __init__(self):
            self.inbound = queue.Queue()
            self.sent = []
            self.inbound.put({"type": "session.created"})

        def send(self, event):
            self.sent.append(event)
            if event["type"] == "session.update":
                self.inbound.put({"type": "session.updated", "session": event["session"]})
            if event["type"] == "input_audio_buffer.commit":
                sealed = fixture("window-sealed-r6.json")
                self.inbound.put(sealed)
                for event in mirror("item-1", 96000, sealed["final_units"][0]["text"]):
                    self.inbound.put(event)
                self.inbound.put(receipt(96000, 6))

        def recv(self):
            event = self.inbound.get(timeout=2)
            if event is None:
                raise EOFError()
            return event

        def close(self):
            self.inbound.put(None)

    connection = Connection()

    class Client:
        realtime = None

        def connect(self, **_kwargs):
            return self

        def enter(self):
            return connection

    client = Client()
    client.realtime = client
    monkeypatch.setattr(realtime_asr_benchmark.time, "sleep", lambda _: None)
    request = {"mode": "revision_window_v1", "scene": scene}
    result = realtime_asr_benchmark._run_asr(
        client,
        b"\0\0" * 96000,
        language="zh",
        reference=fixture("window-sealed-r6.json")["final_units"][0]["text"],
        policy=None,
        window_request=request,
    )
    assert result["quality_metrics"]["normalized"]["cer"] == 0
    assert result["quality_metrics"]["preview_count"] == 0
    update = next(e for e in connection.sent if e["type"] == "session.update")
    assert update["session"]["speechrail"]["window"] == request
    assert update["session"]["speechrail"]["task"] == task
    assert "asr" not in update["session"]["speechrail"]
