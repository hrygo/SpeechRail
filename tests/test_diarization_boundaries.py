"""Dependency boundaries for the clean diarization domain/application layers."""

import ast
from pathlib import Path

ROOT = Path(__file__).parents[1] / "src" / "speechrail"
FORBIDDEN_PREFIXES = ("fastapi", "coreml", "nemo", "speechrail.backends")


def _imports(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    imported: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module is not None:
            imported.add(node.module)
    return imported


def test_diarization_domain_and_actor_do_not_depend_on_transport_or_vendors() -> None:
    paths = [
        *(ROOT / "domain" / "diarization").glob("*.py"),
        *(ROOT / "application" / "diarization").glob("*.py"),
    ]
    violations = {
        str(path.relative_to(ROOT)): sorted(
            imported
            for imported in _imports(path)
            if imported.startswith(FORBIDDEN_PREFIXES)
        )
        for path in paths
    }

    assert {path: imported for path, imported in violations.items() if imported} == {}
