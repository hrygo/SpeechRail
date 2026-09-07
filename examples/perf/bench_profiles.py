"""Compatibility entry point for the modular SpeechRail profile benchmark."""

from __future__ import annotations

try:
    from .benchmark_http import (
        Clock,
        Ffprobe,
        HttpResponse,
        HttpRunner,
        _default_ffprobe,
        _default_http_runner,
        _fixture_request,
        _json_body,
        _probe,
        build_auth_headers,
        validate_base_url,
    )
    from .benchmark_manifest import (
        PHASES,
        PROFILE_DEVICE_PHASES,
        BenchmarkInputError,
        Fixture,
        LoadedManifest,
        load_manifest,
        required_phases,
    )
    from .benchmark_resources import (
        BenchmarkDependencies,
        ProcessResourceMonitor,
        ResourceMonitor,
        SystemSampler,
        _default_system_sampler,
        _hardware_and_os,
        _normalise_resources,
        _release_gate,
        _sanitize_evidence,
        _sanitize_mapping,
        _sanitize_model_identity,
    )
    from .benchmark_runner import (
        main,
        run_profile_benchmark,
        validate_output_path,
        write_result,
    )
except ImportError:  # pragma: no cover - exercised when run as a script
    from benchmark_http import (  # type: ignore[no-redef]
        Clock,
        Ffprobe,
        HttpResponse,
        HttpRunner,
        _default_ffprobe,
        _default_http_runner,
        _fixture_request,
        _json_body,
        _probe,
        build_auth_headers,
        validate_base_url,
    )
    from benchmark_manifest import (  # type: ignore[no-redef]
        PHASES,
        PROFILE_DEVICE_PHASES,
        BenchmarkInputError,
        Fixture,
        LoadedManifest,
        load_manifest,
        required_phases,
    )
    from benchmark_resources import (  # type: ignore[no-redef]
        BenchmarkDependencies,
        ProcessResourceMonitor,
        ResourceMonitor,
        SystemSampler,
        _default_system_sampler,
        _hardware_and_os,
        _normalise_resources,
        _release_gate,
        _sanitize_evidence,
        _sanitize_mapping,
        _sanitize_model_identity,
    )
    from benchmark_runner import (  # type: ignore[no-redef]
        main,
        run_profile_benchmark,
        validate_output_path,
        write_result,
    )


__all__ = [
    "PHASES",
    "PROFILE_DEVICE_PHASES",
    "BenchmarkDependencies",
    "BenchmarkInputError",
    "Clock",
    "Ffprobe",
    "Fixture",
    "HttpResponse",
    "HttpRunner",
    "LoadedManifest",
    "ProcessResourceMonitor",
    "ResourceMonitor",
    "SystemSampler",
    "_default_ffprobe",
    "_default_http_runner",
    "_default_system_sampler",
    "_fixture_request",
    "_hardware_and_os",
    "_json_body",
    "_normalise_resources",
    "_probe",
    "_release_gate",
    "_sanitize_evidence",
    "_sanitize_mapping",
    "_sanitize_model_identity",
    "build_auth_headers",
    "load_manifest",
    "main",
    "required_phases",
    "run_profile_benchmark",
    "validate_base_url",
    "validate_output_path",
    "write_result",
]


if __name__ == "__main__":  # pragma: no cover - CLI dispatch
    raise SystemExit(main())
