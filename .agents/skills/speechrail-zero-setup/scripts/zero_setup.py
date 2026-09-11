#!/usr/bin/env python3
"""SpeechRail 全新空白 Mac 从零搭建与自动化部署工具 (Zero Setup).

用于在全新/空白 Apple Silicon Mac 上完成环境自检、wheel 构建、模型拉取、
独立 Worker 运行环境部署、LaunchAgent 常驻配置与端到端冒烟测试闭环。
"""

from __future__ import annotations

import os
import platform
import sys

# ==============================================================================
# 零依赖前置防线: 在导入任何第三方模块之前 先检查硬件架构与 Python 版本
# ==============================================================================
if sys.platform != "darwin":
    print("❌ 操作系统不支持: SpeechRail 专为 macOS 深度优化，当前系统非 macOS。", file=sys.stderr)
    sys.exit(1)

machine = platform.machine().lower()
if machine not in {"arm64", "aarch64"}:
    print(
        f"❌ 硬件架构不兼容: 检测到当前芯片架构为「{machine}」。\n"
        "   SpeechRail 底层推理引擎 (Qwen3-MLX) 专为 Apple Silicon (M1/M2/M3/M4/M5) 统一内存\n"
        "   与 Metal GPU 架构设计，不支持 Intel (x86_64) Mac。\n"
        "   若在 Intel Mac 上使用，建议选用 whisper.cpp 或调用远端兼容 API 服务。",
        file=sys.stderr,
    )
    sys.exit(1)


def _auto_resolve_python_312() -> None:
    """自动解决 Python 版本问题: 自动拉取 uv、安装独立 Python 3.12 并重启自身。"""
    import shutil
    import subprocess
    from pathlib import Path

    py_ver = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    print(
        f"\033[1;33m[!] 检测到当前解释器为 Python {py_ver}，需专属 Python 3.12。\033[0m\n"
        "\033[1;34m[+] 启动自动自愈引擎，正在为您自动获取 Python 3.12 并切换...\033[0m"
    )

    uv_bin = shutil.which("uv")
    if not uv_bin:
        for candidate in [
            Path.home() / ".local/bin/uv",
            Path.home() / ".cargo/bin/uv",
            Path("/opt/homebrew/bin/uv"),
        ]:
            if candidate.exists() and os.access(candidate, os.X_OK):
                uv_bin = str(candidate)
                break

    if not uv_bin:
        print("\033[1;34m[+] 自动下载并配置包管理器 uv...\033[0m")
        install_res = subprocess.run(
            "curl -LsSf https://astral.sh/uv/install.sh | sh", shell=True, check=False
        )
        if install_res.returncode != 0:
            print("\033[1;31m[ERROR] 自动安装 uv 失败，请检查网络连接。\033[0m", file=sys.stderr)
            sys.exit(1)
        for candidate in [
            Path.home() / ".local/bin/uv",
            Path.home() / ".cargo/bin/uv",
        ]:
            if candidate.exists() and os.access(candidate, os.X_OK):
                uv_bin = str(candidate)
                break

    if not uv_bin:
        print("\033[1;31m[ERROR] 未能定位安装后的 uv (~/.local/bin/uv)。\033[0m", file=sys.stderr)
        sys.exit(1)

    print("\033[1;34m[+] 自动拉取并安装隔离的官方 CPython 3.12 运行时...\033[0m")
    subprocess.run([uv_bin, "python", "install", "3.12"], check=True)

    repo_root = Path(__file__).resolve().parents[4]
    print("\033[1;34m[+] 同步主工程依赖至 Python 3.12 环境...\033[0m")
    sync_cmd = [uv_bin, "sync", "--python", "3.12", "--extra", "dev"]
    subprocess.run(sync_cmd, cwd=repo_root, check=True)

    print("\033[1;32m[✓] Python 3.12 准备完成，正在切换到专属运行时继续执行...\033[0m\n")
    script_path = str(Path(__file__).resolve())
    cmd = [uv_bin, "run", "--python", "3.12", "python", script_path, *sys.argv[1:]]
    ret = subprocess.run(cmd, cwd=repo_root)
    sys.exit(ret.returncode)


if not ((3, 12) <= sys.version_info < (3, 13)) and "--yes" not in sys.argv[1:]:
    print(
        "[ERROR] 准备 Python 3.12 会下载并安装运行时；请显式传入 --yes。",
        file=sys.stderr,
    )
    sys.exit(2)

if not ((3, 12) <= sys.version_info < (3, 13)):
    _auto_resolve_python_312()

# ==============================================================================
# 业务逻辑主体
# ==============================================================================
import argparse  # noqa: E402
import hashlib  # noqa: E402
import io  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
import wave  # noqa: E402
from email.parser import BytesParser  # noqa: E402
from pathlib import Path  # noqa: E402
from zipfile import ZipFile  # noqa: E402

import httpx  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO_ROOT))

from tools.install_macos import (  # noqa: E402
    DiarizationInstallPaths,
    InstallerError,
    install_managed,
)

from speechrail import __version__  # noqa: E402
from speechrail.config.model_catalog import load_catalog  # noqa: E402
from speechrail.service.diarization_assets import (  # noqa: E402
    DiarizationAssetError,
    prepare_diarization_assets,
)
from speechrail.service.launchd import ServiceError  # noqa: E402
from speechrail.service.model_store import resolve_prepared_models  # noqa: E402
from speechrail.service.modelscope import ModelScopeDownloader  # noqa: E402
from speechrail.service.profile_commands import recommend_profile  # noqa: E402
from speechrail.service.profile_smoke import (  # noqa: E402
    PublicApiSmokeProbe,
    SmokeProbeError,
)
from speechrail.service.skill_installer import install_video_podcast_skill  # noqa: E402


def _log(stage: str, message: str) -> None:
    print(f"[\033[1;34m{stage}\033[0m] {message}")


def _success(message: str) -> None:
    print(f"[\033[1;32m✓ SUCCESS\033[0m] {message}")


def _warn(message: str) -> None:
    print(f"[\033[1;33m! WARNING\033[0m] {message}")


def _fail(message: str) -> None:
    print(f"[\033[1;31m✗ FAILED\033[0m] {message}", file=sys.stderr)


def _check_system_prerequisites() -> None:
    _log("PRECHECK", "检查硬件架构与系统依赖...")

    # 检查 ffmpeg
    if not shutil.which("ffmpeg"):
        brew_bin = shutil.which("brew") or (
            "/opt/homebrew/bin/brew" if Path("/opt/homebrew/bin/brew").exists() else None
        )
        if brew_bin:
            _log("PRECHECK", "未检测到 ffmpeg，正在通过 Homebrew 自动安装...")
            try:
                subprocess.run([brew_bin, "install", "ffmpeg"], check=True)
                _success("ffmpeg 已自动安装完成")
            except subprocess.CalledProcessError:
                _warn("自动安装 ffmpeg 失败，建议手动执行: brew install ffmpeg")
        else:
            _warn("系统 PATH 中未找到 ffmpeg。建议先执行: brew install ffmpeg")

    # 检查 uv
    if not shutil.which("uv"):
        _warn("当前 PATH 中未直接发现 uv，将在后续自动调用 uv 路径...")

    _success(f"硬件与环境自检通过: Apple Silicon ({machine}), macOS ({platform.mac_ver()[0]})")


def _get_physical_memory_bytes() -> int:
    try:
        pages = os.sysconf("SC_PHYS_PAGES")
        page_size = os.sysconf("SC_PAGE_SIZE")
        if isinstance(pages, int) and isinstance(page_size, int) and pages > 0 and page_size > 0:
            return pages * page_size
    except (OSError, ValueError):
        pass
    raise InstallerError("无法读取物理内存；请使用 --preset 显式选择运行档位")


def _wheel_version(wheel: Path) -> str:
    with ZipFile(wheel) as archive:
        metadata_names = [
            name for name in archive.namelist() if name.endswith(".dist-info/METADATA")
        ]
        if len(metadata_names) != 1:
            raise InstallerError("构建 wheel 缺少唯一 METADATA")
        metadata = BytesParser().parsebytes(archive.read(metadata_names[0]))
    version = metadata.get("Version")
    if not version:
        raise InstallerError("构建 wheel METADATA 缺少 Version")
    return version


def _build_wheel() -> Path:
    _log("BUILD", "正在构建应用 Wheel 安装包...")
    dist_dir = REPO_ROOT / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)
    output_dir = Path(tempfile.mkdtemp(prefix="speechrail-build-", dir=dist_dir))
    subprocess.run(
        ["uv", "build", "--no-sources", "--wheel", "--out-dir", str(output_dir)],
        cwd=REPO_ROOT,
        check=True,
    )

    wheels = list(output_dir.glob("speechrail-*.whl"))
    if len(wheels) != 1:
        raise InstallerError("本次构建没有生成唯一 SpeechRail wheel")

    wheel_path = wheels[0]
    wheel_version = _wheel_version(wheel_path)
    if wheel_version != __version__:
        raise InstallerError(
            f"wheel metadata version mismatch: expected {__version__}, got {wheel_version}"
        )
    digest = hashlib.sha256(wheel_path.read_bytes()).hexdigest()
    _success(f"Wheel 构建完成: {wheel_path.name} (sha256={digest})")
    return wheel_path


def _wait_for_ready(base_url: str, timeout_seconds: int = 45) -> bool:
    _log("PROBE", f"等待本地服务就绪 ({base_url}/readyz)...")
    start = time.monotonic()
    deadline = start + timeout_seconds

    with httpx.Client(timeout=5.0) as client:
        while time.monotonic() < deadline:
            try:
                resp = client.get(f"{base_url}/readyz")
                if resp.status_code == 200:
                    _success(f"服务已就绪！耗时: {time.monotonic() - start:.1f} 秒")
                    return True
            except Exception:
                pass
            time.sleep(1.0)

    _fail(f"服务在 {timeout_seconds} 秒内未完成预热就绪")
    return False


def _read_api_key(app_home: Path) -> str | None:
    """Read only the local API key needed by an authenticated smoke probe."""
    env_file = app_home / "config" / ".env"
    if not env_file.is_file():
        return None
    try:
        lines = env_file.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise InstallerError("private service configuration cannot be read") from exc
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() != "SPEECHRAIL_API_KEY":
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        return value or None
    return None


def _run_smoke_test(
    base_url: str,
    *,
    app_home: Path,
    prepared_id: str | None,
    api_key: str | None = None,
) -> None:
    """Use the canonical public smoke probe for installation verification."""
    if not prepared_id:
        raise InstallerError("managed install did not return a prepared model identity")
    _log("SMOKE", "执行端到端公共 API 冒烟测试（健康、模型、TTS、ASR）...")
    try:
        prepared = resolve_prepared_models(prepared_id, app_home=app_home)
        with httpx.Client(base_url=base_url, timeout=30.0) as client:
            PublicApiSmokeProbe(
                client=client,
                api_key=api_key,
                deadline_seconds=300.0,
            ).run(prepared)
    except (SmokeProbeError, OSError, ValueError, httpx.HTTPError) as exc:
        _fail("公共 API 冒烟测试失败")
        raise InstallerError("public API smoke failed") from exc
    _success("公共 API 冒烟测试通过（健康、模型、TTS、ASR）")


def _run_diarization_smoke_test(base_url: str, *, api_key: str | None = None) -> None:
    """Exercise the public diarization model without retaining audio or transcript data."""
    _log("SMOKE", "执行分人模型公共 API 冒烟测试...")
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    audio = io.BytesIO()
    with wave.open(audio, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(b"\x00\x00" * 16_000)
    try:
        with httpx.Client(base_url=base_url, timeout=60.0) as client:
            health = client.get("/health", headers=headers)
            models = client.get("/v1/models", headers=headers)
            response = client.post(
                "/v1/audio/transcriptions",
                headers=headers,
                data={"model": "gpt-4o-transcribe-diarize", "response_format": "diarized_json"},
                files={"file": ("diarization-smoke.wav", audio.getvalue(), "audio/wav")},
            )
    except httpx.HTTPError as exc:
        raise InstallerError("diarization public API smoke failed") from exc
    try:
        model_ids = {
            item.get("id") for item in models.json().get("data", []) if isinstance(item, dict)
        }
        segments = response.json().get("segments")
    except (ValueError, AttributeError) as exc:
        raise InstallerError("diarization public API smoke returned invalid JSON") from exc
    if (
        health.status_code != 200
        or health.json().get("diarization_ready") is not True
        or models.status_code != 200
        or "gpt-4o-transcribe-diarize" not in model_ids
        or response.status_code != 200
        or not response.headers.get("X-Request-ID")
        or not isinstance(segments, list)
    ):
        raise InstallerError("diarization public API smoke failed")
    _success("分人模型公共 API 冒烟测试通过")


def run_zero_setup(
    *,
    preset: str | None = None,
    app_home: Path | None = None,
    enable: bool = True,
    run_smoke: bool = True,
    timeout_seconds: int = 300,
    confirmed: bool = False,
    install_video_skill: bool = False,
) -> None:
    if not confirmed:
        raise InstallerError("zero-setup requires explicit confirmation")
    _check_system_prerequisites()

    resolved_app_home = (
        app_home or (Path.home() / "Library" / "Application Support" / "SpeechRail")
    ).resolve()

    mem_bytes = _get_physical_memory_bytes()
    selected_preset = preset or recommend_profile(mem_bytes)
    _log(
        "PLAN",
        f"目标安装路径: {resolved_app_home}\n"
        f"        统一内存大小: {mem_bytes / (1024**3):.1f} GiB\n"
        f"        选定运行档位: \033[1;32m{selected_preset}\033[0m",
    )

    wheel_path = _build_wheel()

    if install_video_skill:
        _log("SKILL", "安装 video-podcast skill 到用户级 .agents/skills ...")
        install_video_podcast_skill(REPO_ROOT / ".agents" / "skills" / "video-podcast")
        _success("video-podcast skill 已安装到用户级 .agents/skills/video-podcast")

    _log("INSTALL", f"开始拉取锁定模型并安装隔离运行时 (预设: {selected_preset})...")
    _log(
        "INSTALL",
        "首次下载含 ASR/TTS 制品，并按档位供给分人资产（balanced/quality 含 CoreML Sortformer 与 "
        "ForcedAligner；light 不供给），全程完成 SHA-256 校验；请保持网络连接稳定。",
    )

    diarization_enabled = load_catalog().preset(selected_preset).diarization

    post_enable = None
    if enable:
        base_url = "http://127.0.0.1:8201"

        def verify_started(candidate_home: Path, prepared_id: str) -> None:
            if run_smoke:
                _run_smoke_test(
                    base_url,
                    app_home=candidate_home,
                    prepared_id=prepared_id,
                    api_key=_read_api_key(candidate_home),
                )
                if diarization_enabled:
                    _run_diarization_smoke_test(base_url, api_key=_read_api_key(candidate_home))
            elif not _wait_for_ready(base_url, timeout_seconds=45):
                raise InstallerError("service did not become ready")

        post_enable = verify_started

    timeout = httpx.Timeout(connect=30.0, read=timeout_seconds, write=30.0, pool=30.0)
    with httpx.Client(timeout=timeout) as client:
        downloader = ModelScopeDownloader(client=client)
        try:
            assets = prepare_diarization_assets(
                resolved_app_home, preset_id=selected_preset, downloader=downloader
            )
        except DiarizationAssetError as exc:
            raise InstallerError("diarization asset preparation failed") from exc
        result = install_managed(
            wheel_path,
            app_home=resolved_app_home,
            preset_id=selected_preset,
            downloader=downloader,
            enable=enable,
            post_enable=post_enable,
            diarization_assets=(
                DiarizationInstallPaths(
                    coreml_model_path=assets.coreml_model_path,
                    aligner_model_dir=assets.aligner_model_dir,
                )
                if assets is not None
                else None
            ),
        )

    _log("INFO", f"应用主目录: {result.app_home}")
    _log("INFO", f"服务 Plist 路径: {result.plist_path}")
    _log("INFO", f"LaunchAgent 状态: {'已激活并运行' if result.enabled else '已安装但未启用'}")

    _success("Managed 运行时与服务安装及验证成功！")

    print("\n" + "=" * 60)
    print("\033[1;32mSpeechRail 本地语音服务已通过本次安装与验证。\033[0m")
    print("=" * 60)
    print("• 本地服务地址 : http://127.0.0.1:8201/v1")
    print("• 常用管理命令 :")
    print("  uv run speechrail service status    # 查看当前运行 PID 与端口状态")
    print("  uv run speechrail service restart   # 短等待/精确强杀后重启")
    print("  uv run speechrail service stop      # 安全停服")
    print("  uv run speechrail service start     # 安全启动")
    print("  uv run speechrail profile list      # 查看三档模型列表")
    print("  uv run speechrail profile apply ... # 停服切换，失败自动回退")
    print("• 双击配置脚本 : ~/Library/Application Support/SpeechRail/SpeechRail 设置.command")
    print("• OpenAI SDK 快速接入:")
    print("  client = OpenAI(base_url='http://127.0.0.1:8201/v1', api_key='local')")
    print("=" * 60 + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="SpeechRail 全新 Mac 从零搭建与自动化安装")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="确认安装依赖、下载模型、写入 app home 并注册用户级 LaunchAgent",
    )
    parser.add_argument(
        "--preset",
        choices=("quality", "balanced", "light"),
        help=(
            "指定运行档位（默认根据本机内存推荐：8GB=light, 16GB=balanced, 16GB+=quality）"
        ),
    )
    parser.add_argument(
        "--app-home",
        type=Path,
        help="自定义应用主目录 (默认: ~/Library/Application Support/SpeechRail)",
    )
    parser.add_argument(
        "--no-enable",
        action="store_true",
        help="安装后不立即激活 LaunchAgent 常驻服务",
    )
    parser.add_argument(
        "--install-video-podcast-skill",
        action="store_true",
        help="另行安装项目附带的 video-podcast 用户级 skill",
    )
    parser.add_argument(
        "--skip-smoke",
        action="store_true",
        help="跳过服务启动后的端到端 ASR/TTS 冒烟测试",
    )
    args = parser.parse_args()

    try:
        run_zero_setup(
            preset=args.preset,
            app_home=args.app_home,
            enable=not args.no_enable,
            run_smoke=not args.skip_smoke,
            confirmed=args.yes,
            install_video_skill=args.install_video_podcast_skill,
        )
    except (InstallerError, ServiceError, KeyboardInterrupt) as exc:
        _fail(f"搭建过程终止: {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
