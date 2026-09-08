---
name: speechrail-zero-setup
description: >-
  在全新 Apple Silicon Mac 上安装 SpeechRail 的首装 SOP。仅在用户明确要求完成 SpeechRail
  从零安装、下载模型并注册本机服务时使用；普通 Python 版本排障、日常升级或远程部署不触发。
---

# SpeechRail 空白 Mac 首装

本流程会安装本机依赖、下载模型、写入用户 app home 并注册用户级 LaunchAgent。诊断默认只读；任何安装入口都必须显式 `--yes`。共享运行边界见 [本机 operator contract](../speechrail-local-deploy/references/operator-contract.md)。

## 前置条件

- Apple Silicon `arm64`，macOS 14+，Python `>=3.12,<3.13`；Python 由 `uv` 提供隔离运行时，不修改系统 Python。
- 预留至少 25 GB 磁盘空间，并可访问项目锁定的下载源。
- profile 推荐以代码中的 `recommend_profile()` 为唯一事实源；无法读取物理内存时停止自动推荐，要求用户显式指定 `--preset`。
- 安装前确认脚本解析到包含 `pyproject.toml` 的项目根目录；不得从未知目录继续执行。

## 首选入口

克隆项目后，从项目根目录执行：

```bash
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh --yes
```

可显式指定档位、app home，并可独立选择是否安装附带的视频制作技能：

```bash
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh \
  --yes \
  --preset balanced \
  --app-home "$HOME/Library/Application Support/SpeechRail"

./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh \
  --yes \
  --preset balanced \
  --install-video-podcast-skill
```

已有 `uv` 与 Python 3.12 时可直接调用核心安装器；同样必须显式确认：

```bash
uv run --python 3.12 python \
  .agents/skills/speechrail-zero-setup/scripts/zero_setup.py \
  --yes --preset balanced
```

`zero_setup.py` 在独立输出目录构建本次唯一 wheel，核对 wheel metadata 版本并记录 SHA-256；不会从 `dist/` 猜测旧产物。默认不安装用户级 `video-podcast` skill，该操作只有传入 `--install-video-podcast-skill` 时才执行，且失败不应改变 managed runtime。

## 安装事务

确认后依次完成：

1. 检查架构、macOS、磁盘和依赖；缺失 Xcode CLT、Homebrew、`ffmpeg`、`uv` 或 Python 3.12 时按入口提示安装。
2. 构建并验证精确 wheel；从 ModelScope 准备 catalog 锁定且逐文件校验的 ASR/TTS 制品，并从固定 Hugging Face revision 准备 CoreML Sortformer FP16 bundle 与 `Qwen3-ForcedAligner-0.6B`。每个文件的 size 与 SHA-256 均须匹配锁定 manifest。
3. 将四组已校验制品原子发布到 app home，创建隔离 worker runtime，写入权限为 `0600` 的私有配置（含 `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH` 与 `SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR`），并执行 managed-runtime preflight。
4. 安装用户级 `com.speechrail` LaunchAgent；启用时使用统一生命周期 controller。
5. 使用 `PublicApiSmokeProbe` 在进程内读取必要凭据，验证 health、ready、models、voices、TTS 和 ASR；再以不落盘的短 PCM 调用 `gpt-4o-transcribe-diarize` / `diarized_json`。失败时由安装事务恢复旧指针或清理首次安装状态，并返回非零。

不要把真实 API key 放进命令参数或 shell 历史，不在仓库内生成测试音频，也不输出完整转写。手工复查仍使用统一探针；只记录 HTTP 状态、request ID、非空音频/转写校验和脱敏错误。

## 已有实例

若检测到已运行的 SpeechRail，首装脚本不得在运行态替换。已有明确服务维护授权时使用 `speechrail service stop`；否则报告当前 PID、listener、profile 和阻塞原因。升级现有 wheel 使用 `speechrail-release`，日常启停或切档使用 `speechrail-local-deploy`。

## 完成条件

- 架构、系统版本、磁盘和 Python 3.12 检查通过；任何回退假设都已披露。
- 本次 wheel 的 metadata 版本与项目一致，SHA-256 已记录。
- managed runtime preflight 通过，只有一个目标 listener，PID/executable、profile 和 selection 一致。
- `/health`、`/readyz`、`/v1/models`、`/v1/voices` 以及真实 TTS→ASR smoke 通过；`diarization_ready=true`，`/v1/models` 包含 `gpt-4o-transcribe-diarize`，匿名分人 smoke 返回有效 `segments` 数组。
- 安装失败时旧 runtime/selection 保持可恢复；首次安装失败时不留下可误启动的半配置。
- 只有显式请求安装 `video-podcast` 时才验证其用户级副本；该技能不是 SpeechRail 服务安装的完成条件。

交付报告区分已安装、已验证和未验证项，不使用“100%”或“自动自愈”代替证据。
