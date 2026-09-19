from __future__ import annotations

import json
from pathlib import Path

import pytest

from speechrail.domain.tts import (
    VoiceRegistry,
    VoiceRevisionConflictError,
)


def test_instruction_voice_revision_changes_only_for_acoustic_fields(tmp_path):
    registry = VoiceRegistry(
        storage_path=tmp_path / "custom_voices.json",
        voices_dir=tmp_path / "voices",
    )

    created = registry.create_custom_profile(
        name="Narrator",
        instruction="calm narrator",
        voice_id="narrator",
        seed=7,
    )
    assert created.revision is not None
    assert created.revision.startswith("vr_")

    renamed = registry.update_custom_profile(
        "narrator",
        name="Narrator Renamed",
        expected_revision=created.revision,
    )
    assert renamed.revision == created.revision

    updated = registry.update_custom_profile(
        "narrator",
        instruction="brighter narrator",
        expected_revision=created.revision,
    )
    assert updated.revision is not None
    assert updated.revision != created.revision

    with pytest.raises(VoiceRevisionConflictError):
        registry.update_custom_profile(
            "narrator",
            seed=8,
            expected_revision=created.revision,
        )


def test_conditional_lease_checks_revision_inside_registry_lock(tmp_path):
    registry = VoiceRegistry(
        storage_path=tmp_path / "custom_voices.json",
        voices_dir=tmp_path / "voices",
    )
    created = registry.create_custom_profile(
        name="Narrator",
        instruction="stable narrator",
        voice_id="stable",
        seed=11,
    )

    with registry.lease_profile("stable", expected_revision=created.revision) as leased:
        assert leased.revision == created.revision

    updated = registry.update_custom_profile(
        "stable",
        seed=12,
        expected_revision=created.revision,
    )

    with (
        pytest.raises(VoiceRevisionConflictError),
        registry.lease_profile("stable", expected_revision=created.revision),
    ):
        pass

    with registry.lease_profile("stable", expected_revision=updated.revision) as leased:
        assert leased.revision == updated.revision


def test_legacy_record_without_revision_remains_unknown(tmp_path):
    storage = tmp_path / "custom_voices.json"
    storage.write_text(
        json.dumps(
            [
                {
                    "id": "legacy",
                    "name": "Legacy",
                    "instruction": "legacy instruction",
                    "seed": 42,
                    "temperature": 0.1,
                    "created_at": 1.0,
                    "mode": "instruction",
                }
            ]
        ),
        encoding="utf-8",
    )
    storage.chmod(0o600)

    registry = VoiceRegistry(storage_path=storage, voices_dir=tmp_path / "voices")
    legacy = registry.get_profile("legacy")
    assert legacy.revision is None

    with (
        pytest.raises(VoiceRevisionConflictError),
        registry.lease_profile("legacy", expected_revision="vr_" + "0" * 32),
    ):
        pass


def test_revision_persists_across_registry_restart(tmp_path):
    storage = tmp_path / "custom_voices.json"
    voices = tmp_path / "voices"
    first = VoiceRegistry(storage_path=storage, voices_dir=voices)
    created = first.create_custom_profile(
        name="Persistent",
        instruction="persistent identity",
        voice_id="persistent",
        seed=17,
    )

    second = VoiceRegistry(storage_path=storage, voices_dir=voices)
    reloaded = second.get_profile("persistent")
    assert reloaded.revision == created.revision


def test_revision_history_survives_restart_and_supports_cas_rollback(tmp_path):
    storage = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage, voices_dir=voices_dir)
    created = registry.create_custom_profile(
        name="Narrator",
        instruction="old recipe",
        voice_id="narrator",
        seed=21,
    )
    updated = registry.update_custom_profile(
        "narrator",
        instruction="new recipe",
        seed=22,
        expected_revision=created.revision,
    )
    assert updated.revision != created.revision

    restarted = VoiceRegistry(storage_path=storage, voices_dir=voices_dir)
    revisions = restarted.list_revisions("narrator")
    assert {item.revision for item in revisions} == {
        created.revision,
        updated.revision,
    }

    restored = restarted.rollback_custom_profile(
        "narrator",
        target_revision=created.revision,
        expected_revision=updated.revision,
    )
    assert restored.revision == created.revision
    assert restored.instruction == "old recipe"
    assert restored.seed == 21
    assert restored.name == "Narrator"

    with pytest.raises(VoiceRevisionConflictError):
        restarted.rollback_custom_profile(
            "narrator",
            target_revision=updated.revision,
            expected_revision=updated.revision,
        )


def test_clone_history_keeps_old_audio_until_voice_is_deleted(tmp_path):
    storage = tmp_path / "custom_voices.json"
    voices_dir = tmp_path / "voices"
    registry = VoiceRegistry(storage_path=storage, voices_dir=voices_dir)

    first = registry.create_cloned_profile(
        name="Clone",
        ref_text="first reference",
        audio_bytes=b"first-audio",
        voice_id="clone_history",
        duration_seconds=2.0,
    )
    first_path = first.audio_path
    assert first_path is not None

    second = registry.create_cloned_profile(
        name="Clone",
        ref_text="second reference",
        audio_bytes=b"second-audio",
        voice_id="clone_history",
        duration_seconds=2.0,
    )
    assert second.revision != first.revision
    assert Path(first_path).is_file()

    restored = registry.rollback_custom_profile(
        "clone_history",
        target_revision=first.revision,
        expected_revision=second.revision,
    )
    assert restored.revision == first.revision
    assert restored.audio_path == first_path
    assert Path(first_path).read_bytes() == b"first-audio"

    all_paths = {
        Path(item.audio_path)
        for item in registry.list_revisions("clone_history")
        if item.audio_path is not None
    }
    registry.delete_custom_profile("clone_history")
    assert all(not path.exists() for path in all_paths)
