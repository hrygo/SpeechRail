"""模型目录、四档 preset 与 runtime lock 的契约测试。"""

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
    ArtifactFile,
    ModelArtifact,
    ModelCatalog,
    ModelPreset,
    RuntimeLock,
    SourceLocation,
    TierPrecision,
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
    artifacts = [
        _artifact(key="asr-q4", family="qwen3_asr", variant="asr", bits=4),
        _artifact(key="asr-q8", family="qwen3_asr", variant="asr", bits=8),
        _artifact(key="tts-custom-q4", family="qwen3_tts", variant="custom_voice", bits=4),
        _artifact(key="tts-custom-q8", family="qwen3_tts", variant="custom_voice", bits=8),
        _artifact(key="tts-design-q8", family="qwen3_tts", variant="voice_design", bits=8),
        _artifact(key="tts-base-q8", family="qwen3_tts", variant="base", bits=8),
        _artifact(key="aligner-q8", family="qwen3_forced_aligner", variant="aligner", bits=8),
        _artifact(
            key="aligner-bf16",
            family="qwen3_forced_aligner",
            variant="aligner",
            bits=None,
            group_size=None,
            format_name="none",
            dtype="bf16",
        ),
        _artifact(
            key="asr-1.7b-bf16",
            family="qwen3_asr",
            variant="asr",
            bits=None,
            group_size=None,
            format_name="none",
            dtype="bf16",
        ),
        _artifact(
            key="tts-1.7b-design-bf16",
            family="qwen3_tts",
            variant="voice_design",
            bits=None,
            group_size=None,
            format_name="none",
            dtype="bf16",
        ),
        _artifact(
            key="tts-1.7b-base-bf16",
            family="qwen3_tts",
            variant="base",
            bits=None,
            group_size=None,
            format_name="none",
            dtype="bf16",
        ),
    ]
    return {
        "schema_version": 2,
        "artifacts": artifacts,
        "presets": [
            {
                "id": "quality",
                "asr": "asr-q8",
                "tts": "tts-design-q8",
                "tts_clone": "tts-base-q8",
                "aligner": "aligner-bf16",
                "diarization": True,
            },
            {
                "id": "balanced",
                "asr": "asr-q8",
                "tts": "tts-custom-q8",
                "tts_clone": None,
                "aligner": "aligner-q8",
                "diarization": True,
            },
            {
                "id": "light",
                "asr": "asr-q8",
                "tts": "tts-custom-q8",
                "tts_clone": None,
                "aligner": None,
                "diarization": False,
            },
            {
                "id": "extreme",
                "asr": "asr-1.7b-bf16",
                "tts": "tts-1.7b-design-bf16",
                "tts_clone": "tts-1.7b-base-bf16",
                "aligner": "aligner-bf16",
                "diarization": True,
            },
        ],
        "precision_policy": {
            "extreme": {"asr": "bf16", "tts": "bf16", "aligner": "bf16"},
            "quality": {"asr": 8, "tts": 8, "aligner": "bf16"},
            "balanced": {"asr": 8, "tts": 8, "aligner": 8},
            "light": {"asr": 8, "tts": 8, "aligner": None},
        },
    }


def _hashed_requirement(name: str) -> str:
    return f"{name}==1.0 --hash=sha256:{SHA256}"


def test_preset_cannot_override_execution_policy() -> None:
    with pytest.raises(ValidationError):
        ModelPreset(
            id="light",
            asr="asr-small-q8",
            tts="tts-small-q8",
            aligner=None,
            diarization=False,
            chunk_ms=50,
        )


def test_load_catalog_matches_tier_precision_policy() -> None:
    catalog = load_catalog()
    artifacts = {artifact.key: artifact for artifact in catalog.artifacts}

    assert catalog.schema_version == 2
    assert len(catalog.artifacts) == 12
    assert {item.id for item in catalog.presets} == {"quality", "balanced", "light", "extreme"}
    assert catalog.preset("quality") == preset("quality")

    by_id = {item.id: item for item in catalog.presets}
    for preset_id in ("light", "balanced", "quality", "extreme"):
        item = by_id[preset_id]
        tier = catalog.precision_policy[preset_id]
        for artifact, precision in (
            (artifacts[item.asr], tier.asr),
            (artifacts[item.tts], tier.tts),
        ):
            if precision == "bf16":
                assert artifact.quantization.bits is None
                assert artifact.quantization.dtype == "bf16"
            else:
                assert artifact.quantization.bits == precision
                assert artifact.quantization.dtype is None
        if tier.aligner is None:
            assert item.aligner is None
        else:
            assert item.aligner is not None
            aligner = artifacts[item.aligner].quantization
            if tier.aligner == "bf16":
                assert aligner.bits is None
                assert aligner.dtype == "bf16"
            else:
                assert aligner.bits == tier.aligner
                assert aligner.dtype is None

    assert by_id["light"].asr == "asr-0.6b-q8"
    assert by_id["light"].tts == "tts-0.6b-custom-q8"
    assert by_id["light"].aligner is None
    assert by_id["light"].diarization is False
    assert by_id["balanced"].asr == "asr-1.7b-q8"
    assert by_id["balanced"].tts == "tts-0.6b-custom-q8"
    assert by_id["balanced"].aligner == "aligner-q8"
    assert by_id["balanced"].diarization is True
    assert by_id["quality"].asr == "asr-1.7b-q8"
    assert by_id["quality"].tts == "tts-1.7b-design-q8"
    assert by_id["quality"].tts_clone == "tts-1.7b-base-q8"
    assert artifacts[by_id["quality"].tts_clone].variant == "base"
    assert by_id["quality"].aligner == "aligner-bf16"
    assert by_id["quality"].diarization is True
    assert by_id["extreme"].asr == "asr-1.7b-bf16"
    assert by_id["extreme"].tts == "tts-1.7b-design-bf16"
    assert by_id["extreme"].tts_clone == "tts-1.7b-base-bf16"
    assert by_id["extreme"].aligner == "aligner-bf16"
    assert by_id["extreme"].diarization is True


def test_tier_precision_accepts_bf16_asr_tts_and_aligner() -> None:
    precision = TierPrecision(asr="bf16", tts="bf16", aligner="bf16")

    assert precision.asr == "bf16"
    assert precision.tts == "bf16"
    assert precision.aligner == "bf16"


@pytest.mark.parametrize(
    ("policy_field", "message"),
    [("asr", "ASR precision"), ("tts", "TTS precision")],
)
def test_catalog_rejects_extreme_precision_policy_mismatch(
    policy_field: str, message: str
) -> None:
    payload = _catalog_payload()
    policy = payload["precision_policy"]
    assert isinstance(policy, dict)
    extreme_policy = policy["extreme"]
    assert isinstance(extreme_policy, dict)
    extreme_policy[policy_field] = 8

    with pytest.raises(ValidationError, match=message):
        ModelCatalog.model_validate(payload)


def test_extreme_preset_requires_voice_design_and_base_clone() -> None:
    payload = _catalog_payload()
    presets = payload["presets"]
    assert isinstance(presets, list)
    extreme = presets[3]
    assert isinstance(extreme, dict)
    extreme["tts_clone"] = None

    with pytest.raises(ValidationError, match="must declare a base clone"):
        ModelCatalog.model_validate(payload)


def test_extreme_clone_rejects_non_base_tts_artifact() -> None:
    payload = _catalog_payload()
    presets = payload["presets"]
    assert isinstance(presets, list)
    extreme = presets[3]
    assert isinstance(extreme, dict)
    extreme["tts_clone"] = "tts-design-q8"

    with pytest.raises(ValidationError, match="variant=base"):
        ModelCatalog.model_validate(payload)


@pytest.mark.parametrize(
    ("preset_id", "clone_key"),
    [
        ("extreme", "tts-base-q8"),
        ("quality", "tts-1.7b-base-bf16"),
    ],
)
def test_catalog_clone_precision_matches_preset_tts_policy(
    preset_id: str, clone_key: str
) -> None:
    payload = _catalog_payload()
    presets = payload["presets"]
    assert isinstance(presets, list)
    selected = next(item for item in presets if item["id"] == preset_id)
    selected["tts_clone"] = clone_key

    with pytest.raises(ValidationError, match=r"clone.*precision|precision.*clone"):
        ModelCatalog.model_validate(payload)


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
    clone = artifacts[catalog.preset("quality").tts_clone or ""]
    source = clone.sources[0]

    assert clone.variant == "base"
    assert clone.revision == "73ae2cb59832ed1eb13c249e378b854cfc643131"
    assert source.provider == "modelscope"
    assert source.revision == clone.revision


def test_preset_relationships_keep_weight_changes_only() -> None:
    catalog = ModelCatalog.model_validate(_catalog_payload())
    by_id = {item.id: item for item in catalog.presets}

    assert by_id["quality"].asr == by_id["balanced"].asr
    assert by_id["quality"].tts != by_id["balanced"].tts
    assert by_id["balanced"].tts == by_id["light"].tts


def test_catalog_and_nested_models_are_immutable() -> None:
    catalog = ModelCatalog.model_validate(_catalog_payload())

    with pytest.raises(ValidationError):
        catalog.schema_version = 3
    with pytest.raises(ValidationError):
        catalog.artifacts[0].key = "changed"
    with pytest.raises(TypeError):
        catalog.artifacts[0] = catalog.artifacts[0]  # type: ignore[index]
    with pytest.raises(TypeError):
        catalog.precision_policy["light"] = catalog.precision_policy["light"]  # type: ignore[index]


def test_catalog_deep_copy_is_independent_and_json_stable() -> None:
    catalog = load_catalog()
    expected_policy = json.loads(catalog.model_dump_json())["precision_policy"]

    for clone in (copy.deepcopy(catalog), catalog.model_copy(deep=True)):
        assert clone == catalog
        assert clone is not catalog
        assert isinstance(clone.precision_policy["light"], TierPrecision)
        assert json.loads(clone.model_dump_json())["precision_policy"] == expected_policy
        with pytest.raises(TypeError):
            clone.precision_policy["light"] = clone.precision_policy["light"]  # type: ignore[index]

    restored = ModelCatalog.model_validate_json(catalog.model_dump_json())
    assert restored.precision_policy == catalog.precision_policy
    assert json.loads(restored.model_dump_json())["precision_policy"] == expected_policy


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
    """没有量化的制品必须写明权重本身的数值格式，否则同一列里会有一行说不出精度。"""
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
    """精度只有一个维度：同时写 bits 与 dtype 无法判断该读哪一个。"""
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
    presets = payload["presets"]
    assert isinstance(presets, list)
    presets[0] = {
        "id": "quality",
        "asr": "missing",
        "tts": "tts-design-q8",
        "aligner": "aligner-bf16",
        "diarization": True,
    }

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


def test_catalog_rejects_precision_policy_bits_mismatch() -> None:
    payload = _catalog_payload()
    policy = payload["precision_policy"]
    assert isinstance(policy, dict)
    light = policy["light"]
    assert isinstance(light, dict)
    light["asr"] = 4

    with pytest.raises(ValidationError, match=r"precision_policy|bits"):
        ModelCatalog.model_validate(payload)


def test_catalog_rejects_aligner_policy_mismatch() -> None:
    payload = _catalog_payload()
    presets = payload["presets"]
    assert isinstance(presets, list)
    light = presets[2]
    assert isinstance(light, dict)
    light["aligner"] = "aligner-q8"

    with pytest.raises(ValidationError, match=r"aligner|precision_policy"):
        ModelCatalog.model_validate(payload)


def test_catalog_rejects_aligner_dtype_mismatch() -> None:
    """档位说 bf16、制品写 fp16：同一件事两种说法，必须报错。"""
    payload = _catalog_payload()
    artifacts = payload["artifacts"]
    assert isinstance(artifacts, list)
    aligner = next(
        item for item in artifacts if isinstance(item, dict) and item["key"] == "aligner-bf16"
    )
    quantization = aligner["quantization"]
    assert isinstance(quantization, dict)
    quantization["dtype"] = "fp16"

    with pytest.raises(ValidationError, match=r"dtype|precision_policy"):
        ModelCatalog.model_validate(payload)


def test_catalog_rejects_aligner_reference_with_wrong_identity() -> None:
    payload = _catalog_payload()
    artifacts = payload["artifacts"]
    assert isinstance(artifacts, list)
    artifacts.append(_artifact(key="fake-aligner", family="qwen3_asr", variant="asr", bits=8))
    assert isinstance(payload["presets"], list)
    policy = payload["precision_policy"]
    assert isinstance(policy, dict)
    assert isinstance(policy["light"], dict)
    policy["light"]["aligner"] = 8
    payload["presets"][2] = {
        "id": "light",
        "asr": "asr-q8",
        "tts": "tts-custom-q8",
        "aligner": "fake-aligner",
        "diarization": True,
    }

    with pytest.raises(ValidationError, match=r"aligner|variant|family"):
        ModelCatalog.model_validate(payload)


def test_light_tier_uses_q8_quantization_under_schema_v2() -> None:
    catalog = ModelCatalog.model_validate(_catalog_payload())
    by_id = {item.id: item for item in catalog.presets}

    assert by_id["light"].asr == "asr-q8"
    assert by_id["light"].tts == "tts-custom-q8"


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
