import importlib.util
import sys
import types
from pathlib import Path
from types import SimpleNamespace

_hatchling = types.ModuleType("hatchling")
_builders = types.ModuleType("hatchling.builders")
_hooks = types.ModuleType("hatchling.builders.hooks")
_plugin = types.ModuleType("hatchling.builders.hooks.plugin")
_interface = types.ModuleType("hatchling.builders.hooks.plugin.interface")


class _BuildHookInterface:
    pass


_interface.BuildHookInterface = _BuildHookInterface
sys.modules.update(
    {
        module.__name__: module
        for module in (_hatchling, _builders, _hooks, _plugin, _interface)
    }
)

_HATCH_BUILD_PATH = Path(__file__).parents[1] / "hatch_build.py"
_SPEC = importlib.util.spec_from_file_location("speechrail_test_hatch_build", _HATCH_BUILD_PATH)
assert _SPEC is not None and _SPEC.loader is not None
hatch_build = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = hatch_build
_SPEC.loader.exec_module(hatch_build)


def test_custom_build_hook_skips_macos_native_worker_on_non_macos(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setattr(
        hatch_build,
        "sys",
        SimpleNamespace(platform="linux"),
        raising=False,
    )

    def unexpected_native_build(*args, **kwargs):
        raise AssertionError("the macOS native worker must not build on Linux")

    monkeypatch.setattr(hatch_build.subprocess, "run", unexpected_native_build)
    hook = SimpleNamespace(
        target_name="wheel",
        root=str(tmp_path),
        directory=str(tmp_path / "build"),
    )
    build_data: dict[str, object] = {}

    hatch_build.CustomBuildHook.initialize(hook, "2.0.3", build_data)

    assert build_data == {}
    assert not (tmp_path / "build" / "speechrail-native").exists()
