"""macOS user-service adapter for a single interactive SpeechRail process."""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

SERVICE_LABEL = "com.speechrail"
_THROTTLE_SECONDS = 10

Runner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]


class ServiceError(RuntimeError):
    """Raised when a service lifecycle operation cannot be completed safely."""


class UnsupportedPlatformError(ServiceError):
    """Raised when the macOS-only local service is requested elsewhere."""


def _require_absolute(path: Path, *, name: str) -> Path:
    if not path.is_absolute():
        raise ServiceError(f"{name} must be an absolute path")
    return path.resolve()


@dataclass(frozen=True)
class LaunchAgentDefinition:
    """All non-secret values rendered into a LaunchAgent plist."""

    working_directory: Path
    python_executable: Path
    stdout_path: Path
    stderr_path: Path

    def __post_init__(self) -> None:
        working_directory = _require_absolute(self.working_directory, name="working directory")
        python_executable = _require_absolute(self.python_executable, name="python executable")
        stdout_path = _require_absolute(self.stdout_path, name="stdout path")
        stderr_path = _require_absolute(self.stderr_path, name="stderr path")
        if not working_directory.is_dir():
            raise ServiceError("working directory must exist")
        if not python_executable.is_file():
            raise ServiceError("python executable must exist and be a file")
        object.__setattr__(self, "working_directory", working_directory)
        object.__setattr__(self, "python_executable", python_executable)
        object.__setattr__(self, "stdout_path", stdout_path)
        object.__setattr__(self, "stderr_path", stderr_path)

    def to_plist(self) -> bytes:
        """Render a portable XML plist without copying the environment or secrets."""
        return plistlib.dumps(
            {
                "Label": SERVICE_LABEL,
                "ProgramArguments": [
                    str(self.python_executable),
                    "-m",
                    "speechrail",
                    "serve",
                ],
                "WorkingDirectory": str(self.working_directory),
                "RunAtLoad": True,
                "KeepAlive": {"SuccessfulExit": False},
                "ThrottleInterval": _THROTTLE_SECONDS,
                "ProcessType": "Interactive",
                "StandardOutPath": str(self.stdout_path),
                "StandardErrorPath": str(self.stderr_path),
            },
            fmt=plistlib.FMT_XML,
            sort_keys=False,
        )


@dataclass(frozen=True)
class LaunchAgentPaths:
    """Filesystem locations owned by the current user's LaunchAgent."""

    plist_path: Path
    log_directory: Path

    def __post_init__(self) -> None:
        object.__setattr__(
            self, "plist_path", _require_absolute(self.plist_path, name="plist path")
        )
        object.__setattr__(
            self, "log_directory", _require_absolute(self.log_directory, name="log directory")
        )


def _run_subprocess(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True)


class LaunchAgentManager:
    """Manage one per-user LaunchAgent without shell interpolation or root access."""

    def __init__(
        self,
        *,
        definition: LaunchAgentDefinition,
        paths: LaunchAgentPaths,
        uid: int,
        runner: Runner = _run_subprocess,
    ) -> None:
        if uid < 0:
            raise ServiceError("uid must be non-negative")
        self.definition = definition
        self.paths = paths
        self.uid = uid
        self._runner = runner

    @property
    def domain(self) -> str:
        return f"gui/{self.uid}"

    @property
    def target(self) -> str:
        return f"{self.domain}/{SERVICE_LABEL}"

    def install(self) -> Path:
        """Write the service definition and logs directory without enabling it."""
        self.paths.plist_path.parent.mkdir(parents=True, exist_ok=True)
        self.paths.log_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.paths.log_directory.chmod(0o700)
        self._write_plist_atomically(self.definition.to_plist())
        return self.paths.plist_path

    def enable(self) -> None:
        """Load then start the installed user service."""
        if not self.paths.plist_path.is_file():
            raise ServiceError("service is not installed; run 'speechrail service install' first")
        self._run(("launchctl", "bootstrap", self.domain, str(self.paths.plist_path)))
        self._run(("launchctl", "kickstart", "-k", self.target))

    def disable(self) -> None:
        """Stop and unload the user service while retaining its plist."""
        self._run(("launchctl", "bootout", self.target))

    def restart(self) -> None:
        """Restart the running service without changing its persisted definition."""
        self._run(("launchctl", "kickstart", "-k", self.target))

    def status(self) -> str:
        """Return launchd's status output for the user service."""
        return self._run(("launchctl", "print", self.target)).stdout

    def uninstall(self) -> None:
        """Unload the service before deleting its plist to avoid an orphaned process."""
        self.disable()
        self.paths.plist_path.unlink(missing_ok=True)

    def _run(self, command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        try:
            completed = self._runner(command)
        except OSError as exc:
            raise ServiceError("launchctl could not be executed") from exc
        if completed.returncode != 0:
            raise ServiceError(f"launchctl operation failed with exit code {completed.returncode}")
        return completed

    def _write_plist_atomically(self, payload: bytes) -> None:
        descriptor, temporary_name = tempfile.mkstemp(
            dir=self.paths.plist_path.parent,
            prefix=f".{SERVICE_LABEL}.",
            suffix=".plist.tmp",
        )
        temporary_path = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            temporary_path.chmod(0o644)
            temporary_path.replace(self.paths.plist_path)
        except Exception:
            temporary_path.unlink(missing_ok=True)
            raise


def create_launch_agent_manager(*, working_directory: Path | None = None) -> LaunchAgentManager:
    """Build the macOS user-service manager from the local repository context."""
    if sys.platform != "darwin":
        raise UnsupportedPlatformError("SpeechRail managed service is supported only on macOS")
    root = (working_directory or Path.cwd()).resolve()
    home = Path.home().resolve()
    log_directory = home / "Library" / "Logs" / "SpeechRail"
    definition = LaunchAgentDefinition(
        working_directory=root,
        python_executable=Path(sys.executable).resolve(),
        stdout_path=log_directory / "stdout.log",
        stderr_path=log_directory / "stderr.log",
    )
    return LaunchAgentManager(
        definition=definition,
        paths=LaunchAgentPaths(
            plist_path=home / "Library" / "LaunchAgents" / f"{SERVICE_LABEL}.plist",
            log_directory=log_directory,
        ),
        uid=os.getuid(),
    )


__all__ = [
    "SERVICE_LABEL",
    "LaunchAgentDefinition",
    "LaunchAgentManager",
    "LaunchAgentPaths",
    "ServiceError",
    "UnsupportedPlatformError",
    "create_launch_agent_manager",
]
