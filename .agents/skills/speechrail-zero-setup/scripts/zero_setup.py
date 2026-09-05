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


if not ((3, 12) <= sys.version_info < (3, 13)):
    _auto_resolve_python_312()

# ==============================================================================
# 业务逻辑主体
# ==============================================================================
import argparse  # noqa: E402
import shutil  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

import httpx  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO_ROOT))

from tools.install_macos import InstallerError, install_managed  # noqa: E402

from speechrail.service.launchd import ServiceError  # noqa: E402
from speechrail.service.modelscope import ModelScopeDownloader  # noqa: E402
from speechrail.service.profile_commands import recommend_profile  # noqa: E402


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
    return 16 * 1024**3  # 默认假定 16GB


def _build_wheel() -> Path:
    _log("BUILD", "正在构建应用 Wheel 安装包...")
    dist_dir = REPO_ROOT / "dist"
    subprocess.run(["uv", "build", "--no-sources", "--wheel"], cwd=REPO_ROOT, check=True)

    wheels = sorted(dist_dir.glob("speechrail-*.whl"), key=os.path.getmtime)
    if not wheels:
        raise InstallerError("Wheel 构建完成但在 dist/ 目录下未找到产物")

    wheel_path = wheels[-1]
    _success(f"Wheel 构建完成: {wheel_path.name}")
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


def _run_smoke_test(base_url: str) -> None:
    _log("SMOKE", "执行端到端 TTS 语音合成与 ASR 转写冒烟测试...")
    with httpx.Client(base_url=base_url, timeout=30.0) as client:
        # 1. 测试 TTS
        test_text = "欢迎使用 SpeechRail 本地语音运行时服务。"
        tts_resp = client.post(
            "/v1/audio/speech",
            json={
                "model": "tts-1",
                "input": test_text,
                "voice": "serena",
                "response_format": "wav",
            },
        )
        if tts_resp.status_code != 200:
            _fail(f"TTS 测试失败，HTTP 状态码: {tts_resp.status_code}, 响应: {tts_resp.text}")
            return

        audio_bytes = tts_resp.content
        if len(audio_bytes) < 1000:
            _fail(f"TTS 生成音频过小 ({len(audio_bytes)} 字节)")
            return

        _success(f"TTS 语音合成测试成功 (生成 {len(audio_bytes)} 字节 WAV 音频)")

        # 2. 测试 ASR
        asr_resp = client.post(
            "/v1/audio/transcriptions",
            files={"file": ("test.wav", audio_bytes, "audio/wav")},
            data={"model": "whisper-1", "response_format": "json"},
        )
        if asr_resp.status_code != 200:
            _fail(f"ASR 测试失败，HTTP 状态码: {asr_resp.status_code}, 响应: {asr_resp.text}")
            return

        result = asr_resp.json()
        transcript = result.get("text", "")
        _success(f"ASR 语音转写测试成功，转写文本: 「{transcript}」")


def run_zero_setup(
    *,
    preset: str | None = None,
    app_home: Path | None = None,
    enable: bool = True,
    run_smoke: bool = True,
    timeout_seconds: int = 300,
) -> None:
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

    _log("INSTALL", f"开始拉取 ModelScope 权重并安装隔离运行时 (预设: {selected_preset})...")
    _log(
        "INSTALL",
        "提示：首次下载需获取约 1.5GB~5GB 模型快照并完成 SHA-256 校验，请保持网络连接稳定。",
    )

    timeout = httpx.Timeout(connect=30.0, read=timeout_seconds, write=30.0, pool=30.0)
    with httpx.Client(timeout=timeout) as client:
        downloader = ModelScopeDownloader(client=client)
        result = install_managed(
            wheel_path,
            app_home=resolved_app_home,
            preset_id=selected_preset,
            downloader=downloader,
            enable=enable,
        )

    _success("Managed 运行时与服务安装成功！")
    _log("INFO", f"应用主目录: {result.app_home}")
    _log("INFO", f"服务 Plist 路径: {result.plist_path}")
    _log("INFO", f"LaunchAgent 状态: {'已激活并运行' if result.enabled else '已安装但未启用'}")

    if enable:
        base_url = "http://127.0.0.1:8201"
        if _wait_for_ready(base_url, timeout_seconds=45) and run_smoke:
            _run_smoke_test(base_url)

    print("\n" + "=" * 60)
    print("\033[1;32m🎉 恭喜！SpeechRail 本地语音服务已 100% 完成从 0 搭建！\033[0m")
    print("=" * 60)
    print("• 本地服务地址 : http://127.0.0.1:8201/v1")
    print("• 常用管理命令 :")
    print("  uv run speechrail service status    # 查看当前运行 PID 与端口状态")
    print("  uv run speechrail service restart   # 重启服务")
    print("  uv run speechrail profile list      # 查看三档模型列表")
    print("  uv run speechrail profile apply ... # 无缝切换运行档位")
    print("• 双击配置脚本 : ~/Library/Application Support/SpeechRail/SpeechRail 设置.command")
    print("• OpenAI SDK 快速接入:")
    print("  client = OpenAI(base_url='http://127.0.0.1:8201/v1', api_key='local')")
    print("=" * 60 + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="SpeechRail 全新 Mac 从零搭建与自动化安装")
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
        )
    except (InstallerError, ServiceError, KeyboardInterrupt) as exc:
        _fail(f"搭建过程终止: {exc}")
        sys.exit(1)


if __name__ == "__main__":
    main()
