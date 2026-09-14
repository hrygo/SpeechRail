#!/usr/bin/env python3
"""Verify that a release tag exactly matches the project version."""

from __future__ import annotations

import argparse
import tomllib
from collections.abc import Sequence
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def project_version(root: Path) -> str:
    """Read the release version from the project's ``[project]`` table."""
    with (root / "pyproject.toml").open("rb") as handle:
        document = tomllib.load(handle)
    project = document.get("project")
    version = project.get("version") if isinstance(project, dict) else None
    if not isinstance(version, str) or not version:
        raise ValueError("pyproject.toml is missing [project].version")
    return version


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    parser.add_argument("--tag", required=True, help="Git tag to verify")
    args = parser.parse_args(argv)

    try:
        version = project_version(args.root)
    except (OSError, tomllib.TOMLDecodeError, ValueError) as error:
        print(f"release tag verification FAILED: {error}")
        return 1

    expected_tag = f"v{version}"
    if args.tag != expected_tag:
        print(f"release tag verification FAILED: expected {expected_tag}, got {args.tag}")
        return 1

    print(f"release tag verified: {args.tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
