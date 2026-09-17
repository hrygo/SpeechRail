"""Best-effort runtime resource observations for the local macOS service.

The monitoring surface must distinguish an observed physical footprint from
the configured model-footprint declaration used by the admission policy.  The
macOS ``footprint`` tool is the authoritative source for unified-memory
physical footprint; if any service-owned process cannot be sampled, the
aggregate is marked incomplete instead of being presented as a complete zero
or partial total.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from collections import defaultdict

_FOOTPRINT_PATTERN = re.compile(r"^\s*phys_footprint:\s*(\d+)\s+B\s*$", re.MULTILINE)
_PROCESS_LINE_PATTERN = re.compile(r"^\s*(\d+)\s+(\d+)\s*$")
_FOOTPRINT_TIMEOUT_SECONDS = 0.75
_PS_TIMEOUT_SECONDS = 0.5


def service_physical_footprint() -> tuple[int | None, str, bool, int]:
    """Return the aggregate physical footprint of this process and descendants.

    Returns ``(bytes, source, complete, process_count)``.  ``bytes`` is only
    populated when every discovered service-owned process was sampled.  The
    process count remains useful when the value is unavailable, while the
    source is a bounded machine-readable label suitable for the JSON API.
    """

    pids = _service_process_ids(os.getpid())
    footprint_tool = shutil.which("footprint")
    if footprint_tool is None:
        return None, "unavailable", False, len(pids)

    values = [_read_footprint(footprint_tool, pid) for pid in pids]
    if not pids or any(value is None for value in values):
        return None, "macos_footprint_incomplete", False, len(pids)
    return (
        sum(value for value in values if value is not None),
        "macos_footprint",
        True,
        len(pids),
    )


def _service_process_ids(root_pid: int) -> tuple[int, ...]:
    """Find the current process and its descendants without reading commands."""

    try:
        process = subprocess.Popen(
            ["/bin/ps", "-axo", "pid=,ppid="],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return (root_pid,)
    try:
        ps_output, _ = process.communicate(timeout=_PS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        return (root_pid,)
    if process.returncode != 0 or not ps_output:
        return (root_pid,)

    children: dict[int, list[int]] = defaultdict(list)
    for line in ps_output.splitlines():
        match = _PROCESS_LINE_PATTERN.match(line)
        if match is None:
            continue
        pid, parent_pid = (int(value) for value in match.groups())
        children[parent_pid].append(pid)

    found = {root_pid}
    pending = [root_pid]
    while pending:
        parent_pid = pending.pop()
        for child_pid in children.get(parent_pid, []):
            if child_pid not in found:
                found.add(child_pid)
                pending.append(child_pid)
    # ``ps`` lists itself, and it is a child of this process while it runs.  That
    # collector exits before ``footprint`` samples it, so keeping it in the set
    # would make every aggregate look incomplete and hide the real reading.
    found.discard(process.pid)
    return tuple(sorted(found))


def _read_footprint(tool: str, pid: int) -> int | None:
    try:
        result = subprocess.run(
            [tool, "-p", str(pid), "-f", "bytes", "--noCategories"],
            capture_output=True,
            check=False,
            text=True,
            timeout=_FOOTPRINT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    match = _FOOTPRINT_PATTERN.search(result.stdout)
    return int(match.group(1)) if match is not None else None


__all__ = ["service_physical_footprint"]
