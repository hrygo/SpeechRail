#!/usr/bin/env python3
"""Fail when the two macOS test manifests stop describing the same test suite.

`swift test` and `xcodebuild test` compile this suite from two hand-maintained
lists: SwiftPM takes every `.swift` in the test directory, while Xcode takes
only what its `Unit Test Sources` build phase names. Nothing checked that the
two agreed, so a file could quietly drop out of the Xcode gate — or a file
could be removed from disk and left behind in the phase, where it fails to
build.

The rule is deliberately one-directional and mechanical: every test file on
disk must be compiled by the Xcode unit-test target, unless it is on the
allowlist below with a stated reason. Anything else is drift, in either
direction.

`--test-unit` exists to prove the app target still builds under Xcode; this
check is what keeps the comment above that step honest.

What this cannot see: whether a test file's *subject* is also in the phase.
Adding `WindowLayoutPolicyTests.swift` without `WindowLayoutPolicy.swift`
passes here and fails to compile. That division is deliberate — this check
owns "which suites run", the compiler owns "whether they build" — but it means
a green run of this script is not evidence that `xcodebuild test` compiles.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "macos" / "SpeechRailApp" / "Package.swift"
PBXPROJ = ROOT / "macos" / "SpeechRailApp" / "SpeechRailApp.xcodeproj" / "project.pbxproj"
TEST_DIR = ROOT / "macos" / "SpeechRailApp" / "SpeechRailMacControlTests"
PACKAGE_MANIFEST = "macos/SpeechRailApp/Package.swift"
PBXPROJ_MANIFEST = "macos/SpeechRailApp/SpeechRailApp.xcodeproj/project.pbxproj"

TEST_TARGET_NAME = "SpeechRailMacControlTests"
UNIT_TEST_TARGET_NAME = "SpeechRailAppTests"

#: Test files that exist on disk but cannot join the Xcode gate yet.
#:
#: `ModelNamePresentation` / `ModelReadinessPresenter` live inside
#: `ModelManagementView.swift`, which `Package.swift` excludes from
#: `SpeechRailAppSupport`, so the Xcode test target has no definition to link
#: against either. Joining them is a structural split, not a phase entry —
#: see #194. Every entry here must name the issue that unblocks it.
ALLOWLIST: dict[str, str] = {
    "ModelNamePresentationTests.swift": "#194",
    "ModelReadinessPresentationTests.swift": "#194",
}


def _spm_test_target_body() -> str:
    """Return the `SpeechRailMacControlTests` target declaration."""

    text = PACKAGE.read_text(encoding="utf-8")
    start = text.find(f'.testTarget(\n            name: "{TEST_TARGET_NAME}"')
    if start < 0:
        raise SystemExit(f"{PACKAGE_MANIFEST} no longer declares the {TEST_TARGET_NAME} target")
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise SystemExit(f"{PACKAGE_MANIFEST} has an unterminated {TEST_TARGET_NAME} target")


def _object_paths(objects: dict[str, dict[str, object]]) -> dict[str, str]:
    """Map every file reference to its path relative to the package root."""

    parents: dict[str, str] = {}
    for value in objects.values():
        if value.get("isa") not in {
            "PBXGroup",
            "PBXVariantGroup",
            "XCVersionGroup",
        }:
            continue
        for child in value.get("children", []):
            parents[child] = value["_id"]

    paths: dict[str, str] = {}
    for key, value in objects.items():
        if value.get("isa") != "PBXFileReference":
            continue
        parts = [value.get("path") or value.get("name")]
        cursor = parents.get(key)
        while cursor is not None:
            group = objects[cursor]
            if group.get("path"):
                parts.append(group["path"])
            if group.get("sourceTree") == "SOURCE_ROOT" or group.get("name") == "Products":
                break
            cursor = parents.get(cursor)
        paths[key] = "/".join(part for part in reversed(parts) if part)
    return paths


def xcode_unit_test_sources() -> set[str]:
    """Return the repo-relative paths the Xcode unit-test target compiles."""

    raw = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(PBXPROJ)],
        check=True,
        capture_output=True,
    ).stdout
    objects = json.loads(raw)["objects"]
    for key, value in objects.items():
        value["_id"] = key

    target_ids = [
        key
        for key, value in objects.items()
        if value.get("isa") == "PBXNativeTarget"
        and value.get("name") == UNIT_TEST_TARGET_NAME
        and value.get("productType") == "com.apple.product-type.bundle.unit-test"
    ]
    if len(target_ids) != 1:
        raise SystemExit(
            f"{PBXPROJ_MANIFEST} must declare exactly one {UNIT_TEST_TARGET_NAME} "
            f"unit-test target, found {len(target_ids)}"
        )

    phases = [
        objects[phase_id]
        for phase_id in objects[target_ids[0]]["buildPhases"]
        if objects[phase_id]["isa"] == "PBXSourcesBuildPhase"
    ]
    if len(phases) != 1:
        raise SystemExit(
            f"{UNIT_TEST_TARGET_NAME} must have exactly one Sources build phase, "
            f"found {len(phases)}"
        )

    paths = _object_paths(objects)
    names: set[str] = set()
    for build_file_id in phases[0]["files"]:
        resolved = paths.get(objects[build_file_id]["fileRef"])
        if resolved is None:
            raise SystemExit(f"{PBXPROJ_MANIFEST} has a Sources entry with no readable path")
        names.add(resolved)
    return names


TEST_DIR_PREFIX = "SpeechRailMacControlTests/"


def find_drift(
    *,
    package_body: str | None = None,
    compiled_tests: set[str] | None = None,
    on_disk: set[str] | None = None,
    allowlist: dict[str, str] | None = None,
) -> list[str]:
    """Return every way the two manifests disagree about the test suite.

    Every input defaults to the real repository. The overrides exist so the
    rules themselves can be exercised against a manifest that has actually
    drifted, which is the only way to show the checker fails when it should.
    """

    problems: list[str] = []

    # The SwiftPM side is only "every file on disk" while the target is not
    # narrowed. If that ever changes, this check would be asserting something
    # false, so it fails loudly instead of quietly under-reporting.
    body = _spm_test_target_body() if package_body is None else package_body
    for narrowing in ("exclude:", "sources:"):
        if narrowing in body:
            problems.append(
                f"{PACKAGE_MANIFEST} narrows the {TEST_TARGET_NAME} target with "
                f"`{narrowing}`; this checker compares the whole directory and "
                "must be taught the new list before it can be trusted"
            )

    if compiled_tests is None:
        compiled_tests = {
            name[len(TEST_DIR_PREFIX) :]
            for name in xcode_unit_test_sources()
            if name.startswith(TEST_DIR_PREFIX)
        }
    if on_disk is None:
        on_disk = {path.name for path in TEST_DIR.glob("*.swift")}
    exemptions = ALLOWLIST if allowlist is None else allowlist

    for name in sorted(on_disk - compiled_tests):
        if name in exemptions:
            continue
        problems.append(
            f"{name} exists but the Xcode unit-test target does not compile "
            f"it; `xcodebuild test` silently runs fewer suites than `swift test`"
        )

    for name in sorted(compiled_tests - on_disk):
        problems.append(
            f"{name} is in the Xcode Sources phase but no longer exists on disk; "
            f"the Xcode project will not build"
        )

    for name in sorted(set(exemptions) - on_disk):
        problems.append(
            f"allowlist still excuses {name}, which is no longer on disk; "
            "delete the entry so the exemption cannot outlive its reason"
        )

    for name, reason in sorted(exemptions.items()):
        if not reason.startswith("#"):
            problems.append(f"allowlist entry {name} must name the issue unblocking it")

    return problems


def main() -> int:
    problems = find_drift()
    if problems:
        for problem in problems:
            print(f"macos-test-target-coverage: {problem}", file=sys.stderr)
        return 1
    print("macos-test-target-coverage: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
