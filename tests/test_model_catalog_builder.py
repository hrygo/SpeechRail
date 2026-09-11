from __future__ import annotations

import io
import json
import sys
from importlib import import_module
from pathlib import Path
from typing import Any

import pytest

# ``uv run pytest`` 将 console script 的 bin 目录作为 ``sys.path[0]``, 因此需
# 将仓库根目录加入路径, 才能导入仓库内的 ``tools`` 包。
sys.path.insert(0, str(Path(__file__).parents[1]))

_catalog_builder = import_module("tools.build_model_catalog")
build_catalog = _catalog_builder.build_catalog
require_immutable_revision = _catalog_builder.require_immutable_revision


REVISION = "0123456789abcdef0123456789abcdef01234567"


def _file(path: str, *, digest: str | None = None, size: int = 4) -> dict[str, Any]:
    return {
        "path": path,
        "size": size,
        "sha256": digest or ("a" * 64),
    }


def _artifact(
    *,
    key: str = "qwen3-asr-0.6b-8bit",
    model_id: str = "Qwen/Qwen3-ASR-0.6B",
    files: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    return {
        "key": key,
        "model_id": model_id,
        "revision": REVISION,
        "family": "qwen3",
        "variant": "0.6b",
        "quantization": {"bits": 8, "group_size": 64, "format": "mlx"},
        "files": files or [_file("config.json"), _file("model.safetensors")],
        "sources": [
            {
                "provider": "offline",
                "repository": "fixture/qwen3-asr-0.6b",
                "revision": REVISION,
            }
        ],
    }


def _default_precision_policy() -> dict[str, Any]:
    return {
        "quality": {"asr": 8, "tts": 8, "aligner": None},
        "balanced": {"asr": 8, "tts": 8, "aligner": None},
        "light": {"asr": 8, "tts": 8, "aligner": None},
    }


def _catalog(
    *artifacts: dict[str, Any],
    precision_policy: dict[str, Any] | None = None,
) -> dict[str, Any]:
    artifact_keys = [artifact["key"] for artifact in artifacts]
    first_key = artifact_keys[0] if artifact_keys else "missing"
    presets = [
        {"id": preset_id, "asr": first_key, "tts": first_key, "aligner": None, "diarization": False}
        for preset_id in ("quality", "balanced", "light")
    ]
    return {
        "schema_version": 2,
        "artifacts": list(artifacts),
        "presets": presets,
        "precision_policy": precision_policy or _default_precision_policy(),
    }


def _aligner_artifact(*, key: str = "aligner-q8", bits: int | None = 8) -> dict[str, Any]:
    return {
        "key": key,
        "model_id": "fixture/Qwen3-ForcedAligner-0.6B",
        "revision": REVISION,
        "family": "qwen3_forced_aligner",
        "variant": "aligner",
        "quantization": {
            "bits": bits,
            "group_size": 64 if bits is not None else None,
            "format": "mlx" if bits is not None else "none",
        },
        "files": [_file("config.json"), _file("model.safetensors"), _file("tokenizer.json")],
        "sources": [
            {
                "provider": "offline",
                "repository": "fixture/qwen3-forced-aligner",
                "revision": REVISION,
            }
        ],
    }


def _legal_metadata() -> dict[str, Any]:
    asr = _artifact(
        key="asr-1.7b-q8",
        files=[_file("config.json"), _file("model.safetensors"), _file("tokenizer.json")],
    )
    return {
        "schema_version": 2,
        "artifacts": [asr, _aligner_artifact()],
        "presets": [
            {
                "id": "quality",
                "asr": "asr-1.7b-q8",
                "tts": "asr-1.7b-q8",
                "aligner": "aligner-q8",
                "diarization": True,
            },
            {
                "id": "balanced",
                "asr": "asr-1.7b-q8",
                "tts": "asr-1.7b-q8",
                "aligner": "aligner-q8",
                "diarization": True,
            },
            {
                "id": "light",
                "asr": "asr-1.7b-q8",
                "tts": "asr-1.7b-q8",
                "aligner": None,
                "diarization": False,
            },
        ],
        "precision_policy": {
            "quality": {"asr": 8, "tts": 8, "aligner": 8},
            "balanced": {"asr": 8, "tts": 8, "aligner": 8},
            "light": {"asr": 8, "tts": 8, "aligner": None},
        },
    }


def test_mutable_revision_cannot_ship() -> None:
    with pytest.raises(ValueError, match="immutable"):
        require_immutable_revision("main")


@pytest.mark.parametrize("revision", ["latest", "v1.2.3", "release-2026-09"])
def test_latest_and_tag_only_revisions_cannot_ship(revision: str) -> None:
    with pytest.raises(ValueError, match="immutable"):
        require_immutable_revision(revision)


def test_commit_hash_is_normalized_and_returned() -> None:
    assert require_immutable_revision(REVISION.upper()) == REVISION


def test_build_catalog_normalizes_artifacts_and_sorts_files() -> None:
    artifact = _artifact(
        files=[_file("model.safetensors"), _file("config.json"), _file("tokenizer.json")]
    )

    catalog = build_catalog(_catalog(artifact))

    assert catalog["schema_version"] == 2
    assert [item["path"] for item in catalog["artifacts"][0]["files"]] == [
        "config.json",
        "model.safetensors",
        "tokenizer.json",
    ]
    assert catalog["artifacts"][0]["revision"] == REVISION


def test_missing_file_hash_is_rejected() -> None:
    missing_hash = _file("model.safetensors")
    del missing_hash["sha256"]

    with pytest.raises(ValueError, match="sha256"):
        build_catalog(_catalog(_artifact(files=[missing_hash])))


@pytest.mark.parametrize(
    "path", ["../config.json", "weights/../../config.json", "/tmp/model.safetensors", "..\\secret"]
)
def test_path_traversal_or_absolute_file_path_is_rejected(path: str) -> None:
    with pytest.raises(ValueError, match="path"):
        build_catalog(_catalog(_artifact(files=[_file(path)])))


def test_duplicate_file_path_is_rejected() -> None:
    files = [_file("model.safetensors"), _file("model.safetensors", digest="b" * 64)]

    with pytest.raises(ValueError, match="duplicate"):
        build_catalog(_catalog(_artifact(files=files)))


def test_tts_artifact_requires_speech_tokenizer_files() -> None:
    tts = _artifact(
        key="qwen3-tts-0.6b-customvoice-8bit",
        model_id="Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
        files=[_file("config.json"), _file("model.safetensors")],
    )

    with pytest.raises(ValueError, match=r"speech_tokenizer|codec"):
        build_catalog(_catalog(tts))


def test_tts_artifact_with_speech_tokenizer_files_is_accepted() -> None:
    tts = _artifact(
        key="qwen3-tts-0.6b-customvoice-8bit",
        model_id="Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
        files=[
            _file("config.json"),
            _file("model.safetensors"),
            _file("speech_tokenizer/config.json"),
        ],
    )

    catalog = build_catalog(_catalog(tts))

    assert catalog["artifacts"][0]["model_id"] == "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"


def test_mirror_with_different_file_hash_is_rejected() -> None:
    artifact = _artifact()
    artifact["sources"] = [
        {
            "provider": "offline",
            "repository": "fixture/one",
            "revision": REVISION,
            "files": [_file("config.json"), _file("model.safetensors")],
        },
        {
            "provider": "offline",
            "repository": "fixture/two",
            "revision": REVISION,
            "files": [_file("config.json", digest="b" * 64), _file("model.safetensors")],
        },
    ]

    with pytest.raises(ValueError, match=r"hash|mirror|equivalent"):
        build_catalog(_catalog(artifact))


def test_runtime_lock_cannot_be_embedded_in_model_catalog() -> None:
    entries = _catalog(_artifact())
    entries["runtime_lock"] = {"id": "must-be-separate"}

    with pytest.raises(ValueError, match="runtime_lock"):
        build_catalog(entries)


def test_duplicate_artifact_key_is_rejected() -> None:
    first = _artifact()
    second = _artifact(files=[_file("config.json"), _file("model.safetensors", digest="b" * 64)])

    with pytest.raises(ValueError, match="duplicate artifact key"):
        build_catalog(_catalog(first, second))


def test_cli_writes_only_to_an_explicit_output_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    output = tmp_path / "catalog.json"
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(_catalog(_artifact()))))

    assert _catalog_builder.main(["-", "--output", str(output)]) == 0
    assert json.loads(output.read_text(encoding="utf-8"))["schema_version"] == 2


def test_preset_without_aligner_or_diarization_is_rejected() -> None:
    entries = _catalog(_artifact())
    presets = entries["presets"]
    assert isinstance(presets, list)
    presets[0] = {"id": "quality", "asr": "qwen3-asr-0.6b-8bit", "tts": "qwen3-asr-0.6b-8bit"}

    with pytest.raises(ValueError, match=r"aligner|diarization"):
        build_catalog(entries)


def test_preset_diarization_must_be_a_real_bool() -> None:
    entries = _catalog(_artifact())
    presets = entries["presets"]
    assert isinstance(presets, list)
    preset = presets[0]
    assert isinstance(preset, dict)
    preset["diarization"] = 1

    with pytest.raises(ValueError, match="bool"):
        build_catalog(entries)


def test_preset_aligner_must_reference_a_known_artifact() -> None:
    entries = _catalog(_artifact())
    presets = entries["presets"]
    assert isinstance(presets, list)
    preset = presets[0]
    assert isinstance(preset, dict)
    preset["aligner"] = "aligner-missing"

    with pytest.raises(ValueError, match="unknown artifact"):
        build_catalog(entries)


def test_legal_metadata_produces_schema_v2_with_precision_policy() -> None:
    catalog = build_catalog(_legal_metadata())

    assert catalog["schema_version"] == 2
    policy = catalog["precision_policy"]
    assert isinstance(policy, dict)
    assert set(policy) == {"quality", "balanced", "light"}
    assert policy["light"]["aligner"] is None
    assert policy["quality"]["aligner"] == 8


@pytest.mark.parametrize(
    "precision_policy",
    [
        {
            "quality": {"asr": 8, "tts": 8, "aligner": None},
            "balanced": {"asr": 8, "tts": 8, "aligner": None},
        },
        {
            "quality": {"asr": 8, "tts": 8},
            "balanced": {"asr": 8, "tts": 8, "aligner": None},
            "light": {"asr": 8, "tts": 8, "aligner": None},
        },
        {
            "quality": {"asr": 0, "tts": 8, "aligner": None},
            "balanced": {"asr": 8, "tts": 8, "aligner": None},
            "light": {"asr": 8, "tts": 8, "aligner": None},
        },
        {
            "quality": {"asr": True, "tts": 8, "aligner": None},
            "balanced": {"asr": 8, "tts": 8, "aligner": None},
            "light": {"asr": 8, "tts": 8, "aligner": None},
        },
        {
            "quality": {"asr": 8, "tts": 8, "aligner": "q8"},
            "balanced": {"asr": 8, "tts": 8, "aligner": None},
            "light": {"asr": 8, "tts": 8, "aligner": None},
        },
    ],
    ids=["missing-tier", "missing-inner-key", "non-positive", "bool", "bad-aligner"],
)
def test_illegal_precision_policy_is_rejected(precision_policy: dict[str, Any]) -> None:
    entries = _catalog(_artifact(), precision_policy=precision_policy)

    with pytest.raises(ValueError, match=r"precision_policy|aligner|asr|tts|missing|unsupported"):
        build_catalog(entries)
