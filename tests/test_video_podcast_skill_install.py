from __future__ import annotations

import importlib.util
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

_INSTALLER_PATH = Path(__file__).parents[1] / "tools" / "install_macos.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_skill_installer", _INSTALLER_PATH)
assert _SPEC is not None and _SPEC.loader is not None
install_macos = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = install_macos
_SPEC.loader.exec_module(install_macos)


PROJECT_ROOT = Path(__file__).parents[1]
PROJECT_SKILL = PROJECT_ROOT / ".agents" / "skills" / "video-podcast"


def _skill_files(root: Path) -> dict[Path, bytes]:
    return {
        path.relative_to(root): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc"
    }


def test_video_podcast_skill_is_portable_and_installed_completely(tmp_path: Path) -> None:
    user_skills = tmp_path / ".agents" / "skills"

    installed = install_macos.install_video_podcast_skill(
        PROJECT_SKILL,
        user_skills_dir=user_skills,
    )

    assert installed == user_skills / "video-podcast"
    assert _skill_files(installed) == _skill_files(PROJECT_SKILL)
    assert not any("__pycache__" in path.parts for path in installed.rglob("*"))
    assert not any(path.suffix == ".pyc" for path in installed.rglob("*"))
    assert all(
        not install_macos._LOCAL_ABSOLUTE_PATH_RE.search(content.decode("utf-8"))
        for content in _skill_files(installed).values()
        if b"\x00" not in content
    )


def test_video_podcast_skill_install_rejects_local_absolute_paths(tmp_path: Path) -> None:
    source = tmp_path / "video-podcast"
    shutil.copytree(PROJECT_SKILL, source, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    manifest = source / "SKILL.md"
    manifest.write_text(
        manifest.read_text(encoding="utf-8") + "\nPrivate path: /Users/example/private\n",
        encoding="utf-8",
    )

    with pytest.raises(install_macos.InstallerError, match="absolute path"):
        install_macos.install_video_podcast_skill(
            source,
            user_skills_dir=tmp_path / "user" / "skills",
        )


def test_video_podcast_skill_install_refuses_destination_symlink(tmp_path: Path) -> None:
    user_skills = tmp_path / "user" / "skills"
    user_skills.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (user_skills / "video-podcast").symlink_to(outside, target_is_directory=True)

    with pytest.raises(install_macos.InstallerError, match="symlink"):
        install_macos.install_video_podcast_skill(PROJECT_SKILL, user_skills_dir=user_skills)

    assert not (outside / "SKILL.md").exists()


def test_video_podcast_skill_install_replaces_previous_copy_atomically(tmp_path: Path) -> None:
    user_skills = tmp_path / "user" / "skills"
    installed = install_macos.install_video_podcast_skill(
        PROJECT_SKILL,
        user_skills_dir=user_skills,
    )
    (installed / "stale.txt").write_text("stale", encoding="utf-8")

    install_macos.install_video_podcast_skill(PROJECT_SKILL, user_skills_dir=user_skills)

    assert not (installed / "stale.txt").exists()
    assert _skill_files(installed) == _skill_files(PROJECT_SKILL)


@pytest.mark.skipif(
    sys.platform != "darwin" or not ((3, 12) <= sys.version_info < (3, 13)),
    reason="zero-setup is a macOS Python 3.12 entry point",
)
def test_zero_setup_installs_skill_before_managed_service(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    zero_setup_path = (
        PROJECT_ROOT
        / ".agents"
        / "skills"
        / "speechrail-zero-setup"
        / "scripts"
        / "zero_setup.py"
    )
    spec = importlib.util.spec_from_file_location(
        "speechrail_zero_setup_test", zero_setup_path
    )
    assert spec is not None and spec.loader is not None
    zero_setup = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = zero_setup
    spec.loader.exec_module(zero_setup)

    events: list[tuple[str, Path | None]] = []
    wheel = tmp_path / "speechrail.whl"
    wheel.write_bytes(b"test wheel")

    monkeypatch.setattr(zero_setup, "_check_system_prerequisites", lambda: None)
    monkeypatch.setattr(zero_setup, "_get_physical_memory_bytes", lambda: 16 * 1024**3)
    monkeypatch.setattr(zero_setup, "_build_wheel", lambda: wheel)
    monkeypatch.setattr(
        zero_setup,
        "install_video_podcast_skill",
        lambda source: events.append(("skill", source)),
        raising=False,
    )

    class FakeClient:
        def __init__(self, *args: object, **kwargs: object) -> None:
            del args, kwargs

        def __enter__(self) -> FakeClient:
            return self

        def __exit__(self, *args: object) -> None:
            del args

    monkeypatch.setattr(zero_setup.httpx, "Client", FakeClient)

    def fake_install_managed(*args: object, **kwargs: object) -> SimpleNamespace:
        del args, kwargs
        events.append(("service", None))
        return SimpleNamespace(
            app_home=tmp_path / "app",
            plist_path=tmp_path / "com.speechrail.plist",
            enabled=False,
        )

    monkeypatch.setattr(zero_setup, "install_managed", fake_install_managed)

    zero_setup.run_zero_setup(
        preset="light",
        app_home=tmp_path / "app",
        enable=False,
        run_smoke=False,
    )

    assert [kind for kind, _ in events] == ["skill", "service"]
    assert events[0][1] == zero_setup.REPO_ROOT / ".agents" / "skills" / "video-podcast"


@pytest.mark.skipif(
    sys.platform != "darwin" or not ((3, 12) <= sys.version_info < (3, 13)),
    reason="zero-setup is a macOS Python 3.12 entry point",
)
def test_zero_setup_reads_private_api_key_without_exposing_it(
    tmp_path: Path,
) -> None:
    zero_setup_path = (
        PROJECT_ROOT
        / ".agents"
        / "skills"
        / "speechrail-zero-setup"
        / "scripts"
        / "zero_setup.py"
    )
    spec = importlib.util.spec_from_file_location(
        "speechrail_zero_setup_key_test", zero_setup_path
    )
    assert spec is not None and spec.loader is not None
    zero_setup = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = zero_setup
    spec.loader.exec_module(zero_setup)

    app_home = tmp_path / "app"
    config = app_home / "config" / ".env"
    config.parent.mkdir(parents=True)
    config.write_text(
        "SPEECHRAIL_HOST=127.0.0.1\nSPEECHRAIL_API_KEY=\"local-secret\"\n",
        encoding="utf-8",
    )

    assert zero_setup._read_api_key(app_home) == "local-secret"


@pytest.mark.skipif(
    sys.platform != "darwin" or not ((3, 12) <= sys.version_info < (3, 13)),
    reason="zero-setup is a macOS Python 3.12 entry point",
)
def test_zero_setup_smoke_failure_is_fatal(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    zero_setup_path = (
        PROJECT_ROOT
        / ".agents"
        / "skills"
        / "speechrail-zero-setup"
        / "scripts"
        / "zero_setup.py"
    )
    spec = importlib.util.spec_from_file_location(
        "speechrail_zero_setup_smoke_test", zero_setup_path
    )
    assert spec is not None and spec.loader is not None
    zero_setup = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = zero_setup
    spec.loader.exec_module(zero_setup)

    class FakeClient:
        def __init__(self, *args: object, **kwargs: object) -> None:
            del args, kwargs

        def __enter__(self) -> FakeClient:
            return self

        def __exit__(self, *args: object) -> None:
            del args

    class FailingProbe:
        def __init__(self, **kwargs: object) -> None:
            del kwargs

        def run(self, prepared: object) -> None:
            del prepared
            raise zero_setup.SmokeProbeError("probe failed")

    monkeypatch.setattr(zero_setup.httpx, "Client", FakeClient)
    monkeypatch.setattr(zero_setup, "resolve_prepared_models", lambda *args, **kwargs: object())
    monkeypatch.setattr(zero_setup, "PublicApiSmokeProbe", FailingProbe)

    with pytest.raises(zero_setup.InstallerError, match="public API smoke failed"):
        zero_setup._run_smoke_test(
            "http://127.0.0.1:8201",
            app_home=tmp_path / "app",
            prepared_id="prepared-quality",
        )
