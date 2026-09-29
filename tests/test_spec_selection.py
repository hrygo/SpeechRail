from __future__ import annotations

from pathlib import Path

import pytest

import speechrail.config.selection as selection_module
from speechrail.config import Settings
from speechrail.config.model_catalog import load_catalog, load_runtime_lock
from speechrail.config.model_locations import ModelLocationError, ModelLocations
from speechrail.config.selection import SelectionError, active_model_catalog, resolve_selection
from speechrail.domain.model_spec import required_spec_artifact


def _settings(**kwargs: object) -> Settings:
    return Settings(_env_file=None, **kwargs)  # type: ignore[arg-type,call-arg]


def _selection(
    *,
    asr_spec: str = "fast",
    tts_spec: str = "fast",
    auto: str = "off",
    generation: int = 1,
) -> dict[str, object]:
    return {
        "schema_version": 2,
        "asr_spec": asr_spec,
        "tts_spec": tts_spec,
        "auto": auto,
        "generation": generation,
        "runtime_lock_id": load_runtime_lock().id,
    }


def _directory(tmp_path: Path, artifact_key: str) -> Path:
    path = tmp_path / "models" / artifact_key
    path.mkdir(parents=True)
    return path


def _locations(bindings: dict[str, Path]) -> ModelLocations:
    return ModelLocations(bindings=dict(bindings))


def test_selection_resolves_only_from_the_explicit_v2_spec_fields(tmp_path: Path) -> None:
    asr_dir = _directory(tmp_path, "asr-0.6b-q8")
    tts_dir = _directory(tmp_path, "tts-0.6b-custom-q8")
    base_dir = _directory(tmp_path, "tts-0.6b-base-q8")

    resolved = resolve_selection(_settings(), _selection(), load_catalog(), tmp_path)

    assert resolved.qwen3_model_dir == asr_dir.resolve()
    assert resolved.qwen3_tts_model_dir == tts_dir.resolve()
    assert resolved.qwen3_tts_clone_model_dir == base_dir.resolve()
    assert resolved.asr_artifact_key == "asr-0.6b-q8"
    assert resolved.tts_artifact_key == "tts-0.6b-custom-q8"
    assert resolved.tts_base_artifact_key == "tts-0.6b-base-q8"
    assert resolved.selection_asr_spec == "fast"
    assert resolved.selection_tts_spec == "fast"
    assert resolved.selection_generation == 1
    assert resolved.dtype == "float16"


def test_active_catalog_never_infers_identity_from_directory_names(tmp_path: Path) -> None:
    directory = _directory(tmp_path, "asr-0.6b-q8")
    settings = _settings(qwen3_model_dir=directory)

    active = active_model_catalog(settings)

    assert active.profile is None
    assert active.asr is None
    assert active.tts is None


def test_selection_resolves_bound_artifacts_from_external_directories(
    tmp_path: Path,
) -> None:
    external_asr = tmp_path / "omlx" / "mlx-community--Qwen3-ASR-1.7B-bf16"
    external_tts = tmp_path / "omlx" / "mlx-community--Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
    external_base = tmp_path / "omlx" / "mlx-community--Qwen3-TTS-12Hz-1.7B-Base-bf16"
    for directory in (external_asr, external_tts, external_base):
        directory.mkdir(parents=True)

    resolved = resolve_selection(
        _settings(),
        _selection(asr_spec="reference", tts_spec="reference"),
        load_catalog(),
        tmp_path,
        locations=_locations(
            {
                "asr-1.7b-bf16": external_asr,
                "tts-1.7b-custom-bf16": external_tts,
                "tts-1.7b-base-bf16": external_base,
            }
        ),
    )

    assert resolved.qwen3_model_dir == external_asr.resolve()
    assert resolved.qwen3_tts_model_dir == external_tts.resolve()
    assert resolved.qwen3_tts_clone_model_dir == external_base.resolve()
    assert resolved.asr_artifact_key == "asr-1.7b-bf16"


def test_selection_rejects_binding_key_absent_from_catalog(tmp_path: Path) -> None:
    _directory(tmp_path, "asr-0.6b-q8")
    _directory(tmp_path, "tts-0.6b-custom-q8")
    _directory(tmp_path, "tts-0.6b-base-q8")
    external = tmp_path / "omlx"
    external.mkdir()

    with pytest.raises(ModelLocationError, match="unknown artifact key"):
        resolve_selection(
            _settings(),
            _selection(),
            load_catalog(),
            tmp_path,
            locations=_locations({"tts-9.9b-imaginary": external}),
        )


def test_selection_without_locations_keeps_managed_directories(tmp_path: Path) -> None:
    asr_dir = _directory(tmp_path, "asr-0.6b-q8")
    tts_dir = _directory(tmp_path, "tts-0.6b-custom-q8")
    _directory(tmp_path, "tts-0.6b-base-q8")

    resolved = resolve_selection(_settings(), _selection(), load_catalog(), tmp_path)

    assert resolved.qwen3_model_dir == asr_dir.resolve()
    assert resolved.qwen3_tts_model_dir == tts_dir.resolve()


def test_resolved_active_catalog_uses_recorded_artifact_keys(tmp_path: Path) -> None:
    _directory(tmp_path, "asr-0.6b-q8")
    _directory(tmp_path, "tts-0.6b-custom-q8")
    _directory(tmp_path, "tts-0.6b-base-q8")

    resolved = resolve_selection(_settings(), _selection(), load_catalog(), tmp_path)
    active = active_model_catalog(resolved)

    assert active.profile == "fast/fast"
    assert active.asr is not None and active.asr.key == "asr-0.6b-q8"
    assert active.tts is not None and active.tts.key == "tts-0.6b-custom-q8"
    assert active.tts_clone is not None and active.tts_clone.key == "tts-0.6b-base-q8"
    assert active.generation == 1


@pytest.mark.parametrize("spec", ["fast", "quality", "reference"])
def test_every_target_spec_resolves_to_catalog_bound_artifacts(
    tmp_path: Path, spec: str
) -> None:
    catalog = load_catalog()
    asr_key = catalog.binding(spec, "asr")  # type: ignore[arg-type]
    tts_key = catalog.binding(spec, "tts_custom_voice")  # type: ignore[arg-type]
    base_key = catalog.binding(spec, "tts_base")  # type: ignore[arg-type]
    for artifact_key in (asr_key, tts_key, base_key):
        _directory(tmp_path, artifact_key)

    resolved = resolve_selection(
        _settings(), _selection(asr_spec=spec, tts_spec=spec), catalog, tmp_path
    )

    assert resolved.asr_artifact_key == asr_key
    assert resolved.tts_artifact_key == tts_key
    assert resolved.tts_base_artifact_key == base_key


def test_selection_without_a_bound_artifact_fails_closed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _directory(tmp_path, "asr-0.6b-q8")
    _directory(tmp_path, "tts-0.6b-custom-q8")
    monkeypatch.setattr(selection_module, "required_spec_artifact", lambda tier, role: None)

    with pytest.raises(SelectionError, match="no artifact for"):
        resolve_selection(_settings(), _selection(), load_catalog(), tmp_path)


def test_selection_requires_the_base_clone_snapshot(tmp_path: Path) -> None:
    _directory(tmp_path, "asr-0.6b-q8")
    _directory(tmp_path, "tts-0.6b-custom-q8")

    with pytest.raises(SelectionError, match="TTS clone model snapshot directory is missing"):
        resolve_selection(_settings(), _selection(), load_catalog(), tmp_path)


@pytest.mark.parametrize("spec", ["fast", "quality", "reference"])
def test_voice_design_is_not_a_tier_role(spec: str) -> None:
    """The design artifact is on-demand, so no tier may claim the role."""

    assert required_spec_artifact(spec, "voice_design") is None  # type: ignore[arg-type]
    assert load_catalog().voice_design_artifact() is not None


@pytest.mark.parametrize("spec", ["fast", "quality", "reference"])
def test_voice_design_is_published_for_every_spec_once_supplied(
    tmp_path: Path, spec: str
) -> None:
    """Any ``tts_spec`` must expose design jobs once the shared snapshot exists.

    The user documentation states that VoiceDesign is not bound to a tier, so
    the selection layer has to keep publishing the same artifact for every
    spec. Re-binding it to one tier would silently falsify that contract.
    """

    catalog = load_catalog()
    design = catalog.voice_design_artifact()
    assert design is not None
    for role in ("asr", "tts_custom_voice", "tts_base"):
        _directory(tmp_path, catalog.binding(spec, role))  # type: ignore[arg-type]
    _directory(tmp_path, design.key)

    resolved = resolve_selection(
        _settings(), _selection(asr_spec=spec, tts_spec=spec), catalog, tmp_path
    )

    assert resolved.voice_design_artifact_key == design.key
    assert active_model_catalog(resolved, catalog).voice_design is not None


@pytest.mark.parametrize("spec", ["fast", "quality", "reference"])
def test_missing_design_snapshot_degrades_instead_of_failing(
    tmp_path: Path, spec: str
) -> None:
    """A missing design snapshot must not block ASR/TTS/Base activation."""

    catalog = load_catalog()
    for role in ("asr", "tts_custom_voice", "tts_base"):
        _directory(tmp_path, catalog.binding(spec, role))  # type: ignore[arg-type]

    resolved = resolve_selection(
        _settings(), _selection(asr_spec=spec, tts_spec=spec), catalog, tmp_path
    )

    assert resolved.voice_design_artifact_key is None
    assert active_model_catalog(resolved, catalog).voice_design is None


def test_legacy_selection_is_rejected_before_paths_are_used(tmp_path: Path) -> None:
    with pytest.raises(SelectionError, match="schema_version"):
        resolve_selection(
            _settings(),
            {
                "schema_version": 1,
                "preset": "quality",
                "generation": 1,
                "asr": "asr-1.7b-q8",
                "tts": "tts-1.7b-design-q8",
                "runtime_lock_id": load_runtime_lock().id,
            },
            load_catalog(),
            tmp_path,
        )
