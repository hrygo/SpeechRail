#!/usr/bin/env python3
"""Install a SpeechRail wheel into a user-owned macOS runtime."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from speechrail.config.model_catalog import ModelCatalog, RuntimeLock
    from speechrail.service.bootstrap import RuntimeCurrentSnapshot, RuntimePaths
    from speechrail.service.model_store import Downloader
    from speechrail.service.paths import ServiceLayout

# Managed dependencies are loaded lazily. Both installation paths share the
# package-owned per-port lock; explicit-env therefore fails closed if the
# SpeechRail package is unavailable instead of risking a live pointer swap.
ModelCatalog: Any = None
RuntimeLock: Any = None
RuntimeCurrentSnapshot: Any = None
RuntimePaths: Any = None
ServiceLayout: Any = None
ServerInstanceError: Any = None
ServerInstanceLock: Any = None
ProfileStore: Any = None
load_catalog: Any = None
load_runtime_lock: Any = None
prepare_models: Any = None
prepare_runtime: Any = None
recover_selection: Any = None
restore_runtime_current: Any = None
snapshot_runtime_current: Any = None

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
    prepared_id: str | None = None
    runtime_key: str | None = None


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
    layout: InstallLayout | ServiceLayout,
    *,
    require_tts: bool,
    runner: CommandRunner,
) -> PreflightOutcome:
    """Run preflight through the newly installed wheel, not the source tree."""
    command: tuple[str, ...] = (
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


def _config_enables_diarization(env_file: Path) -> bool:
    """Detect an opted-in diarization profile without logging configuration values."""
    for raw_line in env_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("SPEECHRAIL_DIARIZATION_MODEL_PATH="):
            return bool(line.partition("=")[2].strip())
    return False


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


def _write_private_config(destination: Path, content: str | bytes) -> None:
    """Create a private managed config without replacing an existing file."""
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary_name = tempfile.mkstemp(dir=destination.parent, prefix=".env.")
    temporary_path = Path(temporary_name)
    created_identity: tuple[int, int] | None = None
    try:
        data = content.encode("utf-8") if isinstance(content, str) else content
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        temporary_path.chmod(0o600)
        temporary_stat = temporary_path.stat(follow_symlinks=False)
        created_identity = (temporary_stat.st_dev, temporary_stat.st_ino)
        try:
            os.link(temporary_path, destination)
        except FileExistsError as exc:
            raise InstallerError(
                "configuration was created concurrently and will not be overwritten"
            ) from exc
        directory_descriptor = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except Exception:
        if created_identity is not None:
            try:
                destination_stat = destination.stat(follow_symlinks=False)
                if (destination_stat.st_dev, destination_stat.st_ino) == created_identity:
                    destination.unlink()
            except OSError:
                pass
        raise
    finally:
        temporary_path.unlink(missing_ok=True)


def _setup_launcher_path(app_home: Path) -> Path:
    return app_home.absolute() / "SpeechRail 设置.command"


def _write_setup_launcher(app_home: Path) -> Path:
    """Atomically install a double-click entry for the current managed release."""
    resolved_home = app_home.absolute()
    destination = _setup_launcher_path(resolved_home)
    if destination.is_symlink():
        raise InstallerError("setup launcher must not be a symlink")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    home = shlex.quote(str(resolved_home))
    content = (
        "#!/bin/zsh\n"
        "set -eu\n"
        f"APP_HOME={home}\n"
        'RUNTIME_PYTHON="$APP_HOME/runtime/current/.venv/bin/python"\n'
        'if [[ ! -x "$RUNTIME_PYTHON" ]]; then\n'
        '  print -u2 "SpeechRail is not installed at: $APP_HOME"\n'
        "  exit 1\n"
        "fi\n"
        'exec "$RUNTIME_PYTHON" -m speechrail setup --app-home "$APP_HOME"\n'
    ).encode()
    descriptor, temporary_name = tempfile.mkstemp(
        dir=destination.parent, prefix=".SpeechRail-Setup."
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), 0o700)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        if destination.is_symlink():
            raise InstallerError("setup launcher must not be a symlink")
        temporary.replace(destination)
        directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


_LOCAL_ABSOLUTE_PATH_RE = re.compile(
    r"file:///(?:Users|Volumes|private|tmp|var|home|Library|Applications|opt)/"
    r"|(?<![A-Za-z0-9_])/(?:Users|Volumes|private|tmp|var|home|Library|Applications|opt)(?:/|$)"
    r"|(?<![A-Za-z0-9_])[A-Za-z]:[\\/]"
)


def _ignore_skill_artifacts(_: str, names: list[str]) -> set[str]:
    return {
        name
        for name in names
        if name == "__pycache__" or name.endswith(".pyc") or name == ".DS_Store"
    }


def _validate_video_podcast_skill(source: Path) -> None:
    if source.is_symlink() or not source.is_dir():
        raise InstallerError("video-podcast skill source is missing or invalid")

    for path in source.rglob("*"):
        if path.is_symlink():
            raise InstallerError("video-podcast skill must not contain symlinks")
        if not path.is_file() or path.name == ".DS_Store" or path.suffix == ".pyc":
            continue
        try:
            content = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if _LOCAL_ABSOLUTE_PATH_RE.search(content):
            raise InstallerError("video-podcast skill contains a local absolute path")


def install_video_podcast_skill(
    source: Path,
    *,
    user_skills_dir: Path | None = None,
) -> Path:
    """Install the portable video-podcast skill into the current user's skill directory."""
    source = source.absolute()
    target_root = (user_skills_dir or Path.home() / ".agents" / "skills").absolute()
    _validate_video_podcast_skill(source)

    if target_root.is_symlink():
        raise InstallerError("user skill directory must not be a symlink")
    target_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = target_root / "video-podcast"
    if target.is_symlink():
        raise InstallerError("user video-podcast skill must not be a symlink")
    if target.exists() and not target.is_dir():
        raise InstallerError("user video-podcast skill must be a directory")

    staging_parent = Path(tempfile.mkdtemp(prefix=".video-podcast.", dir=target_root))
    staged = staging_parent / "video-podcast"
    backup: Path | None = None
    try:
        shutil.copytree(source, staged, ignore=_ignore_skill_artifacts)
        if target.exists():
            backup = target_root / f".video-podcast.backup-{uuid.uuid4().hex}"
            target.replace(backup)
        try:
            staged.replace(target)
        except BaseException:
            if backup is not None and not target.exists():
                backup.replace(target)
            raise
        if backup is not None:
            shutil.rmtree(backup)
        return target
    finally:
        shutil.rmtree(staging_parent, ignore_errors=True)


def _copy_config_exclusive(source: Path, destination: Path) -> None:
    """Copy a managed source config without replacing a concurrent destination."""
    _write_private_config(destination, source.read_bytes())


def _managed_config(
    layout: ServiceLayout,
    *,
    asr_key: str,
    tts_key: str,
) -> str:
    """Render the minimal loopback configuration for a catalog selection."""
    model_root = layout.models_root
    vendor_python = layout.vendor_current / "bin" / "python"
    vendor_ffmpeg = layout.vendor_current / "ffmpeg" / "bin" / "ffmpeg"
    lines = (
        "SPEECHRAIL_HOST=127.0.0.1",
        "SPEECHRAIL_PORT=8201",
        f"SPEECHRAIL_QWEN3_MODEL_DIR={model_root / asr_key}",
        f"SPEECHRAIL_QWEN3_PYTHON={vendor_python}",
        f"SPEECHRAIL_QWEN3_TTS_MODEL_DIR={model_root / tts_key}",
        f"SPEECHRAIL_QWEN3_TTS_PYTHON={vendor_python}",
        f"SPEECHRAIL_FFMPEG_PATH={vendor_ffmpeg}",
        "SPEECHRAIL_ALLOW_MODEL_DOWNLOADS=false",
        "SPEECHRAIL_TTS_ALLOW_MODEL_DOWNLOADS=false",
    )
    return "\n".join(lines) + "\n"


def _selection_candidate(
    catalog: ModelCatalog, runtime_lock: RuntimeLock, preset_id: str, generation: int
) -> dict[str, object]:
    try:
        selected = catalog.preset(preset_id)
    except KeyError as exc:
        raise InstallerError(f"unknown managed preset: {preset_id}") from exc
    return {
        "schema_version": 1,
        "preset": selected.id,
        "generation": generation,
        "asr": selected.asr,
        "tts": selected.tts,
        "runtime_lock_id": runtime_lock.id,
    }


def _same_selection(
    current: dict[str, object] | None, candidate: dict[str, object]
) -> bool:
    if current is None:
        return False
    return all(current.get(key) == value for key, value in candidate.items() if key != "generation")


def _configured_service_port(layout: InstallLayout | ServiceLayout, env_file: Path | None) -> int:
    """Read the local service port without loading a runtime or exposing secrets."""
    source = layout.config_file if layout.config_file.is_file() else env_file
    if source is None:
        return 8201
    try:
        lines = source.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise InstallerError("service configuration cannot be read") from exc
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        if key.strip() != "SPEECHRAIL_PORT":
            continue
        try:
            port = int(value.strip())
        except ValueError as exc:
            raise InstallerError("service port is invalid") from exc
        if not 1 <= port <= 65_535:
            raise InstallerError("service port is invalid")
        return port
    return 8201


def _assert_service_port_free(port: int, directory: Path | None) -> None:
    """Refuse to replace managed pointers while a server owns the port."""
    if ServerInstanceLock is None or ServerInstanceError is None:
        raise InstallerError("managed install service lock is unavailable")
    try:
        with ServerInstanceLock(port, directory=directory):
            pass
    except ServerInstanceError as exc:
        raise InstallerError(
            "managed installation requires the SpeechRail service to be stopped"
        ) from exc
    except OSError as exc:
        raise InstallerError("managed installation could not verify the service lock") from exc


def _stage_wheel(
    wheel: Path,
    layout: InstallLayout | ServiceLayout,
    *,
    uv_executable: str,
    runner: CommandRunner,
    install_diarization: bool = False,
    allow_existing: bool = True,
) -> tuple[Path, Path, bool]:
    """Stage one wheel release, optionally reusing a complete release.

    Managed and explicit-env installation deliberately share this boundary so
    the release identity, virtualenv creation and cleanup rules cannot drift.
    """
    release_dir = layout.runtime_root / "releases" / _release_id(wheel)
    if release_dir.is_symlink():
        raise InstallerError("wheel release must not be a symlink")
    if release_dir.exists():
        runtime_python = release_dir / ".venv" / "bin" / "python"
        if allow_existing and runtime_python.is_file():
            return release_dir, runtime_python, False
        raise InstallerError("this wheel release is incomplete")

    release_dir.mkdir(parents=True)
    venv_dir = release_dir / ".venv"
    runtime_python = venv_dir / "bin" / "python"
    wheel_requirement = str(wheel)
    if install_diarization:
        wheel_requirement += "[diarization]"
    try:
        _run((uv_executable, "venv", "--python", "3.12", str(venv_dir)), runner)
        _run(
            (
                uv_executable,
                "pip",
                "install",
                "--python",
                str(runtime_python),
                wheel_requirement,
            ),
            runner,
        )
    except BaseException:
        shutil.rmtree(release_dir, ignore_errors=True)
        raise
    return release_dir, runtime_python, True


def _load_managed_dependencies() -> type[Any]:
    """Load package code lazily for managed installs and return RuntimePaths."""
    global ModelCatalog, ProfileStore, RuntimeCurrentSnapshot, RuntimeLock, RuntimePaths
    global ServerInstanceError, ServerInstanceLock
    global ServiceLayout
    global load_catalog, load_runtime_lock, prepare_models, prepare_runtime, recover_selection
    global restore_runtime_current, snapshot_runtime_current
    try:
        from speechrail.config.model_catalog import ModelCatalog as CatalogType
        from speechrail.config.model_catalog import RuntimeLock as LockType
        from speechrail.config.model_catalog import load_catalog as catalog_loader
        from speechrail.config.model_catalog import load_runtime_lock as lock_loader
        from speechrail.runtime.server_lock import ServerInstanceError as ServerInstanceErrorType
        from speechrail.runtime.server_lock import ServerInstanceLock as ServerInstanceLockType
        from speechrail.service.bootstrap import (
            RuntimeCurrentSnapshot as RuntimeSnapshotType,
        )
        from speechrail.service.bootstrap import RuntimePaths as RuntimePathsType
        from speechrail.service.bootstrap import prepare_runtime as runtime_preparer
        from speechrail.service.bootstrap import restore_runtime_current as runtime_restore
        from speechrail.service.bootstrap import snapshot_runtime_current as runtime_snapshot
        from speechrail.service.model_store import (
            prepare_models as models_preparer,
        )
        from speechrail.service.paths import ServiceLayout as LayoutType
        from speechrail.service.profile_store import (
            ProfileStore as ProfileStoreType,
        )
        from speechrail.service.profile_store import (
            recover_selection as selection_loader,
        )
    except ImportError as exc:
        raise InstallerError("managed install requires the SpeechRail package") from exc
    if ModelCatalog is None:
        ModelCatalog = CatalogType
    if RuntimeLock is None:
        RuntimeLock = LockType
    if RuntimePaths is None:
        RuntimePaths = RuntimePathsType
    if RuntimeCurrentSnapshot is None:
        RuntimeCurrentSnapshot = RuntimeSnapshotType
    if ServiceLayout is None:
        ServiceLayout = LayoutType
    if ProfileStore is None:
        ProfileStore = ProfileStoreType
    if ServerInstanceError is None:
        ServerInstanceError = ServerInstanceErrorType
    if ServerInstanceLock is None:
        ServerInstanceLock = ServerInstanceLockType
    if load_catalog is None:
        load_catalog = catalog_loader
    if load_runtime_lock is None:
        load_runtime_lock = lock_loader
    if prepare_models is None:
        prepare_models = models_preparer
    if prepare_runtime is None:
        prepare_runtime = runtime_preparer
    if recover_selection is None:
        recover_selection = selection_loader
    if restore_runtime_current is None:
        restore_runtime_current = runtime_restore
    if snapshot_runtime_current is None:
        snapshot_runtime_current = runtime_snapshot
    return RuntimePathsType


def _assert_explicit_install_allowed(
    layout: InstallLayout,
    env_file: Path,
    *,
    server_lock_directory: Path | None,
) -> None:
    """Keep the historical installer isolated from managed profile state."""
    selection_path = layout.app_home / "config" / "selection.json"
    if selection_path.exists() or selection_path.is_symlink():
        raise InstallerError(
            "legacy installer refuses managed selection; use install_managed instead"
        )
    _load_managed_dependencies()
    _assert_service_port_free(
        _configured_service_port(layout, env_file),
        server_lock_directory,
    )


def _prepare_models_for_install(
    preset_id: str,
    *,
    app_home: Path,
    downloader: Downloader,
    catalog: ModelCatalog,
    runtime_lock: RuntimeLock,
) -> str:
    try:
        return asyncio.run(
            prepare_models(
                preset_id,
                app_home=app_home,
                downloader=downloader,
                catalog=catalog,
                runtime_lock=runtime_lock,
            )
        )
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        raise InstallerError("model preparation failed") from exc


def install_managed(
    wheel: Path,
    *,
    app_home: Path,
    preset_id: str,
    downloader: Downloader,
    runtime_runner: CommandRunner | None = None,
    uv_executable: str = "uv",
    require_tts: bool = True,
    enable: bool = False,
    runner: CommandRunner = _runner,
    catalog: ModelCatalog | None = None,
    runtime_lock: RuntimeLock | None = None,
    env_file: Path | None = None,
    server_lock_directory: Path | None = None,
    post_enable: Callable[[Path, str], None] | None = None,
) -> InstallResult:
    """Install one catalog preset with a shared, lock-keyed vendor runtime."""
    if not wheel.is_file() or wheel.suffix != ".whl":
        raise InstallerError("wheel file is missing or invalid")
    if env_file is not None and not env_file.is_file():
        raise InstallerError("configuration file is missing")
    if post_enable is not None and not enable:
        raise InstallerError("post-enable verifier requires enable=True")
    runtime_paths_type = _load_managed_dependencies()

    try:
        selected_catalog = catalog if catalog is not None else load_catalog()
        selected_lock = runtime_lock if runtime_lock is not None else load_runtime_lock()
        selected_preset = selected_catalog.preset(preset_id)
    except (KeyError, ValueError, TypeError) as exc:
        raise InstallerError("managed catalog or runtime lock is invalid") from exc

    layout = ServiceLayout.for_app_home(app_home)
    layout.ensure_directories()
    if layout.config_file.is_symlink():
        raise InstallerError("configuration file must not be a symlink")
    if (
        layout.config_file.exists()
        and env_file is not None
        and layout.config_file.absolute() != env_file.absolute()
    ):
        raise InstallerError("configuration already exists and will not be overwritten")
    service_port = _configured_service_port(layout, env_file)
    _assert_service_port_free(service_port, server_lock_directory)
    current_selection = recover_selection(layout.app_home)
    candidate = _selection_candidate(
        selected_catalog,
        selected_lock,
        preset_id,
        int(current_selection.get("generation", 0) if current_selection else 0) + 1,
    )
    if current_selection is not None and not _same_selection(current_selection, candidate):
        raise InstallerError("a different managed preset is already configured")
    config_created = False
    release_created = False
    release_dir: Path | None = None
    old_target: Path | None = None
    runtime_snapshot: Any = None
    switched = False
    selection_created = False
    enable_attempted = False
    current_python: Path | None = None
    selection_path = layout.app_home / "config" / "selection.json"
    try:
        # Keep the application wheel in its own release before touching model/runtime state.
        release_dir, runtime_python, release_created = _stage_wheel(
            wheel,
            layout,
            uv_executable=uv_executable,
            runner=runner,
            install_diarization=(
                _config_enables_diarization(layout.config_file)
                if layout.config_file.is_file()
                else env_file is not None and _config_enables_diarization(env_file)
            ),
        )
        prepared_id = _prepare_models_for_install(
            preset_id,
            app_home=layout.app_home,
            downloader=downloader,
            catalog=selected_catalog,
            runtime_lock=selected_lock,
        )
        if not isinstance(prepared_id, str) or not prepared_id.strip():
            raise InstallerError("model preparation returned an invalid prepared ID")
        runtime_snapshot = snapshot_runtime_current(layout.app_home)
        prepared_runtime = prepare_runtime(
            selected_lock,
            layout.app_home,
            runtime_runner if runtime_runner is not None else runner,
        )
        if not isinstance(prepared_runtime, runtime_paths_type):
            raise InstallerError("runtime preparation returned invalid paths")
        if prepared_runtime.asr_python != prepared_runtime.tts_python:
            raise InstallerError("managed ASR and TTS runtimes must share one Python")

        if layout.config_file.exists():
            if env_file is not None and layout.config_file.absolute() != env_file.absolute():
                raise InstallerError("configuration already exists and will not be overwritten")
        elif env_file is not None:
            _copy_config_exclusive(env_file, layout.config_file)
            config_created = True
        else:
            _write_private_config(
                layout.config_file,
                _managed_config(
                    layout,
                    asr_key=selected_preset.asr,
                    tts_key=selected_preset.tts,
                ),
            )
            config_created = True

        preflight = run_preflight(
            runtime_python,
            layout,
            require_tts=require_tts,
            runner=runner,
        )
        if not preflight.ok:
            raise InstallerError("preflight failed; service was not enabled")

        # Preparation can take minutes. Recheck immediately before changing
        # runtime/current so a service started during preparation cannot be
        # mistaken for a safe cutover.
        _assert_service_port_free(service_port, server_lock_directory)

        already_current = (
            layout.current_runtime.is_symlink()
            and layout.current_runtime.resolve() == release_dir.resolve()
        )
        if not already_current:
            old_target = _switch_current(layout, release_dir)
            switched = True
        current_python = layout.current_runtime / ".venv" / "bin" / "python"
        _write_setup_launcher(layout.app_home)
        if not already_current:
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
        if current_selection is None:
            ProfileStore(layout.app_home).initialize(candidate)
            selection_created = True
        if enable:
            enable_attempted = True
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
            if post_enable is not None:
                post_enable(layout.app_home, prepared_id)
        return InstallResult(
            app_home=layout.app_home,
            runtime_python=runtime_python,
            plist_path=layout.plist_path,
            enabled=enable,
            prepared_id=prepared_id,
            runtime_key=prepared_runtime.runtime_key,
        )
    except BaseException as original_error:
        rollback_error: BaseException | None = None
        if enable_attempted and current_python is not None:
            try:
                _run(
                    (
                        str(current_python),
                        "-m",
                        "speechrail",
                        "service",
                        "stop",
                        "--app-home",
                        str(layout.app_home),
                    ),
                    runner,
                )
            except BaseException as exc:
                rollback_error = exc
        if runtime_snapshot is not None:
            try:
                restore_runtime_current(runtime_snapshot)
            except BaseException as exc:
                if rollback_error is None:
                    rollback_error = exc
        if switched and release_dir is not None:
            try:
                if layout.current_runtime.is_symlink():
                    layout.current_runtime.unlink()
                if old_target is not None:
                    layout.current_runtime.symlink_to(old_target, target_is_directory=True)
            except BaseException as exc:
                if rollback_error is None:
                    rollback_error = exc
        if config_created:
            try:
                layout.config_file.unlink(missing_ok=True)
            except BaseException as exc:
                if rollback_error is None:
                    rollback_error = exc
        if selection_created:
            try:
                if selection_path.is_symlink():
                    raise InstallerError("selection file became a symlink during rollback")
                selection_path.unlink(missing_ok=True)
            except BaseException as exc:
                if rollback_error is None:
                    rollback_error = exc
        if release_created and release_dir is not None:
            try:
                shutil.rmtree(release_dir, ignore_errors=True)
            except BaseException as exc:
                if rollback_error is None:
                    rollback_error = exc
        if rollback_error is not None:
            failure = InstallerError("managed installation rollback failed")
            failure.add_note(f"rollback error: {type(rollback_error).__name__}")
            raise failure from original_error
        raise


def install_wheel(
    wheel: Path,
    *,
    app_home: Path,
    env_file: Path,
    uv_executable: str = "uv",
    require_tts: bool = True,
    enable: bool = False,
    runner: CommandRunner = _runner,
    server_lock_directory: Path | None = None,
) -> InstallResult:
    """Stage, validate and optionally enable one wheel-based installation."""
    if not wheel.is_file() or wheel.suffix != ".whl":
        raise InstallerError("wheel file is missing or invalid")
    if not env_file.is_file():
        raise InstallerError("configuration file is missing")

    layout = InstallLayout.for_app_home(app_home)
    layout.ensure_directories()
    config_created = False
    config_exists = layout.config_file.exists()
    if config_exists and layout.config_file.absolute() != env_file.absolute():
        raise InstallerError("configuration already exists and will not be overwritten")
    _assert_explicit_install_allowed(
        layout,
        env_file,
        server_lock_directory=server_lock_directory,
    )
    if not config_exists:
        _copy_config(env_file, layout.config_file)
        config_created = True

    release_dir = layout.runtime_root / "releases" / _release_id(wheel)
    if release_dir.exists():
        if config_created:
            layout.config_file.unlink(missing_ok=True)
        raise InstallerError("this wheel is already staged")
    try:
        release_dir, runtime_python, _ = _stage_wheel(
            wheel,
            layout,
            uv_executable=uv_executable,
            runner=runner,
            install_diarization=_config_enables_diarization(env_file),
            allow_existing=False,
        )
        result = run_preflight(
            runtime_python, layout, require_tts=require_tts, runner=runner
        )
        if not result.ok:
            raise InstallerError("preflight failed; service was not enabled")

        old_target = _switch_current(layout, release_dir)
        try:
            current_python = layout.current_runtime / ".venv" / "bin" / "python"
            _write_setup_launcher(layout.app_home)
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
