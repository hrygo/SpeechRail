from __future__ import annotations

import json
from pathlib import Path

import pytest

from speechrail.domain.voice_validation import (
    VoiceValidationRepository,
    VoiceValidationStoreUnavailableError,
)


def _record(index: int) -> dict[str, object]:
    return {
        "voice_id": f"voice_{index}",
        "voice_revision": f"vr_{index:032x}",
        "status": "pass",
        "run_id": f"run_{index}",
        "model_artifact": "tts_clone_base",
        "model_catalog_revision": "a" * 40,
        "failure_codes": [],
        "validated_for": ["output"],
    }


def test_validation_store_is_atomic_bounded_and_revision_keyed(tmp_path: Path) -> None:
    path = tmp_path / "voice_validations.json"
    repository = VoiceValidationRepository(path, max_entries=2)

    repository.put(_record(1))
    repository.put(_record(2))
    repository.put(_record(3))

    assert len(json.loads(path.read_text(encoding="utf-8"))) == 2
    assert repository.get(
        voice_id="voice_1",
        voice_revision=f"vr_{1:032x}",
        model_artifact="tts_clone_base",
        model_catalog_revision="a" * 40,
    ) is None
    current = repository.get(
        voice_id="voice_3",
        voice_revision=f"vr_{3:032x}",
        model_artifact="tts_clone_base",
        model_catalog_revision="a" * 40,
    )
    assert current is not None
    assert current["validated_for"] == ["output"]


def test_validation_store_fails_closed_on_corrupt_records(tmp_path: Path) -> None:
    path = tmp_path / "voice_validations.json"
    path.write_text('{"not": "a list"}', encoding="utf-8")
    repository = VoiceValidationRepository(path)

    with pytest.raises(VoiceValidationStoreUnavailableError):
        repository.get(
            voice_id="voice_1",
            voice_revision="vr_" + "1" * 32,
            model_artifact="tts_clone_base",
            model_catalog_revision="a" * 40,
        )


def test_validation_store_selects_the_exact_current_runtime_binding(tmp_path: Path) -> None:
    repository = VoiceValidationRepository(tmp_path / "voice_validations.json")
    common = {
        "voice_id": "voice_current",
        "voice_revision": "vr_" + "c" * 32,
        "status": "pass",
        "model_artifact": "tts_clone_base",
        "model_catalog_revision": "a" * 40,
        "policy_version": "voice_quality_v1",
        "runtime_fingerprint": "vf_old",
        "preprocess_version": "energy_v1",
        "generation_recipe_revision": "qwen3_tts_base_clone_v1",
        "failure_codes": [],
        "validated_for": ["output"],
    }
    repository.put(
        {
            **common,
            "run_id": "old",
            "model_runtime_revision": "rt_" + "1" * 64,
        }
    )
    repository.put(
        {
            **common,
            "run_id": "new",
            "model_runtime_revision": "rt_" + "2" * 64,
            "runtime_fingerprint": "vf_new",
        }
    )

    current = repository.get(
        voice_id="voice_current",
        voice_revision="vr_" + "c" * 32,
        model_artifact="tts_clone_base",
        model_catalog_revision="a" * 40,
        model_runtime_revision="rt_" + "2" * 64,
        runtime_fingerprint="vf_new",
        preprocess_version="energy_v1",
        generation_recipe_revision="qwen3_tts_base_clone_v1",
        policy_version="voice_quality_v1",
        require_current_binding=True,
    )
    assert current is not None
    assert current["run_id"] == "new"

    assert (
        repository.get(
            voice_id="voice_current",
            voice_revision="vr_" + "c" * 32,
            model_artifact="tts_clone_base",
            model_catalog_revision="a" * 40,
            require_current_binding=True,
        )
        is None
    )
