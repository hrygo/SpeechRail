"""Voice-store ownership and domain-import regressions, with temporary files only."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from speechrail.app import create_app
from speechrail.config import Settings


def test_test_collection_isolates_default_app_before_fixtures(tmp_path: Path) -> None:
    script = """
import os
import runpy
import sys
from pathlib import Path
sys.dont_write_bytecode = True
home = Path(sys.argv[1])
Path.home = classmethod(lambda cls: home)
os.environ.pop("SPEECHRAIL_VOICE_STORE_PATH", None)
os.environ.pop("SPEECHRAIL_VOICE_AUDIO_DIR", None)
events = []
def audit(event, args):
    if event in {"open", "os.mkdir", "os.chmod", "os.rename", "os.remove"}:
        for value in args:
            if isinstance(value, (str, bytes)) and str(value).startswith(str(home)):
                events.append(event)
sys.addaudithook(audit)
test_defaults = runpy.run_path(sys.argv[2])
import speechrail.app
assert events == [], events
assert not str(speechrail.app.app.state.services.voice_store.storage_path).startswith(str(home))
"""
    result = subprocess.run(
        [sys.executable, "-c", script, str(tmp_path), str(Path(__file__).with_name("conftest.py"))],
        env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parents[1] / "src")},
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_same_parent_stores_do_not_share_auxiliary_artifacts(tmp_path: Path) -> None:
    from speechrail.http.routes.voice_designs import _design_idempotency_journal, _repository
    from speechrail.infrastructure.voice_registry import FileVoiceRegistry

    stores = [
        FileVoiceRegistry.open(tmp_path / f"{name}.json", tmp_path / name / "audio")
        for name in ("a", "b")
    ]
    profiles = [
        store.create_custom_profile("Same", "same recipe", voice_id="same", seed=7)
        for store in stores
    ]
    stores[0].validation_store.put(
        {"voice_id": "same", "voice_revision": profiles[0].revision, "status": "pass"}
    )
    assert stores[1].validation_store.get(
        voice_id="same", voice_revision=profiles[1].revision,
        model_artifact=None, model_catalog_revision=None,
    ) is None
    for journals in (
        [create_app(Settings(api_key=None), voice_store=s).state.services.voice_clone_journal
         for s in stores],
        [_design_idempotency_journal(s) for s in stores],
    ):
        for journal, fingerprint in zip(journals, ("a" * 64, "b" * 64), strict=True):
            assert journal.begin(
                owner="speechrail-local", operation="test", key="same", fingerprint=fingerprint,
            ).state == "new"
    assert _repository(stores[0]).path != _repository(stores[1]).path
    assert _repository(stores[0]).assets_dir != _repository(stores[1]).assets_dir


@pytest.mark.parametrize(
    "artifact",
    [
        "voice_validations.json",
        "voice_clone_idempotency.json",
        "voice_design_idempotency.json",
        "voice_design_candidates.json",
        "voice_design_candidates",
    ],
)
def test_nondefault_store_refuses_ambiguous_legacy_artifacts(
    tmp_path: Path, artifact: str,
) -> None:
    from speechrail.domain.tts import VoiceStoreUnavailableError
    from speechrail.infrastructure.voice_registry import FileVoiceRegistry

    legacy = tmp_path / artifact
    legacy.write_text("{}", encoding="utf-8")
    with pytest.raises(VoiceStoreUnavailableError, match="ownership"):
        FileVoiceRegistry.open(tmp_path / "alternate.json", tmp_path / "audio")
    assert legacy.read_text(encoding="utf-8") == "{}"


def test_default_store_keeps_existing_artifact_locations(tmp_path: Path) -> None:
    from speechrail.infrastructure.voice_registry import FileVoiceRegistry

    store = FileVoiceRegistry.open(tmp_path / "custom_voices.json", tmp_path / "audio")
    for name in (
        "voice_validations.json", "voice_clone_idempotency.json",
        "voice_design_idempotency.json", "voice_design_candidates.json",
        "voice_design_candidates",
    ):
        assert store.artifact_path(name) == tmp_path / name


def test_domain_voice_import_has_no_home_filesystem_side_effect(tmp_path: Path) -> None:
    script = """
import sys
from pathlib import Path
sys.dont_write_bytecode = True
home = Path(sys.argv[1])
Path.home = classmethod(lambda cls: home)
events = []
def audit(event, args):
    if event in {"subprocess.Popen", "os.fork", "os.posix_spawn", "socket.connect"}:
        events.append(event)
    if event in {"open", "os.mkdir", "os.chmod", "os.rename", "os.remove"}:
        for value in args:
            if isinstance(value, (str, bytes)) and str(value).startswith(str(home)):
                events.append(event)
sys.addaudithook(audit)
import speechrail.domain.tts
assert events == [], events
"""
    source = Path(__file__).resolve().parents[1] / "src"
    result = subprocess.run(
        [sys.executable, "-c", script, str(tmp_path)],
        env={**os.environ, "PYTHONPATH": str(source)},
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert not list(tmp_path.iterdir())


def test_two_apps_have_independent_revision_validation_and_lease_owners(tmp_path: Path) -> None:
    from speechrail.infrastructure.voice_registry import FileVoiceRegistry

    store_a = FileVoiceRegistry.open(tmp_path / "a" / "voices.json", tmp_path / "a" / "audio")
    store_b = FileVoiceRegistry.open(tmp_path / "b" / "voices.json", tmp_path / "b" / "audio")
    first = store_a.create_custom_profile("First", "recipe a", voice_id="same")
    second = store_b.create_custom_profile("Second", "recipe b", voice_id="same")
    settings = Settings(api_key=None)
    app_a = create_app(settings, voice_store=store_a)
    app_b = create_app(settings, voice_store=store_b)
    assert app_a.state.services.voice_store is store_a
    assert app_b.state.services.voice_store is store_b
    with store_b.lease_profile("same", expected_revision=second.revision):
        response = TestClient(app_a).patch(
            "/v1/speechrail/voices/same",
            json={"instruction": "new recipe a", "expected_revision": first.revision},
        )
        assert response.status_code == 200
        assert store_b.get_profile("same").revision == second.revision
    assert store_a.get_profile("same").revision != first.revision
    assert store_a.validation_store is not store_b.validation_store
    assert store_a.storage_path != store_b.storage_path
    assert store_a.voices_dir != store_b.voices_dir
    detail = TestClient(app_b).get("/v1/voices/same")
    assert detail.status_code == 200
    assert detail.json()["revision"] == second.revision


def test_clone_idempotency_journal_belongs_to_each_app(tmp_path: Path) -> None:
    from speechrail.infrastructure.voice_registry import FileVoiceRegistry

    stores = [
        FileVoiceRegistry.open(tmp_path / name / "voices.json", tmp_path / name / "audio")
        for name in ("a", "b")
    ]
    apps = [create_app(Settings(api_key=None), voice_store=store) for store in stores]
    journals = [app.state.services.voice_clone_journal for app in apps]
    assert journals[0] is not journals[1]
    for journal, fingerprint in zip(journals, ("a" * 64, "b" * 64), strict=True):
        decision = journal.begin(
            owner="speechrail-local",
            operation="voice.clone",
            key="same-key",
            fingerprint=fingerprint,
        )
        assert decision.state == "new"
    assert all(store.artifact_path("voice_clone_idempotency.json").is_file() for store in stores)


def test_two_clone_stores_have_independent_audio_read_leases(tmp_path: Path) -> None:
    from speechrail.domain.tts import VoiceInUseError
    from speechrail.infrastructure.voice_registry import FileVoiceRegistry

    stores = [
        FileVoiceRegistry.open(tmp_path / name / "voices.json", tmp_path / name / "audio")
        for name in ("a", "b")
    ]
    profiles = [
        store.create_cloned_profile(
            name="Same", ref_text="test reference", voice_id="same",
            audio_bytes=b"fake audio", duration_seconds=1.0,
        )
        for store in stores
    ]
    with stores[1].lease_profile("same", expected_revision=profiles[1].revision):
        stores[0].delete_custom_profile("same")
        assert not Path(profiles[0].audio_path).exists()
        assert Path(profiles[1].audio_path).is_file()
        with pytest.raises(VoiceInUseError):
            stores[1].delete_custom_profile("same")
    stores[1].delete_custom_profile("same")
    assert not Path(profiles[1].audio_path).exists()


def test_identical_voice_revisions_do_not_share_validation_evidence(tmp_path: Path) -> None:
    from speechrail.infrastructure.voice_registry import FileVoiceRegistry

    stores = [
        FileVoiceRegistry.open(tmp_path / name / "voices.json", tmp_path / name / "audio")
        for name in ("a", "b")
    ]
    profiles = [
        store.create_custom_profile("Same", "same recipe", voice_id="same", seed=7)
        for store in stores
    ]
    assert profiles[0].revision == profiles[1].revision
    stores[0].validation_store.put(
        {"voice_id": "same", "voice_revision": profiles[0].revision, "status": "pass"}
    )
    binding = {
        "voice_id": "same",
        "voice_revision": profiles[0].revision,
        "model_artifact": None,
        "model_catalog_revision": None,
    }
    assert stores[0].validation_store.get(**binding)["status"] == "pass"
    assert stores[1].validation_store.get(**binding) is None
