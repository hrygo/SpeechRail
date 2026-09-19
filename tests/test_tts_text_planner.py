"""Versioned planner metadata must preserve the existing acoustic input exactly."""
from dataclasses import FrozenInstanceError

import pytest

from speechrail.domain.tts import bounded_sentences
from speechrail.domain.tts_text_planner import PLANNER_VERSION, TtsTextPlanner


@pytest.mark.parametrize("text", [
    "", "短句。", "天地玄黄" * 210,
    "Dr. Smith uses https://example.org/a.b and pays 3.14 USD. " * 12,
    '“不要！他说：‘请稍候。’” Then e.g. another sentence; 还有下一句。' * 14,
    "a_b@example.org is not a negative number: -2.5.\n" * 15,
    "🙂a\u0301中文\tEnglish！？" * 120,
])
@pytest.mark.parametrize("limit", [1, 37, 240])
def test_plan_is_deterministic_lossless_and_matches_existing_split(text: str, limit: int) -> None:
    planner = TtsTextPlanner(max_chars=limit)
    plan = planner.plan(text)
    assert plan == planner.plan(text)
    assert plan.version == PLANNER_VERSION
    assert tuple(c.spoken_text for c in plan.chunks) == bounded_sentences(text, limit)
    assert "".join(c.spoken_text for c in plan.chunks) == text
    position = 0
    for index, chunk in enumerate(plan.chunks):
        assert chunk.index == index
        assert chunk.source_start == position
        assert text[chunk.source_start:chunk.source_end] == chunk.spoken_text
        assert 0 < len(chunk.spoken_text) <= limit
        assert chunk.suggested_pause_ms is None
        position = chunk.source_end
    assert position == len(text)
    assert plan.native_context_conditioning == "unsupported"
    assert plan.coordinate_space == "normalized_text_unicode_codepoints"


def test_plan_cannot_be_mutated_or_share_state_between_requests() -> None:
    planner = TtsTextPlanner()
    first = planner.plan("first request.")
    assert planner.plan("different request.").input_sha256 != first.input_sha256
    with pytest.raises(FrozenInstanceError):
        first.version = "mutable"  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        first.chunks[0].spoken_text = "changed"  # type: ignore[misc]


def test_plan_summary_has_no_text_hash_or_request_identifier() -> None:
    summary = TtsTextPlanner(max_chars=10).plan("private material " * 5).summary()
    assert set(summary) == {"planner_version", "planner_chunks", "planner_max_chars"}
    assert summary["planner_version"] == PLANNER_VERSION


@pytest.mark.parametrize("limit", [0, -1, 4097, True, 2.5])
def test_invalid_policy_limits_fail_before_planning(limit: int) -> None:
    with pytest.raises(ValueError, match="invalid_planner_limit"):
        TtsTextPlanner(max_chars=limit)


@pytest.mark.parametrize(("text", "limit", "kind"), [
    ("One. second long sentence", 10, "sentence"),
    ("abcdefghijklmno, more words", 18, "secondary"),
    ("hello world plus", 8, "whitespace"),
    ("abcdefghijklm", 4, "hard_limit"),
])
def test_boundary_metadata_matches_the_selected_policy(text: str, limit: int, kind: str) -> None:
    plan = TtsTextPlanner(max_chars=limit).plan(text)
    assert plan.chunks[0].boundary == kind
    assert plan.chunks[-1].boundary == "end_of_input"
