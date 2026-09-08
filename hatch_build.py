"""Build the macOS-only CoreML diarization worker into the wheel."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class CustomBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, object]) -> None:
        del version
        if self.target_name != "wheel":
            return
        root = Path(self.root)
        package_dir = Path(self.directory) / "speechrail-native"
        package_dir.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["swift", "build", "--configuration", "release", "--package-path", "native/diarization"],
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
