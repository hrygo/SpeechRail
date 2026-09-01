"""Stable filesystem layout for an installed local SpeechRail service."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from speechrail.service.launchd import SERVICE_LABEL


def _absolute(path: Path, *, name: str) -> Path:
    if not path.is_absolute():
        raise ValueError(f"{name} must be absolute")
    return path.absolute()


@dataclass(frozen=True)
class ServiceLayout:
    """User-owned locations used by the packaged service."""

    app_home: Path
    runtime_root: Path
    current_runtime: Path
    config_directory: Path
    config_file: Path
    log_directory: Path
    plist_path: Path

    @classmethod
    def for_app_home(cls, app_home: Path, *, user_home: Path | None = None) -> ServiceLayout:
        """Build a layout while preserving the runtime symlink used for upgrades."""
        resolved_app_home = _absolute(app_home, name="app home")
        resolved_user_home = _absolute(user_home or Path.home(), name="user home")
        runtime_root = resolved_app_home / "runtime"
        return cls(
            app_home=resolved_app_home,
            runtime_root=runtime_root,
            current_runtime=runtime_root / "current",
            config_directory=resolved_app_home / "config",
            config_file=resolved_app_home / "config" / ".env",
            log_directory=resolved_user_home / "Library" / "Logs" / "SpeechRail",
            plist_path=(
                resolved_user_home / "Library" / "LaunchAgents" / f"{SERVICE_LABEL}.plist"
            ),
        )

    def ensure_directories(self) -> None:
        """Create only user-owned service directories with private permissions."""
        for directory in (
            self.app_home,
            self.config_directory,
            self.runtime_root,
            self.runtime_root / "releases",
            self.log_directory,
            self.plist_path.parent,
        ):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            directory.chmod(0o700)

    def secure_config_file(self) -> None:
        """Restrict an existing environment file to the current user."""
        if not self.config_file.is_file():
            raise FileNotFoundError(self.config_file)
        self.config_file.chmod(0o600)


__all__ = ["ServiceLayout"]
