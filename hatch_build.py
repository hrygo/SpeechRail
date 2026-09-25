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
        _include_vendor_overlay(self, build_data)
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

def _include_vendor_overlay(hook: object, build_data: dict[str, object]) -> None:
    root_value = getattr(hook, "root", None)
    if not isinstance(root_value, (str, Path)):
        raise RuntimeError("vendor overlay hook root is invalid")
    root = Path(root_value)
    source_root = root / "vendor" / "mlx-audio-incremental" / "src"
    if not source_root.is_dir():
        raise RuntimeError("vendor overlay source directory is missing")
    sources = sorted(path for path in source_root.rglob("*.py") if path.is_file())
    if not sources:
        raise RuntimeError("vendor overlay contains no Python modules")
    force_include = build_data.setdefault("force_include", {})
    assert isinstance(force_include, dict)
    for source in sources:
        if source.is_symlink():
            raise RuntimeError("vendor overlay cannot contain symlinks")
        relative = source.relative_to(source_root).as_posix()
        if not relative.startswith("mlx_audio/"):
            raise RuntimeError("vendor overlay modules must stay within mlx_audio")
        destination = "speechrail/assets/vendor/mlx-audio-incremental/src/" + relative
        force_include[str(source)] = destination
