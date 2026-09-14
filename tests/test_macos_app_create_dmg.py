from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

_SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "macos_app_create_dmg.sh"
pytestmark = pytest.mark.skipif(
    sys.platform != "darwin", reason="DMG packaging requires macOS tools"
)


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(_SCRIPT_PATH), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _app(root: Path, version: str = "2.6.0") -> Path:
    app = root / "SpeechRail.app"
    info = app / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    info.write_bytes(
        plistlib.dumps(
            {
                "CFBundleDisplayName": "SpeechRail",
                "CFBundleIdentifier": "com.speechrail.desktop",
                "CFBundleShortVersionString": version,
                "CFBundleVersion": "2",
            }
        )
    )
    return app


def test_missing_app_bundle_is_rejected(tmp_path: Path) -> None:
    result = _run(
        "--app-path",
        str(tmp_path / "SpeechRail.app"),
        "--version",
        "2.6.0",
        "--output-path",
        str(tmp_path / "SpeechRail.dmg"),
    )

    assert result.returncode == 1
    assert "app bundle not found" in result.stderr


def test_bundle_version_must_match_release_version(tmp_path: Path) -> None:
    app = _app(tmp_path, version="2.6.1")

    result = _run(
        "--app-path",
        str(app),
        "--version",
        "2.6.0",
        "--output-path",
        str(tmp_path / "SpeechRail.dmg"),
    )

    assert result.returncode == 1
    assert "bundle version" in result.stderr


def test_output_must_be_a_new_dmg_path(tmp_path: Path) -> None:
    app = _app(tmp_path)

    result = _run(
        "--app-path",
        str(app),
        "--version",
        "2.6.0",
        "--output-path",
        str(tmp_path / "SpeechRail.zip"),
    )

    assert result.returncode == 2
    assert "--output-path must end with .dmg" in result.stderr


def test_existing_dmg_is_not_overwritten(tmp_path: Path) -> None:
    app = _app(tmp_path)
    output = tmp_path / "SpeechRail-2.6.0-macOS-arm64.dmg"
    output.write_text("existing artifact", encoding="utf-8")

    result = _run(
        "--app-path",
        str(app),
        "--version",
        "2.6.0",
        "--output-path",
        str(output),
    )

    assert result.returncode == 2
    assert "refusing to overwrite" in result.stderr
    assert output.read_text(encoding="utf-8") == "existing artifact"


def test_bundle_build_version_must_be_present_and_numeric(tmp_path: Path) -> None:
    app = _app(tmp_path)
    info = app / "Contents" / "Info.plist"
    plist = plistlib.loads(info.read_bytes())
    plist.pop("CFBundleVersion")
    info.write_bytes(plistlib.dumps(plist))

    result = _run(
        "--app-path",
        str(app),
        "--version",
        "2.6.0",
        "--output-path",
        str(tmp_path / "SpeechRail.dmg"),
    )

    assert result.returncode == 1
    assert "CFBundleVersion" in result.stderr


def test_valid_bundle_produces_mountable_dmg(tmp_path: Path) -> None:
    app = _app(tmp_path)
    output = tmp_path / "SpeechRail-2.6.0-macOS-arm64.dmg"

    result = _run(
        "--app-path",
        str(app),
        "--version",
        "2.6.0",
        "--output-path",
        str(output),
    )

    assert result.returncode == 0, result.stderr
    assert output.is_file()
