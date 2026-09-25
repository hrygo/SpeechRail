---
name: speechrail-zero-setup
description: >-
  在全新 Apple Silicon Mac 上完成 SpeechRail 服务首装、模型准备和用户级 LaunchAgent 注册。
  仅在用户明确要求从零安装时触发；日常运维、版本发布、App 安装或远程部署不触发。
---

# SpeechRail 空白 Mac 首装

本流程会安装本机依赖、下载模型、写入用户 app home 并注册用户级 LaunchAgent。诊断默认只读；任何安装入口都必须显式 `--yes`。共享运行边界见 [本机 operator contract](../speechrail-local-deploy/references/operator-contract.md)。

已有实例的启停、切档、回滚和故障排查读 [speechrail-local-deploy](../speechrail-local-deploy/SKILL.md)；
wheel/App 发布或已有 App 整理读 [speechrail-release](../speechrail-release/SKILL.md)。

## 前置条件

- 按仓库 `AGENTS.md` 核对 Apple Silicon、macOS 26+ 与 Python 3.14.7 基线；Python 由 `uv` 提供隔离运行时，不修改系统 Python。
  任何脚本中的较低版本检查都不构成当前项目基线的放行条件。
- 依据目标 profile 的锁定制品、vendor runtime、wheel staging 与回退空间估算磁盘需求；脚本最小空间检查
  只是预检，不是完整容量保证。确认可访问所需锁定下载源。
- 规格推荐以代码中的 `recommend_selection()` 为内存兜底建议；ASR 与 TTS 两项规格独立选择（`--asr-spec` / `--tts-spec`），无法读取物理内存时停止自动推荐并要求用户显式指定。
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
  --asr-spec quality \
  --tts-spec quality \
  --app-home "$HOME/Library/Application Support/SpeechRail"

./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh \
  --yes \
  --asr-spec fast \
  --tts-spec fast \
  --install-video-podcast-skill
```

已有 `uv` 与 Python 3.14.7 时可直接调用核心安装器；同样必须显式确认：

```bash
uv run --python 3.14.7 python \
  .agents/skills/speechrail-zero-setup/scripts/zero_setup.py \
  --yes --asr-spec quality --tts-spec quality
```

`zero_setup.py` 在独立输出目录构建本次唯一 wheel，核对 wheel metadata 版本并记录 SHA-256；不会从 `dist/` 猜测旧产物。默认不安装用户级 `video-podcast` skill，该操作只有传入 `--install-video-podcast-skill` 时才执行，且失败不应改变 managed runtime。

## 安装事务

确认后依次完成：

1. 检查架构、macOS、磁盘和依赖；缺失 Xcode CLT、Homebrew、`ffmpeg`、`uv` 或 Python 3.14.7 时按入口提示安装。
2. 构建并验证精确 wheel；从 ModelScope 准备 catalog 锁定且逐文件校验的 ASR/TTS 制品（所选 ASR 规格 + 所选 TTS 规格的 `tts_custom_voice` / `tts_base` 角色），统一落在 `models/<artifact_key>`。分人是任务级 opt-in，只有传入 `--diarization-aligner aligner-q8|aligner-bf16` 时才额外供给：从固定 revision 准备 CoreML Sortformer FP16 bundle，并从 ModelScope 按点名 artifact 供给对应 ForcedAligner。每个文件的 size 与 SHA-256 均须匹配锁定 manifest。
3. 将已校验制品原子发布到 app home，创建隔离 worker runtime，写入权限为 `0600` 的私有配置，并执行 managed-runtime preflight。仅当本次供给分人资产时，私有配置才包含 `SPEECHRAIL_DIARIZATION_COREML_MODEL_PATH` 与 `SPEECHRAIL_QWEN3_ALIGNER_MODEL_DIR`。
4. 安装用户级 `com.speechrail` LaunchAgent；启用时使用统一生命周期 controller。
5. 使用 `PublicApiSmokeProbe` 在进程内读取必要凭据，验证 health、ready、models、voices、TTS 和 ASR；本次供给分人资产时再以不落盘的短 PCM 调用 `gpt-4o-transcribe-diarize` / `diarized_json`，未供给时跳过该 smoke。失败时由安装事务恢复旧指针或清理首次安装状态，并返回非零。

不要把真实 API key 放进命令参数或 shell 历史，不在仓库内生成测试音频，也不输出完整转写。手工复查仍使用统一探针；只记录 HTTP 状态、request ID、非空音频/转写校验和脱敏错误。

上述 smoke 属于完整首装事务。只有用户请求已覆盖依赖安装、模型下载、服务注册与启动及内置探针时，
才传入 `--yes`；该参数只表达已有授权，不能由 agent 添加参数来创造授权。用户明确限定只准备或只诊断时，
不得调用完整首装入口。UI 自动化、benchmark 和额外真实推理按各自授权边界处理。

每次安装都会在 `runtime/releases` 新增一个 release 目录，installer 不自动清理旧版本；重复首装或升级会让
app home 持续增长。因此磁盘预算还需考虑 release 累积，不能把首次预检阈值当作长期上限。保留、清理
与陈旧进程边界读 [speechrail-local-deploy](../speechrail-local-deploy/SKILL.md)。

## 已有实例

若检测到已运行的 SpeechRail，首装脚本不得在运行态替换。已有明确服务维护授权时使用 `speechrail service stop`；否则报告当前 PID、listener、profile 和阻塞原因。升级现有 wheel 使用 `speechrail-release`，日常启停或切档使用 `speechrail-local-deploy`。

## 完成条件

- 架构、系统版本、磁盘和 Python 3.14.7 检查通过；任何回退假设都已披露。
- 本次 wheel 的 metadata 版本与项目一致，SHA-256 已记录。
- managed runtime preflight 通过，只有一个目标 listener，PID/executable、profile 和 selection 一致。
- `/health`、`/readyz`、`/v1/models`、`/v1/voices` 以及真实 TTS→ASR smoke 通过。本次供给分人资产时额外要求 `diarization_ready=true`、`/v1/models` 包含 `gpt-4o-transcribe-diarize`，且匿名分人 smoke 返回有效 `segments` 数组；未供给时应报告分人未配置且 `/v1/models` 不含该别名。
- 安装失败时旧 runtime/selection 保持可恢复；首次安装失败时不留下可误启动的半配置。
- 只有显式请求安装 `video-podcast` 时才验证其用户级副本；该技能不是 SpeechRail 服务安装的完成条件。

交付报告区分已安装、已验证和未验证项，不使用“100%”或“自动自愈”代替证据。
