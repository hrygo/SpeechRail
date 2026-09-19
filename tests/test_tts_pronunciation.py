from __future__ import annotations

import json

import pytest

from speechrail.domain.tts_pronunciation import (
    PronunciationConflictError,
    PronunciationEntry,
    PronunciationRegistry,
    PronunciationRevokedError,
    apply_pronunciation,
    make_pronunciation_set,
)


def _entries() -> tuple[PronunciationEntry, ...]:
    return (
        PronunciationEntry(
            id="name-zhou",
            surface="周杰伦",
            spoken="周杰伦",
            language="zh",
        ),
        PronunciationEntry(
            id="place-chang-an",
            surface="长安",
            spoken="常安",
            language="zh",
        ),
        PronunciationEntry(
            id="unit-km",
            surface="km",
            spoken="公里",
            language="zh",
            case_sensitive=False,
            word_boundary=True,
        ),
        PronunciationEntry(
            id="abbr-ai",
            surface="AI",
            spoken="A I",
            language="auto",
            case_sensitive=False,
            word_boundary=True,
        ),
        PronunciationEntry(
            id="mixed-openai",
            surface="OpenAI",
            spoken="Open A I",
            language="auto",
            case_sensitive=False,
            word_boundary=True,
        ),
    )


@pytest.mark.parametrize(
    ("raw", "language", "expected"),
    [
        ("去长安跑5km", "zh", "去常安跑5公里。"),
        ("OpenAI 与 AI", "zh", "Open A I 与 A I。"),
        ("周杰伦在长安", "zh", "周杰伦在常安。"),
    ],
)
def test_fixed_fixtures_produce_deterministic_spoken_text_and_raw_spans(
    raw: str,
    language: str,
    expected: str,
) -> None:
    pronunciation = make_pronunciation_set("story", _entries())
    first = apply_pronunciation(raw, pronunciation, language=language)
    second = apply_pronunciation(raw, pronunciation, language=language)

    assert first == second
    assert first.text == expected
    assert first.spoken_sha256 == second.spoken_sha256
    assert first.pronunciation_revision == pronunciation.revision
    for hit in first.hits:
        assert 0 <= hit.raw_start <= hit.raw_end <= len(raw)
        assert 0 <= hit.spoken_start < hit.spoken_end <= len(first.text)


def test_normalization_mapping_preserves_display_span_after_markup_and_emoji() -> None:
    raw = "**长安** 🙂 5km"
    pronunciation = make_pronunciation_set("story", _entries())
    spoken = apply_pronunciation(raw, pronunciation, language="zh")
    assert spoken.text == "常安  5公里。"

    chang_an = next(hit for hit in spoken.hits if hit.entry_id == "place-chang-an")
    assert raw[chang_an.raw_start : chang_an.raw_end] == "长安"
    unit = next(hit for hit in spoken.hits if hit.entry_id == "unit-km")
    assert raw[unit.raw_start : unit.raw_end].lower() == "km"


def test_longest_match_wins_before_stable_entry_id() -> None:
    entries = (
        PronunciationEntry(id="short", surface="Open", spoken="欧喷"),
        PronunciationEntry(id="long", surface="OpenAI", spoken="Open A I"),
    )
    pronunciation = make_pronunciation_set("overlap", entries)
    spoken = apply_pronunciation("OpenAI", pronunciation)
    assert spoken.text == "Open A I."
    assert [hit.entry_id for hit in spoken.hits] == ["long"]


def test_word_boundary_and_case_policy_are_explicit() -> None:
    pronunciation = make_pronunciation_set(
        "boundary",
        (
            PronunciationEntry(
                id="ai",
                surface="AI",
                spoken="A I",
                case_sensitive=False,
                word_boundary=True,
            ),
        ),
    )
    assert apply_pronunciation("AI ai", pronunciation).text == "A I A I."
    assert apply_pronunciation("RAIL", pronunciation).text == "RAIL."


def test_conflicting_duplicate_surface_policy_fails_closed() -> None:
    with pytest.raises(PronunciationConflictError):
        make_pronunciation_set(
            "conflict",
            (
                PronunciationEntry(id="a", surface="长安", spoken="常安"),
                PronunciationEntry(id="b", surface="长安", spoken="长安"),
            ),
        )


def test_empty_set_does_not_change_existing_tts_normalization() -> None:
    empty = make_pronunciation_set("empty", ())
    spoken = apply_pronunciation(" **Hello** ", empty)
    assert spoken.text == "Hello."
    assert spoken.hits == ()


def test_registry_cas_revision_restart_revoke_and_delete(tmp_path) -> None:
    path = tmp_path / "pronunciation.json"
    registry = PronunciationRegistry(path)
    first = registry.put("story", _entries(), expected_revision=None)

    changed_entries = (
        *_entries(),
        PronunciationEntry(id="new", surface="GPU", spoken="G P U"),
    )
    with pytest.raises(PronunciationConflictError):
        registry.put("story", changed_entries, expected_revision=None)

    second = registry.put(
        "story",
        changed_entries,
        expected_revision=first.revision,
    )
    assert second.revision != first.revision

    restarted = PronunciationRegistry(path)
    assert restarted.get("story").revision == second.revision
    assert restarted.get("story", revision=first.revision).revision == first.revision

    revoked = restarted.revoke("story", first.revision)
    assert revoked.revoked is True
    with pytest.raises(PronunciationRevokedError):
        restarted.get("story", revision=first.revision)

    restarted.delete("story")
    with pytest.raises(KeyError):
        restarted.get("story")


def test_registry_file_does_not_contain_input_text(tmp_path) -> None:
    path = tmp_path / "pronunciation.json"
    registry = PronunciationRegistry(path)
    registry.put("story", _entries(), expected_revision=None)
    raw = path.read_text(encoding="utf-8")
    assert "这是一次用户请求正文" not in raw
    data = json.loads(raw)
    assert data[0]["id"] == "story"
