#!/usr/bin/env python3
"""Build the single controlled SpeechRail engine wheel and its provenance.

The target architecture replaces the old ``vendor_overlays`` copy step: the
speech engine ships as exactly one wheel, built from a pinned upstream revision
plus the reviewed incremental sources, with every rebuild input hashed into
``provenance.json``.  ``tools/update_runtime_lock.py`` then copies that
provenance into ``runtime-lock.json`` so a release can only install a wheel that
matches the lock.

The real engine is never built by tests; ``tests/test_engine_wheel_build.py``
injects a fake builder over a tiny temporary package.  Building the shipped
wheel is part of the T03 evidence gate and requires the pinned upstream source
plus network access, so it is never triggered implicitly.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import zipfile
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

_SHA256_RE = r"[0-9a-fA-F]{64}"
_REVISION_RE = r"[0-9a-fA-F]{40}"
_PROVENANCE_NAME = "provenance.json"
EngineWheelBuilder = Callable[[Path, Path], Path]


class EngineWheelBuildError(ValueError):
    """A controlled engine wheel could not be built or described."""


@dataclass(frozen=True, slots=True)
class EngineBuildSpec:
    """Immutable, reviewable inputs for one engine wheel build."""

    source_repository: str
    source_revision: str
    wheel_name: str
    source_root: Path
    incremental_root: Path
    patch_path: Path | None
    build_inputs: tuple[Path, ...]

    def __post_init__(self) -> None:
        import re

        if not self.source_repository:
            raise EngineWheelBuildError("engine build source repository is required")
        if re.fullmatch(_REVISION_RE, self.source_revision) is None:
            raise EngineWheelBuildError(
                "engine build source revision must be a pinned 40-character commit"
            )
        if Path(self.wheel_name).name != self.wheel_name or not self.wheel_name.endswith(
            ".whl"
        ):
            raise EngineWheelBuildError("engine wheel name must be a bare .whl name")
        if not self.build_inputs:
            raise EngineWheelBuildError("engine build inputs are required")


@dataclass(frozen=True, slots=True)
class EngineWheelBuild:
    """The built wheel plus the provenance to pin it in the runtime lock."""

    wheel_path: Path
    sha256: str
    provenance: Mapping[str, str]

    def to_payload(self) -> dict[str, str]:
        return dict(self.provenance)


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise EngineWheelBuildError(f"engine build input is unavailable: {path.name}")
    return _sha256_bytes(path.read_bytes())


def hash_tree(paths: Iterable[Path], *, root: Path) -> str:
    """Return a stable hash over sorted (relative path, content hash) pairs."""

    resolved_root = root.resolve()
    entries: list[tuple[str, str]] = []
    for path in sorted(paths, key=lambda item: item.as_posix()):
        if path.is_symlink():
            raise EngineWheelBuildError("engine build inputs must not be symlinks")
        if path.is_dir():
            files = sorted(item for item in path.rglob("*") if item.is_file())
        elif path.is_file():
            files = [path]
        else:
            raise EngineWheelBuildError(f"engine build input is missing: {path.name}")
        for file in files:
            if file.is_symlink():
                raise EngineWheelBuildError("engine build inputs must not be symlinks")
            try:
                relative = file.resolve().relative_to(resolved_root).as_posix()
            except ValueError as exc:
                raise EngineWheelBuildError(
                    "engine build inputs must stay inside the repository"
                ) from exc
            entries.append((relative, _sha256_file(file)))
    digest = hashlib.sha256()
    for relative, value in sorted(entries):
        digest.update(f"{relative}\0{value}\n".encode())
    return digest.hexdigest()


def load_build_spec(root: Path, spec_path: Path) -> EngineBuildSpec:
    """Read one engine build spec; never guesses a revision or wheel name."""

    resolved_root = root.resolve()
    try:
        payload = json.loads((resolved_root / spec_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EngineWheelBuildError("engine build spec is unavailable or invalid") from exc
    if not isinstance(payload, Mapping):
        raise EngineWheelBuildError("engine build spec must be a JSON object")
    required = {"source_repository", "source_revision", "wheel_name", "source_root",
                "incremental_root", "build_inputs"}
    unknown = sorted(set(payload) - (required | {"patch"}))
    missing = sorted(required - set(payload))
    if missing or unknown:
        raise EngineWheelBuildError(
            f"engine build spec fields are invalid: missing={missing} unknown={unknown}"
        )
    raw_inputs = payload["build_inputs"]
    if not isinstance(raw_inputs, list) or not all(
        isinstance(item, str) and item for item in raw_inputs
    ):
        raise EngineWheelBuildError("engine build inputs must be a list of relative paths")
    patch = payload.get("patch")
    if patch is not None and (not isinstance(patch, str) or not patch):
        raise EngineWheelBuildError("engine build patch must be a relative path")
    for value in (
        payload["source_repository"],
        payload["source_revision"],
        payload["wheel_name"],
        payload["source_root"],
        payload["incremental_root"],
    ):
        if not isinstance(value, str) or not value:
            raise EngineWheelBuildError("engine build spec values must be non-empty strings")
    return EngineBuildSpec(
        source_repository=payload["source_repository"],
        source_revision=payload["source_revision"],
        wheel_name=payload["wheel_name"],
        source_root=(resolved_root / payload["source_root"]).resolve(),
        incremental_root=(resolved_root / payload["incremental_root"]).resolve(),
        patch_path=None if patch is None else (resolved_root / patch).resolve(),
        build_inputs=tuple(
            (resolved_root / item).resolve() for item in raw_inputs
        ),
    )


def _default_builder(source_root: Path, out_dir: Path) -> Path:
    """Build with ``python -m build`` from the pinned source checkout."""

    try:
        completed = subprocess.run(
            (
                sys.executable,
                "-m",
                "build",
                "--wheel",
                "--no-isolation",
                "--outdir",
                str(out_dir),
                str(source_root),
            ),
            check=False,
            capture_output=True,
        )
    except OSError as exc:  # pragma: no cover - depends on the local toolchain
        raise EngineWheelBuildError("engine wheel build could not start") from exc
    if completed.returncode != 0:
        raise EngineWheelBuildError(
            "engine wheel build failed: "
            + completed.stderr.decode("utf-8", "replace").strip().splitlines()[-1]
        )
    wheels = sorted(out_dir.glob("*.whl"))
    if not wheels:
        raise EngineWheelBuildError("engine wheel build produced no wheel")
    return wheels[-1]


def build_engine_wheel(
    spec: EngineBuildSpec,
    *,
    root: Path,
    out_dir: Path | None = None,
    builder: EngineWheelBuilder | None = None,
) -> EngineWheelBuild:
    """Build one wheel and write the provenance the runtime lock consumes."""

    resolved_root = root.resolve()
    destination = (out_dir or (resolved_root / "vendor" / "engine-build" / "dist")).resolve()
    if not spec.source_root.is_dir():
        raise EngineWheelBuildError("pinned engine source checkout is missing")
    if spec.patch_path is not None and not spec.patch_path.is_file():
        raise EngineWheelBuildError("engine build patch is missing")
    destination.mkdir(parents=True, exist_ok=True)
    build_inputs_sha256 = hash_tree(spec.build_inputs, root=resolved_root)
    patch_sha256 = hash_tree(
        (spec.patch_path,) if spec.patch_path is not None else (spec.incremental_root,),
        root=resolved_root,
    )
    build = builder or _default_builder
    built = build(spec.source_root, destination)
    wheel_path = destination / spec.wheel_name
    if built.resolve() != wheel_path.resolve():
        if not built.exists():
            raise EngineWheelBuildError("engine wheel build produced no wheel")
        built.replace(wheel_path)
    if not zipfile.is_zipfile(wheel_path):
        raise EngineWheelBuildError("engine wheel is not a valid archive")
    provenance = {
        "filename": spec.wheel_name,
        "sha256": _sha256_file(wheel_path),
        "source_repository": spec.source_repository,
        "source_revision": spec.source_revision,
        "patch_sha256": patch_sha256,
        "build_inputs_sha256": build_inputs_sha256,
    }
    (destination / _PROVENANCE_NAME).write_text(
        json.dumps(provenance, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return EngineWheelBuild(
        wheel_path=wheel_path,
        sha256=provenance["sha256"],
        provenance=provenance,
    )


def _arguments(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, default=None)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _arguments(argv)
    spec = load_build_spec(args.root, args.spec)
    build = build_engine_wheel(spec, root=args.root, out_dir=args.out_dir)
    print(json.dumps({"wheel": build.wheel_path.name, **build.to_payload()}, sort_keys=True))
    return 0


if __name__ == "__main__":  # pragma: no cover - thin CLI wrapper
    raise SystemExit(main())
