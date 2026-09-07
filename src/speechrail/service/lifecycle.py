"""Lifecycle adapter for the one local SpeechRail service instance."""

from __future__ import annotations

import os
import re
import signal
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

from speechrail.runtime.server_lock import (
    ServerInstanceError,
    ServerInstanceLock,
    ServerInstanceOwner,
)
from speechrail.service.launchd import ServiceError

_PORT_WAIT_INTERVAL_SECONDS = 0.25
_GRACEFUL_STOP_TIMEOUT_SECONDS = 2.0
_FORCE_KILL_TIMEOUT_SECONDS = 10.0
_PID_RE = re.compile(r"^\s*pid = (\d+)\s*$", re.MULTILINE)


def _service_pid(status: str) -> int | None:
    match = _PID_RE.search(status)
    if match is None:
        return None
    pid = int(match.group(1))
    return pid if pid > 1 else None


def _kill_process_group(pid: int) -> None:
    """Kill only the exact LaunchAgent process group after graceful stop stalls."""
    if pid <= 1 or pid == os.getpid():
        raise ServiceError("refusing to kill an unsafe service pid")
    try:
        process_group = os.getpgid(pid)
    except ProcessLookupError:
        return
    if process_group > 1 and process_group == pid and process_group != os.getpgrp():
        os.killpg(process_group, signal.SIGKILL)
    else:
        os.kill(pid, signal.SIGKILL)


def _is_live_speechrail_process(owner: ServerInstanceOwner) -> bool:
    """Validate a lock owner before allowing recovery to signal its PID."""
    if owner.pid <= 1 or owner.pid == os.getpid():
        return False
    try:
        os.kill(owner.pid, 0)
    except OSError:
        return False
    try:
        completed = subprocess.run(
            ("ps", "-p", str(owner.pid), "-o", "command="),
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return False
    command = completed.stdout.strip()
    suffix = " -m speechrail serve"
    if not command.endswith(suffix):
        return False
    command_executable = command[: -len(suffix)]
    try:
        return os.path.realpath(command_executable) == os.path.realpath(owner.executable)
    except (OSError, ValueError):
        return False


def _owner_pid_for_port(port: int) -> int | None:
    """Resolve a validated SpeechRail owner for a held server lock."""
    try:
        owner = ServerInstanceLock.read_owner(port)
    except AttributeError:
        return None
    if owner is None or not _is_live_speechrail_process(owner):
        return None
    return owner.pid


class ServiceController(Protocol):
    """Start and stop the one local SpeechRail service instance."""

    def stop(self) -> None: ...

    def start(self) -> None: ...


class LaunchAgentManagerLike(Protocol):
    """Narrow manager surface used by profile switching."""

    def status(self) -> str: ...

    def disable(self) -> None: ...

    def enable(self) -> None: ...


@dataclass(frozen=True, slots=True)
class StopPolicy:
    """Bounded stop timings shared by every local service operator."""

    graceful_timeout_seconds: float = _GRACEFUL_STOP_TIMEOUT_SECONDS
    force_kill_timeout_seconds: float = _FORCE_KILL_TIMEOUT_SECONDS
    poll_interval_seconds: float = _PORT_WAIT_INTERVAL_SECONDS

    def __post_init__(self) -> None:
        if min(
            self.graceful_timeout_seconds,
            self.force_kill_timeout_seconds,
            self.poll_interval_seconds,
        ) <= 0:
            raise ValueError("service stop timings must be positive")


class ServiceLifecycle:
    """Vendor-neutral bounded lifecycle for one local service instance."""

    def __init__(
        self,
        *,
        status_reader: Callable[[], str],
        disable: Callable[[], None],
        enable: Callable[[], None],
        port: int | None = None,
        policy: StopPolicy | None = None,
        sleeper: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
        process_killer: Callable[[int], None] = _kill_process_group,
        owner_pid_resolver: Callable[[int], int | None] | None = None,
    ) -> None:
        self._status = status_reader
        self._disable = disable
        self._enable = enable
        self._port = port
        self._policy = policy or StopPolicy()
        self._sleep = sleeper
        self._clock = clock
        self._process_killer = process_killer
        self._owner_pid_resolver = owner_pid_resolver or _owner_pid_for_port

    def _wait_for_previous_instance(self, *, timeout_seconds: float) -> None:
        """Wait until the old ASGI process releases its per-port singleton lock."""
        if self._port is None:
            return
        deadline = self._clock() + timeout_seconds
        while True:
            try:
                with ServerInstanceLock(self._port):
                    return
            except ServerInstanceError as exc:
                if self._clock() >= deadline:
                    raise ServiceError("previous service instance did not stop") from exc
                self._sleep(self._policy.poll_interval_seconds)

    def stop(self) -> None:
        try:
            status = self._status()
        except ServiceError:
            # launchctl may lose the job record while the old process still
            # owns the port. Recover only a validated SpeechRail owner.
            try:
                self._wait_for_previous_instance(
                    timeout_seconds=self._policy.graceful_timeout_seconds
                )
            except ServiceError as lock_error:
                pid = self._owner_pid_resolver(self._port) if self._port is not None else None
                if pid is None:
                    raise ServiceError(
                        "service status unavailable and previous service owner is not verifiable"
                    ) from lock_error
                self._process_killer(pid)
                try:
                    self._wait_for_previous_instance(
                        timeout_seconds=self._policy.force_kill_timeout_seconds
                    )
                except ServiceError as force_error:
                    raise ServiceError("previous service instance did not stop") from force_error
            return
        pid = _service_pid(status)
        self._disable()
        # bootout returns before the process and its vendor workers necessarily
        # release the port. The same singleton lock guards replacement startup.
        try:
            self._wait_for_previous_instance(
                timeout_seconds=self._policy.graceful_timeout_seconds
            )
        except ServiceError:
            if pid is None:
                pid = self._owner_pid_resolver(self._port) if self._port is not None else None
            if pid is None:
                raise
            self._process_killer(pid)
            try:
                self._wait_for_previous_instance(
                    timeout_seconds=self._policy.force_kill_timeout_seconds
                )
            except ServiceError as force_error:
                raise ServiceError("previous service instance did not stop") from force_error

    def start(self) -> None:
        # A stale unmanaged process must not be mistaken for the candidate
        # service during the first public smoke probe.
        self._wait_for_previous_instance(timeout_seconds=self._policy.graceful_timeout_seconds)
        self._enable()

    def restart(self) -> None:
        """Restart through the same bounded stop/start lifecycle as switching."""
        self.stop()
        self.start()


class LaunchAgentServiceController:
    """Adapt the user LaunchAgent manager to the shared service lifecycle."""

    def __init__(
        self,
        manager: LaunchAgentManagerLike,
        *,
        sleeper: Callable[[float], None] = time.sleep,
        port: int | None = None,
        clock: Callable[[], float] = time.monotonic,
        graceful_stop_timeout_seconds: float = _GRACEFUL_STOP_TIMEOUT_SECONDS,
        force_kill_timeout_seconds: float = _FORCE_KILL_TIMEOUT_SECONDS,
        process_killer: Callable[[int], None] = _kill_process_group,
        owner_pid_resolver: Callable[[int], int | None] | None = None,
    ) -> None:
        self._lifecycle = ServiceLifecycle(
            status_reader=manager.status,
            disable=manager.disable,
            enable=manager.enable,
            port=port,
            policy=StopPolicy(
                graceful_timeout_seconds=graceful_stop_timeout_seconds,
                force_kill_timeout_seconds=force_kill_timeout_seconds,
            ),
            sleeper=sleeper,
            clock=clock,
            process_killer=process_killer,
            owner_pid_resolver=owner_pid_resolver,
        )

    def stop(self) -> None:
        self._lifecycle.stop()

    def start(self) -> None:
        self._lifecycle.start()

    def restart(self) -> None:
        self._lifecycle.restart()
