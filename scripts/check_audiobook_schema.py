from __future__ import annotations

import argparse
import re
import sqlite3
import subprocess
import sys
from pathlib import Path

SCHEMA_SOURCE = Path("macos/SpeechRailApp/SpeechRailApp/AudiobookStoreSchema.swift")
CONTRACT_DIR = Path("contracts/audiobook-schema")
VERSION_PATTERN = re.compile(r"v([1-9][0-9]*)\.sql\Z")
INTERPOLATION_PATTERN = re.compile(r"\\\s*\(")


class SchemaContractError(Exception):
    pass


def _swift_schema(source: str, label: str) -> tuple[int, str]:
    versions = re.findall(
        r"^[ \t]*public\s+static\s+let\s+currentUserVersion\s*:\s*Int32\s*=\s*([0-9]+)\s*$",
        source,
        flags=re.MULTILINE,
    )
    sql_blocks = re.findall(
        r'^[ \t]*public\s+static\s+let\s+createTablesSQL\s*:\s*String\s*=\s*"""\r?\n'
        r'(.*?)^[ \t]*"""[ \t]*$',
        source,
        flags=re.MULTILINE | re.DOTALL,
    )
    if len(versions) != 1 or int(versions[0]) < 1:
        raise SchemaContractError(f"{label}: expected one positive currentUserVersion")
    if len(sql_blocks) != 1:
        raise SchemaContractError(f"{label}: expected one triple-quoted createTablesSQL constant")
    if INTERPOLATION_PATTERN.search(sql_blocks[0]):
        raise SchemaContractError(f"{label}: createTablesSQL must not contain Swift interpolation")
    return int(versions[0]), sql_blocks[0]


def _quoted_end(sql: str, start: int) -> int:
    opening = sql[start]
    closing = "]" if opening == "[" else opening
    index = start + 1
    while index < len(sql):
        if sql[index] == closing:
            if closing != "]" and index + 1 < len(sql) and sql[index + 1] == closing:
                index += 2
                continue
            return index + 1
        index += 1
    raise SchemaContractError("SQL contains an unterminated quoted value or identifier")


def _sql_tokens(sql: str) -> tuple[str, ...]:
    tokens: list[str] = []
    index = 0
    while index < len(sql):
        char = sql[index]
        if char.isspace():
            index += 1
        elif sql.startswith("--", index):
            end = sql.find("\n", index)
            index = len(sql) if end < 0 else end + 1
        elif sql.startswith("/*", index):
            end = sql.find("*/", index + 2)
            if end < 0:
                raise SchemaContractError("SQL contains an unterminated block comment")
            index = end + 2
        elif char in ("'", '"', chr(96), "["):
            end = _quoted_end(sql, index)
            tokens.append(sql[index:end])
            index = end
        elif char.isalnum() or char in "_$":
            end = index + 1
            while end < len(sql) and (sql[end].isalnum() or sql[end] in "_$"):
                end += 1
            tokens.append(sql[index:end].upper())
            index = end
        elif index + 1 < len(sql) and sql[index : index + 2] in {
            "!=",
            "<=",
            "<>",
            ">=",
            "==",
            "||",
            "<<",
            ">>",
        }:
            tokens.append(sql[index : index + 2])
            index += 2
        else:
            tokens.append(char)
            index += 1
    return tuple(tokens)


def _validate_schema_only(sql: str, label: str) -> None:
    schema_heads = {
        ("CREATE", "TABLE"),
        ("CREATE", "INDEX"),
        ("CREATE", "UNIQUE", "INDEX"),
        ("CREATE", "VIEW"),
        ("CREATE", "TRIGGER"),
    }
    current: list[str] = []
    for token in (*_sql_tokens(sql), ";"):
        if token == ";":
            if current:
                statement = tuple(current)
                if statement[0] != "PRAGMA" and not any(
                    statement[: len(head)] == head for head in schema_heads
                ):
                    raise SchemaContractError(
                        f"{label}: snapshots may contain schema statements only"
                    )
                current.clear()
        else:
            current.append(token)


def _execute_schema(sql: str, label: str) -> sqlite3.Connection:
    _validate_schema_only(sql, label)
    connection = sqlite3.connect(":memory:")
    try:
        connection.executescript(sql)
    except sqlite3.Error as error:
        connection.close()
        raise SchemaContractError(f"{label}: SQLite rejected the schema SQL: {error}") from error
    return connection


def _schema_fingerprint(connection: sqlite3.Connection) -> tuple[tuple[object, ...], ...]:
    rows = connection.execute(
        "SELECT type, name, tbl_name, sql FROM sqlite_master "
        "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name, tbl_name"
    )
    return tuple(
        (
            str(row[0]).casefold(),
            str(row[1]).casefold(),
            str(row[2]).casefold(),
            None if row[3] is None else _sql_tokens(str(row[3])),
        )
        for row in rows
    )


def _require_empty_tables(connection: sqlite3.Connection, label: str) -> None:
    tables = connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name"
    )
    for (name,) in tables:
        quoted_name = '"' + str(name).replace('"', '""') + '"'
        if connection.execute(f"SELECT 1 FROM {quoted_name} LIMIT 1").fetchone():
            raise SchemaContractError(f"{label}: schema snapshot contains table data")


def _read_source_schema(root: Path) -> tuple[int, str]:
    path = root / SCHEMA_SOURCE
    try:
        return _swift_schema(path.read_text(encoding="utf-8"), str(SCHEMA_SOURCE))
    except OSError as error:
        raise SchemaContractError(f"cannot read schema source {path}: {error}") from error


def _git_output(root: Path, *args: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=root,
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise SchemaContractError(f"git {' '.join(args[:2])} failed") from error
    return result.stdout


def _check_historical_snapshots(root: Path, base_ref: str) -> None:
    output = _git_output(
        root, "ls-tree", "-r", "--name-only", base_ref, "--", CONTRACT_DIR.as_posix()
    )
    for item in output.decode("utf-8").splitlines():
        relative_path = Path(item)
        if (
            relative_path.parent != CONTRACT_DIR
            or not VERSION_PATTERN.fullmatch(relative_path.name)
        ):
            continue
        baseline = _git_output(root, "show", f"{base_ref}:{item}")
        path = root / relative_path
        try:
            current = path.read_bytes()
        except OSError as error:
            raise SchemaContractError(f"historical schema snapshot {item} was removed") from error
        if current != baseline:
            raise SchemaContractError(f"historical schema snapshot {item} was modified")


def check_schema(repo_root: Path, base_ref: str | None = None) -> None:
    current_version, current_sql = _read_source_schema(repo_root)
    current_connection = _execute_schema(current_sql, str(SCHEMA_SOURCE))
    try:
        current_fingerprint = _schema_fingerprint(current_connection)
    finally:
        current_connection.close()

    if base_ref:
        try:
            base_source = _git_output(
                repo_root, "show", f"{base_ref}:{SCHEMA_SOURCE.as_posix()}"
            ).decode("utf-8")
        except UnicodeDecodeError as error:
            raise SchemaContractError(f"base schema source {SCHEMA_SOURCE} is not UTF-8") from error
        base_version, base_sql = _swift_schema(base_source, f"{base_ref}:{SCHEMA_SOURCE}")
        if current_version < base_version:
            raise SchemaContractError(
                f"currentUserVersion {current_version} cannot be lower than base version "
                f"{base_version}"
            )
        base_connection = _execute_schema(base_sql, f"{base_ref}:{SCHEMA_SOURCE}")
        try:
            base_fingerprint = _schema_fingerprint(base_connection)
        finally:
            base_connection.close()
        if current_fingerprint != base_fingerprint and current_version <= base_version:
            raise SchemaContractError(
                "createTablesSQL changed from the base ref; currentUserVersion must be greater "
                f"than {base_version} (currently {current_version})"
            )
        _check_historical_snapshots(repo_root, base_ref)

    snapshot_path = repo_root / CONTRACT_DIR / f"v{current_version}.sql"
    try:
        snapshot_sql = snapshot_path.read_text(encoding="utf-8")
    except OSError as error:
        relative_path = snapshot_path.relative_to(repo_root)
        raise SchemaContractError(f"missing current schema snapshot {relative_path}") from error
    label = str(snapshot_path.relative_to(repo_root))
    snapshot_connection = _execute_schema(snapshot_sql, label)
    try:
        actual_version = int(snapshot_connection.execute("PRAGMA user_version").fetchone()[0])
        if actual_version != current_version:
            raise SchemaContractError(
                f"{label} sets user_version {actual_version}; expected {current_version}"
            )
        _require_empty_tables(snapshot_connection, label)
        snapshot_fingerprint = _schema_fingerprint(snapshot_connection)
    finally:
        snapshot_connection.close()
    if snapshot_fingerprint != current_fingerprint:
        raise SchemaContractError(f"{label} does not match createTablesSQL structure")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the audiobook SQLite schema contract.")
    parser.add_argument("--base-ref", help="Git ref used to enforce schema version history")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help=argparse.SUPPRESS,
    )
    args = parser.parse_args()
    try:
        check_schema(args.repo_root.resolve(), args.base_ref)
    except (OSError, sqlite3.Error, SchemaContractError) as error:
        sys.stderr.write(f"audiobook schema contract: {error}\n")
        return 1
    sys.stdout.write("Audiobook SQLite schema contract passed.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
