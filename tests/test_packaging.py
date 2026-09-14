"""Packaging contracts for runtime-only service capabilities."""

from __future__ import annotations

import tomllib
from pathlib import Path


def test_supported_macos_app_installs_onnxruntime_for_server_vad() -> None:
    pyproject = Path(__file__).parents[1] / "pyproject.toml"
    project = tomllib.loads(pyproject.read_text(encoding="utf-8"))["project"]

    # Routine bump PRs move the version in pyproject.toml, so assert the pin's
    # shape and scope instead of a literal version: one exactly-pinned
    # onnxruntime, scoped to the supported Apple Silicon wheel only.
    pinned = [dep for dep in project["dependencies"] if dep.startswith("onnxruntime==")]
    assert len(pinned) == 1, f"expected one pinned onnxruntime, found {pinned!r}"

    _, _, marker = pinned[0].partition(";")
    assert marker.strip() == (
        "sys_platform == 'darwin' and platform_machine == 'arm64'"
    ), f"onnxruntime must stay scoped to Apple Silicon, got marker {marker.strip()!r}"
