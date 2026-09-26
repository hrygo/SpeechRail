"""模型目录、档位/角色绑定与 runtime lock 的契约测试。"""

from __future__ import annotations

import copy
import json
import re
from collections.abc import Mapping
from pathlib import Path

import pytest
from pydantic import ValidationError

import speechrail.config.model_catalog as model_catalog
from speechrail.config.model_catalog import (
    REQUIRED_SPEC_BINDINGS,
    ArtifactFile,
    ModelArtifact,
    ModelCatalog,
    RuntimeLock,
    SourceLocation,
    load_catalog,
    load_runtime_lock,
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
    bits: int | None = 8,
    group_size: int | None = 64,
    format_name: str = "mlx",
    dtype: str | None = None,
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
    quantization: dict[str, object] = {
        "bits": bits,
        "group_size": group_size,
        "format": format_name,
        "dtype": dtype,
    }
    return {
        "key": key,
        "model_id": f"fixture/{key}",
        "revision": REVISION,
        "family": family,
        "variant": variant,
        "quantization": quantization,
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
    bf16: dict[str, object] = {
        "bits": None,
        "group_size": None,
        "format_name": "none",
        "dtype": "bf16",
    }
    artifacts = [
        _artifact(key="asr-0.6b-q8", family="qwen3_asr", variant="asr", bits=8),
        _artifact(key="asr-1.7b-q8", family="qwen3_asr", variant="asr", bits=8),
        _artifact(key="asr-1.7b-bf16", family="qwen3_asr", variant="asr", **bf16),
        _artifact(key="tts-0.6b-custom-q8", family="qwen3_tts", variant="custom_voice", bits=8),
        _artifact(key="tts-1.7b-custom-q8", family="qwen3_tts", variant="custom_voice", bits=8),
        _artifact(
            key="tts-1.7b-custom-bf16", family="qwen3_tts", variant="custom_voice", **bf16
        ),
        _artifact(key="tts-0.6b-base-q8", family="qwen3_tts", variant="base", bits=8),
        _artifact(key="tts-1.7b-base-q8", family="qwen3_tts", variant="base", bits=8),
        _artifact(key="tts-1.7b-base-bf16", family="qwen3_tts", variant="base", **bf16),
        _artifact(key="tts-1.7b-design-bf16", family="qwen3_tts", variant="voice_design", **bf16),
        _artifact(key="aligner-q8", family="qwen3_forced_aligner", variant="aligner", bits=8),
        _artifact(key="aligner-bf16", family="qwen3_forced_aligner", variant="aligner", **bf16),
    ]
    return {
        "schema_version": 2,
        "artifacts": artifacts,
        "specs": [
            {"tier": tier, "role": role, "artifact_key": artifact_key}
            for (tier, role), artifact_key in REQUIRED_SPEC_BINDINGS.items()
        ],
    }



def _hashed_requirement(name: str) -> str:
    return f"{name}==1.0 --hash=sha256:{SHA256}"


def test_catalog_specs_match_the_required_role_matrix() -> None:
    catalog = load_catalog()

    bindings = {(item.tier, item.role): item.artifact_key for item in catalog.specs}

    assert bindings == dict(REQUIRED_SPEC_BINDINGS)
    assert catalog.binding("quality", "tts_custom_voice") == "tts-1.7b-custom-q8"
    assert catalog.artifact_for("reference", "tts_base") is not None
    assert catalog.artifact_for("fast", "voice_design") is None


def test_quantization_rejects_bits_and_dtype_together() -> None:
    with pytest.raises(ValidationError, match=r"bits|dtype|precision"):
        model_catalog.QuantizationSpec(
            bits=8,
            group_size=64,
            format="mlx",
            dtype="bf16",
        )


def test_catalog_rejects_unquantized_artifact_without_dtype() -> None:
    payload = _catalog_payload()
    artifacts = payload["artifacts"]
    assert isinstance(artifacts, list)
    asr = next(item for item in artifacts if item["key"] == "asr-1.7b-bf16")
    quantization = asr["quantization"]
    assert isinstance(quantization, dict)
    quantization["dtype"] = None

    with pytest.raises(
        ValidationError, match=r"unquantized artifact must declare quantization\.dtype"
    ):
        ModelCatalog.model_validate(payload)


def test_quality_clone_source_is_pinned_to_modelscope() -> None:
    catalog = load_catalog()
    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}
    clone = artifacts[catalog.binding("quality", "tts_base")]
    source = clone.sources[0]

    assert clone.variant == "base"
    assert clone.revision == "73ae2cb59832ed1eb13c249e378b854cfc643131"
    assert source.provider == "modelscope"
    assert source.revision == clone.revision


def test_catalog_and_nested_models_are_immutable() -> None:
    catalog = ModelCatalog.model_validate(_catalog_payload())

    with pytest.raises(ValidationError):
        catalog.schema_version = 3
    with pytest.raises(ValidationError):
        catalog.artifacts[0].key = "changed"
    with pytest.raises(TypeError):
        catalog.artifacts[0] = catalog.artifacts[0]  # type: ignore[index]


def test_catalog_deep_copy_is_independent_and_json_stable() -> None:
    catalog = load_catalog()
    expected_specs = json.loads(catalog.model_dump_json())["specs"]

    for clone in (copy.deepcopy(catalog), catalog.model_copy(deep=True)):
        assert clone == catalog
        assert clone is not catalog
        assert json.loads(clone.model_dump_json())["specs"] == expected_specs

    restored = ModelCatalog.model_validate_json(catalog.model_dump_json())
    assert restored == catalog
    assert json.loads(restored.model_dump_json())["specs"] == expected_specs


def test_unknown_catalog_and_artifact_keys_fail_closed() -> None:
    payload = _catalog_payload()
    payload["unknown"] = True
    with pytest.raises(ValidationError):
        ModelCatalog.model_validate(payload)

    artifact = _artifact(key="asr", family="qwen3_asr", variant="asr")
    artifact["capabilities"] = ["batch"]
    with pytest.raises(ValidationError):
        ModelArtifact.model_validate(artifact)


def test_artifact_requires_dtype_when_unquantized() -> None:
    """没有量化的制品必须写明权重本身的数值格式, 否则同一列里会有一行说不出精度。"""
    artifact = _artifact(
        key="aligner-bf16",
        family="qwen3_forced_aligner",
        variant="aligner",
        bits=None,
        group_size=None,
        format_name="none",
    )

    with pytest.raises(ValidationError, match=r"dtype"):
        ModelArtifact.model_validate(artifact)

    quantization = artifact["quantization"]
    assert isinstance(quantization, dict)
    quantization["dtype"] = "bf16"
    assert ModelArtifact.model_validate(artifact).quantization.dtype == "bf16"


def test_artifact_rejects_bits_and_dtype_together() -> None:
    """精度只有一个维度: 同时写 bits 与 dtype 无法判断该读哪一个。"""
    artifact = _artifact(
        key="asr-1.7b-q8",
        family="qwen3_asr",
        variant="asr",
        dtype="bf16",
    )

    with pytest.raises(ValidationError, match=r"bits or dtype"):
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
    [
        ("qwen3_asr", "custom_voice"),
        ("qwen3_tts", "asr"),
        ("qwen3_forced_aligner", "asr"),
    ],
)
def test_artifact_rejects_unsupported_family_variant(family: str, variant: str) -> None:
    artifact = _artifact(key="bad", family=family, variant=variant)
    with pytest.raises(ValidationError, match=r"variant|family"):
        ModelArtifact.model_validate(artifact)


def test_catalog_rejects_bad_reference() -> None:
    payload = _catalog_payload()
    specs = payload["specs"]
    assert isinstance(specs, list)
    quality = next(item for item in specs if item["tier"] == "quality" and item["role"] == "asr")
    quality["artifact_key"] = "missing"

    with pytest.raises(ValidationError, match=r"artifact|reference"):
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


def test_runtime_lock_requires_hashed_requirements_and_read_only_hashes() -> None:
    lock = RuntimeLock(
        id="fixture-lock",
        python="3.14.7",
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


def test_runtime_lock_pins_the_engine_wheel_by_build_provenance() -> None:
    lock = RuntimeLock(
        id="fixture-lock",
        python="3.14.7",
        asr_requirements=(_hashed_requirement("asr"),),
        tts_requirements=(_hashed_requirement("tts"),),
        ffmpeg_artifact="imageio-ffmpeg==0.6.0",
        file_hashes={"runtime/asr.txt": SHA256},
        engine_wheel={
            "filename": "mlx_audio-0.4.8+speechrail.1-py3-none-any.whl",
            "sha256": SHA256,
            "source_repository": "https://github.com/Blaizzy/mlx-audio",
            "source_revision": "b" * 40,
            "patch_sha256": "c" * 64,
            "build_inputs_sha256": "d" * 64,
        },
    )

    assert lock.engine_wheel is not None
    with pytest.raises(ValidationError):
        lock.engine_wheel.sha256 = "f" * 64  # type: ignore[misc]
    # The lock no longer carries vendor overlay destinations; only a wheel pin
    # may describe the engine delivery.
    with pytest.raises(ValidationError, match="vendor_overlays"):
        RuntimeLock(
            id="fixture-lock",
            python="3.14.7",
            asr_requirements=(_hashed_requirement("asr"),),
            tts_requirements=(_hashed_requirement("tts"),),
            ffmpeg_artifact="imageio-ffmpeg==0.6.0",
            file_hashes={"runtime/asr.txt": SHA256},
            vendor_overlays={"mlx_audio/tts/models/qwen3_tts/incremental.py": SHA256},
        )
    with pytest.raises(ValidationError):
        RuntimeLock(
            id="fixture-lock",
            python="3.14.7",
            asr_requirements=(_hashed_requirement("asr"),),
            tts_requirements=(_hashed_requirement("tts"),),
            ffmpeg_artifact="imageio-ffmpeg==0.6.0",
            file_hashes={"runtime/asr.txt": SHA256},
            engine_wheel={
                "filename": "../escape.whl",
                "sha256": SHA256,
                "source_repository": "https://github.com/Blaizzy/mlx-audio",
                "source_revision": "b" * 40,
                "patch_sha256": "c" * 64,
                "build_inputs_sha256": "d" * 64,
            },
        )


@pytest.mark.parametrize("python", ["3.12.14", "3.13.15", "3.14", "3.15.0", "3.14.7rc1"])
def test_runtime_lock_rejects_unsupported_python(python: str) -> None:
    with pytest.raises(ValidationError, match=r"3\.14"):
        RuntimeLock(
            id="fixture-lock",
            python=python,
            asr_requirements=(_hashed_requirement("asr"),),
            tts_requirements=(_hashed_requirement("tts"),),
            ffmpeg_artifact="imageio-ffmpeg==0.6.0",
            file_hashes={"runtime/asr.txt": SHA256},
        )


def test_runtime_lock_rejects_unhashed_requirement() -> None:
    with pytest.raises(ValidationError, match="hash"):
        RuntimeLock(
            id="fixture-lock",
            python="3.14.7",
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
            python="3.14.7",
            asr_requirements=(requirement,),
            tts_requirements=(_hashed_requirement("tts"),),
            ffmpeg_artifact="imageio-ffmpeg==0.6.0",
            file_hashes={"runtime/asr.txt": SHA256},
        )


def test_runtime_lock_rejects_normalized_hash_path_collision() -> None:
    with pytest.raises(ValidationError, match="duplicate"):
        RuntimeLock(
            id="fixture-lock",
            python="3.14.7",
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
    assert lock.python.startswith("3.14.")
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
