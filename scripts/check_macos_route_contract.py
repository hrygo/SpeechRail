#!/usr/bin/env python3
"""Fail when the macOS navigation contract stops describing one route registry.

The sidebar groups, the keyboard shortcuts, the UI test route list and the
design audit matrix are four hand-maintained surfaces that all describe the
same 14 `AppRoute` pages. Adding or renaming a page can leave any one of them
behind, and the app still builds and runs — the page just quietly loses its
shortcut, its UI test or its audit row. Issue #79 tracks exactly that drift as
its Phase 0 risk, and this check is the defense it wired into the quality gate.

The rule is mechanical: `AppRoute.swift` is the registry, and the other
surfaces must agree with it. Two structural rules travel with it — `App.swift`
must not keep a second shortcut map (or a teleprompter exception), and
`ControlCenterView` must derive its three groups from the registry instead of
listing pages again.

What this cannot see: whether a shortcut is still the right shortcut, or
whether a page is reachable in practice. It owns "the four surfaces agree",
not "the routes are the right routes".
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_ROUTE = ROOT / "macos" / "SpeechRailApp" / "SpeechRailApp" / "AppRoute.swift"
APP = ROOT / "macos" / "SpeechRailApp" / "SpeechRailApp" / "App.swift"
CONTROL_CENTER = ROOT / "macos" / "SpeechRailApp" / "SpeechRailApp" / "ControlCenterView.swift"
UI_TESTS = ROOT / "macos" / "SpeechRailApp" / "SpeechRailAppUITests" / "SpeechRailAppUITests.swift"
MATRIX = ROOT / "docs" / "design" / "2026-09-15-macos-uiux-redesign" / "UIUX-AUDIT-MATRIX.md"

#: Registry order: route, shortcut key, shortcut modifiers.
ROUTES: tuple[tuple[str, str, str], ...] = (
    ("dubbing", "1", "command"),
    ("voiceDesign", "2", "command"),
    ("voiceClone", "3", "command"),
    ("voiceLibrary", "4", "command"),
    ("works", "5", "command"),
    ("assistant", "6", "command"),
    ("meeting", "7", "command"),
    ("captions", "8", "command"),
    ("teleprompter", "t", "commandShift"),
    ("overview", "9", "command"),
    ("monitoring", "0", "command"),
    ("models", "m", "commandShift"),
    ("diagnostics", "d", "commandShift"),
    ("developerDocs", "h", "commandShift"),
)

#: The sidebar title each route must show, in registry order.
UI_TITLES: tuple[str, ...] = (
    "配音台",
    "音色创作",
    "音色克隆",
    "音色库",
    "我的作品",
    "语音助手",
    "会议助手",
    "实时字幕",
    "AI 提词器",
    "服务状态",
    "运行监控",
    "模型组合",
    "诊断",
    "开发者文档",
)

#: The three sidebar groups `ControlCenterView` must derive from the registry.
GROUPS: tuple[str, ...] = ("creator", "session", "service")


def _read(path: Path, override: str | None) -> str:
    """Return the real repository text unless the caller supplies an override."""

    return path.read_text(encoding="utf-8") if override is None else override


def find_drift(
    *,
    app_route: str | None = None,
    app: str | None = None,
    control_center: str | None = None,
    ui_tests: str | None = None,
    matrix: str | None = None,
) -> list[str]:
    """Return every way the four surfaces disagree with the registry.

    Every input defaults to the real repository. The overrides exist so the
    rules themselves can be exercised against a surface that has actually
    drifted, which is the only way to show the checker fails when it should.
    """

    problems: list[str] = []
    registry = _read(APP_ROUTE, app_route)
    commands = _read(APP, app)
    sidebar = _read(CONTROL_CENTER, control_center)
    tests = _read(UI_TESTS, ui_tests)
    audit = _read(MATRIX, matrix)

    if "public var shortcutSpec: AppRouteShortcutSpec?" not in registry:
        problems.append("AppRoute.shortcutSpec is missing")
    if "public static func routes(in group: AppRouteGroup)" not in registry:
        problems.append("AppRoute.routes(in:) is missing")

    for route, key, modifiers in ROUTES:
        spec = rf'case \.{route}:\s+\.init\(key: "{key}", modifiers: \.{modifiers}\)'
        if not re.search(spec, registry):
            problems.append(f"missing shortcut spec: {spec}")
        if not re.search(rf"^    case {re.escape(route)}$", registry, re.MULTILINE):
            problems.append(f"AppRoute enum is missing: {route}")

    for title in UI_TITLES:
        if f'"{title}"' not in tests:
            problems.append(f"UI test route list is missing: {title}")

    for route, _key, _modifiers in ROUTES:
        if f"| {route} |" not in audit:
            problems.append(f"audit matrix is missing route: {route}")

    if "routeShortcuts" in commands or "route == .teleprompter" in commands:
        problems.append(
            "SpeechRailCommands still owns a duplicate shortcut map or teleprompter exception"
        )

    for group in GROUPS:
        if f"AppRoute.routes(in: .{group})" not in sidebar:
            problems.append(f"ControlCenterView does not derive the {group} group from AppRoute")

    return problems


def main() -> int:
    problems = find_drift()
    if problems:
        for problem in problems:
            print(f"route contract check failed: {problem}", file=sys.stderr)
        return 1
    print(
        "macOS route contract: 14 enum cases, 14 shortcut specs, 14 UI test entries, "
        "14 matrix entries, one registry"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
