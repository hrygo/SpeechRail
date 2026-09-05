"""Executable command surface for the local SpeechRail runtime."""

from __future__ import annotations

import argparse
import os
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
    effective_env = env_file or _discover_env_file()
    settings = Settings.from_env_file(effective_env)
    app_home = (effective_env.parent.parent if effective_env else Path.cwd()).resolve()

    from speechrail.config.model_catalog import load_catalog
    from speechrail.config.selection import resolve_selection
    from speechrail.service.profile_store import claim_startup_selection

    selection = claim_startup_selection(app_home)
    if selection is not None:
        settings = resolve_selection(settings, selection, load_catalog(), app_home)

    from speechrail.app import create_app

    uvicorn.run(create_app(settings), host=settings.host, port=settings.port, log_level="info")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="speechrail", description="SpeechRail local ASR/TTS runtime"
    )
    subcommands = parser.add_subparsers(dest="command")
    serve = subcommands.add_parser("serve", help="start one SpeechRail ASGI process")
    serve.add_argument("--env-file", type=Path, help="load configuration from this file")

    setup = subcommands.add_parser(
        "setup", help="choose and apply a three-tier model profile"
    )
    setup.add_argument(
        "--preset", choices=("quality", "balanced", "light"), help="override the recommendation"
    )
    setup.add_argument("--app-home", type=Path, help="use this installed app home")
    setup.add_argument("--yes", action="store_true", help="apply without an interactive prompt")

    profile = subcommands.add_parser("profile", help="inspect or switch model profiles")
    profile_commands = profile.add_subparsers(dest="profile_command", required=True)
    for command in ("list", "status"):
        command_parser = profile_commands.add_parser(command)
        command_parser.add_argument("--app-home", type=Path, help="use this installed app home")
    apply = profile_commands.add_parser("apply")
    apply.add_argument("preset", choices=("quality", "balanced", "light"))
    apply.add_argument("--app-home", type=Path, help="use this installed app home")
    apply.add_argument("--yes", action="store_true", help="apply without an interactive prompt")
    rollback = profile_commands.add_parser("rollback")
    rollback.add_argument("--app-home", type=Path, help="use this installed app home")
    rollback.add_argument(
        "--yes", action="store_true", help="roll back without an interactive prompt"
    )

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


def _default_app_home() -> Path:
    return Path.home() / "Library" / "Application Support" / "SpeechRail"


def _physical_memory_bytes() -> int:
    """Return installed physical memory without identifying a machine model."""
    try:
        pages = os.sysconf("SC_PHYS_PAGES")
        page_size = os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError) as exc:
        raise ServiceError("could not determine physical memory") from exc
    if not isinstance(pages, int) or not isinstance(page_size, int) or min(pages, page_size) <= 0:
        raise ServiceError("could not determine physical memory")
    return pages * page_size


def _format_bytes(size: int) -> str:
    return f"{size / 1024**3:.1f} GiB"


def _confirm(assume_yes: bool) -> bool:
    if assume_yes:
        return True
    if not sys.stdin.isatty():
        print("Non-interactive use requires --yes.", file=sys.stderr)
        return False
    try:
        answer = input("Continue? [y/N] ")
    except EOFError:
        return False
    return answer.strip().lower() in {"y", "yes"}


def _print_apply_result(result: object) -> int:
    status = getattr(result, "status", "not_ready")
    if status == "unchanged":
        print("Profile is already active.")
        return 0
    if status == "committed":
        print("Profile applied and public API smoke passed.")
        return 0
    if status == "rolled_back":
        print("Profile smoke failed; the previous profile was restored.", file=sys.stderr)
        return 1
    print("Profile switch failed and the service is not ready.", file=sys.stderr)
    return 1


def _run_profile(args: argparse.Namespace) -> int:
    from speechrail.service import profile_commands

    app_home = (args.app_home or _default_app_home()).resolve()
    if args.profile_command == "list":
        current = profile_commands.profile_status(app_home).preset
        for item in profile_commands.list_profiles():
            marker = " *" if item.id == current else ""
            print(
                f"{item.id}{marker}: ASR={item.asr}, TTS={item.tts}, "
                f"download={_format_bytes(item.download_bytes)}"
            )
        return 0
    if args.profile_command == "status":
        status = profile_commands.profile_status(app_home)
        if status.preset is None:
            print("Profile: unconfigured")
        else:
            print(
                f"Profile: {status.preset} (generation {status.generation}, "
                f"ASR={status.asr}, TTS={status.tts})"
            )
        return 0
    if args.profile_command == "apply":
        summary = next(item for item in profile_commands.list_profiles() if item.id == args.preset)
        print(
            f"Apply profile '{summary.id}' "
            f"(up to {_format_bytes(summary.download_bytes)} download)."
        )
        if not _confirm(args.yes):
            print("Cancelled.")
            return 1
        return _print_apply_result(profile_commands.apply_profile(args.preset, app_home=app_home))
    if args.profile_command == "rollback":
        print("Restore the previously committed profile.")
        if not _confirm(args.yes):
            print("Cancelled.")
            return 1
        return _print_apply_result(profile_commands.rollback_profile(app_home=app_home))
    raise ServiceError("unknown profile command")


def _run_setup(args: argparse.Namespace) -> int:
    from speechrail.service import profile_commands

    app_home = (args.app_home or _default_app_home()).resolve()
    current = profile_commands.profile_status(app_home)
    if args.preset is None and current.preset is not None:
        print(f"Profile already configured: {current.preset}")
        return 0
    preset = args.preset or profile_commands.recommend_profile(_physical_memory_bytes())
    if args.preset is None:
        print(f"Recommended profile by physical memory: {preset}")
    else:
        print(f"Selected profile: {preset}")
    summary = next(item for item in profile_commands.list_profiles() if item.id == preset)
    print(
        f"ASR={summary.asr}, TTS={summary.tts}, "
        f"download up to {_format_bytes(summary.download_bytes)}."
    )
    if not _confirm(args.yes):
        print("Cancelled.")
        return 1
    return _print_apply_result(profile_commands.apply_profile(preset, app_home=app_home))


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
        if args.command == "service":
            _run_service(
                args.service_command,
                getattr(args, "app_home", None),
                getattr(args, "asr_only", False),
            )
            return 0
        if args.command == "profile":
            return _run_profile(args)
        if args.command == "setup":
            return _run_setup(args)
        raise ServiceError("unknown command")
    except (ServiceError, RuntimeError, ValueError) as exc:
        prefix = "SpeechRail service" if args.command == "service" else "SpeechRail"
        print(f"{prefix}: {exc}", file=sys.stderr)
        return 1


__all__ = ["main", "run_server"]
