"""Install a SpeechRail wheel into a user-owned macOS runtime.

The installer ships inside the wheel so a release can be installed without a
source checkout.  :func:`install_managed` stays import-only and single-entry:
the ``speechrail install`` subcommand and the release workflow both call it, and
neither adds a second installation path.
"""

from __future__ import annotations

import asyncio
import hashlib
import os
import shlex
import shutil
import subprocess
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from speechrail.config.model_catalog import (
    ModelCatalog,
    RuntimeLock,
    load_catalog,
    load_runtime_lock,
)
from speechrail.domain.model_spec import required_spec_artifact
from speechrail.runtime.server_lock import ServerInstanceError, ServerInstanceLock
from speechrail.service.bootstrap import (
    RuntimeCurrentSnapshot,
    RuntimePaths,
    prepare_runtime,
    restore_runtime_current,
    snapshot_runtime_current,
)
from speechrail.service.installer_errors import InstallerError
from speechrail.service.model_store import Downloader, prepare_spec_models
from speechrail.service.paths import ServiceLayout
from speechrail.service.profile_store import ProfileStore, recover_selection

CommandRunner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]


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


@dataclass(frozen=True)
class DiarizationInstallPaths:
    """Verified external assets that make diarization part of a fresh install."""

    coreml_model_path: Path
    aligner_model_dir: Path


def _runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=False, capture_output=True, text=True)


def _run(command: tuple[str, ...], runner: CommandRunner) -> None:
    try:
        completed = runner(command)
    except OSError as exc:
        raise InstallerError("required local command could not be executed") from exc
    if completed.returncode != 0:
        # The CLI passes an absolute path, so classify by executable name.
        if command and Path(command[0]).name == "uv":
            raise InstallerError("uv command failed")
        raise InstallerError("installed service command failed")


def run_preflight(
    runtime_python: Path,
    layout: ServiceLayout,
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
        "--host-python",
        str(runtime_python),
    )
    if not require_tts:
        command += ("--asr-only",)
    try:
        completed = runner(command)
    except OSError as exc:
        raise InstallerError("installed wheel preflight could not be executed") from exc
    return PreflightOutcome(ok=completed.returncode == 0)


def _config_enables_diarization(env_file: Path) -> bool:
    """Detect an opted-in diarization profile without logging configuration values."""
    for raw_line in env_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH="):
            return bool(line.partition("=")[2].strip())
    return False


def _switch_current(layout: ServiceLayout, release_dir: Path) -> Path | None:
    if layout.current_runtime.exists() and not layout.current_runtime.is_symlink():
        raise InstallerError("runtime/current must be a symlink")
    old_target = layout.current_runtime.readlink() if layout.current_runtime.is_symlink() else None
    temporary_link = layout.runtime_root / ".current.new"
    temporary_link.unlink(missing_ok=True)
    temporary_link.symlink_to(release_dir, target_is_directory=True)
    temporary_link.replace(layout.current_runtime)
    return old_target


def _restore_current(layout: ServiceLayout, old_target: Path | None) -> None:
    if layout.current_runtime.is_symlink():
        layout.current_runtime.unlink()
    if old_target is not None:
        layout.current_runtime.symlink_to(old_target, target_is_directory=True)


def _release_id(wheel: Path, python_version: str) -> str:
    digest = hashlib.sha256(wheel.read_bytes()).hexdigest()[:12]
    python_tag = python_version.replace(".", "")
    return f"{wheel.stem}-{digest}-py{python_tag}"


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


def setup_launcher_path(app_home: Path) -> Path:
    """Return the double-click setup entry written for an installed app home."""
    return app_home.absolute() / "SpeechRail 设置.command"


def _write_setup_launcher(app_home: Path) -> Path:
    """Atomically install a double-click entry for the current managed release."""
    resolved_home = app_home.absolute()
    destination = setup_launcher_path(resolved_home)
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


def _copy_config_exclusive(source: Path, destination: Path) -> None:
    """Copy a managed source config without replacing a concurrent destination."""
    _write_private_config(destination, source.read_bytes())


def _managed_config(
    layout: ServiceLayout,
    *,
    asr_key: str,
    tts_key: str,
    diarization_assets: DiarizationInstallPaths | None = None,
) -> str:
    """Render the minimal loopback configuration for a catalog selection."""
    model_root = layout.models_root
    vendor_python = layout.vendor_current / "bin" / "python"
    vendor_ffmpeg = layout.vendor_current / "ffmpeg" / "bin" / "ffmpeg"
    lines: tuple[str, ...] = (
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
    if diarization_assets is not None:
        lines += (
            f"SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH={diarization_assets.coreml_model_path}",
            f"SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR={diarization_assets.aligner_model_dir}",
        )
    return "\n".join(lines) + "\n"


def _selection_candidate(
    asr_spec: str,
    tts_spec: str,
    auto: str,
    runtime_lock: RuntimeLock,
    generation: int,
) -> dict[str, object]:
    if asr_spec not in _SPEC_TIERS or tts_spec not in _SPEC_TIERS:
        raise InstallerError(f"unknown managed spec tier: {asr_spec}/{tts_spec}")
    if auto not in {"off", "resource"}:
        raise InstallerError(f"unknown managed auto policy: {auto}")
    return {
        "schema_version": 2,
        "asr_spec": asr_spec,
        "tts_spec": tts_spec,
        "auto": auto,
        "generation": generation,
        "runtime_lock_id": runtime_lock.id,
    }


_SPEC_TIERS = frozenset({"fast", "quality", "reference"})
_SELECTION_IDENTITY_KEYS = ("schema_version", "asr_spec", "tts_spec", "auto")


def _same_selection(
    current: dict[str, object] | None, candidate: dict[str, object]
) -> bool:
    """Return whether both records select the same managed profile."""
    if current is None:
        return False
    return all(current.get(key) == candidate.get(key) for key in _SELECTION_IDENTITY_KEYS)


def _selection_drift(
    current: dict[str, object] | None, candidate: dict[str, object]
) -> tuple[str, ...]:
    """Return the candidate fields the committed record does not already carry.

    ``generation`` is skipped because every install bumps it. The runtime lock
    identity stays in, so reinstalling the same profile migrates the committed
    record onto the lock published by the wheel instead of failing.
    """
    if current is None:
        return ()
    return tuple(
        key
        for key, value in candidate.items()
        if key != "generation" and current.get(key) != value
    )


def _configured_service_port(layout: ServiceLayout, env_file: Path | None) -> int:
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
    try:
        with ServerInstanceLock(port, directory=directory):
            pass
    except ServerInstanceError as exc:
        raise InstallerError(
            "managed installation requires the SpeechRail service to be stopped"
        ) from exc
    except OSError as exc:
        raise InstallerError("managed installation could not verify the service lock") from exc



def _patch_entry_points(release_dir: Path) -> None:
    """Replace uv-generated console scripts with stable runtime/current wrappers.

    uv pip install hardcodes the Python absolute path into console scripts.
    After a ``runtime/current`` switch those scripts still reference the old
    release.  Patching them to resolve ``runtime/current`` at startup keeps
    ``~/.local/bin/speechrail[-mcp]`` (which symlinks into the current venv)
    working across releases without client-side changes.
    """
    app_home_default = "$HOME/Library/Application Support/SpeechRail"
    for name, module in (("speechrail-mcp", "speechrail.mcp"), ("speechrail", "speechrail")):
        script = release_dir / ".venv" / "bin" / name
        if not script.is_file():
            continue
        lines = [
            "#!/bin/sh",
            "# Stable entry point: always delegates to runtime/current.",
            '_app_home="${SPEECHRAIL_APP_HOME:-' + app_home_default + '}"',
            '_python="$_app_home/runtime/current/.venv/bin/python"',
            'if [ ! -x "$_python" ]; then',
            '  echo "' + name + ': runtime/current python not found" >&2',
            "  exit 1",
            "fi",
            'exec "$_python" -m ' + module + ' "$@"',
            "",
        ]
        script.write_text("\n".join(lines), encoding="utf-8")
        script.chmod(0o755)


def _stage_wheel(
    wheel: Path,
    layout: ServiceLayout,
    *,
    uv_executable: str,
    runner: CommandRunner,
    python_version: str,
    install_diarization: bool = False,
) -> tuple[Path, Path, bool]:
    """Stage one wheel release, optionally reusing a complete release.

    Managed installation keeps release identity, virtualenv creation and
    cleanup in one boundary.  The ``mcp`` extra is always installed so the
    bundled ``speechrail-mcp`` proxy works out of the box with zero extra
    configuration; ``diarization`` stays opt-in because it needs a model path.
    """
    release_dir = layout.runtime_root / "releases" / _release_id(wheel, python_version)
    if release_dir.is_symlink():
        raise InstallerError("wheel release must not be a symlink")
    if release_dir.exists():
        runtime_python = release_dir / ".venv" / "bin" / "python"
        if runtime_python.is_file():
            return release_dir, runtime_python, False
        raise InstallerError("this wheel release is incomplete")

    release_dir.mkdir(parents=True)
    venv_dir = release_dir / ".venv"
    runtime_python = venv_dir / "bin" / "python"
    wheel_requirement = str(wheel)
    extras: list[str] = ["mcp"]  # mcp 默认启用: 轻量协议层 零配置即用
    if install_diarization:
        extras.append("diarization")
    wheel_requirement += "[" + ",".join(extras) + "]"
    try:
        _run((uv_executable, "venv", "--python", python_version, str(venv_dir)), runner)
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
        _patch_entry_points(release_dir)
    except BaseException:
        shutil.rmtree(release_dir, ignore_errors=True)
        raise
    return release_dir, runtime_python, True


def _prepare_models_for_install(
    asr_spec: str,
    tts_spec: str,
    *,
    app_home: Path,
    downloader: Downloader,
    catalog: ModelCatalog,
    runtime_lock: RuntimeLock,
    progress: Callable[[dict[str, object]], None] | None = None,
) -> str:
    try:
        return asyncio.run(
            prepare_spec_models(
                asr_spec,  # type: ignore[arg-type]
                tts_spec,  # type: ignore[arg-type]
                app_home=app_home,
                downloader=downloader,
                catalog=catalog,
                runtime_lock=runtime_lock,
                progress=progress,
            )
        )
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        raise InstallerError("model preparation failed") from exc


def _provision_managed_diarization_assets(
    app_home: Path,
    *,
    aligner_key: str,
    downloader: Any,
) -> DiarizationInstallPaths:
    """Provision explicit opt-in diarization assets inside a managed install.

    The release workflow may already hand over verified paths.  When it does
    not, the installer still owns the invariant that the requested aligner
    directory exists before the new wheel's preflight resolves it; otherwise an
    upgrade whose previous layout predates the directory fails closed.
    """
    from speechrail.service.diarization_assets import prepare_diarization_assets

    try:
        provisioned = prepare_diarization_assets(
            app_home,
            aligner_key=aligner_key,
            downloader=downloader,
        )
    except Exception as exc:
        raise InstallerError("diarization asset preparation failed") from exc
    return DiarizationInstallPaths(
        coreml_model_path=provisioned.coreml_model_path,
        aligner_model_dir=provisioned.aligner_model_dir,
    )


def install_managed(
    wheel: Path,
    *,
    app_home: Path,
    asr_spec: str,
    tts_spec: str,
    downloader: Downloader,
    auto: str = "off",
    runtime_runner: CommandRunner | None = None,
    uv_executable: str = "uv",
    require_tts: bool = True,
    progress: Callable[[dict[str, object]], None] | None = None,
    enable: bool = False,
    runner: CommandRunner = _runner,
    catalog: ModelCatalog | None = None,
    runtime_lock: RuntimeLock | None = None,
    env_file: Path | None = None,
    server_lock_directory: Path | None = None,
    post_enable: Callable[[Path, str], None] | None = None,
    diarization_assets: DiarizationInstallPaths | None = None,
    diarization_aligner: str | None = None,
) -> InstallResult:
    """Install one explicit ASR/TTS spec pair with a shared, lock-keyed runtime."""
    if not wheel.is_file() or wheel.suffix != ".whl":
        raise InstallerError("wheel file is missing or invalid")
    if env_file is not None and not env_file.is_file():
        raise InstallerError("configuration file is missing")
    if post_enable is not None and not enable:
        raise InstallerError("post-enable verifier requires enable=True")
    if diarization_assets is not None and (
        not diarization_assets.coreml_model_path.is_dir()
        or not diarization_assets.aligner_model_dir.is_dir()
    ):
        raise InstallerError("diarization assets must be verified directories")
    try:
        selected_catalog = catalog if catalog is not None else load_catalog()
        selected_lock = runtime_lock if runtime_lock is not None else load_runtime_lock()
        asr_key = required_spec_artifact(asr_spec, "asr")  # type: ignore[arg-type]
        tts_key = required_spec_artifact(tts_spec, "tts_custom_voice")  # type: ignore[arg-type]
    except (KeyError, ValueError, TypeError) as exc:
        raise InstallerError("managed catalog or runtime lock is invalid") from exc
    if asr_key is None or tts_key is None:
        raise InstallerError(f"managed spec is not bound to artifacts: {asr_spec}/{tts_spec}")
    artifact_keys = {artifact.key for artifact in selected_catalog.artifacts}
    if asr_key not in artifact_keys or tts_key not in artifact_keys:
        raise InstallerError(f"managed spec artifact is unavailable: {asr_key}/{tts_key}")

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
    previous_generation = current_selection.get("generation", 0) if current_selection else 0
    if type(previous_generation) is not int:
        raise InstallerError("managed selection is invalid")
    candidate = _selection_candidate(
        asr_spec,
        tts_spec,
        auto,
        selected_lock,
        previous_generation + 1,
    )
    if current_selection is not None and not _same_selection(current_selection, candidate):
        raise InstallerError("a different managed selection is already configured")
    selection_previous = dict(current_selection) if current_selection is not None else None
    selection_drift = _selection_drift(current_selection, candidate)
    config_created = False
    release_created = False
    release_dir: Path | None = None
    old_target: Path | None = None
    runtime_snapshot: RuntimeCurrentSnapshot | None = None
    switched = False
    selection_created = False
    selection_updated = False
    enable_attempted = False
    current_python: Path | None = None
    selection_path = layout.app_home / "config" / "selection.json"
    try:
        # Provision before the managed config and preflight so the selection's
        # per-tier aligner directory exists when resolve_selection reads it.
        if diarization_assets is None and diarization_aligner is not None:
            diarization_assets = _provision_managed_diarization_assets(
                layout.app_home,
                aligner_key=diarization_aligner,
                downloader=downloader,
            )
        # Keep the application wheel in its own release before touching model/runtime state.
        release_dir, runtime_python, release_created = _stage_wheel(
            wheel,
            layout,
            uv_executable=uv_executable,
            runner=runner,
            python_version=selected_lock.python,
            install_diarization=(
                diarization_assets is not None
                or (
                    _config_enables_diarization(layout.config_file)
                    if layout.config_file.is_file()
                    else env_file is not None and _config_enables_diarization(env_file)
                )
            ),
        )
        prepared_id = _prepare_models_for_install(
            asr_spec,
            tts_spec,
            app_home=layout.app_home,
            downloader=downloader,
            catalog=selected_catalog,
            runtime_lock=selected_lock,
            progress=progress,
        )
        if not isinstance(prepared_id, str) or not prepared_id.strip():
            raise InstallerError("model preparation returned an invalid prepared ID")
        runtime_snapshot = snapshot_runtime_current(layout.app_home)
        prepared_runtime = prepare_runtime(
            selected_lock,
            layout.app_home,
            runtime_runner if runtime_runner is not None else runner,
        )
        if not isinstance(prepared_runtime, RuntimePaths):
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
                    asr_key=asr_key,
                    tts_key=tts_key,
                    diarization_assets=diarization_assets,
                ),
            )
            config_created = True

        if selection_drift:
            ProfileStore(layout.app_home).replace(candidate)
            selection_updated = True

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
        if selection_updated:
            try:
                ProfileStore(layout.app_home).replace(selection_previous)
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


if __name__ == "__main__":
    raise SystemExit(
        "tools/install_macos.py is import-only; call install_managed(...) from the release workflow"
    )
