from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

FFMPEG_ARTIFACT = "imageio-ffmpeg==0.6.0"
_RUNTIME_DIRECTORY = Path("src/speechrail/assets/runtime")
_LOCK_PATH = Path("src/speechrail/assets/runtime-lock.json")
_ENGINE_BUILD_DIRECTORY = Path("vendor/engine-build/dist")
_ENGINE_PROVENANCE_NAME = "provenance.json"
_ENGINE_PIN_FIELDS = (
    "filename",
    "sha256",
    "source_repository",
    "source_revision",
    "patch_sha256",
    "build_inputs_sha256",
)
_SHA256_RE = re.compile(r"[0-9a-fA-F]{64}\Z")
_REVISION_RE = re.compile(r"[0-9a-fA-F]{40}\Z")
_PYTHON_VERSION_RE = re.compile(r"3\.14\.\d+\Z")
_LOCK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
_REQUIREMENT_RE = re.compile(
    r"(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)=="
    r"(?P<version>[A-Za-z0-9][A-Za-z0-9.!+_-]*)"
    r"(?P<hashes>(?:\s+--hash=sha256:[0-9a-fA-F]{64})+)\Z"
)


class RuntimeLockGenerationError(ValueError):
    """Raised when a candidate runtime lock is incomplete or ambiguous."""


def parse_hashed_requirements(text: str, *, source_name: str) -> tuple[str, ...]:
    """Flatten pinned, hash-locked requirements without accepting pip directives."""
    logical_lines: list[tuple[int, str]] = []
    pending: str | None = None
    pending_line = 0

    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        continues = stripped.endswith("\\")
        fragment = stripped[:-1].rstrip() if continues else stripped
        if not fragment:
            raise RuntimeLockGenerationError(
                f"{source_name}:{line_number}: empty requirement continuation"
            )

        if pending is None:
            if continues:
                pending = fragment
                pending_line = line_number
            else:
                logical_lines.append((line_number, fragment))
            continue

        pending = f"{pending} {fragment}"
        if not continues:
            logical_lines.append((pending_line, pending))
            pending = None
            pending_line = 0

    if pending is not None:
        raise RuntimeLockGenerationError(
            f"{source_name}:{pending_line}: unterminated requirement continuation"
        )

    requirements: list[str] = []
    names: set[str] = set()
    for line_number, line in logical_lines:
        match = _REQUIREMENT_RE.fullmatch(line)
        if match is None:
            raise RuntimeLockGenerationError(
                f"{source_name}:{line_number}: expected a pinned requirement with sha256 hashes"
            )
        normalized_name = re.sub(r"[-_.]+", "-", match.group("name")).lower()
        if normalized_name in names:
            raise RuntimeLockGenerationError(
                f"{source_name}:{line_number}: duplicate normalized package name"
            )
        names.add(normalized_name)
        requirements.append(" ".join(line.split()))

    if not requirements:
        raise RuntimeLockGenerationError(f"{source_name}: no hashed requirements found")
    return tuple(requirements)


def _read_requirement_file(path: Path, *, root: Path) -> tuple[tuple[str, ...], str]:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise RuntimeLockGenerationError(f"required lock file is unavailable: {path}") from exc
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeLockGenerationError(f"lock file is not UTF-8: {path}") from exc
    relative = path.relative_to(root).as_posix()
    requirements = parse_hashed_requirements(text, source_name=relative)
    return requirements, hashlib.sha256(raw).hexdigest()


def _read_engine_wheel_pin(root: Path) -> dict[str, str] | None:
    """Read the builder provenance, or ``None`` when the build gate has not run.

    The shipped lock never carries a guessed wheel hash: until the controlled
    build writes ``provenance.json`` next to its wheel, the lock stays without an
    ``engine_wheel`` pin and the runtime installs the requirements only.
    """

    provenance_path = root / _ENGINE_BUILD_DIRECTORY / _ENGINE_PROVENANCE_NAME
    if not provenance_path.is_file():
        return None
    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeLockGenerationError("engine wheel provenance is invalid") from exc
    if not isinstance(provenance, dict) or set(provenance) != set(_ENGINE_PIN_FIELDS):
        raise RuntimeLockGenerationError("engine wheel provenance fields are incomplete")
    pin: dict[str, str] = {}
    for field in _ENGINE_PIN_FIELDS:
        value = provenance[field]
        if not isinstance(value, str) or not value:
            raise RuntimeLockGenerationError("engine wheel provenance values are invalid")
        pin[field] = value
    if Path(pin["filename"]).name != pin["filename"] or not pin["filename"].endswith(".whl"):
        raise RuntimeLockGenerationError("engine wheel provenance filename is invalid")
    if _SHA256_RE.fullmatch(pin["sha256"]) is None:
        raise RuntimeLockGenerationError("engine wheel provenance hash is invalid")
    if _REVISION_RE.fullmatch(pin["source_revision"]) is None:
        raise RuntimeLockGenerationError("engine wheel provenance revision is invalid")
    for field in ("patch_sha256", "build_inputs_sha256"):
        if _SHA256_RE.fullmatch(pin[field]) is None:
            raise RuntimeLockGenerationError(
                f"engine wheel provenance {field} is invalid"
            )
    wheel_path = root / _ENGINE_BUILD_DIRECTORY / pin["filename"]
    if wheel_path.is_symlink() or not wheel_path.is_file():
        raise RuntimeLockGenerationError("engine wheel artifact is unavailable")
    if hashlib.sha256(wheel_path.read_bytes()).hexdigest() != pin["sha256"]:
        raise RuntimeLockGenerationError("engine wheel artifact hash does not match")
    return pin


def build_runtime_lock(root: Path, *, lock_id: str, python_version: str) -> dict[str, Any]:
    """Build lock metadata solely from the two generated, hash-pinned .txt files."""
    if _LOCK_ID_RE.fullmatch(lock_id) is None:
        raise RuntimeLockGenerationError("runtime lock id is invalid")
    if _PYTHON_VERSION_RE.fullmatch(python_version) is None:
        raise RuntimeLockGenerationError("runtime Python must be a 3.14.x release")

    resolved_root = root.resolve()
    asr_path = resolved_root / _RUNTIME_DIRECTORY / "asr.txt"
    tts_path = resolved_root / _RUNTIME_DIRECTORY / "tts.txt"
    asr_requirements, asr_hash = _read_requirement_file(asr_path, root=resolved_root)
    tts_requirements, tts_hash = _read_requirement_file(tts_path, root=resolved_root)
    payload: dict[str, Any] = {
        "id": lock_id,
        "python": python_version,
        "asr_requirements": list(asr_requirements),
        "tts_requirements": list(tts_requirements),
        "ffmpeg_artifact": FFMPEG_ARTIFACT,
        "file_hashes": {
            "runtime/asr.txt": asr_hash,
            "runtime/tts.txt": tts_hash,
        },
    }
    wheel_pin = _read_engine_wheel_pin(resolved_root)
    if wheel_pin is not None:
        payload["engine_wheel"] = wheel_pin
    return payload


def _render_runtime_lock(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _lock_path(root: Path) -> Path:
    return root.resolve() / _LOCK_PATH


def write_runtime_lock(root: Path, payload: dict[str, Any]) -> None:
    """Atomically replace the generated runtime lock in its own directory."""
    target = _lock_path(root)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{target.name}.", suffix=".tmp", dir=target.parent
        )
        temporary_path = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as temporary_file:
            temporary_file.write(_render_runtime_lock(payload))
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        temporary_path.chmod(0o644)
        temporary_path.replace(target)
    except OSError as exc:
        raise RuntimeLockGenerationError(f"could not write runtime lock: {target}") from exc
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def check_runtime_lock(root: Path, payload: dict[str, Any]) -> bool:
    """Compare generated bytes with disk without changing the target or its mtime."""
    try:
        current = _lock_path(root).read_bytes()
    except OSError:
        return False
    return current == _render_runtime_lock(payload)


def _arguments(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", required=True, dest="python_version")
    parser.add_argument("--id", required=True, dest="lock_id")
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[1], help=argparse.SUPPRESS
    )
    parser.add_argument("--check", action="store_true", help="check generated lock without writing")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _arguments(argv)
    try:
        payload = build_runtime_lock(
            args.root, lock_id=args.lock_id, python_version=args.python_version
        )
        if args.check:
            if not check_runtime_lock(args.root, payload):
                print("runtime lock is stale; regenerate it without --check", file=sys.stderr)
                return 1
            print("runtime lock is up to date")
            return 0
        write_runtime_lock(args.root, payload)
    except RuntimeLockGenerationError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(f"runtime lock written: {_lock_path(args.root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
