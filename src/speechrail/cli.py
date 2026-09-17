"""Executable command surface for the local SpeechRail runtime."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

import uvicorn

from speechrail.config import Settings
from speechrail.config.auth import resolve_api_key
from speechrail.observability.logging import configure_logging, default_log_directory
from speechrail.observability.rollup import default_rollup_path
from speechrail.runtime.server_lock import ServerInstanceLock
from speechrail.service import (
    PreflightResult,
    ServiceError,
    ServiceLayout,
    create_launch_agent_manager,
    run_preflight,
)
from speechrail.service.profile_switch import LaunchAgentServiceController

_MACHINE_SCHEMA_VERSION = 1


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

    _apply_observability_defaults(settings, app_home)
    logging_handles = configure_logging(settings.log_dir or default_log_directory())
    if logging_handles is not None:
        logging.getLogger(__name__).info(
            "SpeechRail logs: service=%s access=%s",
            logging_handles.service_log,
            logging_handles.access_log,
        )

    from speechrail.app import create_app

    with ServerInstanceLock(settings.port):
        # ``log_config=None`` keeps uvicorn out of the logging configuration: its
        # loggers inherit the rotating handlers installed above instead of
        # writing to the LaunchAgent's unrotated stdout/stderr files.
        uvicorn.run(
            create_app(settings),
            host=settings.host,
            port=settings.port,
            log_level="info",
            log_config=None,
        )


def _apply_observability_defaults(settings: Settings, app_home: Path) -> None:
    """Fill in the telemetry locations that depend on the runtime layout.

    The rollup directory is only implied for an installed runtime: a source
    checkout must never write a rolling history into the working tree, so there
    it stays opt-in through ``SPEECHRAIL_METRICS_ROLLUP_DIR``.
    """
    if (
        settings.metrics_rollup_enabled
        and settings.metrics_rollup_dir is None
        and ServiceLayout.for_app_home(app_home).current_runtime.exists()
    ):
        settings.metrics_rollup_dir = default_rollup_path(app_home)


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

    install = subcommands.add_parser(
        "install",
        help="install a release wheel as the user runtime without a source checkout",
    )
    install.add_argument(
        "--wheel",
        type=Path,
        help="release wheel to install; defaults to the only speechrail-*.whl in this directory",
    )
    install.add_argument(
        "--preset", choices=("quality", "balanced", "light"), help="override the recommendation"
    )
    install.add_argument("--app-home", type=Path, help="use this installed app home")
    install.add_argument("--yes", action="store_true", help="install without an interactive prompt")
    install.add_argument(
        "--enable",
        action="store_true",
        help="register and start the com.speechrail LaunchAgent after preflight passes",
    )
    install.add_argument(
        "--json", action="store_true", help="emit one machine-readable JSON envelope"
    )

    profile = subcommands.add_parser("profile", help="inspect or switch model profiles")
    profile_commands = profile.add_subparsers(dest="profile_command", required=True)
    for command in ("list", "status"):
        command_parser = profile_commands.add_parser(command)
        command_parser.add_argument("--app-home", type=Path, help="use this installed app home")
        command_parser.add_argument(
            "--json", action="store_true", help="emit one machine-readable JSON envelope"
        )
    apply = profile_commands.add_parser("apply")
    apply.add_argument("preset", choices=("quality", "balanced", "light"))
    apply.add_argument("--app-home", type=Path, help="use this installed app home")
    apply.add_argument("--yes", action="store_true", help="apply without an interactive prompt")
    apply.add_argument(
        "--json", action="store_true", help="emit one machine-readable JSON envelope"
    )
    rollback = profile_commands.add_parser("rollback")
    rollback.add_argument("--app-home", type=Path, help="use this installed app home")
    rollback.add_argument(
        "--yes", action="store_true", help="roll back without an interactive prompt"
    )
    rollback.add_argument(
        "--json", action="store_true", help="emit one machine-readable JSON envelope"
    )

    model = subcommands.add_parser("model", help="inspect or prepare locked model artifacts")
    model_commands = model.add_subparsers(dest="model_command", required=True)
    for command in ("catalog", "status"):
        command_parser = model_commands.add_parser(command)
        command_parser.add_argument("--app-home", type=Path, help="use this installed app home")
        command_parser.add_argument(
            "--json", action="store_true", help="emit one machine-readable JSON envelope"
        )
    prepare = model_commands.add_parser("prepare")
    prepare.add_argument("preset", choices=("quality", "balanced", "light"))
    prepare.add_argument("--app-home", type=Path, help="use this installed app home")
    prepare.add_argument("--yes", action="store_true", help="prepare without an interactive prompt")
    prepare.add_argument(
        "--json", action="store_true", help="emit JSONL progress and one result envelope"
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
        command_parser.add_argument(
            "--json", action="store_true", help="emit one machine-readable JSON envelope"
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


def _print_machine(payload: dict[str, object]) -> None:
    envelope = {"schema_version": _MACHINE_SCHEMA_VERSION, **payload}
    print(json.dumps(envelope, sort_keys=True))


def _machine_command(args: argparse.Namespace) -> str:
    if args.command == "service":
        return f"service.{args.service_command}"
    if args.command == "profile":
        return f"profile.{args.profile_command}"
    if args.command == "model":
        return f"model.{args.model_command}"
    return str(args.command)


def _machine_error_code(exc: BaseException) -> str:
    message = str(exc).lower()
    if "insufficient disk space" in message or "disk space" in message:
        return "insufficient_disk_space"
    if (
        "integrity" in message
        or "hash" in message
        or "verify" in message
        or "manifest" in message
        or "mismatch" in message
    ):
        return "integrity_mismatch"
    if "download" in message or "model source" in message:
        return "download_failed"
    if "model" in message and ("unavailable" in message or "missing" in message):
        return "model_unavailable"
    if "managed runtime" in message:
        return "managed_runtime_missing"
    if "backend_busy" in message:
        return "backend_busy"
    if "in progress" in message or "already running" in message:
        return "operation_in_progress"
    if "unsupported" in message or "only on macos" in message:
        return "unsupported"
    if "invalid" in message:
        return "invalid_request"
    if "not installed" in message or ("service" in message and "launchctl" in message):
        return "service_unavailable"
    return "command_failed"


def _machine_message(value: object) -> str:
    """Keep machine errors short and free of paths or common secret values."""
    message = str(value)
    message = re.sub(
        r"(?i)\b(api[_-]?key|authorization|token|secret|password)\b\s*[:=]\s*\S+",
        r"\1=[redacted]",
        message,
    )
    message = re.sub(r"(?<![:\w])/[^\s\"']+", "[path]", message)
    return message[:240]


def _print_apply_result(
    result: object, *, machine_output: bool = False, command: str = "profile.apply"
) -> int:
    status = getattr(result, "status", "not_ready")
    default_messages: dict[str, str] = {
        "unchanged": "profile is already active",
        "committed": "profile applied and public API smoke passed",
        "rolled_back": "profile smoke failed; the previous profile was restored",
        "not_ready": "profile switch failed and the service is not ready",
    }
    message = getattr(result, "message", None) or default_messages.get(status)
    if machine_output:
        _print_machine(
            {
                "command": command,
                "error_code": getattr(result, "error_code", None),
                "message": message,
                "operation_id": getattr(result, "operation_id", None),
                "status": status,
            }
        )
        return 0 if status in {"unchanged", "committed"} else 1
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
    machine_output = bool(getattr(args, "json", False))
    if args.profile_command == "list":
        current = profile_commands.profile_status(app_home).preset
        profiles = profile_commands.list_profiles()
        if machine_output:
            _print_machine(
                {
                    "command": "profile.list",
                    "current": current,
                    "profiles": [
                        {
                            "aligner": item.aligner,
                            "asr": item.asr,
                            "download_bytes": item.download_bytes,
                            "id": item.id,
                            "tts": item.tts,
                        }
                        for item in profiles
                    ],
                    "status": "ok",
                }
            )
            return 0
        for item in profiles:
            marker = " *" if item.id == current else ""
            print(
                f"{item.id}{marker}: ASR={item.asr}, TTS={item.tts}, "
                f"download={_format_bytes(item.download_bytes)}"
            )
        return 0
    if args.profile_command == "status":
        status = profile_commands.profile_status(app_home)
        if machine_output:
            _print_machine(
                {
                    "asr": status.asr,
                    "command": "profile.status",
                    "generation": status.generation,
                    "preset": status.preset,
                    "status": "ok",
                    "tts": status.tts,
                }
            )
            return 0
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
        if not machine_output:
            print(
                f"Apply profile '{summary.id}' "
                f"(up to {_format_bytes(summary.download_bytes)} download)."
            )
        if not _confirm(args.yes):
            if machine_output:
                _print_machine(
                    {
                        "command": "profile.apply",
                        "error_code": "confirmation_required",
                        "operation_id": None,
                        "status": "cancelled",
                    }
                )
            else:
                print("Cancelled.")
            return 1
        managed_python = _managed_runtime_for_mutation(app_home)
        if managed_python is not None:
            command_args: tuple[str, ...] = ("profile", "apply", args.preset, "--yes")
            if machine_output:
                command_args += ("--json",)
            return _delegate_managed_command(
                command_args,
                app_home,
                managed_python=managed_python,
            )
        return _print_apply_result(
            profile_commands.apply_profile(args.preset, app_home=app_home),
            machine_output=machine_output,
        )
    if args.profile_command == "rollback":
        if not machine_output:
            print("Restore the previously committed profile.")
        if not _confirm(args.yes):
            if machine_output:
                _print_machine(
                    {
                        "command": "profile.rollback",
                        "error_code": "confirmation_required",
                        "operation_id": None,
                        "status": "cancelled",
                    }
                )
            else:
                print("Cancelled.")
            return 1
        managed_python = _managed_runtime_for_mutation(app_home)
        if managed_python is not None:
            command_args = ("profile", "rollback", "--yes")
            if machine_output:
                command_args += ("--json",)
            return _delegate_managed_command(
                command_args,
                app_home,
                managed_python=managed_python,
            )
        return _print_apply_result(
            profile_commands.rollback_profile(app_home=app_home),
            machine_output=machine_output,
            command="profile.rollback",
        )
    raise ServiceError("unknown profile command")


def _run_model(args: argparse.Namespace) -> int:
    from speechrail.config.model_catalog import load_catalog, load_runtime_lock
    from speechrail.service import model_commands

    app_home = (args.app_home or _default_app_home()).resolve()
    machine_output = bool(getattr(args, "json", False))
    if args.model_command == "catalog":
        payload = model_commands.model_catalog_payload(catalog=load_catalog())
        if machine_output:
            print(json.dumps(payload, sort_keys=True))
            return 0
        artifacts = payload.get("artifacts")
        if not isinstance(artifacts, list):
            raise ServiceError("model catalog returned invalid artifacts")
        for artifact in artifacts:
            if not isinstance(artifact, dict):
                continue
            print(
                f"{artifact['key']}: {artifact['variant']} / {artifact['quantization']['format']} "
                f"({_format_bytes(int(artifact['size_bytes']))})"
            )
        return 0
    if args.model_command == "status":
        payload = model_commands.model_status_payload(app_home, catalog=load_catalog())
        if machine_output:
            print(json.dumps(payload, sort_keys=True))
            return 0
        disk = payload.get("disk")
        if not isinstance(disk, dict):
            raise ServiceError("model status returned invalid disk information")
        print(
            f"Models: {_format_bytes(int(disk['model_bytes']))} on disk, "
            f"{_format_bytes(int(disk['free_bytes']))} free"
        )
        artifacts = payload.get("artifacts")
        if not isinstance(artifacts, list):
            raise ServiceError("model status returned invalid artifacts")
        for artifact in artifacts:
            if not isinstance(artifact, dict):
                continue
            print(
                f"{artifact['key']}: {artifact['state']} "
                f"({artifact['verified_file_count']}/{artifact['total_file_count']} files)"
            )
        return 0
    if args.model_command == "prepare":
        if not _confirm(args.yes):
            if machine_output:
                _print_machine(
                    {
                        "command": "model.prepare",
                        "event": "result",
                        "error_code": "confirmation_required",
                        "message": "model preparation requires confirmation",
                        "status": "cancelled",
                    }
                )
            else:
                print("Cancelled.")
            return 1

        managed_python = _managed_runtime_for_mutation(app_home)
        if managed_python is not None:
            command_args: tuple[str, ...] = ("model", "prepare", args.preset, "--yes")
            if machine_output:
                command_args += ("--json",)
            return _delegate_managed_command(
                command_args,
                app_home,
                managed_python=managed_python,
            )

        import httpx

        from speechrail.service.modelscope import ModelScopeDownloader

        def progress(event: dict[str, object]) -> None:
            if machine_output:
                _print_machine({"event": "progress", "command": "model.prepare", **event})
            else:
                phase = event.get("phase", "preparing")
                artifact = event.get("artifact")
                suffix = f" ({artifact})" if isinstance(artifact, str) else ""
                print(f"{phase}{suffix}")

        timeout = httpx.Timeout(connect=30.0, read=300.0, write=30.0, pool=30.0)
        cancel_event = asyncio.Event()
        previous_sigterm = signal.getsignal(signal.SIGTERM)

        def request_cancel(_signum: int, _frame: object) -> None:
            cancel_event.set()
            raise KeyboardInterrupt

        signal.signal(signal.SIGTERM, request_cancel)
        try:
            with httpx.Client(timeout=timeout) as client:
                prepared_id = asyncio.run(
                    model_commands.prepare_profile_models(
                        args.preset,
                        app_home,
                        progress=progress,
                        downloader=ModelScopeDownloader(client=client),
                        catalog=load_catalog(),
                        runtime_lock=load_runtime_lock(),
                        cancel_event=cancel_event,
                    )
                )
        except KeyboardInterrupt:
            if machine_output:
                _print_machine(
                    {
                        "event": "result",
                        "command": "model.prepare",
                        "error_code": "cancelled",
                        "message": "model preparation was cancelled",
                        "status": "cancelled",
                    }
                )
            else:
                print("Cancelled.")
            return 130
        finally:
            signal.signal(signal.SIGTERM, previous_sigterm)
        if machine_output:
            _print_machine(
                {
                    "event": "result",
                    "command": "model.prepare",
                    "prepared_id": prepared_id,
                    "status": "committed",
                }
            )
        else:
            print(f"Model preparation committed: {prepared_id}")
        return 0
    raise ServiceError("unknown model command")


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
    managed_python = _managed_runtime_for_mutation(app_home)
    if managed_python is not None:
        return _delegate_managed_command(
            ("setup", "--preset", preset, "--yes"),
            app_home,
            managed_python=managed_python,
        )
    return _print_apply_result(profile_commands.apply_profile(preset, app_home=app_home))


def _wheel_metadata_version(wheel: Path) -> str:
    """Read the wheel's own METADATA version instead of trusting its file name."""
    from zipfile import BadZipFile, ZipFile

    try:
        with ZipFile(wheel) as archive:
            candidates = [
                name for name in archive.namelist() if name.endswith(".dist-info/METADATA")
            ]
            if len(candidates) != 1:
                raise ServiceError("install requires a wheel with exactly one METADATA file")
            metadata = archive.read(candidates[0]).decode("utf-8", "replace")
    except (BadZipFile, OSError) as exc:
        raise ServiceError("install could not read the wheel metadata") from exc
    for line in metadata.splitlines():
        if line.startswith("Version: "):
            return line.removeprefix("Version: ").strip()
    raise ServiceError("install found no version in the wheel metadata")


def _resolve_install_wheel(explicit: Path | None, *, version: str) -> Path:
    """Resolve the wheel to install and refuse a version that cannot match this code."""
    if explicit is None:
        candidates = sorted(Path.cwd().glob("speechrail-*.whl"))
        if len(candidates) != 1:
            raise ServiceError(
                "install needs exactly one speechrail-*.whl in this directory; pass --wheel"
            )
        wheel = candidates[0]
    else:
        wheel = explicit
    if not wheel.is_file() or wheel.suffix != ".whl":
        raise ServiceError("install requires an existing wheel file")
    found = _wheel_metadata_version(wheel)
    if found != version:
        raise ServiceError(
            f"install refuses a mismatched wheel: {wheel.name} is {found}, "
            f"this installer is {version}"
        )
    return wheel


def _require_uv() -> str:
    """Return the uv executable, or fail with the step that is actually missing."""
    uv = shutil.which("uv")
    if uv is None:
        raise ServiceError(
            "install drives uv to build the managed runtime, but uv is not on PATH; "
            "install it first: https://docs.astral.sh/uv/getting-started/installation/"
        )
    return uv


def _wait_until_ready(
    base_url: str,
    *,
    timeout_seconds: float,
    app_home: Path | None,
) -> tuple[bool, str]:
    """Poll /readyz so a first-time user learns whether the service works.

    The install is already committed at this point, so a timeout is reported as
    a status instead of failing the command.
    """
    headers = {"Accept": "application/json"}
    api_key = resolve_api_key(app_home=app_home)
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    deadline = time.monotonic() + timeout_seconds
    detail = "no response yet"
    while True:
        try:
            with urlopen(Request(f"{base_url}/readyz", headers=headers), timeout=5.0) as response:
                if response.status == 200:
                    return True, "ready"
                detail = f"HTTP {response.status}"
        except HTTPError as exc:
            detail = f"HTTP {exc.code}"
        except (URLError, OSError) as exc:
            detail = type(exc).__name__
        if time.monotonic() >= deadline:
            return False, detail
        time.sleep(2.0)


def _install_service_base_url(app_home: Path) -> str:
    return f"http://127.0.0.1:{_service_port(app_home)}"


def _installed_preset(app_home: Path) -> str | None:
    """Return the preset this app home already committed to, if any.

    One app home keeps exactly one preset, so an upgrade must repeat the
    installed tier instead of falling back to the memory recommendation.
    """
    from speechrail.service.profile_store import recover_selection

    try:
        selection = recover_selection(app_home)
    except (OSError, ValueError):
        return None
    if not selection:
        return None
    preset = selection.get("preset")
    return preset if isinstance(preset, str) else None


def _run_install(args: argparse.Namespace) -> int:
    """Install one release wheel as the managed runtime, disabled unless asked to start."""
    from speechrail import __version__
    from speechrail.service import profile_commands
    from speechrail.service.installer_errors import InstallerError
    from speechrail.service.managed_install import install_managed, setup_launcher_path

    machine_output = bool(getattr(args, "json", False))
    app_home = (args.app_home or _default_app_home()).resolve()
    wheel = _resolve_install_wheel(getattr(args, "wheel", None), version=__version__)
    uv_executable = _require_uv()
    installed_preset = _installed_preset(app_home)
    preset = (
        args.preset
        or installed_preset
        or profile_commands.recommend_profile(_physical_memory_bytes())
    )
    summary = next(item for item in profile_commands.list_profiles() if item.id == preset)
    enable = bool(getattr(args, "enable", False))
    installed_cli = f'"{app_home}/runtime/current/.venv/bin/speechrail"'
    if not machine_output:
        carried = installed_preset is not None and args.preset is None
        print(f"Wheel: {wheel.name}")
        suffix = " (kept from the installed service)" if carried else ""
        print(f"Profile: {preset}{suffix} (ASR={summary.asr}, TTS={summary.tts})")
        print(f"App home: {app_home}")
        budget = _format_bytes(summary.download_bytes)
        print(f"Download up to {budget} before the service is ready.")
    if not _confirm(args.yes):
        if machine_output:
            _print_machine(
                {
                    "command": "install",
                    "error_code": "cancelled",
                    "message": "installation requires confirmation",
                    "status": "cancelled",
                }
            )
        else:
            print("Cancelled.")
        return 1

    import httpx

    from speechrail.service.modelscope import ModelScopeDownloader

    def progress(event: dict[str, object]) -> None:
        if machine_output:
            _print_machine({"event": "progress", "command": "install", **event})
        else:
            phase = event.get("phase", "preparing")
            artifact = event.get("artifact")
            suffix = f" ({artifact})" if isinstance(artifact, str) else ""
            print(f"{phase}{suffix}", flush=True)

    timeout = httpx.Timeout(connect=30.0, read=300.0, write=30.0, pool=30.0)
    try:
        with httpx.Client(timeout=timeout) as client:
            result = install_managed(
                wheel,
                app_home=app_home,
                preset_id=preset,
                downloader=ModelScopeDownloader(client=client),
                enable=enable,
                progress=progress,
                uv_executable=uv_executable,
            )
    except InstallerError as exc:
        if "to be stopped" in str(exc):
            raise ServiceError(
                "install must not replace a running service; stop it first: "
                f"{installed_cli} service stop --app-home \"{app_home}\""
            ) from exc
        if "different managed preset is already configured" in str(exc):
            raise ServiceError(
                "install keeps one preset per app home; an installed service already "
                f"selected {installed_preset or 'a tier'}, so repeat that preset or switch "
                f"tiers with: {installed_cli} profile apply <tier> --yes"
            ) from exc
        raise

    runtime_cli = result.runtime_python.parent / "speechrail"
    base_url = _install_service_base_url(result.app_home)
    ready: bool | None = None
    readiness_detail = ""
    if enable:
        ready, readiness_detail = _wait_until_ready(
            base_url,
            timeout_seconds=60.0,
            app_home=result.app_home,
        )
    if machine_output:
        envelope: dict[str, object] = {
            "app_home": str(result.app_home),
            "base_url": base_url,
            "command": "install",
            "enabled": result.enabled,
            "prepared_id": result.prepared_id,
            "preset": preset,
            "runtime_cli": str(runtime_cli),
            "runtime_python": str(result.runtime_python),
            "status": "committed",
        }
        if ready is not None:
            envelope["readyz"] = ready
        _print_machine(envelope)
        return 0
    print(f"Installed {wheel.name} into {result.app_home}")
    print(f"Runtime: {result.runtime_python}")
    if result.prepared_id is not None:
        print(f"Prepared models: {result.prepared_id}")
    if result.enabled:
        print("com.speechrail is registered and started.")
        if ready:
            print(f"Service is ready at {base_url} (/readyz returned HTTP 200).")
        else:
            print(f"Service is not ready yet ({readiness_detail}); check it with:")
            print(f'  "{runtime_cli}" service preflight --app-home "{result.app_home}"')
            print(f"  curl -s -i {base_url}/readyz | head -1")
    else:
        print("The service is installed but not started.")
        print(f'Start it: "{runtime_cli}" service start --app-home "{result.app_home}"')
    print(
        f'Service CLI: "{runtime_cli}" service <status|start|stop> '
        f'--app-home "{result.app_home}"'
    )
    print(f"Change profile later: double-click {setup_launcher_path(result.app_home)}")
    return 0


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


def _print_machine_preflight(result: PreflightResult) -> None:
    _print_machine(
        {
            "checks": [
                {
                    "message": _machine_message(check.message),
                    "name": check.name,
                    "ok": check.ok,
                }
                for check in result.checks
            ],
            "command": "service.preflight",
            "status": "ok" if result.ok else "failed",
        }
    )


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
    json_output: bool,
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
    if json_output:
        command_args.append("--json")
    try:
        completed = subprocess.run(tuple(command_args), check=False)
    except OSError as exc:
        raise ServiceError("managed service runtime could not be executed") from exc
    return completed.returncode


def _delegate_managed_command(
    command_args: Sequence[str],
    app_home: Path,
    *,
    managed_python: Path,
) -> int:
    child_args = (
        str(managed_python),
        "-I",
        "-m",
        "speechrail",
        *command_args,
        "--app-home",
        str(app_home),
    )
    try:
        completed = subprocess.run(child_args, check=False)
    except OSError as exc:
        raise ServiceError("managed service runtime could not be executed") from exc
    return completed.returncode


def _managed_runtime_for_mutation(app_home: Path) -> Path | None:
    """Return the managed interpreter or fail closed for a broken install."""

    layout = ServiceLayout.for_app_home(app_home)
    managed_python = _managed_service_python(app_home)
    if managed_python is not None:
        return managed_python
    if (
        (layout.current_runtime.exists() or layout.current_runtime.is_symlink())
        and (
            not layout.current_python.is_file()
            or not os.access(layout.current_python, os.X_OK)
        )
    ):
        raise ServiceError("managed runtime Python is missing or not executable")
    return None


def _run_service(
    command: str,
    app_home: Path | None = None,
    asr_only: bool = False,
    host_python: Path | None = None,
    json_output: bool = False,
) -> int | None:
    if app_home is not None:
        resolved_app_home = app_home.expanduser().absolute()
        layout = ServiceLayout.for_app_home(resolved_app_home)
        managed_python = _managed_runtime_for_mutation(resolved_app_home)
        if managed_python is not None:
            return _delegate_service_command(
                command,
                resolved_app_home,
                managed_python=managed_python,
                asr_only=asr_only,
                host_python=host_python,
                json_output=json_output,
            )
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
        if json_output:
            _print_machine_preflight(result)
            return None if result.ok else 1
        _print_preflight(result)
        if not result.ok:
            raise ServiceError("preflight failed; service state unchanged")
        return None
    if app_home is None:
        manager = create_launch_agent_manager()
    else:
        manager = create_launch_agent_manager(working_directory=app_home)
    if command == "install":
        if json_output:
            manager.install()
            _print_machine({"command": "service.install", "status": "completed"})
            return None
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
        status_output = manager.status()
        if json_output:
            state = "unknown"
            lowered = status_output.lower()
            if (
                "state = running" in lowered
                or status_output.strip().lower() in {"running", "active"}
            ):
                state = "running"
            elif "state = stopped" in lowered or "state = exited" in lowered:
                state = "stopped"
            _print_machine(
                {
                    "command": "service.status",
                    "service_state": state,
                    "status": "ok",
                }
            )
        else:
            print(status_output, end="")
        return None
    elif command == "uninstall":
        manager.uninstall()
    else:
        raise ServiceError("unknown service command")
    if json_output:
        _print_machine({"command": f"service.{command}", "status": "completed"})
    else:
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
                getattr(args, "json", False),
            )
            return 0 if service_result is None else service_result
        if args.command == "profile":
            return _run_profile(args)
        if args.command == "model":
            return _run_model(args)
        if args.command == "setup":
            return _run_setup(args)
        if args.command == "install":
            return _run_install(args)
        raise ServiceError("unknown command")
    except (ServiceError, RuntimeError, ValueError) as exc:
        if getattr(args, "json", False):
            _print_machine(
                {
                    "command": _machine_command(args),
                    "error_code": _machine_error_code(exc),
                    "message": _machine_message(exc),
                    "status": "failed",
                }
            )
            return 1
        prefix = "SpeechRail service" if args.command == "service" else "SpeechRail"
        print(f"{prefix}: {exc}", file=sys.stderr)
        return 1


__all__ = ["main", "run_server"]
