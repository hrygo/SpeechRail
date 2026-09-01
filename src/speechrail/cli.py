"""Executable command surface for the local SpeechRail runtime."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

import uvicorn

from speechrail.config import Settings
from speechrail.service import (
    PreflightResult,
    ServiceError,
    ServiceLayout,
    create_launch_agent_manager,
    run_preflight,
)


def _discover_env_file() -> Path | None:
    """Prefer the private installed config while keeping source checkout behavior."""
    candidate = Path.cwd() / "config" / ".env"
    return candidate if candidate.is_file() else None


def run_server(env_file: Path | None = None) -> None:
    """Run one ASGI process with an explicit or app-home configuration file."""
    settings = Settings.from_env_file(env_file or _discover_env_file())
    from speechrail.app import create_app

    uvicorn.run(create_app(settings), host=settings.host, port=settings.port, log_level="info")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="speechrail", description="SpeechRail local ASR/TTS runtime"
    )
    subcommands = parser.add_subparsers(dest="command")
    serve = subcommands.add_parser("serve", help="start one SpeechRail ASGI process")
    serve.add_argument("--env-file", type=Path, help="load configuration from this file")
    service = subcommands.add_parser("service", help="manage the macOS user LaunchAgent")
    service_commands = service.add_subparsers(dest="service_command", required=True)
    for command in ("install", "enable", "disable", "restart", "status", "uninstall", "preflight"):
        command_parser = service_commands.add_parser(command)
        command_parser.add_argument(
            "--app-home",
            type=Path,
            help="use this installed app home as the service working directory",
        )
        if command == "preflight":
            command_parser.add_argument(
                "--asr-only",
                action="store_true",
                help="allow the service to run without a configured TTS profile",
            )
    return parser


def _print_preflight(result: PreflightResult) -> None:
    for check in result.checks:
        state = "OK" if check.ok else "FAIL"
        print(f"{state} {check.name}: {check.message}")


def _run_service(command: str, app_home: Path | None = None, asr_only: bool = False) -> None:
    if command == "preflight":
        layout = ServiceLayout.for_app_home(app_home or Path.cwd())
        result = run_preflight(layout, require_tts=not asr_only)
        _print_preflight(result)
        if not result.ok:
            raise ServiceError("preflight failed; service was not enabled")
        return
    if app_home is None:
        manager = create_launch_agent_manager()
    else:
        manager = create_launch_agent_manager(working_directory=app_home)
    if command == "install":
        print(f"Installed LaunchAgent plist: {manager.install()}")
        print("Run 'speechrail service enable' to start SpeechRail.")
        return
    if command == "enable":
        manager.enable()
    elif command == "disable":
        manager.disable()
    elif command == "restart":
        manager.restart()
    elif command == "status":
        print(manager.status(), end="")
        return
    elif command == "uninstall":
        manager.uninstall()
    else:
        raise ServiceError("unknown service command")
    print(f"SpeechRail service {command} completed.")


def main(argv: Sequence[str] | None = None) -> int:
    """Run the console command and return a shell-compatible exit status."""
    args = _parser().parse_args(list(argv) if argv is not None else None)
    if args.command is None:
        run_server()
        return 0
    if args.command == "serve":
        run_server(args.env_file)
        return 0
    try:
        _run_service(
            args.service_command,
            getattr(args, "app_home", None),
            getattr(args, "asr_only", False),
        )
    except ServiceError as exc:
        print(f"SpeechRail service: {exc}", file=sys.stderr)
        return 1
    return 0


__all__ = ["main", "run_server"]
