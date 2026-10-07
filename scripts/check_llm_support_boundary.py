#!/usr/bin/env python3
"""Type-check the shared LLM support without any feature source files."""

import subprocess
from pathlib import Path


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    package = root / "macos" / "SpeechRailApp"
    source = package / "SpeechRailApp" / "LLMProvider.swift"
    # Build only the SDK dependency. No SpeechRail preparation/prompts target is
    # passed to the compiler, so a reverse dependency is a real compilation error.
    subprocess.run(
        ["swift", "build", "--package-path", str(package), "--target", "OpenAI"],
        check=True,
    )
    binary_path = Path(
        subprocess.check_output(
            ["swift", "build", "--package-path", str(package), "--show-bin-path"],
            text=True,
        ).strip()
    )
    subprocess.run(
        [
            "swiftc",
            "-typecheck",
            "-swift-version",
            "6",
            "-I",
            str(binary_path),
            "-I",
            str(binary_path / "Modules"),
            str(source),
        ],
        check=True,
    )
    print("LLM support type-check passed with no feature sources.")


if __name__ == "__main__":
    main()
