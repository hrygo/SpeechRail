from __future__ import annotations

from pathlib import Path

import pytest

from speechrail.config.model_catalog import load_catalog
from speechrail.service.profile_commands import (
    ProfileCommandError,
    apply_profile,
    list_profiles,
    model_changes,
    profile_status,
    recommend_profile,
    rollback_profile,
)
from speechrail.service.profile_store import ProfileStore
from speechrail.service.profile_switch import ApplyResult


def _selection(preset: str, generation: int) -> dict[str, object]:
    selected = load_catalog().preset(preset)
    return {
        "schema_version": 1,
        "preset": preset,
        "generation": generation,
        "asr": selected.asr,
        "tts": selected.tts,
        "runtime_lock_id": "speechrail-mlx-py312-v1",
    }


def test_catalog_lists_exact_three_tiers_and_balanced_to_light_only_changes_asr() -> None:
    profiles = list_profiles(load_catalog())
    assert [profile.id for profile in profiles] == ["quality", "balanced", "light"]
    balanced = next(profile for profile in profiles if profile.id == "balanced")
    light = next(profile for profile in profiles if profile.id == "light")
    assert balanced.tts == light.tts
    assert model_changes(balanced, light) == frozenset({"asr"})


def test_model_changes_accepts_the_public_mapping_shape() -> None:
    old = {"asr": "large-q8", "tts": "small-custom-q8"}
    new = {"asr": "small-q8", "tts": "small-custom-q8"}
    assert model_changes(old, new) == frozenset({"asr"})


@pytest.mark.parametrize(
    ("memory_gib", "expected"),
    [(8, "light"), (12, "balanced"), (16, "quality"), (64, "quality")],
)
def test_recommendation_uses_memory_only(memory_gib: int, expected: str) -> None:
    assert recommend_profile(memory_gib * 1024**3) == expected


def test_status_is_read_only_and_preserves_unconfigured_directory(tmp_path: Path) -> None:
    assert profile_status(tmp_path).preset is None
    assert not (tmp_path / "config").exists()
    assert not (tmp_path / "state").exists()


def test_apply_prepares_then_switches_exact_preset(tmp_path: Path) -> None:
    events: list[str] = []

    def prepare(preset: str, app_home: Path) -> str:
        events.append(f"prepare:{preset}:{app_home.name}")
        return "prepared-light"

    def switch(prepared_id: str, app_home: Path) -> ApplyResult:
        events.append(f"switch:{prepared_id}:{app_home.name}")
        return ApplyResult("committed", "op_test", None)

    result = apply_profile("light", app_home=tmp_path, prepare=prepare, switch=switch)
    assert result.status == "committed"
    assert events == [f"prepare:light:{tmp_path.name}", f"switch:prepared-light:{tmp_path.name}"]


def test_rollback_uses_previous_complete_pair_without_download(tmp_path: Path) -> None:
    store = ProfileStore(tmp_path)
    old, current = _selection("quality", 1), _selection("light", 2)
    store.initialize(old)
    operation = store.begin(old, current)
    for stage in ("VERIFIED", "STOPPING", "SWITCHING"):
        store.mark(operation, stage)
    store.stage_candidate(operation)
    store.claim_startup_selection()
    store.mark(operation, "SMOKING")
    store.commit(operation)
    calls: list[str] = []

    def switch(prepared_id: str, app_home: Path) -> ApplyResult:
        calls.append(prepared_id)
        return ApplyResult("committed", "op_rollback", None)

    result = rollback_profile(
        app_home=tmp_path,
        switch=switch,
        resolve_previous=lambda selection, app_home: "prepared_quality",
    )
    assert result.status == "committed"
    assert len(calls) == 1 and calls[0].startswith("prepared_")


def test_rollback_without_previous_selection_is_explicit(tmp_path: Path) -> None:
    with pytest.raises(ProfileCommandError, match="previous"):
        rollback_profile(app_home=tmp_path, switch=lambda prepared_id, app_home: None)  # type: ignore[arg-type,return-value]
