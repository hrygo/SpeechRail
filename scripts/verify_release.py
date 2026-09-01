#!/usr/bin/env python3
"""Verify a wheel-based SpeechRail installation without exposing secrets."""

from __future__ import annotations

import argparse
import json
import subprocess
import urllib.error
import urllib.request
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from zipfile import BadZipFile, ZipFile

CommandRunner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]
HttpGetter = Callable[[str], tuple[int, object]]


@dataclass(frozen=True)
class VerificationCheck:
    name: str
    ok: bool
    message: str


@dataclass(frozen=True)
class VerificationResult:
    ok: bool
    checks: tuple[VerificationCheck, ...]


def _runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True)


def _http_get(base_url: str, path: str) -> tuple[int, object]:
    request = urllib.request.Request(f"{base_url.rstrip('/')}{path}")
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return 0, {}


def _wheel_check(wheel: Path) -> VerificationCheck:
    try:
        with ZipFile(wheel) as archive:
            names = set(archive.namelist())
    except (OSError, BadZipFile):
        return VerificationCheck("wheel", False, "wheel is missing or invalid")
    required = {"speechrail/__main__.py", "speechrail/cli.py"}
    forbidden = ("tests/", ".env", ".log", ".wav", ".mp3", ".safetensors", "/Users/")
    ok = required <= names and not any(
        name.startswith("tests/") or any(token in name for token in forbidden[1:])
        for name in names
    )
    return VerificationCheck(
        "wheel", ok, "wheel contents are safe" if ok else "wheel contents are invalid"
    )


def _plist_check(app_home: Path, plist_path: Path) -> VerificationCheck:
    try:
        import plistlib

        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException):
        return VerificationCheck("plist", False, "LaunchAgent plist is missing or invalid")
    arguments = plist.get("ProgramArguments")
    ok = (
        plist.get("Label") == "com.speechrail"
        and plist.get("WorkingDirectory") == str(app_home)
        and isinstance(arguments, list)
        and len(arguments) >= 4
        and arguments[1:4] == ["-m", "speechrail", "serve"]
        and "EnvironmentVariables" not in plist
    )
    return VerificationCheck(
        "plist", ok, "LaunchAgent plist is safe" if ok else "LaunchAgent plist is invalid"
    )


def _endpoint_check(name: str, status: int, payload: object, predicate: bool) -> VerificationCheck:
    return VerificationCheck(name, status == 200 and predicate, f"HTTP status {status}")


def verify_release(
    *,
    wheel: Path,
    app_home: Path,
    plist_path: Path | None = None,
    base_url: str = "http://127.0.0.1:8201",
    runner: CommandRunner = _runner,
    http_get: Callable[[str], tuple[int, object]] | None = None,
) -> VerificationResult:
    """Check package, service command, plist and local readiness endpoints."""
    checks = [_wheel_check(wheel)]
    current_python = app_home / "runtime" / "current" / ".venv" / "bin" / "python"
    command = (str(current_python), "-m", "speechrail", "--help")
    try:
        command_result = runner(command)
        command_ok = command_result.returncode == 0
    except OSError:
        command_ok = False
    cli_ok = current_python.is_file() and command_ok
    checks.append(
        VerificationCheck(
            "cli",
            cli_ok,
            "installed CLI is executable" if cli_ok else "installed CLI is unavailable",
        )
    )
    checks.append(
        _plist_check(
            app_home,
            plist_path or Path.home() / "Library" / "LaunchAgents" / "com.speechrail.plist",
        )
    )

    getter = http_get or (lambda path: _http_get(base_url, path))
    try:
        health_status, health = getter("/health")
        ready_status, ready = getter("/readyz")
        models_status, models = getter("/v1/models")
        voices_status, voices = getter("/v1/voices")
    except Exception:
        health_status = ready_status = models_status = voices_status = 0
        health = ready = models = voices = {}
    checks.extend(
        [
            _endpoint_check(
                "health",
                health_status,
                health,
                isinstance(health, dict)
                and health.get("asr_ready") is True
                and health.get("tts_ready") is True
                and health.get("ready") is True,
            ),
            _endpoint_check(
                "readyz",
                ready_status,
                ready,
                isinstance(ready, dict) and ready.get("ready") is True,
            ),
            _endpoint_check(
                "models",
                models_status,
                models,
                isinstance(models, dict) and bool(models.get("data")),
            ),
            _endpoint_check(
                "voices",
                voices_status,
                voices,
                isinstance(voices, dict)
                and isinstance(voices.get("data"), list)
                and bool(voices.get("data"))
                and all(
                    isinstance(item, dict) and item.get("available") is True
                    for item in voices["data"]
                ),
            ),
        ]
    )
    return VerificationResult(ok=all(check.ok for check in checks), checks=tuple(checks))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Verify a SpeechRail wheel installation")
    parser.add_argument("--wheel", type=Path, required=True)
    parser.add_argument("--app-home", type=Path, required=True)
    parser.add_argument("--plist", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:8201")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    result = verify_release(
        wheel=args.wheel,
        app_home=args.app_home,
        plist_path=args.plist,
        base_url=args.base_url,
    )
    for check in result.checks:
        print(f"{'OK' if check.ok else 'FAIL'} {check.name}: {check.message}")
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
