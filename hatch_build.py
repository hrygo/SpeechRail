"""Build the macOS-only CoreML diarization worker into the wheel."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

#: The single macOS release this wheel targets, matching the project baseline
#: in ``AGENTS.md``. Left unset, hatchling derives the platform tag from the
#: build host, so one commit yields ``macosx_26_0`` on a CI runner and
#: ``macosx_27_0`` on a newer Mac: two different artifacts published under one
#: version number, and a local ``speechrail install`` check stops standing in
#: for the wheel people actually download. An explicit environment value still
#: wins, so a deliberate one-off build is not silently overridden.
MACOSX_DEPLOYMENT_TARGET = "26.0"

# Opt-out for the native worker build, used by CI to keep an editable install
# cheap. The worker is a release artifact input, not a test input: nothing in
# the test suite consumes the binary this hook produces, so a test-only sync
# does not have to pay for it. Default stays "build", and any wheel published
# by CI is still asserted to carry the worker before release.
NATIVE_BUILD_SKIP_ENV = "SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD"


class CustomBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        del version
        if self.target_name != "wheel":
            return
        os.environ.setdefault("MACOSX_DEPLOYMENT_TARGET", MACOSX_DEPLOYMENT_TARGET)
        _include_engine_wheel(self, build_data)
        if sys.platform != "darwin" or _native_build_skipped():
            # The application is macOS-only; Linux CI can build and test the
            # Python package without attempting to compile its CoreML worker.
            # The opt-out covers macOS, where the worker is otherwise compiled
            # on every sync even when the caller only needs the Python package.
            return
        root = Path(self.root)
        package_dir = Path(self.directory) / "speechrail-native"
        package_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "swift",
                "build",
                "--configuration",
                "release",
                "--package-path",
                "native/diarization",
            ],
            cwd=root,
            check=True,
        )
        binary = root / "native/diarization/.build/release/SpeechRailDiarizationWorker"
        if not binary.is_file():
            raise RuntimeError("Swift diarization worker build did not produce an executable")
        destination = package_dir / "SpeechRailDiarizationWorker"
        shutil.copy2(binary, destination)
        force_include = build_data.setdefault("force_include", {})
        assert isinstance(force_include, dict)
        force_include[str(destination)] = "speechrail/_native/SpeechRailDiarizationWorker"
        build_data["infer_tag"] = True


def _native_build_skipped() -> bool:
    """Return whether the caller opted out of compiling the native worker."""

    return os.environ.get(NATIVE_BUILD_SKIP_ENV, "").strip().lower() in {
        "1",
        "true",
        "yes",
    }


def _include_engine_wheel(hook: object, build_data: dict[str, object]) -> None:
    """Ship the controlled engine wheel and its provenance, not overlay sources.

    The wheel only exists once ``tools/build_engine_wheel.py`` has passed the T03
    build gate.  Until then nothing is force-included and the runtime lock carries
    no ``engine_wheel`` pin, so a build never pretends to deliver a wheel it does
    not have.
    """

    root_value = getattr(hook, "root", None)
    if not isinstance(root_value, (str, Path)):
        raise RuntimeError("engine wheel hook root is invalid")
    dist_root = Path(root_value) / "vendor" / "engine-build" / "dist"
    if not dist_root.is_dir():
        return
    provenance = dist_root / "provenance.json"
    wheels = sorted(path for path in dist_root.glob("*.whl") if path.is_file())
    if not wheels:
        if provenance.exists():
            raise RuntimeError("engine wheel provenance has no wheel")
        return
    if len(wheels) != 1 or not provenance.is_file():
        raise RuntimeError("engine build dist must contain exactly one wheel and provenance")
    wheel = wheels[0]
    if wheel.is_symlink() or provenance.is_symlink():
        raise RuntimeError("engine wheel delivery cannot contain symlinks")
    force_include = build_data.setdefault("force_include", {})
    assert isinstance(force_include, dict)
    force_include[str(wheel)] = "speechrail/assets/vendor/engine/dist/" + wheel.name
    force_include[str(provenance)] = "speechrail/assets/vendor/engine/dist/provenance.json"
