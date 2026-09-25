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
import os
import shutil
import subprocess
import tempfile
import zipfile
from collections.abc import Callable, Iterable, Iterator, Mapping, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from functools import partial
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


def _run_git_bytes(source_root: Path, *arguments: str) -> bytes:
    try:
        completed = subprocess.run(
            ("git", "-C", str(source_root), *arguments),
            check=False,
            capture_output=True,
        )
    except OSError as exc:  # pragma: no cover - depends on the local toolchain
        raise EngineWheelBuildError("engine source checkout requires git") from exc
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip().splitlines()
        raise EngineWheelBuildError(
            "engine source checkout command failed: "
            + (detail[-1] if detail else "unknown error")
        )
    return completed.stdout


def _run_git(source_root: Path, *arguments: str) -> str:
    return _run_git_bytes(source_root, *arguments).decode("utf-8").strip()


def _normalize_repository(repository: str) -> str:
    normalized = repository.strip().rstrip("/")
    return normalized[:-4] if normalized.endswith(".git") else normalized


def _verify_source_checkout(spec: EngineBuildSpec) -> None:
    """Require a clean checkout of the exact pinned upstream revision."""

    source_root = spec.source_root
    if source_root.is_symlink() or not source_root.is_dir():
        raise EngineWheelBuildError("pinned engine source checkout is missing")
    head = _run_git(source_root, "rev-parse", "HEAD").lower()
    if head != spec.source_revision.lower():
        raise EngineWheelBuildError(
            "engine source checkout revision does not match the pinned revision"
        )
    status = _run_git(source_root, "status", "--porcelain", "--untracked-files=no")
    if status:
        raise EngineWheelBuildError("engine source checkout has tracked modifications (dirty)")
    repository = _normalize_repository(
        _run_git(source_root, "remote", "get-url", "origin")
    )
    if repository != _normalize_repository(spec.source_repository):
        raise EngineWheelBuildError(
            "engine source checkout origin does not match the pinned repository"
        )


def _tracked_source_files(source_root: Path) -> tuple[Path, ...]:
    """Return the files committed at the pinned revision, never ``.git`` or untracked input."""

    names = _run_git_bytes(source_root, "ls-files", "-z").split(b"\0")
    files: list[Path] = []
    for raw_name in names:
        if not raw_name:
            continue
        try:
            relative = raw_name.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise EngineWheelBuildError("engine source checkout has a non-UTF-8 path") from exc
        path = source_root / relative
        if path.is_symlink() or not path.is_file():
            raise EngineWheelBuildError("engine source checkout contains an unsupported file")
        try:
            path.resolve().relative_to(source_root.resolve())
        except (OSError, RuntimeError, ValueError) as exc:
            raise EngineWheelBuildError("engine source checkout path escapes its root") from exc
        files.append(path)
    if not files:
        raise EngineWheelBuildError("engine source checkout has no tracked files")
    return tuple(sorted(files, key=lambda item: item.relative_to(source_root).as_posix()))


def _overlay_files(
    incremental_root: Path,
    repository_root: Path,
) -> tuple[Path, ...]:
    """Return the additive overlay files that must reach the built wheel."""

    if incremental_root.is_symlink() or not incremental_root.is_dir():
        raise EngineWheelBuildError("engine build input incremental overlay is missing")
    try:
        relative_root = incremental_root.relative_to(repository_root).as_posix()
    except ValueError as exc:
        raise EngineWheelBuildError(
            "engine incremental overlay must stay inside the repository"
        ) from exc
    names = _run_git_bytes(
        repository_root,
        "ls-files",
        "-z",
        "--full-name",
        "--",
        relative_root,
    ).split(b"\0")
    files: list[Path] = []
    for raw_name in names:
        if not raw_name:
            continue
        try:
            relative = raw_name.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise EngineWheelBuildError("engine incremental overlay has a non-UTF-8 path") from exc
        path = repository_root / relative
        try:
            path.resolve().relative_to(incremental_root.resolve())
        except (OSError, RuntimeError, ValueError) as exc:
            raise EngineWheelBuildError(
                "engine incremental overlay file escapes its root"
            ) from exc
        if path.is_symlink() or not path.is_file():
            raise EngineWheelBuildError("engine incremental overlay is not a regular file")
        files.append(path)
    files.sort(key=lambda item: item.relative_to(incremental_root).as_posix())
    if not files:
        raise EngineWheelBuildError("engine incremental overlay is empty")
    return tuple(files)


def _apply_patch(patch_path: Path, source_root: Path) -> None:
    try:
        completed = subprocess.run(
            (
                "patch",
                "-p1",
                "--batch",
                "--forward",
                "--input",
                str(patch_path),
            ),
            cwd=source_root,
            check=False,
            capture_output=True,
        )
    except OSError as exc:  # pragma: no cover - depends on the local toolchain
        raise EngineWheelBuildError("engine build patch could not start") from exc
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip().splitlines()
        raise EngineWheelBuildError(
            "engine build patch failed: " + (detail[-1] if detail else "unknown error")
        )


@contextmanager
def _staged_source(
    source_root: Path,
    source_files: tuple[Path, ...],
    overlay_files: tuple[Path, ...],
    incremental_root: Path,
    patch_path: Path | None,
) -> Iterator[Path]:
    """Stage upstream plus the reviewed additive overlay for a clean build."""

    with tempfile.TemporaryDirectory(prefix="speechrail-engine-build-") as temporary:
        staged = Path(temporary) / "source"
        staged.mkdir()
        for source in source_files:
            relative = source.relative_to(source_root)
            destination = staged / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        if patch_path is not None:
            _apply_patch(patch_path, staged)
        for overlay in overlay_files:
            relative = overlay.relative_to(incremental_root)
            destination = staged / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.exists() or destination.is_symlink():
                raise EngineWheelBuildError(
                    "engine incremental overlay collides with upstream source: "
                    + relative.as_posix()
                )
            shutil.copy2(overlay, destination)
        yield staged


def hash_tree(paths: Iterable[Path], *, root: Path) -> str:
    """Return a stable hash over sorted (relative path, content hash) pairs."""

    resolved_root = root.resolve()
    entries: list[tuple[str, str]] = []
    for path in sorted(paths, key=lambda item: item.as_posix()):
        if path.is_symlink():
            raise EngineWheelBuildError("engine build inputs must not be symlinks")
        if path.is_dir():
            if (path / ".git").exists() or (path / ".git").is_file():
                files = list(_tracked_source_files(path))
            else:
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


def _engine_build_environment(source_root: Path) -> dict[str, str]:
    """Pin wheel timestamps to the immutable upstream commit time."""

    epoch = _run_git(source_root, "show", "-s", "--format=%ct", "HEAD")
    if not epoch.isdigit():
        raise EngineWheelBuildError("engine source checkout has no valid commit timestamp")
    environment = os.environ.copy()
    environment["SOURCE_DATE_EPOCH"] = epoch
    return environment


def _default_builder(
    source_root: Path,
    out_dir: Path,
    *,
    environment: Mapping[str, str] | None = None,
) -> Path:
    """Build with uv's isolated PEP 517 frontend from the pinned source checkout."""

    build_environment = (
        dict(environment) if environment is not None else _engine_build_environment(source_root)
    )
    try:
        completed = subprocess.run(
            (
                "uv",
                "build",
                "--wheel",
                "--out-dir",
                str(out_dir),
                str(source_root),
            ),
            env=build_environment,
            check=False,
            capture_output=True,
        )
    except OSError as exc:  # pragma: no cover - depends on the local toolchain
        raise EngineWheelBuildError("engine wheel build could not start") from exc
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip().splitlines()
        raise EngineWheelBuildError(
            "engine wheel build failed: "
            + (detail[-1] if detail else "unknown error")
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
    _verify_source_checkout(spec)
    source_files = _tracked_source_files(spec.source_root)
    if spec.patch_path is not None and not spec.patch_path.is_file():
        raise EngineWheelBuildError("engine build patch is missing")
    overlay_files = _overlay_files(spec.incremental_root, resolved_root)
    destination.mkdir(parents=True, exist_ok=True)
    build_inputs = tuple(
        overlay
        for item in spec.build_inputs
        for overlay in (
            overlay_files if item == spec.incremental_root else (item,)
        )
    )
    build_inputs_sha256 = hash_tree(build_inputs, root=resolved_root)
    patch_sha256 = hash_tree(
        (spec.patch_path,) if spec.patch_path is not None else overlay_files,
        root=resolved_root,
    )
    build = builder or partial(
        _default_builder,
        environment=_engine_build_environment(spec.source_root),
    )
    wheel_path = destination / spec.wheel_name
    with tempfile.TemporaryDirectory(
        prefix=".engine-wheel-", dir=destination
    ) as build_directory:
        with _staged_source(
            spec.source_root,
            source_files,
            overlay_files,
            spec.incremental_root,
            spec.patch_path,
        ) as staged:
            built = build(staged, Path(build_directory))
        if not built.is_file():
            raise EngineWheelBuildError("engine wheel build produced no wheel")
        if not zipfile.is_zipfile(built):
            raise EngineWheelBuildError("engine wheel is not a valid archive")
        with zipfile.ZipFile(built) as archive:
            members = set(archive.namelist())
        if built.resolve() != wheel_path.resolve():
            shutil.copy2(built, wheel_path)
    missing_overlay = sorted(
        path.relative_to(spec.incremental_root).as_posix()
        for path in overlay_files
        if path.relative_to(spec.incremental_root).as_posix() not in members
    )
    if missing_overlay:
        raise EngineWheelBuildError(
            "engine wheel is missing persistent incremental overlay files: "
            + ", ".join(missing_overlay)
        )
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
