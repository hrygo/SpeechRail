"""模型目录、三档 preset 与 runtime lock 的契约测试。"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from copy import deepcopy
from pathlib import Path

import pytest
from pydantic import ValidationError

import speechrail.config.model_catalog as model_catalog
from speechrail.config.model_catalog import (
    ArtifactFile,
    ModelArtifact,
    ModelCatalog,
    ModelPreset,
    RuntimeLock,
    SourceLocation,
    load_catalog,
    load_runtime_lock,
    preset,
)

REVISION = "a" * 40
SHA256 = "b" * 64


def _file(path: str) -> dict[str, object]:
    return {"path": path, "size": 4, "sha256": SHA256}


def _artifact(
    *,
    key: str,
    family: str,
    variant: str,
    bits: int = 8,
    files: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    if files is None:
        files = [
            _file("config.json"),
            _file("model.safetensors"),
            _file("tokenizer_config.json"),
            _file("vocab.json"),
            _file("merges.txt"),
        ]
        if family == "qwen3_tts":
            files.extend(
                [_file("speech_tokenizer/config.json"), _file("speech_tokenizer/model.safetensors")]
            )
    return {
        "key": key,
        "model_id": f"fixture/{key}",
        "revision": REVISION,
        "family": family,
        "variant": variant,
        "quantization": {"bits": bits, "group_size": 64, "format": "mlx"},
        "files": files,
        "sources": [
            {
                "provider": "fixture",
                "repository": f"fixture/{key}",
                "revision": REVISION,
            }
        ],
    }


def _catalog_payload() -> dict[str, object]:
    artifacts = [
        _artifact(key="asr", family="qwen3_asr", variant="asr"),
        _artifact(key="tts-custom", family="qwen3_tts", variant="custom_voice"),
        _artifact(key="tts-design", family="qwen3_tts", variant="voice_design"),
    ]
    return {
        "schema_version": 1,
        "artifacts": artifacts,
        "presets": [
            {"id": "quality", "asr": "asr", "tts": "tts-design"},
            {"id": "balanced", "asr": "asr", "tts": "tts-custom"},
            {"id": "light", "asr": "asr", "tts": "tts-custom"},
        ],
    }


def _hashed_requirement(name: str) -> str:
    return f"{name}==1.0 --hash=sha256:{SHA256}"


def test_preset_cannot_override_execution_policy() -> None:
    with pytest.raises(ValidationError):
        ModelPreset(id="light", asr="asr-small-q8", tts="tts-small-q8", chunk_ms=50)


def test_load_catalog_contains_complete_eight_bit_presets() -> None:
    catalog = load_catalog()
    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}

    assert catalog.schema_version == 1
    assert {item.id for item in catalog.presets} == {"quality", "balanced", "light"}
    assert catalog.preset("quality") == preset("quality")
    assert artifacts["asr-1.7b-q8"].quantization.bits == 8
    assert artifacts["tts-0.6b-custom-q4"].quantization.bits == 4
    assert all(
        artifacts[key].quantization.bits == 8
        for item in catalog.presets
        for key in (item.asr, item.tts)
    )
    assert "tts-0.6b-custom-q4" not in {item.tts for item in catalog.presets}


def test_preset_relationships_keep_weight_changes_only() -> None:
    catalog = ModelCatalog.model_validate(_catalog_payload())
    by_id = {item.id: item for item in catalog.presets}

    assert by_id["quality"].asr == by_id["balanced"].asr
    assert by_id["balanced"].tts == by_id["light"].tts


def test_catalog_and_nested_models_are_immutable() -> None:
    catalog = ModelCatalog.model_validate(_catalog_payload())

    with pytest.raises(ValidationError):
        catalog.schema_version = 2
    with pytest.raises(ValidationError):
        catalog.artifacts[0].key = "changed"
    with pytest.raises(TypeError):
        catalog.artifacts[0] = catalog.artifacts[0]  # type: ignore[index]


def test_unknown_catalog_and_artifact_keys_fail_closed() -> None:
    payload = _catalog_payload()
    payload["unknown"] = True
    with pytest.raises(ValidationError):
        ModelCatalog.model_validate(payload)

    artifact = _artifact(key="asr", family="qwen3_asr", variant="asr")
    artifact["capabilities"] = ["batch"]
    with pytest.raises(ValidationError):
        ModelArtifact.model_validate(artifact)


@pytest.mark.parametrize(
    "path", ["../config.json", "weights/../../model.safetensors", "/tmp/model"]
)
def test_artifact_file_rejects_path_traversal(path: str) -> None:
    with pytest.raises(ValidationError, match="path"):
        ArtifactFile(path=path, size=1, sha256=SHA256)


def test_artifact_rejects_invalid_revision_and_hash() -> None:
    with pytest.raises(ValidationError, match="revision"):
        SourceLocation(provider="fixture", repository="fixture/model", revision="main")
    with pytest.raises(ValidationError, match="sha256"):
        ArtifactFile(path="model.safetensors", size=1, sha256="bad")


def test_artifact_requires_tokenizer_or_codec_files() -> None:
    asr_without_tokenizer = _artifact(
        key="asr",
        family="qwen3_asr",
        variant="asr",
        files=[_file("config.json"), _file("model.safetensors")],
    )
    with pytest.raises(ValidationError, match="tokenizer"):
        ModelArtifact.model_validate(asr_without_tokenizer)

    tts_without_codec = _artifact(
        key="tts",
        family="qwen3_tts",
        variant="custom_voice",
        files=[
            _file("config.json"),
            _file("model.safetensors"),
            _file("tokenizer_config.json"),
            _file("vocab.json"),
            _file("merges.txt"),
            _file("speech_tokenizer/config.json"),
        ],
    )
    with pytest.raises(ValidationError, match=r"codec|speech_tokenizer"):
        ModelArtifact.model_validate(tts_without_codec)


@pytest.mark.parametrize("missing", ["config.json", "model.safetensors"])
def test_artifact_requires_core_files(missing: str) -> None:
    files = [
        _file(path)
        for path in (
            "config.json",
            "model.safetensors",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
        )
        if path != missing
    ]
    artifact = _artifact(key="asr", family="qwen3_asr", variant="asr", files=files)

    with pytest.raises(ValidationError, match=r"config\.json|model\.safetensors"):
        ModelArtifact.model_validate(artifact)


def test_complete_tokenizer_json_can_replace_split_tokenizer_files() -> None:
    artifact = _artifact(
        key="asr",
        family="qwen3_asr",
        variant="asr",
        files=[_file("config.json"), _file("model.safetensors"), _file("tokenizer.json")],
    )

    assert ModelArtifact.model_validate(artifact).files[-1].path == "tokenizer.json"


@pytest.mark.parametrize(
    ("family", "variant"),
    [("qwen3_asr", "custom_voice"), ("qwen3_tts", "asr")],
)
def test_artifact_rejects_unsupported_family_variant(family: str, variant: str) -> None:
    artifact = _artifact(key="bad", family=family, variant=variant)
    with pytest.raises(ValidationError, match=r"variant|family"):
        ModelArtifact.model_validate(artifact)


def test_catalog_rejects_bad_reference() -> None:
    payload = _catalog_payload()
    presets = payload["presets"]
    assert isinstance(presets, list)
    presets[0] = {"id": "quality", "asr": "missing", "tts": "tts-design"}

    with pytest.raises(ValidationError, match=r"artifact|reference|asr"):
        ModelCatalog.model_validate(payload)


def test_mirror_revision_may_differ_from_canonical_revision() -> None:
    artifact = _artifact(key="asr", family="qwen3_asr", variant="asr")
    sources = artifact["sources"]
    assert isinstance(sources, list)
    sources.append(
        {
            "provider": "mirror",
            "repository": "mirror/asr",
            "revision": "c" * 40,
        }
    )

    parsed = ModelArtifact.model_validate(artifact)
    assert parsed.sources[1].revision == "c" * 40


def test_at_least_one_source_revision_must_match_artifact() -> None:
    artifact = _artifact(key="asr", family="qwen3_asr", variant="asr")
    sources = artifact["sources"]
    assert isinstance(sources, list)
    sources[0]["revision"] = "c" * 40

    with pytest.raises(ValidationError, match=r"canonical|revision"):
        ModelArtifact.model_validate(artifact)


def test_catalog_rejects_four_bit_default_tts() -> None:
    payload = _catalog_payload()
    artifacts = payload["artifacts"]
    assert isinstance(artifacts, list)
    q4 = deepcopy(artifacts[1])
    assert isinstance(q4, dict)
    q4["key"] = "tts-custom-q4"
    quantization = q4["quantization"]
    assert isinstance(quantization, dict)
    quantization["bits"] = 4
    artifacts.append(q4)
    presets = payload["presets"]
    assert isinstance(presets, list)
    presets[1] = {"id": "balanced", "asr": "asr", "tts": "tts-custom-q4"}
    presets[2] = {"id": "light", "asr": "asr", "tts": "tts-custom-q4"}

    with pytest.raises(ValidationError, match=r"8|quantization|bit"):
        ModelCatalog.model_validate(payload)


def test_runtime_lock_requires_hashed_requirements_and_read_only_hashes() -> None:
    lock = RuntimeLock(
        id="fixture-lock",
        python="3.12.14",
        asr_requirements=(_hashed_requirement("asr"),),
        tts_requirements=(_hashed_requirement("tts"),),
        ffmpeg_artifact="imageio-ffmpeg==0.6.0",
        file_hashes={"runtime/asr.txt": SHA256},
    )

    assert isinstance(lock.file_hashes, Mapping)
    with pytest.raises(TypeError):
        lock.file_hashes["runtime/other.txt"] = SHA256  # type: ignore[index]
    with pytest.raises(ValidationError):
        lock.file_hashes = {}  # type: ignore[misc]


def test_runtime_lock_rejects_unhashed_requirement() -> None:
    with pytest.raises(ValidationError, match="hash"):
        RuntimeLock(
            id="fixture-lock",
            python="3.12.14",
            asr_requirements=("asr==1.0",),
            tts_requirements=(_hashed_requirement("tts"),),
            ffmpeg_artifact="imageio-ffmpeg==0.6.0",
            file_hashes={"runtime/asr.txt": SHA256},
        )


@pytest.mark.parametrize(
    "requirement",
    [
        f"asr>=1.0 --hash=sha256:{SHA256}",
        "--index-url=https://example.invalid/simple",
        f"asr==1.0 --hash=sha256:{SHA256} --extra-index-url=https://example.invalid/simple",
        "asr @ https://example.invalid/asr.whl",
    ],
)
def test_runtime_lock_rejects_unpinned_or_injected_requirement(requirement: str) -> None:
    with pytest.raises(ValidationError, match=r"package==version|sha256"):
        RuntimeLock(
            id="fixture-lock",
            python="3.12.14",
            asr_requirements=(requirement,),
            tts_requirements=(_hashed_requirement("tts"),),
            ffmpeg_artifact="imageio-ffmpeg==0.6.0",
            file_hashes={"runtime/asr.txt": SHA256},
        )


def test_runtime_lock_rejects_normalized_hash_path_collision() -> None:
    with pytest.raises(ValidationError, match="duplicate"):
        RuntimeLock(
            id="fixture-lock",
            python="3.12.14",
            asr_requirements=(_hashed_requirement("asr"),),
            tts_requirements=(_hashed_requirement("tts"),),
            ffmpeg_artifact="imageio-ffmpeg==0.6.0",
            file_hashes={"runtime/asr.txt": SHA256, "./runtime/asr.txt": SHA256},
        )


def test_load_runtime_lock_rejects_asset_hash_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = Path("src/speechrail/assets/runtime-lock.json")
    payload = json.loads(source.read_text(encoding="utf-8"))
    payload["file_hashes"]["runtime/asr.txt"] = "c" * 64
    lock_path = tmp_path / "runtime-lock.json"
    lock_path.write_text(json.dumps(payload), encoding="utf-8")
    monkeypatch.setattr(model_catalog, "_RUNTIME_LOCK_PATH", lock_path)

    with pytest.raises(ValueError, match="hash mismatch"):
        load_runtime_lock()


def test_load_runtime_lock_has_hashed_requirements() -> None:
    lock = load_runtime_lock()

    assert lock.id
    assert lock.python.startswith("3.12.")
    assert lock.asr_requirements
    assert lock.tts_requirements
    assert all("--hash=sha256:" in item for item in lock.asr_requirements)
    assert all("--hash=sha256:" in item for item in lock.tts_requirements)


def test_published_runtime_lock_aligns_all_cross_role_package_versions() -> None:
    lock = load_runtime_lock()

    def versions(requirements: tuple[str, ...]) -> dict[str, str]:
        parsed: dict[str, str] = {}
        for requirement in requirements:
            match = re.match(r"^([A-Za-z0-9_.-]+)==([^\s]+)", requirement)
            assert match is not None
            package = re.sub(r"[-_.]+", "-", match.group(1)).casefold()
            assert package not in parsed
            parsed[package] = match.group(2)
        return parsed

    asr = versions(lock.asr_requirements)
    tts = versions(lock.tts_requirements)
    overlap = sorted(asr.keys() & tts.keys())
    assert overlap
    mismatches = {
        package: (asr[package], tts[package])
        for package in overlap
        if asr[package] != tts[package]
    }
    assert not mismatches
