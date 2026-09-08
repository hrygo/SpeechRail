"""Packaging contracts for runtime-only service capabilities."""

from __future__ import annotations

import tomllib
from pathlib import Path


def test_supported_macos_app_installs_onnxruntime_for_server_vad() -> None:
    pyproject = Path(__file__).parents[1] / "pyproject.toml"
    project = tomllib.loads(pyproject.read_text(encoding="utf-8"))["project"]
    dependencies = project["dependencies"]

    assert (
        "onnxruntime==1.29.0; sys_platform == 'darwin' and platform_machine == 'arm64'"
        in dependencies
    )
