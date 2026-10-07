from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/macos_app_build.sh"


def test_local_build_rejects_test_manifest_drift_before_invoking_xcode(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    checker = bin_dir / "python3"
    checker.write_text("#!/bin/sh\nexit 23\n", encoding="utf-8")
    checker.chmod(0o755)
    marker = tmp_path / "xcode-invoked"
    xcode = bin_dir / "xcodebuild"
    xcode.write_text('#!/bin/sh\ntouch "$XCODE_MARKER"\nexit 9\n', encoding="utf-8")
    xcode.chmod(0o755)
    result = subprocess.run(
        ["bash", str(SCRIPT), "--configuration", "Debug"],
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "XCODE_MARKER": str(marker),
        },
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == 23, result.stderr
    assert not marker.exists(), "Xcode must not start when manifest parity fails"


@pytest.mark.parametrize("build_status", ["0", "7"])
def test_ci_build_preserves_cache_and_removes_bundle(
    tmp_path: Path, build_status: str
) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    xcode = bin_dir / "xcodebuild"
    xcode.write_text(
        """#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
assert args.count('-scheme') == 1
assert 'ARCHS=arm64' in args
assert 'CODE_SIGNING_ALLOWED=NO' in args
root = pathlib.Path(args[args.index('-derivedDataPath') + 1])
(root / 'Build/Products/Debug/SpeechRail.app').mkdir(parents=True)
(root / 'Build/Intermediates.noindex').mkdir(parents=True)
(root / 'Build/Intermediates.noindex/compiled.o').write_bytes(b'object')
sys.exit(int(os.getenv('BUILD_STATUS')))
""",
        encoding="utf-8",
    )
    xcode.chmod(0o755)
    derived = tmp_path / "derived"
    result = subprocess.run(
        [
            "bash", str(SCRIPT), "--ci-derived-data", str(derived), "--",
            "CODE_SIGNING_ALLOWED=NO", "ARCHS=arm64",
        ],
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "GITHUB_ACTIONS": "true",
            "CI": "true",
            "RUNNER_TEMP": str(tmp_path),
            "BUILD_STATUS": build_status,
        },
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == int(build_status), result.stderr
    assert (derived / "Build/Intermediates.noindex/compiled.o").is_file()
    assert not (derived / "Build/Products/Debug/SpeechRail.app").exists()


@pytest.mark.parametrize("in_ci", ["true", "false"])
def test_ci_cache_path_cannot_escape_runner_temp(tmp_path: Path, in_ci: str) -> None:
    result = subprocess.run(
        ["bash", str(SCRIPT), "--ci-derived-data", str(tmp_path / "outside")],
        env={
            **os.environ, "GITHUB_ACTIONS": in_ci, "CI": in_ci,
            "RUNNER_TEMP": str(tmp_path / "runner"),
        },
        capture_output=True,
        timeout=10,
    )
    assert result.returncode == 2
    assert not (tmp_path / "outside").exists()
