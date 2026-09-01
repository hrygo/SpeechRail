"""Executable command surface for the local SpeechRail runtime."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence

import uvicorn

from speechrail.app import app
from speechrail.config import Settings
from speechrail.service import ServiceError, create_launch_agent_manager


def run_server() -> None:
    """Run one ASGI process with the configured loopback-first settings."""
    settings = Settings()
    uvicorn.run(app, host=settings.host, port=settings.port, log_level="info")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="speechrail", description="SpeechRail local ASR/TTS runtime")
    subcommands = parser.add_subparsers(dest="command")
    subcommands.add_parser("serve", help="start one SpeechRail ASGI process")
    service = subcommands.add_parser("service", help="manage the macOS user LaunchAgent")
    service_commands = service.add_subparsers(dest="service_command", required=True)
    for command in ("install", "enable", "disable", "restart", "status", "uninstall"):
        service_commands.add_parser(command)
    return parser


def _run_service(command: str) -> None:
    manager = create_launch_agent_manager()
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
    if args.command in {None, "serve"}:
        run_server()
        return 0
    try:
        _run_service(args.service_command)
    except ServiceError as exc:
        print(f"SpeechRail service: {exc}", file=sys.stderr)
        return 1
    return 0


__all__ = ["main", "run_server"]
