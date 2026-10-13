"""The macOS route-contract checker must fail on the drift it claims to catch."""

from __future__ import annotations

import importlib.util
from pathlib import Path


def _checker() -> object:
    script_path = Path(__file__).parents[1] / "scripts" / "check_macos_route_contract.py"
    spec = importlib.util.spec_from_file_location(
        "check_macos_route_contract",
        script_path,
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _satisfied_world(module: object) -> dict[str, str]:
    """A synthetic repository where the four surfaces agree with the registry."""

    routes = module.ROUTES  # type: ignore[attr-defined]
    titles = module.UI_TITLES  # type: ignore[attr-defined]
    groups = module.GROUPS  # type: ignore[attr-defined]

    enum_lines = [f"    case {route}" for route, _key, _modifiers in routes]
    spec_lines: list[str] = []
    for route, key, modifiers in routes:
        spec_lines.append(f"        case .{route}:")
        spec_lines.append(f'            .init(key: "{key}", modifiers: .{modifiers})')

    registry = "\n".join(
        [
            "public enum AppRoute {",
            *enum_lines,
            "",
            "    public var shortcutSpec: AppRouteShortcutSpec? {",
            "        switch self {",
            *spec_lines,
            "        }",
            "    }",
            "",
            "    public static func routes(in group: AppRouteGroup) { allCases }",
            "}",
        ]
    )
    ui_tests = "\n".join(f'        "{title}",' for title in titles)
    paired = zip(routes, titles, strict=True)
    matrix = "\n".join(f"| {route} | {title} |" for (route, _k, _m), title in paired)
    control_center = "\n".join(
        f"    AppRoute.routes(in: .{group}).map {{ $0 }}" for group in groups
    )
    return {
        "app_route": registry,
        "app": "// no second shortcut map\n",
        "control_center": control_center,
        "ui_tests": ui_tests,
        "matrix": matrix,
    }


def test_the_real_registry_and_its_four_surfaces_agree_today() -> None:
    """The real AppRoute, App, ControlCenterView, UI tests and audit matrix."""

    module = _checker()
    assert module.find_drift() == []  # type: ignore[attr-defined]


def test_a_world_with_no_drift_reports_nothing() -> None:
    module = _checker()
    world = _satisfied_world(module)
    assert module.find_drift(**world) == []  # type: ignore[attr-defined]


def test_a_dropped_route_is_reported_from_both_the_enum_and_the_shortcut_spec() -> None:
    module = _checker()
    world = _satisfied_world(module)
    world["app_route"] = world["app_route"].replace(
        '    case teleprompter\n', ""
    ).replace(
        '        case .teleprompter:\n'
        '            .init(key: "t", modifiers: .commandShift)\n',
        "",
    )
    problems = module.find_drift(**world)  # type: ignore[attr-defined]
    assert any("AppRoute enum is missing: teleprompter" in p for p in problems), problems
    assert any("shortcut spec" in p for p in problems), problems


def test_a_missing_ui_test_title_is_reported() -> None:
    module = _checker()
    world = _satisfied_world(module)
    world["ui_tests"] = world["ui_tests"].replace('        "AI 提词器",\n', "")
    problems = module.find_drift(**world)  # type: ignore[attr-defined]
    assert any("UI test route list is missing: AI 提词器" in p for p in problems), problems


def test_a_missing_matrix_row_is_reported() -> None:
    module = _checker()
    world = _satisfied_world(module)
    world["matrix"] = "\n".join(
        line for line in world["matrix"].splitlines() if not line.startswith("| monitoring |")
    )
    problems = module.find_drift(**world)  # type: ignore[attr-defined]
    assert any("audit matrix is missing route: monitoring" in p for p in problems), problems


def test_a_second_shortcut_map_in_app_swift_is_reported() -> None:
    module = _checker()
    world = _satisfied_world(module)
    world["app"] = "private let routeShortcuts: [AppRoute: KeyboardShortcut] = [:]"
    problems = module.find_drift(**world)  # type: ignore[attr-defined]
    assert any("duplicate shortcut map" in p for p in problems), problems


def test_a_teleprompter_exception_in_app_swift_is_reported() -> None:
    module = _checker()
    world = _satisfied_world(module)
    world["app"] = "if route == .teleprompter { return nil }"
    problems = module.find_drift(**world)  # type: ignore[attr-defined]
    assert any("teleprompter exception" in p for p in problems), problems


def test_a_group_the_sidebar_stops_deriving_is_reported() -> None:
    module = _checker()
    world = _satisfied_world(module)
    world["control_center"] = "\n".join(
        line for line in world["control_center"].splitlines() if ".service" not in line
    )
    problems = module.find_drift(**world)  # type: ignore[attr-defined]
    assert any("service group" in p for p in problems), problems
