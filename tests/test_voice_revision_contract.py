from __future__ import annotations

import json

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

    with pytest.raises(VoiceRevisionConflictError):
        with registry.lease_profile("stable", expected_revision=created.revision):
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

    with pytest.raises(VoiceRevisionConflictError):
        with registry.lease_profile("legacy", expected_revision="vr_" + "0" * 32):
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
