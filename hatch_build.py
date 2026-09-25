"""Build the macOS-only CoreML diarization worker into the wheel."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        del version
        if self.target_name != "wheel":
            return
        _include_engine_wheel(self, build_data)
        if sys.platform != "darwin":
            # The application is macOS-only; Linux CI can build and test the
            # Python package without attempting to compile its CoreML worker.
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
