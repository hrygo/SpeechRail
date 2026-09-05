"""模型选择的原子持久化与中断恢复。此模块不加载模型或修改服务运行态。"""

from __future__ import annotations

import contextlib
import json
import os
import re
import stat
import tempfile
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, StrictInt, StrictStr, field_validator

_SAFE_KEY = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
_STAGES = {
    "PREPARING": {"VERIFIED", "ROLLING_BACK", "ROLLED_BACK"},
    "VERIFIED": {"DRAINING", "ROLLING_BACK", "ROLLED_BACK"},
    "DRAINING": {"ACTIVATING", "ROLLING_BACK", "ROLLED_BACK"},
    "ACTIVATING": {"SMOKING", "ROLLING_BACK"},
    "SMOKING": {"COMMITTED", "ROLLING_BACK"},
    "ROLLING_BACK": {"ROLLED_BACK", "NOT_READY"},
    "COMMITTED": set(), "ROLLED_BACK": set(), "NOT_READY": set(),
}
_TERMINAL = {"COMMITTED", "ROLLED_BACK", "NOT_READY"}


class SelectionRecord(BaseModel):
    """持久化选择仅记录已准备的模型键和共同 runtime 身份。"""

    model_config = ConfigDict(frozen=True, extra="forbid")
    schema_version: StrictInt
    preset: Literal["quality", "balanced", "light"]
    generation: StrictInt = Field(gt=0)
    asr: StrictStr
    tts: StrictStr
    runtime_lock_id: StrictStr

    @field_validator("schema_version")
    @classmethod
    def version_supported(cls, value: int) -> int:
        if value != 1:
            raise ValueError("unsupported selection schema")
        return value

    @field_validator("asr", "tts", "runtime_lock_id")
    @classmethod
    def safe_key(cls, value: str) -> str:
        if not _SAFE_KEY.fullmatch(value):
            raise ValueError("invalid model or runtime key")
        return value


def _selection(value: object) -> dict[str, object] | None:
    if value is None:
        return None
    return dict(SelectionRecord.model_validate(value).model_dump())


def allowed_transition(old: str, new: str) -> bool:
    return new in _STAGES.get(old, set())


class ProfileStore:
    """短文件锁保护持久化步骤。跨步骤互斥由未完成 journal 保持。"""

    def __init__(self, app_home: Path) -> None:
        self.app_home = app_home.absolute()
        self.selection_path = self.app_home / "config/selection.json"
        self.previous_path = self.app_home / "config/selection.previous.json"
        self.journal_path = self.app_home / "state/profile-transaction.json"

    def _safe_path(self, path: Path) -> None:
        for candidate in (self.app_home, path.parent, path):
            if candidate.is_symlink():
                raise ValueError("profile store rejects symlink targets")

    def _read(self, path: Path) -> object:
        self._safe_path(path)
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except FileNotFoundError:
            return None
        with os.fdopen(descriptor, "rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise ValueError("profile record must be a regular file")
            raw = source.read(65_537)
        if len(raw) > 65_536:
            raise ValueError("profile record too large")
        try:
            return json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("profile record is corrupt") from exc

    def _prepare(self) -> None:
        self._safe_path(self.selection_path)
        self._safe_path(self.journal_path)
        self.app_home.mkdir(parents=True, exist_ok=True)
        for directory in (self.selection_path.parent, self.journal_path.parent):
            directory.mkdir(mode=0o700, exist_ok=True)
            directory.chmod(0o700)

    @contextlib.contextmanager
    def _locked(self) -> Iterator[None]:
        import fcntl

        self._prepare()
        path = self.journal_path.parent / "profile.lock"
        self._safe_path(path)
        descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise RuntimeError("profile_store_busy") from exc
            yield
        finally:
            os.close(descriptor)

    def _write(self, path: Path, value: object) -> None:
        self._safe_path(path)
        raw = (json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n").encode()
        if len(raw) > 65_536:
            raise ValueError("profile record too large")
        descriptor, temporary_name = tempfile.mkstemp(prefix=".profile-", dir=path.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
            self._safe_path(path)
            temporary.replace(path)
            parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent)
            finally:
                os.close(parent)
        finally:
            temporary.unlink(missing_ok=True)

    def _journal(self) -> dict[str, object] | None:
        raw = self._read(self.journal_path)
        if raw is None:
            return None
        if not isinstance(raw, dict) or set(raw) != {
            "schema_version", "operation_id", "stage", "previous", "candidate"
        }:
            raise ValueError("invalid transaction schema")
        if type(raw["schema_version"]) is not int or raw["schema_version"] != 1:
            raise ValueError("unsupported transaction schema")
        if not isinstance(raw["operation_id"], str) or not re.fullmatch(
            r"op_[0-9a-f]{32}", raw["operation_id"]
        ):
            raise ValueError("invalid operation ID")
        if not isinstance(raw["stage"], str) or raw["stage"] not in _STAGES:
            raise ValueError("invalid transaction stage")
        _selection(raw["previous"])
        return raw

    def recover(self) -> dict[str, object] | None:
        journal = self._journal()
        if journal is not None:
            # 未完成日志中的 candidate 可能损坏。恢复只依赖已校验的 previous。
            if journal["stage"] != "COMMITTED":
                return _selection(journal["previous"])
            committed = _selection(journal["candidate"])
            if committed != _selection(self._read(self.selection_path)):
                raise ValueError("committed selection mismatch")
            return committed
        return _selection(self._read(self.selection_path))

    def initialize(self, selection: Mapping[str, object]) -> None:
        validated = _selection(selection)
        with self._locked():
            if self._read(self.selection_path) is not None or self._journal() is not None:
                raise ValueError("selection already initialized")
            self._write(self.selection_path, validated)

    def begin(
        self, previous: Mapping[str, object] | None, candidate: Mapping[str, object]
    ) -> str:
        old, new = _selection(previous), _selection(candidate)
        assert new is not None
        previous_generation = old["generation"] if old else 0
        assert isinstance(previous_generation, int)
        if new["generation"] != previous_generation + 1:
            raise ValueError("candidate generation must follow previous generation")
        with self._locked():
            journal = self._journal()
            if journal is not None and journal["stage"] not in _TERMINAL:
                raise RuntimeError("profile_store_busy")
            if self.recover() != old:
                raise ValueError("previous selection does not match current selection")
            operation_id = f"op_{uuid4().hex}"
            self._write(self.journal_path, {
                "schema_version": 1, "operation_id": operation_id, "stage": "PREPARING",
                "previous": old, "candidate": new,
            })
            return operation_id

    def _operation(self, operation_id: str) -> dict[str, object]:
        journal = self._journal()
        if journal is None or journal["operation_id"] != operation_id:
            raise ValueError("unknown profile operation")
        return journal

    def mark(self, operation_id: str, stage: str) -> None:
        if stage == "COMMITTED":
            raise ValueError("commit transition requires commit()")
        with self._locked():
            journal = self._operation(operation_id)
            if not allowed_transition(str(journal["stage"]), stage):
                raise ValueError("invalid profile transition")
            journal["stage"] = stage
            self._write(self.journal_path, journal)

    def commit(self, operation_id: str) -> None:
        with self._locked():
            journal = self._operation(operation_id)
            if journal["stage"] == "COMMITTED":
                self.recover()
                return
            if not allowed_transition(str(journal["stage"]), "COMMITTED"):
                raise ValueError("invalid commit transition before smoke")
            candidate = _selection(journal["candidate"])
            if candidate is None:
                raise ValueError("candidate is missing")
            self._write(self.previous_path, journal["previous"])
            self._write(self.selection_path, candidate)
            journal["stage"] = "COMMITTED"
            self._write(self.journal_path, journal)

    def rollback(self, operation_id: str) -> None:
        with self._locked():
            journal = self._operation(operation_id)
            if journal["stage"] == "COMMITTED":
                raise ValueError("committed operation requires a new rollback transaction")
            previous = _selection(journal["previous"])
            # null 表示首次安装失败后的明确未配置状态。
            self._write(self.selection_path, previous)
            journal["stage"] = "ROLLED_BACK"
            self._write(self.journal_path, journal)


def recover_selection(app_home: Path) -> dict[str, object] | None:
    return ProfileStore(app_home).recover()
