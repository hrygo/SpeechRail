"""Injected libproc/tree only; no live process, model, audio or benchmark reads."""

import ctypes

import pytest


class FakeTree:
    backend = "injected"

    def __init__(self):
        from meeting_process_snapshot import ProcessKey, ProcessUsage

        self.rows = {pid: ProcessUsage(ProcessKey(pid, pid * 100), pid * 10) for pid in (1, 2, 3)}
        self.edges = {1: (2,), 2: (3,), 3: ()}
        self.reads = []

    def read(self, pid):
        self.reads.append(pid)
        return self.rows.get(pid)

    def children(self, pid):
        return self.edges[pid]


def collect(tree, **kwargs):
    from meeting_process_snapshot import ProcessKey, collect_process_snapshot

    return collect_process_snapshot(
        roots=(ProcessKey(1, 100),), reader=tree, clock=lambda: 10.0, **kwargs
    )


@pytest.mark.parametrize("reverse", [False, True])
def test_exact_root_descendants_and_nested_roots_are_deduplicated(reverse):
    from meeting_process_snapshot import ProcessKey, collect_process_snapshot

    tree = FakeTree()
    roots = (ProcessKey(1, 100), ProcessKey(2, 200))
    value = collect_process_snapshot(
        roots=roots[::-1] if reverse else roots, reader=tree, clock=lambda: 10.0
    )
    assert value["sample_sum_phys_footprint_bytes"] == 60
    assert [r["pid"] for r in value["processes"]] == [1, 2, 3]
    assert tree.reads.count(1) == tree.reads.count(2) == tree.reads.count(3) == 2
    assert tree.reads[-3:] == [3, 2, 1]
    assert value["atomic_snapshot_verified"] is False
    assert value["peak_footprint_verified"] is False
    assert value["worker_reaping_verified"] is False
    assert value["certification_eligible"] is False


@pytest.mark.parametrize(
    "fault",
    [
        "missing",
        "root_reuse",
        "child_reuse",
        "new_child",
        "cycle",
        "duplicate_child",
        "budget",
        "private_error",
    ],
)
def test_partial_or_changing_tree_cannot_become_a_complete_footprint_sample(fault):
    from meeting_process_snapshot import ProcessKey, ProcessUsage

    tree = FakeTree()
    if fault == "missing":
        tree.rows.pop(3)
    elif fault == "root_reuse":
        tree.rows[1] = ProcessUsage(ProcessKey(1, 999), 10)
    elif fault == "child_reuse":
        original = tree.read

        def read(pid):
            seen = pid in tree.reads
            value = original(pid)
            return ProcessUsage(ProcessKey(pid, 999), 10) if pid == 2 and seen else value

        tree.read = read
    elif fault == "new_child":
        original = tree.children
        calls = []

        def children(pid):
            second = pid in calls
            calls.append(pid)
            return (2, 4) if pid == 1 and second else original(pid)

        tree.children = children
    elif fault == "cycle":
        tree.edges[3] = (1,)
    elif fault == "duplicate_child":
        tree.edges[1] = (2, 2)
    elif fault == "private_error":

        def broken(pid):
            raise RuntimeError("private /weights secret transcript")

        tree.read = broken
    with pytest.raises(ValueError) as exc:
        collect(tree, max_processes=2 if fault == "budget" else 64)
    assert "private" not in str(exc.value)


def test_snapshot_span_clock_and_identity_bounds_fail_closed():
    from meeting_process_snapshot import ProcessKey, collect_process_snapshot

    with pytest.raises(ValueError):
        ProcessKey(True, 1)
    with pytest.raises(ValueError):
        ProcessKey(1, 0)
    with pytest.raises(ValueError):
        ProcessKey(1, 1 << 64)
    for ticks in ([10.0, 12.0], [10.0, 9.0], [True, 10.0]):
        it = iter(ticks)
        with pytest.raises(ValueError):
            collect_process_snapshot(
                roots=(ProcessKey(1, 100),),
                reader=FakeTree(),
                clock=lambda source=it: next(source),
                max_span_seconds=1.0,
            )


class Function:
    def __init__(self, fn):
        self.fn = fn

    def __call__(self, *args):
        return self.fn(*args)


class Library:
    def __init__(self):
        from meeting_process_snapshot import _RusageInfoV0

        self.result, self.count, self.exited = 0, 2, False

        def usage(pid, flavor, pointer):
            assert flavor == 0
            value = ctypes.cast(pointer, ctypes.POINTER(_RusageInfoV0)).contents
            value.ri_proc_start_abstime = 123456789
            value.ri_phys_footprint = 987654321
            value.ri_proc_exit_abstime = 1 if self.exited else 0
            return self.result

        def children(pid, buffer, size):
            assert size == 65 * ctypes.sizeof(ctypes.c_int)
            buffer[0], buffer[1] = 2, 3
            return self.count

        self.proc_pid_rusage = Function(usage)
        self.proc_listchildpids = Function(children)


def test_libproc_abi_fields_and_children_count_use_native_bytes_without_rss_conversion():
    from meeting_process_snapshot import MacProcessReader, _RusageInfoV0

    assert ctypes.sizeof(_RusageInfoV0) == 96
    assert _RusageInfoV0.ri_phys_footprint.offset == 72
    assert _RusageInfoV0.ri_proc_start_abstime.offset == 80
    reader = MacProcessReader(_library=Library())
    value = reader.read(1)
    assert value.key.start_abstime == 123456789
    assert value.phys_footprint_bytes == 987654321
    assert reader.children(1) == (2, 3)
    assert reader.backend == "injected"


def test_libproc_errors_zombies_and_saturated_child_buffer_do_not_return_partial_values():
    from meeting_process_snapshot import MacProcessReader

    library = Library()
    reader = MacProcessReader(_library=library)
    library.result = -1
    assert reader.read(1) is None
    library.result, library.exited = 0, True
    assert reader.read(1) is None
    library.count = 65
    with pytest.raises(ValueError):
        reader.children(1)
    library.count = -1
    with pytest.raises(ValueError):
        reader.children(1)
