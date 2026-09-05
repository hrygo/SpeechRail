from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

_INSTALLER_PATH = Path(__file__).parents[1] / "tools" / "install_macos.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_setup_installer", _INSTALLER_PATH)
assert _SPEC is not None and _SPEC.loader is not None
install_macos = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = install_macos
_SPEC.loader.exec_module(install_macos)


def test_repository_launcher_never_executes_an_unverified_remote_script() -> None:
    script = Path("deploy/macos/SpeechRail-Setup.command").read_text(encoding="utf-8")
    assert "curl | sh" not in script
    assert "eval " not in script
    assert "sudo" not in script


def test_installed_launcher_handles_spaces_and_non_ascii_app_home(tmp_path: Path) -> None:
    app_home = tmp_path / "语音 服务"
    runtime_python = app_home / "runtime/current/.venv/bin/python"
    runtime_python.parent.mkdir(parents=True)
    captured = tmp_path / "captured.txt"
    runtime_python.write_text(
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + f"'{captured}'" + "\n",
        encoding="utf-8",
    )
    runtime_python.chmod(0o700)

    launcher = install_macos._write_setup_launcher(app_home)
    completed = subprocess.run(
        (str(launcher),), check=False, capture_output=True, text=True
    )

    assert completed.returncode == 0
    assert launcher.stat().st_mode & 0o777 == 0o700
    assert captured.read_text(encoding="utf-8").splitlines() == [
        "-m",
        "speechrail",
        "setup",
        "--app-home",
        str(app_home),
    ]


def test_installed_launcher_refuses_a_symlink_target(tmp_path: Path) -> None:
    target = tmp_path / "outside.command"
    target.write_text("keep", encoding="utf-8")
    app_home = tmp_path / "SpeechRail"
    app_home.mkdir()
    (app_home / "SpeechRail 设置.command").symlink_to(target)

    try:
        install_macos._write_setup_launcher(app_home)
    except install_macos.InstallerError as exc:
        assert "symlink" in str(exc)
    else:
        raise AssertionError("launcher symlink must be rejected")
    assert target.read_text(encoding="utf-8") == "keep"
