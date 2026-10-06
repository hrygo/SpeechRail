"""Preserve unchanged tracked input mtimes across fresh CI checkouts.

SwiftPM/Xcode use input mtimes to invalidate cached objects. Cache keys isolate
toolchain and dependencies; this manifest avoids recompiling unchanged sources
just because checkout created them anew. Changed/new inputs keep their new mtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path


def safe_input(root: Path, name: str, scopes: list[str]) -> Path | None:
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        return None
    if not any(relative.is_relative_to(Path(scope)) for scope in scopes):
        return None
    path = root / relative
    if not path.is_file() or any(
        part.is_symlink() for part in (path, *path.parents) if part != root.parent
    ):
        return None
    if not path.resolve().is_relative_to(root):
        return None
    return path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(root: Path, manifest: Path, scopes: list[str]) -> None:
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--", *scopes], cwd=root
    ).decode().split("\0")
    records = {}
    for name in names:
        path = safe_input(root, name, scopes)
        if path is not None:
            records[name] = {"sha256": digest(path), "mtime_ns": path.stat().st_mtime_ns}
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(records, sort_keys=True), encoding="utf-8")
    print(f"Build cache: recorded {len(records)} tracked inputs")


def restore(root: Path, manifest: Path, scopes: list[str]) -> None:
    try:
        records = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("Build cache: no valid input manifest; using checkout timestamps")
        return
    if not isinstance(records, dict):
        print("Build cache: invalid input manifest; using checkout timestamps")
        return
    restored = 0
    for name, record in records.items():
        if not isinstance(record, dict):
            continue
        path = safe_input(root, name, scopes)
        mtime = record.get("mtime_ns")
        if path is None or not isinstance(mtime, int) or mtime < 0:
            continue
        if digest(path) != record.get("sha256"):
            continue
        try:
            os.utime(path, ns=(path.stat().st_atime_ns, mtime))
        except (OSError, OverflowError):
            continue
        restored += 1
    print(f"Build cache: restored {restored} unchanged input timestamps")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("snapshot", "restore"))
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("scopes", nargs="+")
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = args.manifest if args.manifest.is_absolute() else root / args.manifest
    if args.mode == "snapshot":
        snapshot(root, manifest, args.scopes)
    else:
        restore(root, manifest, args.scopes)


if __name__ == "__main__":
    main()
