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
_normalise_quantization = _catalog_builder._normalise_quantization
_REQUIRED_SPEC_BINDINGS = _catalog_builder._REQUIRED_SPEC_BINDINGS


REVISION = "0123456789abcdef0123456789abcdef01234567"


def _file(path: str, *, digest: str | None = None, size: int = 4) -> dict[str, Any]:
    return {
        "path": path,
        "size": size,
        "sha256": digest or ("a" * 64),
    }


_BF16_QUANTIZATION: dict[str, Any] = {
    "bits": None,
    "dtype": "bf16",
    "group_size": None,
    "format": "none",
}
_Q8_QUANTIZATION: dict[str, Any] = {
    "bits": 8,
    "dtype": None,
    "group_size": 64,
    "format": "mlx",
}


def _files_for(family: str) -> list[dict[str, Any]]:
    if family == "qwen3_tts":
        return [
            _file("config.json"),
            _file("model.safetensors"),
            _file("tokenizer.json"),
            _file("speech_tokenizer/config.json"),
            _file("speech_tokenizer/model.safetensors"),
        ]
    return [_file("config.json"), _file("model.safetensors"), _file("tokenizer.json")]


def _artifact(
    *,
    key: str = "asr-0.6b-q8",
    model_id: str | None = None,
    family: str = "qwen3_asr",
    variant: str = "asr",
    files: list[dict[str, Any]] | None = None,
    quantization: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "key": key,
        "model_id": model_id or f"fixture/{key}",
        "revision": REVISION,
        "family": family,
        "variant": variant,
        "quantization": dict(quantization or _Q8_QUANTIZATION),
        "files": files if files is not None else _files_for(family),
        "sources": [
            {
                "provider": "offline",
                "repository": f"fixture/{key}",
                "revision": REVISION,
            }
        ],
    }


def _canonical_artifacts() -> list[dict[str, Any]]:
    return [
        _artifact(key="asr-0.6b-q8"),
        _artifact(key="asr-1.7b-q8"),
        _artifact(key="asr-1.7b-bf16", quantization=_BF16_QUANTIZATION),
        _artifact(key="tts-0.6b-custom-q8", family="qwen3_tts", variant="custom_voice"),
        _artifact(key="tts-1.7b-custom-q8", family="qwen3_tts", variant="custom_voice"),
        _artifact(
            key="tts-1.7b-custom-bf16",
            family="qwen3_tts",
            variant="custom_voice",
            quantization=_BF16_QUANTIZATION,
        ),
        _artifact(key="tts-0.6b-base-q8", family="qwen3_tts", variant="base"),
        _artifact(key="tts-1.7b-base-q8", family="qwen3_tts", variant="base"),
        _artifact(
            key="tts-1.7b-base-bf16",
            family="qwen3_tts",
            variant="base",
            quantization=_BF16_QUANTIZATION,
        ),
        _artifact(
            key="tts-1.7b-design-bf16",
            family="qwen3_tts",
            variant="voice_design",
            quantization=_BF16_QUANTIZATION,
        ),
        _artifact(key="aligner-q8", family="qwen3_forced_aligner", variant="aligner"),
        _artifact(
            key="aligner-bf16",
            family="qwen3_forced_aligner",
            variant="aligner",
            quantization=_BF16_QUANTIZATION,
        ),
    ]


def _canonical_specs() -> list[dict[str, Any]]:
    return [
        {"tier": tier, "role": role, "artifact_key": artifact_key}
        for (tier, role), artifact_key in _REQUIRED_SPEC_BINDINGS.items()
    ]



def _catalog(
    *artifacts: dict[str, Any],
) -> dict[str, Any]:
    """Return a legal 12-artifact catalog, replacing canonical artifacts by key."""

    by_key = {artifact["key"]: dict(artifact) for artifact in _canonical_artifacts()}
    for artifact in artifacts:
        by_key[artifact["key"]] = artifact
    return {
        "schema_version": 2,
        "artifacts": list(by_key.values()),
        "specs": _canonical_specs(),
    }


def _legal_metadata() -> dict[str, Any]:
    return _catalog()



def _artifact_by_key(catalog: dict[str, Any], key: str) -> dict[str, Any]:
    artifacts = catalog["artifacts"]
    assert isinstance(artifacts, list)
    entry = next(item for item in artifacts if item["key"] == key)
    assert isinstance(entry, dict)
    return entry


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
    assert len(catalog["artifacts"]) == 12
    assert len(catalog["specs"]) == 12
    assert [item["path"] for item in _artifact_by_key(catalog, "asr-0.6b-q8")["files"]] == [
        "config.json",
        "model.safetensors",
        "tokenizer.json",
    ]
    assert _artifact_by_key(catalog, "asr-0.6b-q8")["revision"] == REVISION


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

    assert (
        _artifact_by_key(catalog, "qwen3-tts-0.6b-customvoice-8bit")["model_id"]
        == "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice"
    )


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
    entries = _catalog()
    artifacts = entries["artifacts"]
    assert isinstance(artifacts, list)
    artifacts.extend([first, second])

    with pytest.raises(ValueError, match="duplicate artifact key"):
        build_catalog(entries)


def test_cli_writes_only_to_an_explicit_output_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    output = tmp_path / "catalog.json"
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(_catalog(_artifact()))))

    assert _catalog_builder.main(["-", "--output", str(output)]) == 0
    assert json.loads(output.read_text(encoding="utf-8"))["schema_version"] == 2


def test_legal_metadata_produces_schema_v2_catalog() -> None:
    catalog = build_catalog(_legal_metadata())

    assert catalog["schema_version"] == 2
    assert set(catalog) == {"schema_version", "artifacts", "specs"}
    bindings = {(item["tier"], item["role"]): item["artifact_key"] for item in catalog["specs"]}
    assert bindings == dict(_REQUIRED_SPEC_BINDINGS)
    for key in (
        "asr-1.7b-bf16",
        "tts-1.7b-custom-bf16",
        "tts-1.7b-design-bf16",
        "tts-1.7b-base-bf16",
        "aligner-bf16",
    ):
        assert _artifact_by_key(catalog, key)["quantization"] == {
            "bits": None,
            "dtype": "bf16",
            "format": "none",
            "group_size": None,
        }


@pytest.mark.parametrize(
    "quantization",
    [
        {"bits": 8, "dtype": "bf16", "group_size": 64, "format": "mlx"},
        {"bits": None, "dtype": None, "group_size": None, "format": "none"},
    ],
    ids=["bits-and-dtype", "unquantized-without-dtype"],
)
def test_quantization_rejects_mixed_or_missing_precision(quantization: dict[str, Any]) -> None:
    with pytest.raises(ValueError, match=r"bits|dtype|precision"):
        _normalise_quantization(quantization, artifact_key="fixture")
