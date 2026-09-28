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


def test_custom_build_hook_honors_the_native_build_opt_out_on_macos(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setattr(
        hatch_build,
        "sys",
        SimpleNamespace(platform="darwin"),
        raising=False,
    )
    monkeypatch.setenv(hatch_build.NATIVE_BUILD_SKIP_ENV, "1")

    def unexpected_native_build(*args, **kwargs):
        raise AssertionError("the opt-out must skip the native worker build")

    monkeypatch.setattr(hatch_build.subprocess, "run", unexpected_native_build)
    hook = SimpleNamespace(
        target_name="wheel",
        root=str(tmp_path),
        directory=str(tmp_path / "build"),
    )
    build_data: dict[str, object] = {}

    hatch_build.CustomBuildHook.initialize(hook, "2.0.3", build_data)

    # Nothing native is claimed or shipped, and no build directory is created.
    assert build_data == {}
    assert not (tmp_path / "build" / "speechrail-native").exists()


def test_custom_build_hook_still_builds_the_native_worker_without_the_opt_out(
    monkeypatch, tmp_path
) -> None:
    monkeypatch.setattr(
        hatch_build,
        "sys",
        SimpleNamespace(platform="darwin"),
        raising=False,
    )
    # An empty or unrelated value must not silently disable the release input.
    for value in ("", "0", "false", "no", "maybe"):
        monkeypatch.setenv(hatch_build.NATIVE_BUILD_SKIP_ENV, value)
        assert not hatch_build._native_build_skipped(), value

    monkeypatch.delenv(hatch_build.NATIVE_BUILD_SKIP_ENV, raising=False)
    assert not hatch_build._native_build_skipped()

    for value in ("1", "true", "TRUE", " Yes "):
        monkeypatch.setenv(hatch_build.NATIVE_BUILD_SKIP_ENV, value)
        assert hatch_build._native_build_skipped(), value


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
