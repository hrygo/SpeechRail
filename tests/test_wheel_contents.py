from __future__ import annotations

from pathlib import Path
from zipfile import ZipFile

import pytest


def assert_wheel_contents(wheel_path: Path) -> None:
    with ZipFile(wheel_path) as archive:
        names = set(archive.namelist())

    assert "speechrail/__main__.py" in names
    assert "speechrail/cli.py" in names
    assert any(name.endswith(".dist-info/METADATA") for name in names)
    assert not any(name.startswith("tests/") for name in names)
    assert not any(name.endswith(('.env', '.log', '.wav', '.mp3', '.safetensors')) for name in names)
    assert not any("/Users/" in name for name in names)


def test_built_wheel_contains_runtime_only() -> None:
    wheels = sorted(Path("dist").glob("*.whl"))
    if not wheels:
        pytest.fail("build a wheel with 'uv build --no-sources --wheel' before this test")
    assert_wheel_contents(wheels[-1])
