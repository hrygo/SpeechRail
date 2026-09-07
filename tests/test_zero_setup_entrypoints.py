from __future__ import annotations

from pathlib import Path

PROJECT_ROOT = Path(__file__).parents[1]
BOOTSTRAP = (
    PROJECT_ROOT
    / ".agents"
    / "skills"
    / "speechrail-zero-setup"
    / "scripts"
    / "bootstrap_mac.sh"
)


def test_bootstrap_resolves_and_validates_repository_before_installing_dependencies() -> None:
    script = BOOTSTRAP.read_text(encoding="utf-8")

    root_resolution = script.index('SCRIPT_DIR="${0:A:h}"')
    root_validation = script.index('if [[ ! -f "$REPO_ROOT/pyproject.toml" ]]')
    first_external_install = min(
        script.index("xcode-select --install"),
        script.index("raw.githubusercontent.com/Homebrew/install"),
        script.index("astral.sh/uv/install.sh"),
    )

    assert 'BASH_SOURCE[0]' not in script
    assert 'REPO_ROOT="${SCRIPT_DIR:h:h:h:h}"' in script
    assert root_resolution < root_validation < first_external_install


def test_bootstrap_requires_yes_before_external_installation() -> None:
    script = BOOTSTRAP.read_text(encoding="utf-8")

    confirmation = script.index('if [[ "${1:-}" != "--yes" ]]')
    first_external_install = min(
        script.index("xcode-select --install"),
        script.index("raw.githubusercontent.com/Homebrew/install"),
        script.index("astral.sh/uv/install.sh"),
    )

    assert confirmation < first_external_install
