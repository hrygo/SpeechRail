"""Install portable user skills independently from the managed runtime."""

from __future__ import annotations

import re
import shutil
import tempfile
import uuid
from pathlib import Path

from speechrail.service.installer_errors import InstallerError

_LOCAL_ABSOLUTE_PATH_RE = re.compile(
    r"file:///(?:Users|Volumes|private|tmp|var|home|Library|Applications|opt)/"
    r"|(?<![A-Za-z0-9_])/(?:Users|Volumes|private|tmp|var|home|Library|Applications|opt)(?:/|$)"
    r"|(?<![A-Za-z0-9_])[A-Za-z]:[\\/]"
)


def _ignore_skill_artifacts(_: str, names: list[str]) -> set[str]:
    return {
        name
        for name in names
        if name == "__pycache__" or name.endswith(".pyc") or name == ".DS_Store"
    }


def _validate_video_podcast_skill(source: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise InstallerError("video-podcast skill source is missing or invalid")

    for path in source.rglob("*"):
        if path.is_symlink():
            raise InstallerError("video-podcast skill must not contain symlinks")
        if not path.is_file() or path.name == ".DS_Store" or path.suffix == ".pyc":
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if _LOCAL_ABSOLUTE_PATH_RE.search(content):
            raise InstallerError("video-podcast skill contains a local absolute path")


def install_video_podcast_skill(
    source: Path,
    *,
    user_skills_dir: Path | None = None,
) -> Path:
    """Install the portable video-podcast skill into the current user's skill directory."""
    source = source.absolute()
    target_root = (user_skills_dir or Path.home() / ".agents" / "skills").absolute()
    _validate_video_podcast_skill(source)

    if target_root.is_symlink():
        raise InstallerError("user skill directory must not be a symlink")
    target_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = target_root / "video-podcast"
    if target.is_symlink():
        raise InstallerError("user video-podcast skill must not be a symlink")
    if target.exists() and not target.is_dir():
        raise InstallerError("user video-podcast skill must be a directory")

    staging_parent = Path(tempfile.mkdtemp(prefix=".video-podcast.", dir=target_root))
    staged = staging_parent / "video-podcast"
    backup: Path | None = None
    try:
        shutil.copytree(source, staged, ignore=_ignore_skill_artifacts)
        if target.exists():
            backup = target_root / f".video-podcast.backup-{uuid.uuid4().hex}"
            target.replace(backup)
        try:
            staged.replace(target)
        except BaseException:
            if backup is not None and not target.exists():
                backup.replace(target)
            raise
        if backup is not None:
            shutil.rmtree(backup)
        return target
    finally:
        shutil.rmtree(staging_parent, ignore_errors=True)


__all__ = ["InstallerError", "install_video_podcast_skill"]
