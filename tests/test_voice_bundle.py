"""Voice bundle format, inspection and import, with temporary stores only.

Every test uses a real ``FileVoiceRegistry`` on ``tmp_path`` and forged
archives; nothing here touches a model, the network or the user's catalog.
"""

from __future__ import annotations

import hashlib
import io
import json
import wave
import zipfile
from pathlib import Path

import pytest

from speechrail.application.voice_bundle import (
    EXCLUDED_FROM_BUNDLE,
    export_bundle,
    import_bundle,
    inspect_bundle,
    preview_export,
)
from speechrail.domain.voice_bundle import (
    BUNDLE_FORMAT,
    BUNDLE_FORMAT_VERSION,
    MANIFEST_NAME,
    MAX_ARCHIVE_BYTES,
    REFERENCE_AUDIO_PATH,
    VoiceBundleError,
)
from speechrail.infrastructure.voice_registry import FileVoiceRegistry

INSTRUCTION = "温暖的中年男声，语速偏慢，适合叙述。"
REF_TEXT = "这是一段用来克隆音色的参考文本。"


def _wav(seconds: float = 3.0, *, sample_rate: int = 24_000, channels: int = 1) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(b"\x01\x00" * int(seconds * sample_rate) * channels)
    return buffer.getvalue()


def _registry(tmp_path: Path) -> FileVoiceRegistry:
    return FileVoiceRegistry.open(tmp_path / "custom_voices.json", tmp_path / "audio")


def _custom(registry: FileVoiceRegistry) -> list:
    """Custom voices only: ``list_profiles`` also returns the built-in presets."""

    return [profile for profile in registry.list_profiles() if not profile.is_system]


_VOICE_FIELDS = {
    "name",
    "mode",
    "instruction",
    "ref_text",
    "seed",
    "temperature",
    "duration_seconds",
}


def _manifest(**overrides) -> dict:
    manifest = {
        "format": BUNDLE_FORMAT,
        "format_version": BUNDLE_FORMAT_VERSION,
        "source": {
            "voice_id": "custom_1",
            "revision": None,
            "exported_at": "2026-10-23T00:00:00Z",
            "service_version": "4.3.0",
        },
        "voice": {
            "name": "讲述者",
            "mode": "instruction",
            "instruction": INSTRUCTION,
            "seed": 7,
            "temperature": 0.1,
        },
        "assets": [],
    }
    for key, value in overrides.items():
        if key in _VOICE_FIELDS:
            manifest["voice"][key] = value
        else:
            manifest[key] = value
    return manifest


def _zip(entries: dict[str, bytes], *, symlinks: set[str] = frozenset()) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, payload in entries.items():
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.external_attr = (0o120777 << 16) if name in symlinks else (0o600 << 16)
            archive.writestr(info, payload)
    return buffer.getvalue()


def _forged(manifest: dict, assets: dict[str, bytes]) -> bytes:
    entries = {MANIFEST_NAME: json.dumps(manifest).encode()}
    entries.update(assets)
    return _zip(entries)


def _clone_bundle(audio: bytes, **overrides) -> bytes:
    """A well-declared clone bundle whose audio may still be unacceptable."""

    manifest = _manifest(mode="clone", ref_text=REF_TEXT, **overrides)
    manifest["assets"] = [
        {
            "path": REFERENCE_AUDIO_PATH,
            "media_type": "audio/wav",
            "sha256": hashlib.sha256(audio).hexdigest(),
            "bytes": len(audio),
        }
    ]
    return _forged(manifest, {REFERENCE_AUDIO_PATH: audio})


# MARK: - 往返


def test_instruction_voice_round_trip_preserves_identity(tmp_path: Path) -> None:
    # Export and import happen on two machines, so use two independent stores.
    source_store = _registry(tmp_path / "source")
    target_store = _registry(tmp_path / "target")
    source = source_store.create_custom_profile("讲述者", INSTRUCTION, seed=777)

    bundle = export_bundle(source_store, source.id, service_version="4.3.0")
    inspection = inspect_bundle(
        bundle, available_capabilities={"voice_design"}, existing_names=set()
    )
    assert inspection.name == "讲述者"
    assert inspection.mode == "instruction"
    assert inspection.includes_reference_audio is False
    assert inspection.includes_reference_text is False
    assert inspection.required_capabilities == ("voice_design",)
    assert inspection.importable is True

    imported = import_bundle(target_store, bundle, available_capabilities={"voice_design"})

    assert imported.profile.id != source.id, "导入必须新建本地身份"
    assert imported.profile.name == "讲述者"
    assert imported.profile.instruction == INSTRUCTION
    assert imported.profile.seed == 777
    assert imported.profile.mode == "instruction"
    assert imported.renamed_from is None
    assert [p.id for p in _custom(target_store)] == [imported.profile.id]


def test_clone_voice_round_trip_preserves_reference_assets(tmp_path: Path) -> None:
    source_store = _registry(tmp_path / "source")
    target_store = _registry(tmp_path / "target")
    audio = _wav(3.0)
    source = source_store.create_cloned_profile(
        name="旁白男声", ref_text=REF_TEXT, audio_bytes=audio, duration_seconds=3.0
    )

    bundle = export_bundle(source_store, source.id)
    inspection = inspect_bundle(bundle, available_capabilities={"tts_base"}, existing_names=set())
    assert inspection.mode == "clone"
    assert inspection.includes_reference_audio is True
    assert inspection.includes_reference_text is True
    assert inspection.reference_audio_bytes == len(audio)
    assert inspection.required_capabilities == ("tts_base",)
    assert inspection.duration_seconds == pytest.approx(3.0, abs=0.01)

    imported = import_bundle(target_store, bundle, available_capabilities={"tts_base"})

    assert imported.profile.mode == "clone"
    assert imported.profile.ref_text == REF_TEXT
    assert imported.profile.revision == source.revision, "同样的参考应得到同样的声学身份"
    assert Path(imported.profile.audio_path or "").read_bytes() == audio
    # Validation never travels with a bundle: this voice is unverified here.
    assert imported.profile.quality is None


def test_preview_states_assets_and_exclusions(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    source = registry.create_cloned_profile(
        name="旁白男声", ref_text=REF_TEXT, audio_bytes=_wav(2.5), duration_seconds=2.5
    )

    preview = preview_export(registry, source.id)

    assert preview.includes_reference_audio is True
    assert preview.includes_reference_text is True
    assert preview.reference_audio_bytes > 0
    assert preview.reference_audio_sha256 == hashlib.sha256(_wav(2.5)).hexdigest()
    assert list(preview.entries) == [MANIFEST_NAME, REFERENCE_AUDIO_PATH]
    assert list(preview.excluded) == list(EXCLUDED_FROM_BUNDLE)
    assert "模型权重与运行配置" in preview.excluded


def test_system_voice_cannot_be_exported(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    with pytest.raises(VoiceBundleError) as excinfo:
        export_bundle(registry, "serena")
    assert excinfo.value.code == "bundle_system_voice_not_exportable"


# MARK: - 只读预检


def test_inspection_leaves_the_catalog_byte_identical(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    source = registry.create_custom_profile("讲述者", INSTRUCTION, seed=7)
    bundle = export_bundle(registry, source.id)

    store = registry.storage_path
    before_bytes = store.read_bytes()
    before_audio = sorted(p.name for p in registry.voices_dir.iterdir())

    inspect_bundle(bundle, available_capabilities={"voice_design"}, existing_names={"讲述者"})

    assert store.read_bytes() == before_bytes
    assert sorted(p.name for p in registry.voices_dir.iterdir()) == before_audio
    assert [p.id for p in _custom(registry)] == [source.id]


# MARK: - 损坏与攻击面


def test_truncated_archive_is_rejected(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    source = registry.create_custom_profile("讲述者", INSTRUCTION, seed=7)
    bundle = export_bundle(registry, source.id)

    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(
            bundle[: len(bundle) // 2], available_capabilities=set(), existing_names=set()
        )
    assert excinfo.value.code in {"bundle_invalid_zip", "bundle_missing_manifest"}


def test_digest_mismatch_is_rejected(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    source = registry.create_cloned_profile(
        name="旁白男声", ref_text=REF_TEXT, audio_bytes=_wav(3.0), duration_seconds=3.0
    )
    bundle = export_bundle(registry, source.id)

    with zipfile.ZipFile(io.BytesIO(bundle)) as archive:
        manifest = json.loads(archive.read(MANIFEST_NAME))
    tampered = _forged(manifest, {REFERENCE_AUDIO_PATH: _wav(3.0)[:-2] + b"\x00\x00"})

    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(tampered, available_capabilities={"tts_base"}, existing_names=set())
    assert excinfo.value.code in {"bundle_digest_mismatch", "bundle_invalid_asset"}


def test_path_traversal_entry_is_rejected() -> None:
    manifest = _manifest()
    archive = _zip({MANIFEST_NAME: json.dumps(manifest).encode(), "../escape.txt": b"x"})
    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(archive, available_capabilities=set(), existing_names=set())
    assert excinfo.value.code == "bundle_unsafe_entry"


def test_symlink_entry_is_rejected() -> None:
    manifest = _manifest()
    archive = _zip(
        {MANIFEST_NAME: json.dumps(manifest).encode(), "link.json": b"/etc/passwd"},
        symlinks={"link.json"},
    )
    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(archive, available_capabilities=set(), existing_names=set())
    assert excinfo.value.code == "bundle_unsafe_entry"


def test_undeclared_entry_is_rejected() -> None:
    manifest = _manifest()
    archive = _zip({MANIFEST_NAME: json.dumps(manifest).encode(), "extra.bin": b"x"})
    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(archive, available_capabilities=set(), existing_names=set())
    assert excinfo.value.code == "bundle_unexpected_entry"


def test_missing_declared_asset_is_rejected() -> None:
    manifest = _manifest(mode="clone", ref_text=REF_TEXT)
    manifest["assets"] = [
        {
            "path": REFERENCE_AUDIO_PATH,
            "media_type": "audio/wav",
            "sha256": hashlib.sha256(b"absent").hexdigest(),
            "bytes": len(b"absent"),
        }
    ]
    archive = _zip({MANIFEST_NAME: json.dumps(manifest).encode()})
    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(archive, available_capabilities={"tts_base"}, existing_names=set())
    assert excinfo.value.code == "bundle_missing_asset"


def test_future_schema_version_has_its_own_result() -> None:
    archive = _zip({MANIFEST_NAME: json.dumps(_manifest(format_version=99)).encode()})
    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(archive, available_capabilities=set(), existing_names=set())
    assert excinfo.value.code == "bundle_unsupported_version"


def test_foreign_format_is_rejected() -> None:
    archive = _zip({MANIFEST_NAME: json.dumps(_manifest(format="other.voice")).encode()})
    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(archive, available_capabilities=set(), existing_names=set())
    assert excinfo.value.code == "bundle_unsupported_format"


def test_oversized_archive_is_rejected_before_parsing() -> None:
    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(
            b"x" * (MAX_ARCHIVE_BYTES + 1), available_capabilities=set(), existing_names=set()
        )
    assert excinfo.value.code == "bundle_too_large"


def test_reference_audio_is_revalidated_not_trusted() -> None:
    """A manifest cannot claim a duration the container does not support."""

    archive = _clone_bundle(_wav(0.5), duration_seconds=30.0)  # 低于 2s 下限

    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(archive, available_capabilities={"tts_base"}, existing_names=set())
    assert excinfo.value.code == "bundle_invalid_asset"


def test_a_bundle_cannot_claim_a_local_verdict() -> None:
    """`extra="forbid"` is what keeps another machine's verdict out of the catalog."""

    for claim in ({"quality": {"score": 0.99}}, {"validation": "production_ready"}):
        archive = _zip({MANIFEST_NAME: json.dumps(_manifest(**claim)).encode()})
        with pytest.raises(VoiceBundleError) as excinfo:
            inspect_bundle(archive, available_capabilities={"voice_design"}, existing_names=set())
        assert excinfo.value.code == "bundle_invalid_manifest", claim

    nested = _manifest()
    nested["voice"]["validation"] = "production_ready"
    with pytest.raises(VoiceBundleError) as excinfo:
        inspect_bundle(
            _zip({MANIFEST_NAME: json.dumps(nested).encode()}),
            available_capabilities={"voice_design"},
            existing_names=set(),
        )
    assert excinfo.value.code == "bundle_invalid_manifest"


# MARK: - 命名与重复


def test_name_conflict_renames_and_keeps_the_original(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    source = registry.create_custom_profile("讲述者", INSTRUCTION, seed=777)
    bundle = export_bundle(registry, source.id)

    imported = import_bundle(registry, bundle, available_capabilities={"voice_design"})

    assert imported.renamed_from == "讲述者"
    assert imported.profile.name == "讲述者（导入）"
    assert registry.get_profile(source.id).name == "讲述者", "旧音色不得被改名"
    assert registry.get_profile(source.id).revision == source.revision


def test_duplicate_import_creates_two_voices(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    source = registry.create_custom_profile("讲述者", INSTRUCTION, seed=777)
    bundle = export_bundle(registry, source.id)

    first = import_bundle(registry, bundle, available_capabilities={"voice_design"})
    second = import_bundle(registry, bundle, available_capabilities={"voice_design"})

    assert first.profile.id != second.profile.id
    assert second.profile.name == "讲述者（导入 2）"
    assert len(_custom(registry)) == 3


def test_explicit_name_override_is_honoured(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    source = registry.create_custom_profile("讲述者", INSTRUCTION, seed=777)
    bundle = export_bundle(registry, source.id)

    imported = import_bundle(
        registry, bundle, available_capabilities={"voice_design"}, name="备份副本"
    )

    assert imported.profile.name == "备份副本"
    assert imported.renamed_from is None


def test_failed_import_registers_nothing(tmp_path: Path) -> None:
    """A rejected bundle must not leave a half-written voice behind."""

    registry = _registry(tmp_path)
    registry.create_custom_profile("已有音色", INSTRUCTION, seed=7)
    before = [(profile.id, profile.name, profile.revision) for profile in _custom(registry)]

    with pytest.raises(VoiceBundleError) as excinfo:
        import_bundle(registry, _clone_bundle(_wav(0.5)), available_capabilities={"tts_base"})

    assert excinfo.value.code == "bundle_invalid_asset"
    after = [(profile.id, profile.name, profile.revision) for profile in _custom(registry)]
    assert after == before


# MARK: - 能力差异


def test_capability_gap_is_reported_but_import_still_succeeds(tmp_path: Path) -> None:
    registry = _registry(tmp_path)
    source = registry.create_cloned_profile(
        name="旁白男声", ref_text=REF_TEXT, audio_bytes=_wav(3.0), duration_seconds=3.0
    )
    bundle = export_bundle(registry, source.id)

    inspection = inspect_bundle(bundle, available_capabilities=set(), existing_names=set())
    assert inspection.missing_capabilities == ("tts_base",)
    assert inspection.importable is True
    assert any("音色克隆" in note for note in inspection.notes)

    imported = import_bundle(registry, bundle, available_capabilities=set())
    assert imported.profile.mode == "clone"


# MARK: - HTTP 接线


@pytest.fixture
def client(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """App-level client with the voice store redirected into ``tmp_path``."""

    from fastapi.testclient import TestClient

    from speechrail.app import create_app

    monkeypatch.setenv(
        "SPEECHRAIL_VOICE_STORE_PATH", str(tmp_path / "store" / "custom_voices.json")
    )
    monkeypatch.setenv("SPEECHRAIL_VOICE_AUDIO_DIR", str(tmp_path / "store" / "audio"))
    with TestClient(create_app()) as test_client:
        yield test_client


def _create_instruction_voice(client) -> dict:
    response = client.post("/v1/voices", json={"name": "讲述者", "instruction": INSTRUCTION})
    assert response.status_code == 201, response.text
    return response.json()


def test_http_export_preview_inspect_and_import(client) -> None:
    created = _create_instruction_voice(client)

    preview = client.get(f"/v1/voices/{created['id']}/bundle/preview")
    assert preview.status_code == 200, preview.text
    assert preview.json()["entries"] == [MANIFEST_NAME]
    assert "模型权重与运行配置" in preview.json()["excluded"]

    exported = client.get(f"/v1/voices/{created['id']}/bundle")
    assert exported.status_code == 200, exported.text
    assert exported.headers["content-type"] == "application/zip"
    assert ".srvoice" in exported.headers["content-disposition"]
    bundle = exported.content

    inspected = client.post(
        "/v1/voices/bundles/inspect", files={"bundle": ("voice.srvoice", bundle)}
    )
    assert inspected.status_code == 200, inspected.text
    assert inspected.json()["name"] == "讲述者"
    assert inspected.json()["importable"] is True

    imported = client.post("/v1/voices/bundles", files={"bundle": ("voice.srvoice", bundle)})
    assert imported.status_code == 201, imported.text
    body = imported.json()
    assert body["id"] != created["id"]
    assert body["name"] == "讲述者（导入）"
    assert body["renamed_from"] == "讲述者"
    assert body["validation"] == "unverified"

    listing = client.get("/v1/voices").json()["data"]
    assert {entry["id"] for entry in listing} >= {created["id"], body["id"]}


def test_http_inspect_rejects_garbage_without_writing(client) -> None:
    before = client.get("/v1/voices").json()["data"]

    response = client.post(
        "/v1/voices/bundles/inspect", files={"bundle": ("junk.srvoice", b"not a zip")}
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "bundle_invalid_zip"
    assert client.get("/v1/voices").json()["data"] == before


def test_http_export_rejects_unknown_and_system_voices(client) -> None:
    missing = client.get("/v1/voices/does_not_exist/bundle")
    assert missing.status_code == 404

    preset = client.get("/v1/voices/serena/bundle")
    assert preset.status_code == 400
    assert preset.json()["error"]["code"] == "bundle_system_voice_not_exportable"


def test_http_import_of_a_future_schema_reports_415(client) -> None:
    archive = _zip({MANIFEST_NAME: json.dumps(_manifest(format_version=99)).encode()})

    response = client.post("/v1/voices/bundles", files={"bundle": ("v99.srvoice", archive)})

    assert response.status_code == 415
    assert response.json()["error"]["code"] == "bundle_unsupported_version"


def test_http_import_rejects_unusable_audio_without_writing(client) -> None:
    before = client.get("/v1/voices").json()["data"]

    response = client.post(
        "/v1/voices/bundles", files={"bundle": ("bad.srvoice", _clone_bundle(_wav(0.5)))}
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "bundle_invalid_asset"
    assert client.get("/v1/voices").json()["data"] == before
