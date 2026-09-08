"""Executable command surface for the local SpeechRail runtime."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

import uvicorn

from speechrail.config import Settings
from speechrail.config.auth import resolve_api_key
from speechrail.runtime.server_lock import ServerInstanceLock
from speechrail.service import (
    PreflightResult,
    ServiceError,
    ServiceLayout,
    create_launch_agent_manager,
    run_preflight,
)
from speechrail.service.profile_switch import LaunchAgentServiceController


def _discover_env_file() -> Path | None:
    """Prefer the private installed config while keeping source checkout behavior."""
    candidate = Path.cwd() / "config" / ".env"
    return candidate if candidate.is_file() else None


def run_server(env_file: Path | None = None, app_home: Path | None = None) -> None:
    """Run one ASGI process with an explicit or app-home configuration file."""
    if app_home is None:
        effective_env = env_file or _discover_env_file()
        app_home = (effective_env.parent.parent if effective_env else Path.cwd()).resolve()
    else:
        app_home = Path(app_home).resolve()
        candidate_env = app_home / "config" / ".env"
        effective_env = env_file or (candidate_env if candidate_env.is_file() else None)
    settings = Settings.from_env_file(effective_env)

    from speechrail.config.model_catalog import load_catalog
    from speechrail.config.selection import resolve_selection
    from speechrail.service.profile_store import claim_startup_selection

    selection = claim_startup_selection(app_home)
    if selection is not None:
        settings = resolve_selection(settings, selection, load_catalog(), app_home)

    from speechrail.app import create_app

    with ServerInstanceLock(settings.port):
        uvicorn.run(create_app(settings), host=settings.host, port=settings.port, log_level="info")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="speechrail", description="SpeechRail local ASR/TTS runtime"
    )
    subcommands = parser.add_subparsers(dest="command")
    serve = subcommands.add_parser("serve", help="start one SpeechRail ASGI process")
    serve.add_argument("--env-file", type=Path, help="load configuration from this file")
    serve.add_argument(
        "--app-home", type=Path, help="use this installed app home's private configuration"
    )

    diagnose = subcommands.add_parser(
        "diagnose", help="read a safe capability snapshot from a running local service"
    )
    diagnose.add_argument("--base-url", default="http://127.0.0.1:8201")
    diagnose.add_argument("--timeout", type=float, default=5.0)
    diagnose.add_argument(
        "--app-home", type=Path, help="managed app home used for automatic API-key discovery"
    )

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
    for command in (
        "install",
        "start",
        "stop",
        "enable",
        "disable",
        "restart",
        "status",
        "uninstall",
        "preflight",
    ):
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
            command_parser.add_argument(
                "--host-python",
                type=Path,
                help="probe optional service dependencies with this Python executable",
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


def _service_port(app_home: Path | None) -> int:
    """Load the configured port for controller-backed lifecycle operations."""
    if app_home is None:
        return 8201
    layout = ServiceLayout.for_app_home(app_home)
    if not layout.config_file.is_file():
        return 8201
    return Settings.from_env_file(layout.config_file).port


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


def _diagnostic_base_url(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme not in {"http", "https"}
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ServiceError("diagnose requires an HTTP base URL without credentials or query")
    return value.rstrip("/")


def _diagnostic_json(
    url: str, *, timeout: float, app_home: Path | None = None
) -> object:
    if timeout <= 0:
        raise ServiceError("diagnose timeout must be positive")
    headers = {"Accept": "application/json"}
    api_key = resolve_api_key(app_home=app_home)
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = Request(url, headers=headers)
    try:
        with urlopen(request, timeout=timeout) as response:
            if response.status != 200:
                raise ServiceError("diagnose service returned a non-success status")
            return json.loads(response.read().decode("utf-8"))
    except ServiceError:
        raise
    except (HTTPError, URLError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ServiceError(
            "diagnose could not read the service; run 'speechrail service status' and "
            "'speechrail service preflight'"
        ) from exc


def _diagnostic_snapshot(
    health: object, models: object, voices: object
) -> dict[str, object]:
    if not isinstance(health, dict):
        raise ServiceError("diagnose received an invalid health payload")
    raw_models = models.get("data") if isinstance(models, dict) else None
    raw_voices = voices.get("data") if isinstance(voices, dict) else None
    model_rows = raw_models if isinstance(raw_models, list) else []
    voice_rows = raw_voices if isinstance(raw_voices, list) else []
    mode_counts: dict[str, int] = {}
    available_voice_count = 0
    for voice in voice_rows:
        if not isinstance(voice, dict):
            continue
        mode = voice.get("mode")
        if isinstance(mode, str):
            mode_counts[mode] = mode_counts.get(mode, 0) + 1
        if voice.get("available") is True:
            available_voice_count += 1

    readiness = {
        name: health.get(f"{name}_ready") is True
        for name in ("asr", "tts", "diarization")
    }
    recovery: list[str] = []
    if not readiness["asr"] or not readiness["tts"]:
        recovery.append("speechrail service preflight")
    if not all(readiness.values()):
        recovery.append("speechrail profile status")
    recovery.append("GET /health")
    return {
        "status": health.get("status"),
        "profile": health.get("profile"),
        "readiness": readiness,
        "worker_state": {
            name: health.get(f"{name}_state")
            for name in ("asr", "tts", "streaming")
        },
        "tts_lifecycle": health.get("tts_lifecycle")
        if isinstance(health.get("tts_lifecycle"), dict)
        else None,
        "realtime_vad": health.get("realtime_vad")
        if isinstance(health.get("realtime_vad"), dict)
        else None,
        "diarization": health.get("diarization")
        if isinstance(health.get("diarization"), dict)
        else None,
        "models": {
            "count": len(model_rows),
            "ids": [
                item["id"]
                for item in model_rows
                if isinstance(item, dict) and isinstance(item.get("id"), str)
            ],
        },
        "voices": {"available_count": available_voice_count, "mode_counts": mode_counts},
        "last_smoke": {"status": "unset"},
        "recovery": recovery,
    }


def _run_diagnose(args: argparse.Namespace) -> int:
    base_url = _diagnostic_base_url(args.base_url)
    health = _diagnostic_json(
        f"{base_url}/health", timeout=args.timeout, app_home=args.app_home
    )
    models = _diagnostic_json(
        f"{base_url}/v1/models", timeout=args.timeout, app_home=args.app_home
    )
    voices = _diagnostic_json(
        f"{base_url}/v1/voices", timeout=args.timeout, app_home=args.app_home
    )
    print(json.dumps(_diagnostic_snapshot(health, models, voices), sort_keys=True))
    return 0


def _print_preflight(result: PreflightResult) -> None:
    for check in result.checks:
        state = "OK" if check.ok else "FAIL"
        print(f"{state} {check.name}: {check.message}")


def _venv_roots(executable: Path) -> frozenset[Path]:
    roots: set[Path] = set()
    for candidate in (executable.absolute(), executable.resolve()):
        roots.update(parent for parent in candidate.parents if parent.name == ".venv")
    return frozenset(roots)


def _managed_service_python(app_home: Path) -> Path | None:
    """Return the active managed interpreter when the CLI is running elsewhere."""

    candidate = ServiceLayout.for_app_home(app_home).current_python
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        return None
    try:
        if _venv_roots(candidate) & _venv_roots(Path(sys.executable)):
            return None
    except (OSError, RuntimeError):
        return None
    return candidate


def _delegate_service_command(
    command: str,
    app_home: Path,
    *,
    managed_python: Path,
    asr_only: bool,
    host_python: Path | None,
) -> int:
    command_args = [
        str(managed_python),
        "-I",
        "-m",
        "speechrail",
        "service",
        command,
        "--app-home",
        str(app_home),
    ]
    if command == "preflight" and asr_only:
        command_args.append("--asr-only")
    if command == "preflight" and host_python is not None:
        command_args.extend(("--host-python", str(host_python)))
    try:
        completed = subprocess.run(tuple(command_args), check=False)
    except OSError as exc:
        raise ServiceError("managed service runtime could not be executed") from exc
    return completed.returncode


def _run_service(
    command: str,
    app_home: Path | None = None,
    asr_only: bool = False,
    host_python: Path | None = None,
) -> int | None:
    if app_home is not None:
        resolved_app_home = app_home.expanduser().absolute()
        layout = ServiceLayout.for_app_home(resolved_app_home)
        managed_python = _managed_service_python(resolved_app_home)
        if managed_python is not None:
            return _delegate_service_command(
                command,
                resolved_app_home,
                managed_python=managed_python,
                asr_only=asr_only,
                host_python=host_python,
            )
        if (
            (layout.current_runtime.exists() or layout.current_runtime.is_symlink())
            and (
                not layout.current_python.is_file()
                or not os.access(layout.current_python, os.X_OK)
            )
        ):
            raise ServiceError("managed runtime Python is missing or not executable")
    if command == "preflight":
        layout = ServiceLayout.for_app_home(app_home or Path.cwd())
        managed_python = layout.current_python
        result = run_preflight(
            layout,
            require_tts=not asr_only,
            host_python=(
                host_python
                or (managed_python if managed_python.is_file() else None)
            ),
        )
        _print_preflight(result)
        if not result.ok:
            raise ServiceError("preflight failed; service state unchanged")
        return None
    if app_home is None:
        manager = create_launch_agent_manager()
    else:
        manager = create_launch_agent_manager(working_directory=app_home)
    if command == "install":
        print(f"Installed LaunchAgent plist: {manager.install()}")
        print("Run 'speechrail service start' to start SpeechRail.")
        return None
    if command in {"start", "enable", "stop", "disable", "restart"}:
        controller = LaunchAgentServiceController(manager, port=_service_port(app_home))
    else:
        controller = None
    if command in {"start", "enable"}:
        assert controller is not None
        controller.start()
    elif command in {"stop", "disable"}:
        assert controller is not None
        controller.stop()
    elif command == "restart":
        assert controller is not None
        controller.restart()
    elif command == "status":
        print(manager.status(), end="")
        return None
    elif command == "uninstall":
        manager.uninstall()
    else:
        raise ServiceError("unknown service command")
    print(f"SpeechRail service {command} completed.")
    return None


def main(argv: Sequence[str] | None = None) -> int:
    """Run the console command and return a shell-compatible exit status."""
    args = _parser().parse_args(list(argv) if argv is not None else None)
    try:
        if args.command is None:
            run_server()
            return 0
        if args.command == "serve":
            run_server(args.env_file, getattr(args, "app_home", None))
            return 0
        if args.command == "diagnose":
            return _run_diagnose(args)
        if args.command == "service":
            service_result = _run_service(
                args.service_command,
                getattr(args, "app_home", None),
                getattr(args, "asr_only", False),
                getattr(args, "host_python", None),
            )
            return 0 if service_result is None else service_result
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
