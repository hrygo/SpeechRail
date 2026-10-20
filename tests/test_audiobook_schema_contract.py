from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_audiobook_schema.py"

SCHEMA_V1 = """\
PRAGMA foreign_keys = ON;
CREATE TABLE parent (
    id INTEGER PRIMARY KEY NOT NULL,
    name TEXT NOT NULL
);
CREATE TABLE records (
    id INTEGER PRIMARY KEY NOT NULL,
    parent_id INTEGER NOT NULL,
    payload TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (parent_id) REFERENCES parent(id) ON DELETE CASCADE
);
CREATE UNIQUE INDEX records_parent_id ON records(parent_id, id);
CREATE INDEX records_payload ON records(payload);
"""


def _write_swift(root: Path, version: int, sql: str) -> None:
    source = f'''public enum AudiobookStoreSchema {{
    public static let currentUserVersion: Int32 = {version}
    public static let createTablesSQL: String = """
{sql.rstrip()}
    """
}}
'''
    path = root / "macos/SpeechRailApp/SpeechRailApp/AudiobookStoreSchema.swift"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")


def _write_snapshot(root: Path, version: int, sql: str) -> None:
    path = root / f"contracts/audiobook-schema/v{version}.sql"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{sql.rstrip()}\nPRAGMA user_version = {version};\n", encoding="utf-8")


def _run_checker(root: Path, base_ref: str | None = None) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(CHECKER), "--repo-root", str(root)]
    if base_ref is not None:
        command.extend(["--base-ref", base_ref])
    return subprocess.run(command, cwd=root, text=True, capture_output=True, timeout=10)


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


def _commit_base(root: Path, version: int, sql: str, *, snapshot: bool = True) -> str:
    _write_swift(root, version, sql)
    if snapshot:
        _write_snapshot(root, version, sql)
    _git(root, "init", "-q")
    _git(root, "config", "user.name", "Schema Contract Test")
    _git(root, "config", "user.email", "schema-test@example.invalid")
    _git(root, "add", "-A")
    _git(root, "commit", "-qm", "test: seed schema baseline")
    return _git(root, "rev-parse", "HEAD")


def test_accepts_current_schema_snapshot_with_formatting_and_comments(tmp_path: Path) -> None:
    reformatted = """\
-- schema comment
pragma foreign_keys=on;
create table parent (
    id integer primary key not null, -- column comment
    name text not null
);
create table records(
    id integer primary key not null,
    parent_id integer not null,
    payload text not null default '',
    foreign key(parent_id) references parent(id) on delete cascade
);
create unique index records_parent_id on records ( parent_id , id );
create index records_payload on records(payload);
"""
    _write_swift(tmp_path, 1, SCHEMA_V1)
    _write_snapshot(tmp_path, 1, reformatted)

    result = _run_checker(tmp_path)

    assert result.returncode == 0, result.stderr


def test_rejects_snapshot_column_type_mismatch(tmp_path: Path) -> None:
    _write_swift(tmp_path, 1, SCHEMA_V1)
    _write_snapshot(tmp_path, 1, SCHEMA_V1.replace("payload TEXT", "payload BLOB"))

    result = _run_checker(tmp_path)

    assert result.returncode != 0
    assert "v1.sql" in result.stderr


def test_rejects_snapshot_check_constraint_mismatch(tmp_path: Path) -> None:
    checked = SCHEMA_V1.replace(
        "    FOREIGN KEY (parent_id)",
        "    CHECK (length(payload) > 0),\n    FOREIGN KEY (parent_id)",
    )
    _write_swift(tmp_path, 1, checked)
    _write_snapshot(tmp_path, 1, SCHEMA_V1)

    result = _run_checker(tmp_path)

    assert result.returncode != 0
    assert "v1.sql" in result.stderr


def test_rejects_snapshot_expression_index_mismatch(tmp_path: Path) -> None:
    indexed = SCHEMA_V1 + "CREATE INDEX records_payload_expression ON records(lower(payload));\n"
    _write_swift(tmp_path, 1, indexed)
    _write_snapshot(
        tmp_path,
        1,
        SCHEMA_V1 + "CREATE INDEX records_payload_expression ON records(upper(payload));\n",
    )

    result = _run_checker(tmp_path)

    assert result.returncode != 0
    assert "v1.sql" in result.stderr


def test_rejects_swift_column_change_without_matching_snapshot(tmp_path: Path) -> None:
    changed = SCHEMA_V1.replace(
        "    payload TEXT NOT NULL DEFAULT '',",
        "    payload TEXT NOT NULL DEFAULT '',\n    added TEXT,",
    )
    _write_swift(tmp_path, 1, changed)
    _write_snapshot(tmp_path, 1, SCHEMA_V1)

    result = _run_checker(tmp_path)

    assert result.returncode != 0
    assert "v1.sql" in result.stderr


def test_rejects_structural_change_without_version_bump(tmp_path: Path) -> None:
    base_ref = _commit_base(tmp_path, 1, SCHEMA_V1, snapshot=False)
    changed = SCHEMA_V1.replace("payload TEXT", "payload BLOB")
    _write_swift(tmp_path, 1, changed)
    _write_snapshot(tmp_path, 1, changed)

    result = _run_checker(tmp_path, base_ref)

    assert result.returncode != 0
    assert "currentUserVersion" in result.stderr


def test_rejects_version_decrease_when_schema_is_unchanged(tmp_path: Path) -> None:
    base_ref = _commit_base(tmp_path, 2, SCHEMA_V1)
    _write_swift(tmp_path, 1, SCHEMA_V1)
    _write_snapshot(tmp_path, 1, SCHEMA_V1)

    result = _run_checker(tmp_path, base_ref)

    assert result.returncode != 0
    assert "lower" in result.stderr.lower()


def test_rejects_changes_to_a_historical_snapshot(tmp_path: Path) -> None:
    base_ref = _commit_base(tmp_path, 1, SCHEMA_V1)
    changed = SCHEMA_V1.replace("payload TEXT", "payload BLOB")
    _write_swift(tmp_path, 2, changed)
    _write_snapshot(tmp_path, 2, changed)
    historical = tmp_path / "contracts/audiobook-schema/v1.sql"
    historical.write_text(historical.read_text() + "-- altered history\n", encoding="utf-8")

    result = _run_checker(tmp_path, base_ref)

    assert result.returncode != 0
    assert "historical" in result.stderr.lower()


def test_accepts_valid_new_version_with_immutable_history(tmp_path: Path) -> None:
    base_ref = _commit_base(tmp_path, 1, SCHEMA_V1)
    changed = SCHEMA_V1.replace("payload TEXT", "payload BLOB")
    _write_swift(tmp_path, 2, changed)
    _write_snapshot(tmp_path, 2, changed)

    result = _run_checker(tmp_path, base_ref)

    assert result.returncode == 0, result.stderr


def test_rejects_new_version_without_snapshot(tmp_path: Path) -> None:
    base_ref = _commit_base(tmp_path, 1, SCHEMA_V1)
    changed = SCHEMA_V1.replace("payload TEXT", "payload BLOB")
    _write_swift(tmp_path, 2, changed)

    result = _run_checker(tmp_path, base_ref)

    assert result.returncode != 0
    assert "v2.sql" in result.stderr
