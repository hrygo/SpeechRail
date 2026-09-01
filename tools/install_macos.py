#!/usr/bin/env python3
"""Install a SpeechRail wheel into a user-owned macOS runtime."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

CommandRunner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]


class InstallerError(RuntimeError):
    """Raised when a wheel installation cannot be completed safely."""


@dataclass(frozen=True)
class InstallLayout:
    app_home: Path
    runtime_root: Path
    current_runtime: Path
    config_file: Path
    log_directory: Path
    plist_path: Path

    @classmethod
    def for_app_home(cls, app_home: Path) -> InstallLayout:
        if not app_home.is_absolute():
            raise InstallerError("app home must be absolute")
        home = Path.home().absolute()
        runtime_root = app_home.absolute() / "runtime"
        return cls(
            app_home=app_home.absolute(),
            runtime_root=runtime_root,
            current_runtime=runtime_root / "current",
            config_file=app_home.absolute() / "config" / ".env",
            log_directory=home / "Library" / "Logs" / "SpeechRail",
            plist_path=home / "Library" / "LaunchAgents" / "com.speechrail.plist",
        )

    def ensure_directories(self) -> None:
        for directory in (
            self.app_home,
            self.config_file.parent,
            self.runtime_root,
            self.runtime_root / "releases",
            self.log_directory,
            self.plist_path.parent,
        ):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            directory.chmod(0o700)


@dataclass(frozen=True)
class InstallResult:
    app_home: Path
    runtime_python: Path
    plist_path: Path
    enabled: bool


@dataclass(frozen=True)
class PreflightOutcome:
    ok: bool


def _runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True)


def _run(command: tuple[str, ...], runner: CommandRunner) -> None:
    try:
        completed = runner(command)
    except OSError as exc:
        raise InstallerError("required local command could not be executed") from exc
    if completed.returncode != 0:
        if command and command[0] == "uv":
            raise InstallerError("uv command failed")
        raise InstallerError("installed service command failed")


def run_preflight(
    runtime_python: Path,
    layout: InstallLayout,
    *,
    require_tts: bool,
    runner: CommandRunner,
) -> PreflightOutcome:
    """Run preflight through the newly installed wheel, not the source tree."""
    command = (
        str(runtime_python),
        "-m",
        "speechrail",
        "service",
        "preflight",
        "--app-home",
        str(layout.app_home),
    )
    if not require_tts:
        command += ("--asr-only",)
    try:
        completed = runner(command)
    except OSError as exc:
        raise InstallerError("installed wheel preflight could not be executed") from exc
    return PreflightOutcome(ok=completed.returncode == 0)


def _copy_config(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(dir=destination.parent, prefix=".env.")
    temporary_path = Path(temporary_name)
    try:
        os.close(descriptor)
        shutil.copyfile(source, temporary_path)
        temporary_path.chmod(0o600)
        temporary_path.replace(destination)
    except Exception:
        temporary_path.unlink(missing_ok=True)
        raise


def _switch_current(layout: InstallLayout, release_dir: Path) -> Path | None:
    if layout.current_runtime.exists() and not layout.current_runtime.is_symlink():
        raise InstallerError("runtime/current must be a symlink")
    old_target = layout.current_runtime.readlink() if layout.current_runtime.is_symlink() else None
    temporary_link = layout.runtime_root / ".current.new"
    temporary_link.unlink(missing_ok=True)
    temporary_link.symlink_to(release_dir, target_is_directory=True)
    temporary_link.replace(layout.current_runtime)
    return old_target


def _restore_current(layout: InstallLayout, old_target: Path | None) -> None:
    if layout.current_runtime.is_symlink():
        layout.current_runtime.unlink()
    if old_target is not None:
        layout.current_runtime.symlink_to(old_target, target_is_directory=True)


def _release_id(wheel: Path) -> str:
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()[:12]
    return f"{wheel.stem}-{digest}"


def install_wheel(
    wheel: Path,
    *,
    app_home: Path,
    env_file: Path,
    uv_executable: str = "uv",
    require_tts: bool = True,
    enable: bool = False,
    runner: CommandRunner = _runner,
) -> InstallResult:
    """Stage, validate and optionally enable one wheel-based installation."""
    if not wheel.is_file() or wheel.suffix != ".whl":
        raise InstallerError("wheel file is missing or invalid")
    if not env_file.is_file():
        raise InstallerError("configuration file is missing")

    layout = InstallLayout.for_app_home(app_home)
    layout.ensure_directories()
    config_created = False
    if layout.config_file.exists():
        if layout.config_file.absolute() != env_file.absolute():
            raise InstallerError("configuration already exists and will not be overwritten")
    else:
        _copy_config(env_file, layout.config_file)
        config_created = True

    release_dir = layout.runtime_root / "releases" / _release_id(wheel)
    if release_dir.exists():
        if config_created:
            layout.config_file.unlink(missing_ok=True)
        raise InstallerError("this wheel is already staged")
    release_dir.mkdir(parents=True)
    venv_dir = release_dir / ".venv"
    runtime_python = venv_dir / "bin" / "python"
    try:
        _run((uv_executable, "venv", "--python", "3.12", str(venv_dir)), runner)
        _run((uv_executable, "pip", "install", "--python", str(runtime_python), str(wheel)), runner)
        result = run_preflight(
            runtime_python, layout, require_tts=require_tts, runner=runner
        )
        if not result.ok:
            raise InstallerError("preflight failed; service was not enabled")

        old_target = _switch_current(layout, release_dir)
        try:
            current_python = layout.current_runtime / ".venv" / "bin" / "python"
            _run(
                (
                    str(current_python),
                    "-m",
                    "speechrail",
                    "service",
                    "install",
                    "--app-home",
                    str(layout.app_home),
                ),
                runner,
            )
            if enable:
                _run(
                    (
                        str(current_python),
                        "-m",
                        "speechrail",
                        "service",
                        "enable",
                        "--app-home",
                        str(layout.app_home),
                    ),
                    runner,
                )
        except Exception:
            _restore_current(layout, old_target)
            raise
        return InstallResult(
            app_home=layout.app_home,
            runtime_python=runtime_python,
            plist_path=layout.plist_path,
            enabled=enable,
        )
    except Exception:
        if (
            layout.current_runtime.is_symlink()
            and layout.current_runtime.resolve() == release_dir.resolve()
        ):
            layout.current_runtime.unlink()
        shutil.rmtree(release_dir, ignore_errors=True)
        if config_created:
            layout.config_file.unlink(missing_ok=True)
        raise


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Install a SpeechRail wheel on macOS")
    parser.add_argument("--wheel", type=Path, required=True)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument(
        "--app-home",
        type=Path,
        default=Path.home() / "Library" / "Application Support" / "SpeechRail",
    )
    parser.add_argument("--uv", default="uv", dest="uv_executable")
    parser.add_argument("--asr-only", action="store_true")
    parser.add_argument("--enable", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = install_wheel(
            args.wheel,
            app_home=args.app_home,
            env_file=args.env_file,
            uv_executable=args.uv_executable,
            require_tts=not args.asr_only,
            enable=args.enable,
        )
    except InstallerError as exc:
        print(f"SpeechRail installer: {exc}", file=sys.stderr)
        return 1
    print(f"Installed SpeechRail runtime at {result.app_home}")
    print(f"LaunchAgent enabled: {result.enabled}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
