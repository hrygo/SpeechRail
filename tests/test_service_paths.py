from __future__ import annotations

from pathlib import Path

import pytest

from speechrail.config import Settings
from speechrail.service.constants import SERVICE_LABEL
from speechrail.service.paths import ServiceLayout


def test_layout_uses_private_app_home_and_stable_runtime_paths(tmp_path: Path) -> None:
    app_home = tmp_path / "Application Support" / "SpeechRail"

    layout = ServiceLayout.for_app_home(app_home, user_home=tmp_path / "User")

    assert layout.app_home == app_home
    assert layout.runtime_root == app_home / "runtime"
    assert layout.current_runtime == app_home / "runtime" / "current"
    assert layout.config_file == app_home / "config" / ".env"
    assert layout.log_directory == tmp_path / "User" / "Library" / "Logs" / "SpeechRail"
    assert layout.plist_path == (
        tmp_path / "User" / "Library" / "LaunchAgents" / f"{SERVICE_LABEL}.plist"
    )


def test_layout_keeps_current_runtime_as_a_symlink_path(tmp_path: Path) -> None:
    app_home = tmp_path / "SpeechRail"
    layout = ServiceLayout.for_app_home(app_home)

    layout.ensure_directories()
    release = layout.runtime_root / "releases" / "first"
    release.mkdir(parents=True)
    layout.current_runtime.symlink_to(release, target_is_directory=True)

    assert layout.current_runtime.is_symlink()
    assert layout.current_runtime == app_home / "runtime" / "current"


def test_layout_rejects_relative_app_home(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="app home must be absolute"):
        ServiceLayout.for_app_home(Path("relative"), user_home=tmp_path)


def test_settings_can_load_an_explicit_env_file(tmp_path: Path) -> None:
    env_file = tmp_path / ".env"
    env_file.write_text("SPEECHRAIL_PORT=8317\n", encoding="utf-8")

    settings = Settings.from_env_file(env_file)

    assert settings.port == 8317
