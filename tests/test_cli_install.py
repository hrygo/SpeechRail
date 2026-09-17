"""The release-asset install entry point: ``speechrail install``.

A downloader-only user has the wheel but no source checkout.  These tests keep
the command thin and honest: it resolves exactly one local wheel, refuses a
wheel that cannot match the running code, and delegates the real work to the
single packaged installer.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import Any
from zipfile import ZipFile

import pytest

from speechrail import __version__
from speechrail.cli import main
from speechrail.service import managed_install, profile_commands
from speechrail.service.managed_install import InstallResult


def _write_wheel(directory: Path, version: str) -> Path:
    """Write the smallest file that is still a real wheel with METADATA."""
    wheel = directory / f"speechrail-{version}-py3-none-any.whl"
    with ZipFile(wheel, "w") as archive:
        archive.writestr(
            f"speechrail-{version}.dist-info/METADATA",
            f"Metadata-Version: 2.3\nName: speechrail\nVersion: {version}\n",
        )
    return wheel


@pytest.fixture
def install_calls(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> list[dict[str, Any]]:
    """Capture installer calls instead of downloading models or touching runtime/current."""
    calls: list[dict[str, Any]] = []

    def fake_install_managed(wheel: Path, **kwargs: Any) -> InstallResult:
        calls.append({"wheel": wheel, **kwargs})
        app_home = Path(kwargs["app_home"])
        return InstallResult(
            app_home=app_home,
            runtime_python=app_home / "runtime/current/.venv/bin/python",
            plist_path=Path.home() / "Library/LaunchAgents/com.speechrail.plist",
            enabled=bool(kwargs["enable"]),
            prepared_id="prepared-balanced",
            runtime_key="runtime-test",
        )

    monkeypatch.setattr(managed_install, "install_managed", fake_install_managed)
    monkeypatch.chdir(tmp_path)
    return calls


def test_install_requires_exactly_one_local_wheel(
    install_calls: list[dict[str, Any]], capsys: pytest.CaptureFixture[str]
) -> None:
    assert main(["install", "--yes"]) == 1
    assert "speechrail" in capsys.readouterr().err
    assert install_calls == []


def test_install_uses_the_local_wheel_and_stays_disabled_by_default(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    wheel = _write_wheel(tmp_path, __version__)
    app_home = tmp_path / "Application Support" / "SpeechRail"

    assert main(["install", "--yes", "--preset", "light", "--app-home", str(app_home)]) == 0

    assert len(install_calls) == 1
    call = install_calls[0]
    assert call["wheel"] == wheel
    assert call["app_home"] == app_home
    assert call["preset_id"] == "light"
    assert call["enable"] is False
    assert callable(call["progress"])
    assert "not started" in capsys.readouterr().out


def test_install_starts_the_service_only_when_asked(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_wheel(tmp_path, __version__)

    assert main(["install", "--yes", "--preset", "balanced", "--enable"]) == 0

    assert install_calls[0]["enable"] is True
    assert "registered and started" in capsys.readouterr().out


def test_install_refuses_a_wheel_that_cannot_match_this_code(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_wheel(tmp_path, "0.0.1")

    assert main(["install", "--yes"]) == 1

    assert "0.0.1" in capsys.readouterr().err
    assert install_calls == []


def test_install_requires_confirmation_before_any_mutation(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_wheel(tmp_path, __version__)

    assert main(["install", "--preset", "light"]) == 1

    assert install_calls == []
    assert "Cancelled." in capsys.readouterr().out


def test_install_recommends_the_preset_when_none_is_given(
    install_calls: list[dict[str, Any]],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_wheel(tmp_path, __version__)
    monkeypatch.setattr(profile_commands, "recommend_profile", lambda _: "balanced")

    assert main(["install", "--yes"]) == 0

    assert install_calls[0]["preset_id"] == "balanced"


def test_install_emits_one_machine_envelope(
    install_calls: list[dict[str, Any]], tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _write_wheel(tmp_path, __version__)

    assert main(["install", "--yes", "--preset", "light", "--json"]) == 0

    payload = json.loads(capsys.readouterr().out)
    assert payload["command"] == "install"
    assert payload["status"] == "committed"
    assert payload["preset"] == "light"
    assert payload["enabled"] is False


def test_repository_shim_reexports_the_packaged_installer() -> None:
    """The release SOP, zero-setup and older notes import tools.install_macos."""
    shim_path = Path(__file__).parents[1] / "tools" / "install_macos.py"
    spec = importlib.util.spec_from_file_location("speechrail_tools_installer_shim", shim_path)
    assert spec is not None and spec.loader is not None
    shim = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = shim
    spec.loader.exec_module(shim)

    assert shim.install_managed is managed_install.install_managed
    assert shim.run_preflight is managed_install.run_preflight
    assert issubclass(shim.InstallerError, RuntimeError)
    assert not hasattr(shim, "main")
