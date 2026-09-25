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
    dist = tmp_path / "vendor" / "engine-build" / "dist"
    dist.mkdir(parents=True)
    wheel = dist / "mlx_audio-0.4.8+speechrail.1-py3-none-any.whl"
    wheel.write_bytes(b"controlled-engine-wheel")
    provenance = dist / "provenance.json"
    provenance.write_text("{}\n", encoding="utf-8")
    hook = SimpleNamespace(
        target_name="wheel",
        root=str(tmp_path),
        directory=str(tmp_path / "build"),
    )
    build_data: dict[str, object] = {}

    hatch_build.CustomBuildHook.initialize(hook, "2.0.3", build_data)

    assert build_data == {
        "force_include": {
            str(wheel): (
                "speechrail/assets/vendor/engine/dist/"
                "mlx_audio-0.4.8+speechrail.1-py3-none-any.whl"
            ),
            str(provenance): "speechrail/assets/vendor/engine/dist/provenance.json",
        }
    }
    assert not (tmp_path / "build" / "speechrail-native").exists()


def test_custom_build_hook_skips_the_engine_wheel_before_the_build_gate(
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

    # No controlled wheel has been built yet, so nothing is claimed or shipped.
    assert build_data == {}


def test_custom_build_hook_rejects_provenance_without_a_wheel(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setattr(
        hatch_build,
        "sys",
        SimpleNamespace(platform="linux"),
        raising=False,
    )
    dist = tmp_path / "vendor" / "engine-build" / "dist"
    dist.mkdir(parents=True)
    (dist / "provenance.json").write_text("{}\n", encoding="utf-8")
    hook = SimpleNamespace(
        target_name="wheel",
        root=str(tmp_path),
        directory=str(tmp_path / "build"),
    )

    try:
        hatch_build.CustomBuildHook.initialize(hook, "2.0.3", {})
    except RuntimeError as error:
        assert "provenance" in str(error)
    else:  # pragma: no cover - the hook must fail closed
        raise AssertionError("engine wheel provenance without a wheel must fail closed")
