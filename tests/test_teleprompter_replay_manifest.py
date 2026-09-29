from __future__ import annotations

import importlib.util
import sys
import wave
from pathlib import Path

import pytest

_MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "tools/build_teleprompter_replay_manifest.py"
)
_SPEC = importlib.util.spec_from_file_location(
    "speechrail_build_teleprompter_replay_manifest",
    _MODULE_PATH,
)
assert _SPEC is not None and _SPEC.loader is not None
_TOOL = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _TOOL
_SPEC.loader.exec_module(_TOOL)

ManifestDraftError = _TOOL.ManifestDraftError
ALIGN_BACKTRACK_CHARS = _TOOL.ALIGN_BACKTRACK_CHARS
fold_cjk_signs = _TOOL.fold_cjk_signs
ScriptAligner = _TOOL.ScriptAligner
SegmentIndex = _TOOL.SegmentIndex
build_manifest = _TOOL.build_manifest
load_wave_fixture = _TOOL.load_wave_fixture
normalize_text = _TOOL.normalize_text
render_review = _TOOL.render_review
render_capture = _TOOL.render_capture
require_external_path = _TOOL.require_external_path
split_segments = _TOOL.split_segments
to_captured_event = _TOOL.to_captured_event

_SESSION_CAPTURE = _TOOL._SessionCapture

SEGMENTS = [
    "大家好，欢迎来到本期节目。",
    "先看几组数字，这台设备的标称功率是 50 瓦。",
    "价格方面，标称为 2999 元，促销价是 2599 元。",
]


def _capture(*texts: str, kind: str = "snapshot") -> _SESSION_CAPTURE:
    capture = _SESSION_CAPTURE()
    for ordinal, text in enumerate(texts):
        capture.events.append(
            _TOOL.CapturedEvent(
                offset_milliseconds=100 * ordinal,
                kind=kind,
                item_id=f"utterance-{ordinal}",
                event_id=f"utterance-{ordinal}.1",
                revision=1,
                text=text,
                stable_prefix_codepoints=len(text),
            )
        )
    return capture


def test_normalize_text_folds_width_case_and_punctuation() -> None:
    assert normalize_text("Ｗｉｆｉ－Ａ，ＢＣ！") == "wifiabc"
    assert normalize_text("负 20 摄氏度。") == "-20摄氏度"


def test_normalize_text_puts_chinese_numerals_and_the_transcript_in_the_same_form() -> None:
    assert normalize_text("标称功率是 50 瓦") == "标称功率是50瓦"
    assert normalize_text("负 20 到 60 摄氏度") == "-20到60摄氏度"
    assert normalize_text("工作温度是 0 到 35 摄氏度") == "工作温度是0到35摄氏度"


@pytest.mark.parametrize(
    ("text", "expected"),
    [("负20", "-20"), ("正3", "+3"), ("负二十", "负二十"), ("负荷", "负荷")],
)
def test_fold_cjk_signs_only_touches_a_sign_that_fronts_a_number(
    text: str, expected: str
) -> None:
    """A wrong rewrite is worse than none: it moves the reading position."""

    assert fold_cjk_signs(text) == expected


def test_normalize_text_does_not_rewrite_chinese_numerals() -> None:
    """Rewriting Chinese numerals as digits was tried and measured, then dropped.

    It cost ten positioned events on a 41-second reading, because the engine
    emits numeral-shaped noise that the rewrite then destroys, and the supplied
    scripts already use Arabic digits.
    """

    assert normalize_text("大概四十分钟") == "大概四十分钟"
    assert normalize_text("七点半出门") == "七点半出门"


def test_split_segments_uses_blank_lines_and_drops_empties() -> None:
    script = "第一段。\n同段第二行。\n\n第二段。\n\n\n"
    assert split_segments(script) == ["第一段。 同段第二行。", "第二段。"]


def test_segment_index_maps_offsets_back_to_segments() -> None:
    index = SegmentIndex.build(SEGMENTS)
    assert index.segment_of(0) == 0
    assert index.segment_of(len(normalize_text(SEGMENTS[0]))) == 0
    assert index.segment_of(len(normalize_text(SEGMENTS[0])) + 1) == 1
    assert index.segment_of(len(index.script_text)) == 2


def test_aligner_advances_monotonically_across_segments() -> None:
    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    first = aligner.align("大家好，欢迎来到", cumulative=True)
    second = aligner.align("先看几组数字", cumulative=True)
    assert (first.intent, first.segment_index) == ("read", 0)
    assert (second.intent, second.segment_index) == ("read", 1)
    assert first.ratio == 1.0


def test_aligner_treats_a_re_delivery_as_a_duplicate_not_a_re_read() -> None:
    """A hypothesis and its delta carry the same words; that is not a re-read."""

    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    snapshot = aligner.align("大家好，欢迎来到", cumulative=True)
    high_water = aligner.high_water
    duplicate = aligner.align("大家好，欢迎来到", cumulative=False)
    assert (duplicate.intent, duplicate.segment_index) == ("read", 0)
    assert duplicate.intent != "reRead"
    assert aligner.high_water == high_water  # a re-delivery moves nothing
    assert snapshot.segment_index == 0


def test_aligner_does_not_manufacture_confidence_for_a_re_delivered_hallucination() -> None:
    """Repeated words are still off-script words.

    The recognizer emits the same short hallucination on consecutive partials.
    Noticing that the fragment repeats says nothing about whether it is in the
    script, so the re-delivery path must not report full confidence for it: a
    fabricated `read` position is what produces a fabricated latency sample.
    """

    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    first = aligner.align("嗯嗯", cumulative=False)
    again = aligner.align("嗯嗯", cumulative=False)

    assert (first.intent, first.segment_index) == ("read", None)
    assert again.segment_index is None, (
        "a repeated off-script fragment must not be given a reading position"
    )
    assert again.ratio < 0.72
    assert again.intent not in {"improvise", "reRead"}
    assert aligner.high_water == 0


def test_aligner_flags_a_genuine_re_read() -> None:
    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    aligner.align("大家好，欢迎来到", cumulative=True)
    aligner.align("先看几组数字，这台设备的标称功率是 50 瓦", cumulative=True)
    ahead = aligner.align("价格方面，标称为 2999 元", cumulative=True)
    # Not part of the event right before it, and it lands well behind the
    # reading position: that is the shape of a genuine re-read.
    again = aligner.align("先看几组数字", cumulative=False)
    assert again.intent == "reRead"
    # What the reader has *read* stays at the high water mark.
    assert again.segment_index == ahead.segment_index


def test_aligner_never_claims_improvise_from_a_weak_match() -> None:
    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    aligner.align("大家好，欢迎来到", cumulative=True)
    off_script = aligner.align("今天风有点大，不过还好", cumulative=False)
    assert off_script.intent == "read"
    assert off_script.intent not in {"improvise", "reRead"}
    assert off_script.segment_index is None
    assert off_script.ratio < 0.72
    # A detour must not drag the reading position forward.
    assert aligner.align("价格方面，标称为 2999 元", cumulative=True).segment_index == 2


def test_aligner_tolerates_asr_punctuation_drift() -> None:
    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    drifted = aligner.align("标称为2999元，促销价是2599元", cumulative=True)
    assert drifted.intent == "read"
    assert drifted.ratio >= 0.72


def test_aligner_scores_a_revisioned_hypothesis_as_a_whole() -> None:
    """Regression: scoring only the longest block made on-script drift look off-script."""

    segments = ["今天的天气很适合在公园里慢慢散步", "听听周围自然的声音。"]
    aligner = ScriptAligner(index=SegmentIndex.build(segments))
    first = aligner.align("今天的天气。", cumulative=True)
    drifted = aligner.align("今天的天气。很适合在公园里漫步。", cumulative=True)
    advanced = aligner.align("今天的天气。很适合在公园里漫步。慢散步，听。", cumulative=True)
    assert (first.segment_index, first.ratio) == (0, 1.0)
    assert drifted.segment_index == 0
    assert drifted.ratio >= 0.72
    assert advanced.segment_index == 1


def test_aligner_scores_a_long_cumulative_event_by_its_tail() -> None:
    """Regression: a long utterance's opening froze the reading position.

    A revisioned hypothesis repeats everything said so far. Once the reader is
    more than one backtrack window past the opening, an anchor on those opening
    words falls outside the search window, every match is rejected and the
    cursor stops advancing for the rest of the session.
    """

    segments = [
        "先看几组数字，这台设备的标称功率是 50 瓦。",
        "价格方面，标称为 2999 元，促销价是 2599 元。",
        "温度的指标也一样，工作温度是 0 到 35 摄氏度。",
        "保修期是 12 个月，易损件不在保修范围内。",
    ]
    aligner = ScriptAligner(index=SegmentIndex.build(segments))
    spoken = ""
    for segment in segments:
        spoken += segment
        alignment = aligner.align(spoken, cumulative=True)
    # The fourth revision carries the first segment's opening, which by now sits
    # well behind the reading position.
    assert len(normalize_text(spoken)) > ALIGN_BACKTRACK_CHARS
    assert alignment.intent == "read"
    assert alignment.segment_index == 3
    assert alignment.ratio >= 0.72


def test_aligner_recovers_when_the_anchor_was_mangled() -> None:
    """An unrecognised leading token must not throw the event away."""

    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    # "呃" is a hesitation the engine invented, so the anchor "呃欢" appears
    # nowhere in the script and the anchored pass rejects every offset.
    recovered = aligner.align("呃欢迎来到本期节目", cumulative=False)
    assert recovered.intent == "read"
    assert recovered.segment_index == 0
    assert recovered.ratio >= 0.72


def test_to_captured_event_maps_hypothesis_to_snapshot() -> None:
    captured = to_captured_event(
        12.4,
        {
            "type": "speechrail.transcription.hypothesis",
            "utterance_id": "u-7",
            "revision": 3,
            "text": "大家好",
            "stable_prefix_codepoints": 2,
        },
        0,
    )
    assert captured is not None
    assert captured.kind == "snapshot"
    assert captured.offset_milliseconds == 12
    assert captured.item_id == "u-7"
    assert captured.event_id == "u-7.3"
    assert captured.to_manifest() == {
        "at_milliseconds": 12,
        "kind": "snapshot",
        "item_id": "u-7",
        "event_id": "u-7.3",
        "text": "大家好",
        "revision": 3,
        "stable_prefix_codepoints": 2,
    }


def test_to_captured_event_maps_terminal_events_and_ignores_the_rest() -> None:
    completed = to_captured_event(
        5.0,
        {
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item-2",
            "transcript": "大家好",
            "commit_event_id": "c-1",
        },
        1,
    )
    failed = to_captured_event(
        6.0,
        {
            "type": "conversation.item.input_audio_transcription.failed",
            "item_id": "item-3",
            "commit_event_id": "c-1",
        },
        2,
    )
    assert completed is not None and completed.kind == "completed"
    assert completed.event_id == "c-1"
    assert failed is not None and failed.kind == "failed" and failed.text == ""
    assert to_captured_event(1.0, {"type": "session.updated"}, 3) is None


def test_to_captured_event_maps_the_openai_delta_stream_to_partial() -> None:
    captured = to_captured_event(
        3.0,
        {
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item-2",
            "content_index": 0,
            "delta": "大家",
            "event_id": "e-9",
        },
        4,
    )
    assert captured is not None
    assert captured.kind == "partial"
    assert captured.text == "大家"
    assert captured.event_id == "e-9"
    assert captured.to_manifest() == {
        "at_milliseconds": 3,
        "kind": "partial",
        "item_id": "item-2",
        "event_id": "e-9",
        "text": "大家",
    }


def test_build_manifest_matches_the_replay_contract_and_labels_every_event() -> None:
    capture = _capture("大家好，欢迎来到", "今天风有点大", "先看几组数字")
    manifest, review = build_manifest(
        capture,
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    assert set(manifest) == {
        "schema_version",
        "dataset_revision",
        "baseline_commit",
        "candidate_commit",
        "policy_revision",
        "language_lane",
        "device_class",
        "segments",
        "events",
        "labels",
    }
    assert manifest["schema_version"] == "teleprompter.replay.v1"
    assert manifest["segments"] == [
        {"id": "s0", "text": SEGMENTS[0]},
        {"id": "s1", "text": SEGMENTS[1]},
        {"id": "s2", "text": SEGMENTS[2]},
    ]
    labels = manifest["labels"]
    assert isinstance(labels, list) and len(labels) == len(manifest["events"])  # type: ignore[arg-type]
    assert [label["event_index"] for label in labels] == [0, 1, 2]
    # An unmatched event is reported as an unknown reading position, never as
    # an invented improvisation: the runner counts an advancing ``improvise``
    # as a harmful jump.
    assert labels[1]["intent"] == "read"
    assert "expected_segment_index" not in labels[1]
    assert labels[2]["expected_segment_index"] == 1
    assert [note["event_index"] for note in review] == [1]
    assert "improvise" in str(review[0]["reason"])


def test_build_manifest_refuses_material_without_a_version_record() -> None:
    with pytest.raises(ManifestDraftError):
        build_manifest(
            _capture("大家好"),
            SEGMENTS,
            dataset_revision="",
            baseline_commit="base",
            candidate_commit="candidate",
            policy_revision="policy-1",
            language_lane="zh",
            device_class="macbook-builtin-mic",
        )


def test_build_manifest_never_invents_an_improvise_label() -> None:
    """The machine may under-claim a reading position, never over-claim behaviour."""

    capture = _capture("大家好，欢迎来到", "今天风有点大", "先看几组数字")
    capture.events[1].kind = "partial"
    manifest, _ = build_manifest(
        capture,
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    intents = {label["intent"] for label in manifest["labels"]}  # type: ignore[union-attr]
    assert intents <= {"read", "reRead"}
    assert "improvise" not in intents


def test_a_distant_confident_match_never_becomes_a_reading_position() -> None:
    """A distant match must not become a reading position (plan F-04).

    素材构建器此前**没有任何距离闸门**, 而 `ALIGN_FORWARD_CHARS = 600` 在一份
    128 字的脚本上等于全文都在前向窗口内. 实测: 读者的确认位置还在第 0 段时,
    识别器只送来第 2 段的一个 12 字片段, 工具就给出 `expected_segment_index = 2`
    且 `ratio = 1.0`——**匹配质量满分, 于是连人工确认清单都不进**.

    Swift 跟随控制器有 `localAdvanceTokenRadius`(默认 24)挡着这一族, 素材侧
    缺了对应的一道. 真实 41 秒素材实测单次推进最大 17 字, 中位数 5, **没有任何
    一次超过 24**, 所以这道闸门不会动到正常素材.
    """

    far_fragment = "促销价是 2599 元"

    # 前提必须先钉住, 否则本例会「因为错误的原因通过」: 这一条要证明的是
    # 「匹配很自信但离得远」, 不是「匹配模糊」.
    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    assert aligner.align(SEGMENTS[0], cumulative=True).segment_index == 0
    ratio, start, _ = aligner._best_match(normalize_text(far_fragment))
    assert ratio >= _TOOL.ALIGN_MIN_RATIO, "前提：匹配质量是过关的"
    assert start - aligner.cursor > 24, "前提：这一条确实远在半径之外"

    manifest, review = build_manifest(
        _capture(SEGMENTS[0], far_fragment),
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    labels = manifest["labels"]
    assert isinstance(labels, list)
    assert labels[0]["expected_segment_index"] == 0, "前提：第一条确实建立了位置"
    assert "expected_segment_index" not in labels[1], "远距匹配不得给出阅读位置"
    assert labels[1]["intent"] == "read", "拒绝位置不等于拒绝这条事件"

    # 拒绝之后必须让人看见: 否则复核的人无从判断这条标注为什么没有位置.
    flagged = [note for note in review if note["event_index"] == 1]
    assert len(flagged) == 1, f"远距匹配必须进人工确认清单: {review}"
    reason = str(flagged[0]["reason"])
    assert "匹配距离" in reason and "后文短语被误匹配" in reason, reason

    # 拒绝位置还不够, 游标也必须留在原地: 否则下一个事件会拿去和一个从未
    # 到达过的位置比较, 正常片段就会被安到读者没去过的段上.
    after = _capture(SEGMENTS[0], far_fragment, "大家好，欢迎来到")
    manifest_after, _ = build_manifest(
        after,
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    labels_after = manifest_after["labels"]
    assert isinstance(labels_after, list)
    assert (
        labels_after[2].get("expected_segment_index") == 0
    ), "游标被远距匹配推走之后, 正常片段会被安到读者没去过的段上"


def test_a_near_confident_match_still_claims_its_position() -> None:
    """Reverse control: the gate must not block ordinary following too."""

    manifest, _ = build_manifest(
        _capture(SEGMENTS[0], "先看几组数字"),
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    labels = manifest["labels"]
    assert isinstance(labels, list)
    assert labels[1].get("expected_segment_index") == 1


def test_a_keyword_sized_match_never_moves_the_reading_position() -> None:
    """F-19: a two-character match is not evidence of a reading position.

    比例是 `matched / len(needle)`, 所以一个两字的碎片只要出现在稿件里就拿到
    `ratio = 1.0`. Swift 跟随控制器有 `provisionalMinimumMatches` 挡住这一族,
    素材侧此前没有对应的一道.

    真实 41 秒素材实测: 82 个事件里 21 个匹配只有 1-3 字, 它们**一个字符都没
    推进游标**; 29 次真正的推进里最小匹配是 5 字. 所以 4 字这道闸门拦得住
    「仅凭关键词推进」, 且不碰真实素材.
    """

    keyword = "先看"

    aligner = ScriptAligner(index=SegmentIndex.build(SEGMENTS))
    assert aligner.align(SEGMENTS[0], cumulative=True).segment_index == 0
    ratio, start, end = aligner._best_match(normalize_text(keyword))
    assert ratio == 1.0, "前提: 这两个字确实完整地出现在稿件里"
    assert start - aligner.cursor <= _TOOL.ALIGN_MAX_ADVANCE_CHARS, "前提: 它并不远"
    assert end - aligner.cursor > 0, "前提: 它确实落在已确认位置之前, 有能力推进"

    manifest, review = build_manifest(
        _capture(SEGMENTS[0], keyword),
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    labels = manifest["labels"]
    assert isinstance(labels, list)
    # 位置仍然给「读者确实到达的地方」, 而不是不给位置: 事件本身是有效朗读证据.
    assert labels[1].get("expected_segment_index") == 0
    assert labels[1]["intent"] == "read"

    flagged = [note for note in review if note["event_index"] == 1]
    assert len(flagged) == 1, f"关键词级匹配必须进人工确认清单: {review}"
    reason = str(flagged[0]["reason"])
    assert "匹配仅 2 字" in reason, reason


def test_the_review_sidecar_shows_how_far_each_flagged_match_reached() -> None:
    """The sidecar showed match quality but not match distance.

    对齐度只说明「这段文字确实在稿件里」. 匹配离已确认位置多远, 才是判断
    有没有远距跳过的关键维度.
    """

    manifest, review = build_manifest(
        _capture(SEGMENTS[0], "今天风有点大"),
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    assert review, "前提：这份素材确实有存疑项"
    text = render_review(
        manifest,
        review,
        draft=True,
        profile="quality",
        capture_counts={"completed": 2},
    )
    assert "匹配距离" in text
    assert "对齐度" in text


def test_build_manifest_marks_terminal_failures_for_review() -> None:
    capture = _capture("大家好，欢迎来到")
    capture.events.append(
        _TOOL.CapturedEvent(
            offset_milliseconds=900,
            kind="failed",
            item_id="item-1",
            event_id="failed-1",
            revision=None,
            text="",
            stable_prefix_codepoints=None,
        )
    )
    manifest, review = build_manifest(
        capture,
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    assert manifest["labels"][-1]["intent"] == "read"  # type: ignore[index]
    assert [note["reason"] for note in review] == [
        "终态失败没有可对齐文本，intent 需人工确认"
    ]


def test_review_sidecar_never_carries_transcript_text() -> None:
    capture = _capture("大家好，欢迎来到", "今天风有点大")
    manifest, review = build_manifest(
        capture,
        SEGMENTS,
        dataset_revision="A_v1-draft",
        baseline_commit="base",
        candidate_commit="candidate",
        policy_revision="policy-1",
        language_lane="zh",
        device_class="macbook-builtin-mic",
    )
    rendered = render_review(
        manifest, review, draft=True, profile="quality", capture_counts={"a": 1}
    )
    assert "今天风有点大" not in rendered
    assert "大家好" not in rendered
    assert "机器草稿" in rendered
    assert "| 1 |" in rendered


def test_scriptless_capture_does_not_claim_to_be_a_replay_manifest() -> None:
    """No script means no labels and no reading positions, so no manifest version."""

    capture = _capture("大家好，欢迎来到")
    capture.counts["speechrail.transcription.hypothesis"] = 1
    rendered = render_capture(capture)
    assert "schema_version" not in rendered
    assert rendered["capture_schema_version"] == "teleprompter.replay.v1"
    assert "not a TeleprompterReplayManifest" in str(rendered["note"])
    assert rendered["wire_event_counts"] == {"speechrail.transcription.hypothesis": 1}
    assert isinstance(rendered["capture"], list) and len(rendered["capture"]) == 1


def test_require_external_path_refuses_the_repository() -> None:
    inside = Path(__file__).resolve().parent / "draft-manifest.json"
    with pytest.raises(ManifestDraftError):
        require_external_path(inside, "output")


def test_require_external_path_allows_a_controlled_external_directory(
    tmp_path: Path,
) -> None:
    resolved = require_external_path(tmp_path / "manifest.json", "output")
    assert resolved == (tmp_path / "manifest.json").resolve()


def test_load_wave_fixture_requires_24khz_mono_pcm16(tmp_path: Path) -> None:
    path = tmp_path / "fixture.wav"
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24_000)
        output.writeframes(b"\x00\x00" * 2_400)
    pcm, duration = load_wave_fixture(path)
    assert duration == 0.1 and len(pcm) == 4_800

    wrong = tmp_path / "wrong.wav"
    with wave.open(str(wrong), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(48_000)
        output.writeframes(b"\x00\x00" * 100)
    with pytest.raises(ManifestDraftError):
        load_wave_fixture(wrong)
