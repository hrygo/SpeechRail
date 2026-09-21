"""Install and inspect the SpeechRail MCP + skill agent integration."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tempfile
from contextlib import suppress
from dataclasses import dataclass
from importlib import resources
from pathlib import Path
from typing import Any

_RECEIPT_NAME = ".speechrail-install.json"
_SKILL_NAME = "speechrail"
_CONFIG_HEADER = "[mcp_servers.speechrail]"
_ENV_HEADER = "[mcp_servers.speechrail.env]"
_DEFAULT_BASE_URL = "http://127.0.0.1:8201/v1"


class AgentIntegrationError(RuntimeError):
    """A safe, actionable integration conflict or installation failure."""


@dataclass(frozen=True, slots=True)
class AgentPaths:
    client: str
    skills_dir: Path
    config_path: Path


def _default_paths(*, client: str = "codex") -> AgentPaths:
    if client != "codex":
        raise AgentIntegrationError(f"unsupported agent client: {client}")
    home = Path.home()
    return AgentPaths(
        client=client,
        skills_dir=home / ".codex" / "skills",
        config_path=home / ".codex" / "config.toml",
    )


def _paths(
    *, client: str, skills_dir: Path | None, config_path: Path | None
) -> AgentPaths:
    defaults = _default_paths(client=client)
    return AgentPaths(
        client=client,
        skills_dir=(skills_dir or defaults.skills_dir).expanduser().resolve(),
        config_path=(config_path or defaults.config_path).expanduser().resolve(),
    )


def _skill_files() -> dict[str, bytes]:
    root = resources.files("speechrail").joinpath("assets", "skills", _SKILL_NAME)
    files: dict[str, bytes] = {}

    def visit(node: Any, prefix: str = "") -> None:
        for child in node.iterdir():
            relative = f"{prefix}{child.name}"
            if child.is_dir():
                visit(child, relative + "/")
            else:
                files[relative] = child.read_bytes()

    visit(root)
    if "SKILL.md" not in files or "skill-manifest.json" not in files:
        raise AgentIntegrationError("packaged SpeechRail skill is incomplete")
    return files


def _digest(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def _atomic_write(path: Path, content: bytes, *, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, raw_tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    tmp = Path(raw_tmp)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        tmp.chmod(mode)
        tmp.replace(path)
    finally:
        if tmp.exists():
            tmp.unlink(missing_ok=True)


def _mcp_command() -> tuple[str, list[str]]:
    executable = shutil.which("speechrail-mcp")
    if executable:
        return executable, []
    return sys.executable, ["-m", "speechrail.mcp"]


def _toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _mcp_block() -> str:
    command, args = _mcp_command()
    lines = [
        _CONFIG_HEADER,
        f"command = {_toml_string(command)}",
    ]
    if args:
        lines.append("args = [" + ", ".join(_toml_string(arg) for arg in args) + "]")
    lines.extend(
        [
            "",
            _ENV_HEADER,
            f"SPEECHRAIL_BASE_URL = {_toml_string(_DEFAULT_BASE_URL)}",
        ]
    )
    return "\n".join(lines) + "\n"


def _config_block(text: str) -> str | None:
    start = text.find(_CONFIG_HEADER)
    if start < 0:
        return None
    end = len(text)
    offset = start
    for line in text[start:].splitlines(keepends=True)[1:]:
        offset += len(line)
        stripped = line.rstrip("\r\n")
        if stripped.startswith("[") and not stripped.startswith("[mcp_servers.speechrail."):
            end = offset - len(line)
            break
    return text[start:end]


def _install_config(
    path: Path,
    *,
    force: bool,
    managed_block_sha256: str | None = None,
) -> tuple[str, str]:
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    old_block = _config_block(existing)
    new_block = _mcp_block()
    if old_block is not None:
        managed = (
            managed_block_sha256 is not None
            and _digest(old_block.encode("utf-8")) == managed_block_sha256
        )
        if old_block == new_block:
            return "unchanged", old_block
        if not force and not managed:
            raise AgentIntegrationError(
                f"MCP config conflict at {path}; use --force only after reviewing "
                "the existing speechrail entry"
            )
        updated = existing.replace(old_block, new_block, 1)
    else:
        updated = existing
        if updated and not updated.endswith("\n"):
            updated += "\n"
        updated += "\n" + new_block
    if path.exists() and force:
        backup = path.with_name(path.name + ".speechrail-backup")
        if not backup.exists():
            shutil.copy2(path, backup)
    _atomic_write(path, updated.encode("utf-8"), mode=0o600)
    return "installed", new_block


def _receipt_path(paths: AgentPaths) -> Path:
    return paths.skills_dir / _RECEIPT_NAME


def _read_receipt(paths: AgentPaths) -> dict[str, Any] | None:
    path = _receipt_path(paths)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise AgentIntegrationError(f"invalid SpeechRail agent receipt at {path}") from exc
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise AgentIntegrationError(f"unsupported SpeechRail agent receipt at {path}")
    return data


def install(
    *,
    client: str = "codex",
    skills_dir: Path | None = None,
    config_path: Path | None = None,
    force: bool = False,
    operation: str = "install",
) -> dict[str, Any]:
    """Install the packaged skill and one host-local MCP configuration entry."""

    paths = _paths(client=client, skills_dir=skills_dir, config_path=config_path)
    files = _skill_files()
    skill_dir = paths.skills_dir / _SKILL_NAME
    previous = _read_receipt(paths)
    changed_files: list[str] = []
    unchanged_files: list[str] = []
    skill_dir.mkdir(parents=True, exist_ok=True)
    for relative, content in sorted(files.items()):
        target = skill_dir / relative
        if target.exists():
            if target.read_bytes() == content:
                unchanged_files.append(relative)
                continue
            managed_hash = (previous or {}).get("files", {}).get(relative)
            if not force and managed_hash != _digest(target.read_bytes()):
                raise AgentIntegrationError(
                    f"skill file conflict at {target}; use --force after reviewing local edits"
                )
        _atomic_write(target, content, mode=0o644)
        changed_files.append(relative)

    config_status, block = _install_config(
        paths.config_path,
        force=force,
        managed_block_sha256=(previous or {}).get("config_block_sha256"),
    )
    receipt = {
        "schema_version": 1,
        "skill": _SKILL_NAME,
        "skill_version": json.loads(files["skill-manifest.json"].decode())["version"],
        "client": paths.client,
        "skills_dir": str(paths.skills_dir),
        "skill_dir": str(skill_dir),
        "config_path": str(paths.config_path),
        "files": {relative: _digest(content) for relative, content in sorted(files.items())},
        "config_block_sha256": _digest(block.encode("utf-8")),
        "mcp_command": _mcp_command()[0],
        "session_activation": "requires_restart",
    }
    _atomic_write(
        _receipt_path(paths),
        (json.dumps(receipt, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
    )
    return {
        "status": (
            "unchanged"
            if not changed_files and config_status == "unchanged"
            else "installed"
        ),
        "operation": operation,
        "file_installation": "unchanged" if not changed_files else "installed",
        "client_discovery": "configured",
        "session_activation": "requires_restart",
        "packaged": "available",
        "installed": "unchanged" if not changed_files else "installed",
        "client_configured": "configured",
        # File/config inspection cannot prove that the client scanned the
        # entry or reloaded the running session.
        "client_discovered": "unknown",
        "session_activated": "unknown",
        "changed_files": changed_files,
        "unchanged_files": unchanged_files,
        "config_path": str(paths.config_path),
        "skills_dir": str(paths.skills_dir),
    }


def status(
    *, client: str = "codex", skills_dir: Path | None = None, config_path: Path | None = None
) -> dict[str, Any]:
    paths = _paths(client=client, skills_dir=skills_dir, config_path=config_path)
    receipt = _read_receipt(paths)
    if receipt is None:
        skill_dir = paths.skills_dir / _SKILL_NAME
        config_block = (
            _config_block(paths.config_path.read_text(encoding="utf-8"))
            if paths.config_path.is_file()
            else None
        )
        drifted = skill_dir.exists() or config_block is not None
        return {
            "status": "drifted" if drifted else "not_installed",
            "file_installation": "drifted" if skill_dir.exists() else "missing",
            "client_discovery": "drifted" if config_block is not None else "unknown",
            "session_activation": "unknown",
            "packaged": "available",
            "installed": "drifted" if drifted else "missing",
            "client_configured": "drifted" if config_block is not None else "missing",
            "client_discovered": "unknown",
            "session_activated": "unknown",
            "config_path": str(paths.config_path),
            "skills_dir": str(paths.skills_dir),
        }
    files_ok = True
    for relative, expected in receipt.get("files", {}).items():
        target = Path(receipt["skill_dir"]) / relative
        if not target.is_file() or _digest(target.read_bytes()) != expected:
            files_ok = False
            break
    block = (
        _config_block(paths.config_path.read_text(encoding="utf-8"))
        if paths.config_path.is_file()
        else None
    )
    config_ok = block is not None and _digest(block.encode("utf-8")) == receipt.get(
        "config_block_sha256"
    )
    command = receipt.get("mcp_command")
    command_ok = isinstance(command, str) and (
        Path(command).is_file() or shutil.which(command) is not None
    )
    return {
        "status": "installed" if files_ok and config_ok else "drifted",
        "file_installation": "installed" if files_ok else "drifted",
        "client_discovery": "configured" if config_ok and command_ok else "drifted",
        "session_activation": receipt.get("session_activation", "requires_restart"),
        "packaged": "available",
        "installed": "installed" if files_ok else "drifted",
        "client_configured": "configured" if config_ok else "drifted",
        "client_discovered": "unknown",
        "session_activated": "unknown",
        "config_path": str(paths.config_path),
        "skills_dir": str(paths.skills_dir),
        "command_available": command_ok,
    }


def uninstall(
    *, client: str = "codex", skills_dir: Path | None = None, config_path: Path | None = None
) -> dict[str, Any]:
    paths = _paths(client=client, skills_dir=skills_dir, config_path=config_path)
    receipt = _read_receipt(paths)
    if receipt is None:
        return {
            "status": "not_installed",
            "file_installation": "missing",
            "client_discovery": "unchanged",
            "packaged": "available",
            "installed": "missing",
            "client_configured": "unchanged",
            "client_discovered": "unknown",
            "session_activated": "unknown",
        }
    retained: list[str] = []
    removed: list[str] = []
    skill_dir = Path(receipt["skill_dir"])
    for relative, expected in receipt.get("files", {}).items():
        target = skill_dir / relative
        if not target.exists():
            continue
        if _digest(target.read_bytes()) != expected:
            retained.append(relative)
            continue
        target.unlink()
        removed.append(relative)
    if not retained:
        for directory in sorted(
            (path for path in skill_dir.rglob("*") if path.is_dir()), reverse=True
        ):
            with suppress(OSError):
                directory.rmdir()
        with suppress(OSError):
            skill_dir.rmdir()
    block = (
        _config_block(paths.config_path.read_text(encoding="utf-8"))
        if paths.config_path.is_file()
        else None
    )
    config_removed = False
    if block is not None and _digest(block.encode("utf-8")) == receipt.get("config_block_sha256"):
        updated = paths.config_path.read_text(encoding="utf-8").replace(block, "", 1).lstrip("\n")
        _atomic_write(paths.config_path, updated.encode("utf-8"), mode=0o600)
        config_removed = True
    partial_uninstall = bool(retained) or (block is not None and not config_removed)
    if not partial_uninstall:
        _receipt_path(paths).unlink(missing_ok=True)
    return {
        "status": "drifted" if partial_uninstall else "uninstalled",
        "file_installation": "uninstalled" if not retained else "partially_uninstalled",
        "client_discovery": "uninstalled" if config_removed else "retained_due_to_conflict",
        "removed_files": removed,
        "retained_files": retained,
        "session_activation": "requires_restart",
        "packaged": "available",
        "installed": "drifted" if partial_uninstall else "uninstalled",
        "client_configured": "uninstalled" if config_removed else "retained_due_to_conflict",
        "client_discovered": "unknown",
        "session_activated": "unknown",
    }
