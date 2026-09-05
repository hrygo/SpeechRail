from __future__ import annotations

from speechrail.runtime.speaker_centroids import SpeakerCentroidStore


def test_centroid_store_reuses_identity_within_anonymous_ttl_group() -> None:
    store = SpeakerCentroidStore(max_groups=2, ttl_seconds=60, similarity_threshold=0.8)

    first = store.assign(group_id="group-a", raw_label="spk_01", embedding=(1.0, 0.0))
    second = store.assign(group_id="group-a", raw_label="spk_01", embedding=(0.99, 0.01))

    assert first == "spk_01"
    assert second == "spk_01"


def test_centroid_store_does_not_link_groups_or_retains_expired_groups() -> None:
    now = [0.0]
    store = SpeakerCentroidStore(
        max_groups=2, ttl_seconds=10, similarity_threshold=0.8, clock=lambda: now[0]
    )
    store.assign(group_id="group-a", raw_label="spk_01", embedding=(1.0, 0.0))

    assert store.assign(group_id="group-b", raw_label="spk_01", embedding=(0.99, 0.01)) == "spk_01"
    now[0] = 11
    store.expire()

    assert store.group_count == 0


def test_centroid_store_allocates_a_new_canonical_label_for_a_raw_label_collision() -> None:
    store = SpeakerCentroidStore(max_groups=1, ttl_seconds=60, similarity_threshold=0.95)

    assert store.assign(group_id="group-a", raw_label="spk_01", embedding=(1.0, 0.0)) == "spk_01"
    assert store.assign(group_id="group-a", raw_label="spk_01", embedding=(0.0, 1.0)) == "spk_02"


# ---------------------------------------------------------------------------
# R3: multi-evidence speaker matching with generation isolation

import pytest  # noqa: E402

from speechrail.backends.camplus import (  # noqa: E402
    MAX_EMBEDDING_CLIP_BYTES,
    MIN_EMBEDDING_CLIP_BYTES,
    trim_embedding_clip,
)
from speechrail.runtime.speaker_centroids import (  # noqa: E402
    SpeakerEvidenceIndex,
)


def _index(**overrides: object) -> SpeakerEvidenceIndex:
    kwargs: dict[str, object] = {
        "max_groups": 4,
        "ttl_seconds": 900,
        "model_fingerprint": "shape:" + "a" * 64,
        "generation_seed": "process-1",
    }
    kwargs.update(overrides)
    return SpeakerEvidenceIndex(**kwargs)  # type: ignore[arg-type]


def test_evidence_index_requires_two_non_overlapping_clips() -> None:
    index = _index()

    first = index.observe(
        group_id="g", session_id="s1", raw_label="spk_01",
        embedding=(1.0, 0.0), clip_start_sample=0, clip_end_sample=32_000,
    )
    assert first is None

    # An overlapping second clip does not count as independent evidence.
    overlap = index.observe(
        group_id="g", session_id="s1", raw_label="spk_01",
        embedding=(1.0, 0.0), clip_start_sample=16_000, clip_end_sample=48_000,
    )
    assert overlap is None

    second = index.observe(
        group_id="g", session_id="s1", raw_label="spk_01",
        embedding=(0.99, 0.01), clip_start_sample=64_000, clip_end_sample=96_000,
    )
    assert second == "spk_01"


def test_evidence_index_caps_centroids_per_group() -> None:
    index = _index()
    vectors = [
        (1.0, 0.0, 0.0, 0.0),
        (0.0, 1.0, 0.0, 0.0),
        (0.0, 0.0, 1.0, 0.0),
        (0.0, 0.0, 0.0, 1.0),
    ]
    for position, vector in enumerate(vectors):
        index.observe(group_id="g", session_id="s1", raw_label=f"raw_{position}",
                      embedding=vector, clip_start_sample=0, clip_end_sample=32_000)

    fifth = index.observe(group_id="g", session_id="s1", raw_label="raw_4",
                          embedding=(0.7, -0.7, 0.1, 0.1),
                          clip_start_sample=0, clip_end_sample=32_000)
    assert fifth is None  # repeated attempts stay bounded
    assert len(index._groups["g"].centroids) == 4


def test_evidence_index_caps_summaries_per_centroid() -> None:
    index = _index()
    for position in range(12):
        index.observe(group_id="g", session_id="s1", raw_label="spk_01",
                      embedding=(1.0, 0.0), clip_start_sample=position * 64_000,
                      clip_end_sample=(position + 1) * 64_000)
    assert index._groups["g"].summary_counts["spk_01"] == 8


def test_active_input_touches_ttl_and_sixteen_minute_silence_expires() -> None:
    now = [0.0]
    index = _index(clock=lambda: now[0])  # type: ignore[arg-type]
    index.observe(group_id="g", session_id="s1", raw_label="spk_01",
                  embedding=(1.0, 0.0), clip_start_sample=0, clip_end_sample=32_000)

    now[0] = 800.0
    index.observe(group_id="g", session_id="s1", raw_label="spk_01",
                  embedding=(1.0, 0.0), clip_start_sample=64_000, clip_end_sample=96_000)
    now[0] = 1000.0
    index.expire()
    assert index.group_count == 1

    now[0] = 800.0 + 961.0
    index.expire()
    assert index.group_count == 0


def test_generation_depends_on_model_fingerprint_and_process_seed() -> None:
    base = _index(model_fingerprint="shape:" + "a" * 64, generation_seed="p1")
    same = _index(model_fingerprint="shape:" + "a" * 64, generation_seed="p1")
    other_model = _index(model_fingerprint="shape:" + "b" * 64, generation_seed="p1")
    other_process = _index(model_fingerprint="shape:" + "a" * 64, generation_seed="p2")

    assert base.generation == same.generation
    assert base.generation != other_model.generation
    assert base.generation != other_process.generation


def test_same_raw_labels_in_unrelated_groups_never_link() -> None:
    index = _index()
    for group in ("g1", "g2"):
        index.observe(group_id=group, session_id="s1", raw_label="spk_01",
                      embedding=(1.0, 0.0), clip_start_sample=0, clip_end_sample=32_000)
        index.observe(group_id=group, session_id="s1", raw_label="spk_01",
                      embedding=(1.0, 0.0), clip_start_sample=64_000, clip_end_sample=96_000)

    assert index.suggest_links(group_id="g1", session_id="s1") == ()
    assert index.suggest_links(group_id="g2", session_id="s1") == ()


def test_suggest_links_only_pairs_current_session_aliases() -> None:
    index = _index()
    index.observe(group_id="g", session_id="s1", raw_label="spk_03",
                  embedding=(1.0, 0.0), clip_start_sample=0, clip_end_sample=32_000)
    index.observe(group_id="g", session_id="s1", raw_label="spk_03",
                  embedding=(1.0, 0.0), clip_start_sample=64_000, clip_end_sample=96_000)
    index.observe(group_id="g", session_id="s2", raw_label="spk_07",
                  embedding=(0.99, 0.01), clip_start_sample=0, clip_end_sample=32_000)
    index.observe(group_id="g", session_id="s2", raw_label="spk_07",
                  embedding=(0.99, 0.01), clip_start_sample=64_000, clip_end_sample=96_000)

    links = index.suggest_links(group_id="g", session_id="s2")
    assert len(links) == 1
    link = links[0]
    assert (link.from_session_id, link.from_speaker) == ("s1", "spk_03")
    assert (link.to_session_id, link.to_speaker) == ("s2", "spk_07")
    assert 0.0 <= link.similarity <= 1.0


def test_release_session_drops_evidence_also_on_error_paths() -> None:
    index = _index()
    index.observe(group_id="g", session_id="s1", raw_label="spk_01",
                  embedding=(1.0, 0.0), clip_start_sample=0, clip_end_sample=32_000)
    with pytest.raises(RuntimeError):
        try:
            raise RuntimeError("synthetic failure mid-meeting")
        finally:
            index.release_session(group_id="g", session_id="s1")

    assert index.suggest_links(group_id="g", session_id="s1") == ()
    # Evidence is gone: a fresh session must gather two clips again.
    assert index.observe(group_id="g", session_id="s2", raw_label="spk_01",
                         embedding=(1.0, 0.0), clip_start_sample=0,
                         clip_end_sample=32_000) is None


def test_embedding_dimension_mismatch_is_rejected() -> None:
    index = _index()
    index.observe(group_id="g", session_id="s1", raw_label="spk_01",
                  embedding=(1.0, 0.0), clip_start_sample=0, clip_end_sample=32_000)
    try:
        index.observe(group_id="g", session_id="s1", raw_label="spk_02",
                      embedding=(1.0, 0.0, 0.0), clip_start_sample=64_000,
                      clip_end_sample=96_000)
    except ValueError as exc:
        assert "dimension" in str(exc)
    else:
        raise AssertionError("expected dimension mismatch rejection")


def test_embedding_clip_policy_bounds_and_eligibility() -> None:
    two_s = MIN_EMBEDDING_CLIP_BYTES
    five_s = MAX_EMBEDDING_CLIP_BYTES
    assert trim_embedding_clip(b"\x00" * (two_s - 2), overlap_free=True, peak_ratio=0.5) is None
    assert trim_embedding_clip(b"\x00" * two_s, overlap_free=True, peak_ratio=0.5) is not None
    trimmed = trim_embedding_clip(
        b"\x01\x02" * five_s, overlap_free=True, peak_ratio=0.5
    )
    assert trimmed is not None and len(trimmed) == five_s
    assert trim_embedding_clip(b"\x00" * two_s, overlap_free=False, peak_ratio=0.5) is None
    assert trim_embedding_clip(b"\x7f\x7f" * two_s, overlap_free=True, peak_ratio=0.99) is None
