#!/usr/bin/env python3
"""Assert the SpeechRail release version is consistent at every location.

`pyproject.toml`'s `[project].version` is the single source of truth. Every
documented location that must carry the release version is verified, so a
version bump can never partially land — a past release shipped with the
OpenAPI spec, the YAML template and both test fixtures still on older
values, and this gate exists to make that impossible.

Usage:
    uv run python scripts/check_version_consistency.py [--root <repo-root>]

Exit code 0 = every location matches; exit code 1 = report of mismatches.

Known exemptions (locations that legitimately do NOT carry the current
version and are intentionally not checked):
- CHANGELOG.md: historical "[X.Y.Z]" headers reference *released* versions;
  only the current "[X.Y.Z]" header must exist.
- configs/speechrail.example.yaml: the header comment mentions a historic
  reference version that launched the env template (not a `version:` key).
"""

from __future__ import annotations

import argparse
import tomllib
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class _Check:
    label: str
    relative_path: str
    needle: str
    min_count: int = 1


def _expected_version(root: Path) -> str:
    with (root / "pyproject.toml").open("rb") as handle:
        pyproject = tomllib.load(handle)
    return pyproject["project"]["version"]


def _checks(version: str) -> tuple[_Check, ...]:
    return (
        _Check("pyproject [project].version", "pyproject.toml", f'version = "{version}"'),
        _Check("package __version__", "src/speechrail/__init__.py", f'__version__ = "{version}"'),
        _Check(
            "Settings.version (/health)",
            "src/speechrail/config/__init__.py",
            f'version: str = "{version}"',
        ),
        _Check(
            "OpenAPI info.version + /health example",
            "contracts/openapi.yaml",
            f"version: {version}",
            min_count=2,
        ),
        _Check("env template", "configs/speechrail.example.env", f"SPEECHRAIL_VERSION={version}"),
        _Check("yaml template", "configs/speechrail.example.yaml", f"  version: {version}"),
        _Check(
            "test_app_contract /health assertions",
            "tests/test_app_contract.py",
            f'"version": "{version}"',
            min_count=2,
        ),
        _Check(
            "test_installer wheel fixture",
            "tests/test_installer.py",
            f"speechrail-{version}-py3-none-any.whl",
        ),
        _Check(
            "test_release_verification dist-info fixture",
            "tests/test_release_verification.py",
            f"speechrail-{version}.dist-info/METADATA",
        ),
        _Check(
            "uv.lock project version",
            "uv.lock",
            f'name = "speechrail"\nversion = "{version}"',
        ),
        _Check("CHANGELOG release header", "CHANGELOG.md", f"## [{version}] - "),
    )


def check_tree(root: Path, version: str) -> list[str]:
    """Return a list of problems; an empty list means every location matches."""
    problems: list[str] = []
    for check in _checks(version):
        path = root / check.relative_path
        if not path.is_file():
            problems.append(f"MISSING {check.label} ({check.relative_path})")
            continue
        count = path.read_text(encoding="utf-8").count(check.needle)
        if count < check.min_count:
            problems.append(
                f"MISMATCH {check.label} ({check.relative_path}): "
                f"found {count}/{check.min_count} occurrence(s) of {check.needle!r}"
            )
    return problems


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    args = parser.parse_args(argv)

    version = _expected_version(args.root)
    problems = check_tree(args.root, version)

    print(f"expected version: {version}")
    if problems:
        print("version consistency FAILED:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("version consistency OK (all locations match)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
