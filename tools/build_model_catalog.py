#!/usr/bin/env python3
"""根据已核验元数据构建可重复生成的离线模型清单。

本工具只处理元数据, 不解析模型仓库、不下载快照、不导入 vendor runtime,
也不执行模型来源中的代码。调用方可先检查本地快照, 再将文件名、大小和
SHA-256 值组成 JSON 字典交给本工具, 所得字典可供后续清单消费者使用。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Mapping
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Final

_IMMUTABLE_REVISION: Final[re.Pattern[str]] = re.compile(r"[0-9a-fA-F]{40}")
_SHA256: Final[re.Pattern[str]] = re.compile(r"[0-9a-fA-F]{64}")
_SCHEMA_VERSION: Final[int] = 2
_ARTIFACT_FIELDS: Final[frozenset[str]] = frozenset(
    {
        "key",
        "model_id",
        "revision",
        "family",
        "variant",
        "quantization",
        "files",
        "sources",
    }
)
_SOURCE_FIELDS: Final[frozenset[str]] = frozenset({"provider", "repository", "revision"})
_SOURCE_ALLOWED_FIELDS: Final[frozenset[str]] = _SOURCE_FIELDS | frozenset({"files"})
_FILE_FIELDS: Final[frozenset[str]] = frozenset({"path", "size", "sha256"})
# 与 `speechrail.config.model_catalog.WeightDtype` 同义: 本工具不导入包, 以便
# 在没有 runtime 的快照上单独运行, 因此这一份取值在这里重复声明一次。
_WEIGHT_DTYPES: Final[frozenset[str]] = frozenset({"bf16", "fp16", "fp32"})
_QUANTIZATION_FIELDS: Final[frozenset[str]] = frozenset({"bits", "group_size", "format"})
# `dtype` 只在未量化的制品上出现: 量化制品的精度由 `bits` 表达, 两者互斥。
_QUANTIZATION_ALLOWED_FIELDS: Final[frozenset[str]] = _QUANTIZATION_FIELDS | frozenset(
    {"dtype"}
)
_SPEC_TIERS: Final[frozenset[str]] = frozenset({"fast", "quality", "reference"})
_SPEC_FIELDS: Final[frozenset[str]] = frozenset({"tier", "role", "artifact_key"})
_SPEC_ROLE_VARIANTS: Final[dict[str, tuple[str, str]]] = {
    "asr": ("qwen3_asr", "asr"),
    "tts_base": ("qwen3_tts", "base"),
    "tts_custom_voice": ("qwen3_tts", "custom_voice"),
    "voice_design": ("qwen3_tts", "voice_design"),
    "alignment": ("qwen3_forced_aligner", "aligner"),
}
# 与 `speechrail.config.model_catalog.REQUIRED_SPEC_BINDINGS` 同义, 本工具不导入包.
_REQUIRED_SPEC_BINDINGS: Final[dict[tuple[str, str], str]] = {
    ("fast", "asr"): "asr-0.6b-q8",
    ("quality", "asr"): "asr-1.7b-q8",
    ("reference", "asr"): "asr-1.7b-bf16",
    ("fast", "tts_base"): "tts-0.6b-base-q8",
    ("quality", "tts_base"): "tts-1.7b-base-q8",
    ("reference", "tts_base"): "tts-1.7b-base-bf16",
    ("fast", "tts_custom_voice"): "tts-0.6b-custom-q8",
    ("quality", "tts_custom_voice"): "tts-1.7b-custom-q8",
    ("reference", "tts_custom_voice"): "tts-1.7b-custom-bf16",
    ("fast", "alignment"): "aligner-q8",
    ("quality", "alignment"): "aligner-bf16",
    ("reference", "alignment"): "aligner-bf16",
}


def _mapping(value: object, *, context: str) -> Mapping[str, object]:
    if not isinstance(value, Mapping):
        raise ValueError(f"{context} must be an object")
    return value


def _list(value: object, *, context: str) -> list[object]:
    if not isinstance(value, list):
        raise ValueError(f"{context} must be a list")
    return value


def _required_string(data: Mapping[str, object], key: str, *, context: str) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{context}.{key} must be a non-empty string")
    return value


def _check_fields(
    data: Mapping[str, object], expected: frozenset[str], *, context: str
) -> None:
    missing = sorted(expected.difference(data))
    if missing:
        raise ValueError(f"{context} is missing required field(s): {', '.join(missing)}")
    unexpected = sorted(set(data).difference(expected))
    if unexpected:
        raise ValueError(f"{context} has unsupported field(s): {', '.join(unexpected)}")


def require_immutable_revision(revision: object) -> str:
    """返回规范化 revision 哈希, 并拒绝可变引用。

    仓库 tag 以及 ``main``、``latest`` 等 alias 可能随时间变化, 因此清单
    只接受完整的 40 位 Git object ID。结果统一为小写, 保证等价元数据产生
    相同的 JSON。
    """

    if not isinstance(revision, str) or not revision:
        raise ValueError("revision must be an immutable 40-character commit hash")
    if revision != revision.strip() or _IMMUTABLE_REVISION.fullmatch(revision) is None:
        raise ValueError("revision must be immutable; use a full 40-character commit hash")
    return revision.lower()


def _normalise_key(value: object, *, context: str) -> str:
    key = _required_string({"value": value}, "value", context=context)
    if (
        key in {".", ".."}
        or "/" in key
        or "\\" in key
        or "\x00" in key
        or PureWindowsPath(key).drive
    ):
        raise ValueError(f"{context} must be a safe artifact key")
    return key


def _normalise_file_path(value: object, *, context: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ValueError(f"{context}.path must be a safe relative path")

    # 先把两种分隔符都视为路径分隔符, 避免在 macOS/Linux 上构建清单时被
    # Windows 风格的 ``..\\secret`` 路径绕过检查。
    slash_path = value.replace("\\", "/")
    windows_path = PureWindowsPath(value)
    posix_path = PurePosixPath(slash_path)
    if (
        posix_path.is_absolute()
        or windows_path.is_absolute()
        or windows_path.drive
        or any(part == ".." for part in posix_path.parts)
    ):
        raise ValueError(f"{context}.path contains an absolute or traversal path")

    parts = tuple(part for part in posix_path.parts if part not in {"", "."})
    if not parts:
        raise ValueError(f"{context}.path must name a file")
    return "/".join(parts)


def _normalise_sha256(value: object, *, context: str) -> str:
    if not isinstance(value, str) or _SHA256.fullmatch(value) is None:
        raise ValueError(f"{context}.sha256 must be a 64-character hexadecimal hash")
    return value.lower()


def _normalise_file(value: object, *, index: int, artifact_key: str) -> dict[str, object]:
    context = f"artifact {artifact_key!r} file {index}"
    data = _mapping(value, context=context)
    _check_fields(data, _FILE_FIELDS, context=context)
    path = _normalise_file_path(data["path"], context=context)
    size = data["size"]
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        raise ValueError(f"{context}.size must be a non-negative integer")
    return {
        "path": path,
        "size": size,
        "sha256": _normalise_sha256(data["sha256"], context=context),
    }


def _normalise_quantization(value: object, *, artifact_key: str) -> dict[str, object]:
    context = f"artifact {artifact_key!r} quantization"
    data = _mapping(value, context=context)
    missing = sorted(_QUANTIZATION_FIELDS.difference(data))
    if missing:
        raise ValueError(f"{context} is missing required field(s): {', '.join(missing)}")
    unexpected = sorted(set(data).difference(_QUANTIZATION_ALLOWED_FIELDS))
    if unexpected:
        raise ValueError(f"{context} has unsupported field(s): {', '.join(unexpected)}")
    bits = data["bits"]
    dtype = data.get("dtype")
    group_size = data["group_size"]
    if bits is not None and (not isinstance(bits, int) or isinstance(bits, bool) or bits <= 0):
        raise ValueError(f"{context}.bits must be a positive integer or null")
    if group_size is not None and (
        not isinstance(group_size, int) or isinstance(group_size, bool) or group_size <= 0
    ):
        raise ValueError(f"{context}.group_size must be a positive integer or null")
    format_name = _required_string(data, "format", context=context)
    if dtype is not None:
        if not isinstance(dtype, str) or dtype not in _WEIGHT_DTYPES:
            allowed = ", ".join(sorted(_WEIGHT_DTYPES))
            raise ValueError(f"{context}.dtype must be null or one of {allowed}")
        if bits is not None:
            raise ValueError(f"{context} must declare either bits or dtype, not both")
        if group_size is not None or format_name != "none":
            raise ValueError(f"{context} dtype requires group_size=null and format='none'")
    elif bits is None:
        # 未量化的制品必须写明权重本身的数值格式; 否则同一列里会有一行说不出精度。
        raise ValueError(f"{context}.dtype is required when bits is null")
    return {"bits": bits, "group_size": group_size, "format": format_name, "dtype": dtype}


def _normalise_source(
    value: object,
    *,
    index: int,
    artifact_key: str,
    expected_files: list[dict[str, object]],
) -> dict[str, str]:
    context = f"artifact {artifact_key!r} source {index}"
    data = _mapping(value, context=context)
    missing = sorted(_SOURCE_FIELDS.difference(data))
    if missing:
        raise ValueError(f"{context} is missing required field(s): {', '.join(missing)}")
    unexpected = sorted(set(data).difference(_SOURCE_ALLOWED_FIELDS))
    if unexpected:
        raise ValueError(f"{context} has unsupported field(s): {', '.join(unexpected)}")
    provider = _required_string(data, "provider", context=context)
    repository = _required_string(data, "repository", context=context)
    revision = require_immutable_revision(data["revision"])

    # 部分离线元数据还会保留每个镜像的文件列表。该列表只作为校验证据,
    # 对外 SourceLocation 结构仍保持精简, 规范哈希继续保存在 artifact 上。
    if "files" in data:
        mirror_files: list[dict[str, object]] = []
        seen_paths: set[str] = set()
        for file_index, raw_file in enumerate(
            _list(data["files"], context=f"{context}.files")
        ):
            mirror_file = _normalise_file(raw_file, index=file_index, artifact_key=artifact_key)
            path = str(mirror_file["path"])
            if path in seen_paths:
                raise ValueError(f"{context} has duplicate mirror file path: {path}")
            seen_paths.add(path)
            mirror_files.append(mirror_file)
        expected_hashes = {
            str(file_data["path"]): str(file_data["sha256"]) for file_data in expected_files
        }
        mirror_hashes = {
            str(file_data["path"]): str(file_data["sha256"]) for file_data in mirror_files
        }
        if mirror_hashes != expected_hashes:
            raise ValueError(f"{context} mirror files are not hash-equivalent")

    return {"provider": provider, "repository": repository, "revision": revision}


def _is_tts_artifact(data: Mapping[str, object]) -> bool:
    identity = " ".join(
        str(data.get(field, "")).lower()
        for field in ("key", "model_id", "family", "variant")
    )
    return any(marker in identity for marker in ("tts", "customvoice", "voicedesign"))


def _has_codec_files(files: list[dict[str, object]]) -> bool:
    for file_data in files:
        path = str(file_data["path"]).lower()
        parts = set(path.split("/"))
        if "speech_tokenizer" in parts or "codec" in parts or "tokenizer" in parts:
            return True
    return False


def _normalise_artifact(value: object, *, index: int) -> dict[str, object]:
    data = _mapping(value, context=f"artifact {index}")
    key = _normalise_key(data.get("key"), context=f"artifact {index}.key")
    context = f"artifact {key!r}"
    _check_fields(data, _ARTIFACT_FIELDS, context=context)
    # key 已通过专门的安全路径检查; 完整字段结构校验通过后再读取其余字段。
    model_id = _required_string(data, "model_id", context=context)
    revision = require_immutable_revision(data["revision"])
    family = _required_string(data, "family", context=context)
    variant = _required_string(data, "variant", context=context)
    quantization = _normalise_quantization(data["quantization"], artifact_key=key)

    files: list[dict[str, object]] = []
    seen_paths: set[str] = set()
    for file_index, raw_file in enumerate(_list(data["files"], context=f"{context}.files")):
        normalised = _normalise_file(raw_file, index=file_index, artifact_key=key)
        path = str(normalised["path"])
        if path in seen_paths:
            raise ValueError(f"{context} has duplicate file path: {path}")
        seen_paths.add(path)
        files.append(normalised)
    if not files:
        raise ValueError(f"{context}.files must contain at least one file")
    if _is_tts_artifact(data) and not _has_codec_files(files):
        raise ValueError(f"{context} is missing speech_tokenizer codec files")

    sources: list[dict[str, str]] = []
    seen_sources: set[tuple[str, str, str]] = set()
    for source_index, raw_source in enumerate(
        _list(data["sources"], context=f"{context}.sources")
    ):
        normalised_source = _normalise_source(
            raw_source,
            index=source_index,
            artifact_key=key,
            expected_files=files,
        )
        source_identity = (
            normalised_source["provider"],
            normalised_source["repository"],
            normalised_source["revision"],
        )
        if source_identity in seen_sources:
            raise ValueError(f"{context} has duplicate source mirror")
        seen_sources.add(source_identity)
        sources.append(normalised_source)
    if not sources:
        raise ValueError(f"{context}.sources must contain at least one immutable source")

    return {
        "key": key,
        "model_id": model_id,
        "revision": revision,
        "family": family,
        "variant": variant,
        "quantization": quantization,
        "files": sorted(files, key=lambda item: str(item["path"])),
        "sources": sorted(
            sources,
            key=lambda item: (item["provider"], item["repository"], item["revision"]),
        ),
    }


def _normalise_spec(value: object, *, index: int) -> dict[str, object]:
    context = f"spec {index}"
    data = _mapping(value, context=context)
    _check_fields(data, _SPEC_FIELDS, context=context)
    tier = _required_string(data, "tier", context=context)
    if tier not in _SPEC_TIERS:
        raise ValueError(f"{context}.tier must be one of fast, quality, reference")
    role = _required_string(data, "role", context=context)
    if role not in _SPEC_ROLE_VARIANTS:
        raise ValueError(f"{context}.role is not a supported model role")
    artifact_key = _required_string(data, "artifact_key", context=context)
    return {"tier": tier, "role": role, "artifact_key": artifact_key}


def build_catalog(entries: Mapping[str, object]) -> dict[str, object]:
    """校验离线字典并返回规范化的模型清单。

    函数只接受已冻结的清单结构。runtime dependency lock 有独立文件,
    此处主动拒绝嵌入, 避免模型清单悄然绑定到未核验的 runtime。
    """

    if not isinstance(entries, Mapping):
        raise ValueError("catalog input must be an object")
    expected_top_level = frozenset({"schema_version", "artifacts", "specs"})
    _check_fields(entries, expected_top_level, context="catalog")
    schema_version = entries["schema_version"]
    if not isinstance(schema_version, int) or isinstance(schema_version, bool):
        raise ValueError(f"catalog.schema_version must be integer {_SCHEMA_VERSION}")
    if schema_version != _SCHEMA_VERSION:
        raise ValueError(f"catalog.schema_version must be {_SCHEMA_VERSION}")

    artifacts: list[dict[str, object]] = []
    seen_keys: set[str] = set()
    for artifact_index, raw_artifact in enumerate(
        _list(entries["artifacts"], context="catalog.artifacts")
    ):
        artifact = _normalise_artifact(raw_artifact, index=artifact_index)
        key = str(artifact["key"])
        if key in seen_keys:
            raise ValueError(f"catalog has duplicate artifact key: {key}")
        seen_keys.add(key)
        artifacts.append(artifact)

    specs: list[dict[str, object]] = []
    seen_bindings: set[tuple[str, str]] = set()
    for spec_index, raw_spec in enumerate(_list(entries["specs"], context="catalog.specs")):
        spec = _normalise_spec(raw_spec, index=spec_index)
        binding = (str(spec["tier"]), str(spec["role"]))
        if binding in seen_bindings:
            raise ValueError(f"catalog has duplicate spec binding: {binding[0]}/{binding[1]}")
        seen_bindings.add(binding)
        specs.append(spec)
    if seen_bindings != set(_REQUIRED_SPEC_BINDINGS):
        missing = sorted(set(_REQUIRED_SPEC_BINDINGS).difference(seen_bindings))
        extra = sorted(seen_bindings.difference(_REQUIRED_SPEC_BINDINGS))
        raise ValueError(
            "catalog.specs must match the required tier x role matrix"
            f" (missing={missing}, extra={extra})"
        )
    artifacts_by_key = {str(artifact["key"]): artifact for artifact in artifacts}
    for spec in specs:
        binding = (str(spec["tier"]), str(spec["role"]))
        artifact_key = str(spec["artifact_key"])
        if _REQUIRED_SPEC_BINDINGS[binding] != artifact_key:
            raise ValueError(
                f"catalog spec {binding[0]}/{binding[1]} must bind "
                f"{_REQUIRED_SPEC_BINDINGS[binding]}"
            )
        artifact = artifacts_by_key.get(artifact_key)
        if artifact is None:
            raise ValueError(
                f"catalog spec {binding[0]}/{binding[1]} references unknown artifact"
            )
        if (artifact["family"], artifact["variant"]) != _SPEC_ROLE_VARIANTS[binding[1]]:
            raise ValueError(
                f"catalog spec {binding[0]}/{binding[1]} references an incompatible artifact"
            )

    return {
        "schema_version": _SCHEMA_VERSION,
        "artifacts": sorted(artifacts, key=lambda item: str(item["key"])),
        "specs": sorted(specs, key=lambda item: (str(item["tier"]), str(item["role"]))),
    }


def _read_json(path: Path) -> Mapping[str, object]:
    try:
        raw = sys.stdin.read() if str(path) == "-" else path.read_text(encoding="utf-8")
        value = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"could not read catalog JSON: {exc}") from exc
    if not isinstance(value, Mapping):
        raise ValueError("catalog JSON must contain an object")
    return value


def _write_output(path: Path, payload: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload, encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"could not write catalog output: {exc}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="离线 catalog 元数据 JSON; 使用 - 从 stdin 读取")
    parser.add_argument(
        "--output",
        type=Path,
        help="显式指定输出 JSON 路径; 未指定时输出到 stdout",
    )
    args = parser.parse_args(argv)
    try:
        catalog = build_catalog(_read_json(args.input))
        payload = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        if args.output is None:
            sys.stdout.write(payload)
        else:
            _write_output(args.output, payload)
    except ValueError as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
