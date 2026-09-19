from __future__ import annotations

from speechrail.domain.tts_pronunciation import (
    PronunciationEntry,
    apply_pronunciation,
    make_pronunciation_set,
)
from speechrail.domain.tts_text_planner import TtsTextPlanner


def test_plan_spoken_projects_pronunciation_chunk_back_to_raw_input() -> None:
    pronunciation = make_pronunciation_set(
        "story",
        (
            PronunciationEntry(
                id="chang-an",
                surface="长安",
                spoken="常安",
                language="zh",
            ),
        ),
    )
    raw = "**长安**今天很安静"
    spoken = apply_pronunciation(raw, pronunciation, language="zh")
    plan = TtsTextPlanner(max_chars=5).plan_spoken(spoken)

    assert "".join(chunk.spoken_text for chunk in plan.chunks) == spoken.text
    assert plan.chunks[0].raw_start is not None
    assert plan.chunks[0].raw_end is not None
    assert "chang-an" in plan.chunks[0].pronunciation_entry_ids
    assert raw[
        plan.chunks[0].raw_start : plan.chunks[0].raw_end
    ].startswith("长安")


def test_plan_spoken_raw_spans_are_ordered_and_bounded() -> None:
    raw = "OpenAI 与 5km，一起测试 URL https://example.com/a.b"
    spoken = apply_pronunciation(raw)
    plan = TtsTextPlanner(max_chars=12).plan_spoken(spoken)

    previous = 0
    for chunk in plan.chunks:
        assert chunk.raw_start is not None
        assert chunk.raw_end is not None
        assert 0 <= chunk.raw_start <= chunk.raw_end <= len(raw)
        assert chunk.raw_start >= previous
        previous = chunk.raw_start


def test_plan_spoken_is_deterministic_for_same_revision_and_text() -> None:
    pronunciation = make_pronunciation_set(
        "stable",
        (
            PronunciationEntry(id="gpu", surface="GPU", spoken="G P U"),
        ),
    )
    spoken = apply_pronunciation("GPU 测试", pronunciation)
    planner = TtsTextPlanner(max_chars=8)
    assert planner.plan_spoken(spoken) == planner.plan_spoken(spoken)


def test_plan_spoken_downgrades_chunks_split_inside_one_pronunciation_span() -> None:
    pronunciation = make_pronunciation_set(
        "split",
        (
            PronunciationEntry(
                id="chang-an",
                surface="长安",
                spoken="常安",
                language="zh",
            ),
        ),
    )
    spoken = apply_pronunciation("长安", pronunciation, language="zh")

    plan = TtsTextPlanner(max_chars=1).plan_spoken(spoken)

    assert [chunk.spoken_text for chunk in plan.chunks[:2]] == ["常", "安"]
    assert [(chunk.raw_start, chunk.raw_end) for chunk in plan.chunks[:2]] == [
        (None, None),
        (None, None),
    ]
