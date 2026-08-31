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
