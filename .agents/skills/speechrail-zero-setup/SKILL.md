---
name: speechrail-zero-setup
description: >-
  在全新/空白 MacBook (Apple Silicon) 上从零搭建 SpeechRail 完整运行环境的标准流程 (SOP)。
  包含 M 芯片硬件与 macOS 14+ 前置拦截、通过 uv 自动准备隔离的 Python 3.12（解决用户电脑 Python 不兼容问题）、
  自动安装 Xcode CLT/Homebrew/ffmpeg、Managed 预设自动化部署 (quality/balanced/light)、
  外部权重自动拉取与哈希校验、以及 LaunchAgent 常驻和冒烟测试闭环。触发词：从零搭建、空白Mac安装、全新Mac配置、
  zero setup、fresh mac install、从0部署、M芯片检查、Python版本不匹配。
---

# 🚀 SpeechRail 空白 MacBook 从零搭建 SOP (`speechrail-zero-setup`)

本指南面向在**全新、未配置过 AI 运行时的空白 Apple Silicon MacBook**（从 M1 MacBook Air 到 M5 Max 各机型）上，从 0 到 100% 完成硬件兼容性检查、系统基座工具链、隔离的 Python 3.12 准备、应用打包、锁定的独立 Worker 运行时构建、ModelScope 权重拉取、LaunchAgent 常驻以及端到端冒烟验证的完整标准流程。

---

## 🛑 核心前置拦截与自动解决方案 (FAQ & Guardrails)

在开始之前，先明确两个最容易踩坑的硬性条件：

### 1. 硬件支持：为什么必须是 M 系列芯片（Apple Silicon）？
- **硬件事实**：SpeechRail 的推理核心采用 Qwen3-MLX 运行时。MLX 是专为 Apple Silicon 的**统一内存架构 (Unified Memory)** 与 **Metal GPU 算力** 定制的，直接在内存与显存之间实现零拷贝。
- **Intel (x86_64) Mac 现状**：Intel 芯片缺少 Apple Neural Engine 和统一内存架构，无法安装或运行 MLX。脚本会在最前置检测 `uname -m`，若为 `x86_64` 将明确报错拦截，避免徒劳下载几个 GB 的模型。

### 2. Python 版本：用户电脑自带或已装的 Python 不支持怎么办？
- **版本要求**：项目与 MLX Worker 运行环境严格锁定 Python `3.12.x`（`>=3.12,<3.13`）。macOS 自带的 Python 是 3.9，而 Homebrew 目前默认安装的是 3.13，直接用系统 Python 运行 100% 会报语法或依赖冲突。
- **降维解决方案（零污染接管）**：
  我们通过独立包管理器 `uv`（静态二进制，不依赖系统任何 Python）直接自动拉取官方编译的独立 CPython 3.12：
  ```bash
  uv python install 3.12
  ```
  之后所有命令统一通过 `uv run --python 3.12 ...` 调度。**无论用户的 Mac 上装的是什么版本，甚至没装 Python，都能 100% 确保运行环境为纯净标准的 Python 3.12**！

---

## 📋 1. 系统与硬件前置条件

| 检查项 | 绝对底线要求 | 推荐配置 | 终端快速核对命令 |
|---|---|---|---|
| **CPU 架构** | Apple Silicon (`arm64`) | M-Series Pro / Max / Ultra | `uname -m` (必须返回 `arm64`) |
| **操作系统** | macOS 14.0 (Sonoma) 以上 | macOS 15.x (Sequoia) | `sw_vers -productVersion` |
| **磁盘剩余空间** | 至少 20 GB 可用空间 | 40 GB+ 空闲空间 | `df -h /System/Volumes/Data` |
| **网络连通性** | 可稳定访问 GitHub 与 ModelScope | 具备国内高速网络访问能力 | `curl -I https://modelscope.cn` |

---

## ⚡ 2. 推荐方式：一键自动化全流程搭建 (Zero-Touch)

在全新 Mac 打开终端，克隆代码后直接运行 Skill 内置的一键脚本：

```bash
# 1. 克隆代码仓库
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail

# 2. 运行一键全自动引导程序 (自动处理芯片架构检测、Xcode CLT、Homebrew、ffmpeg、Python 3.12 准备与部署)
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh
```

*(如果机器上已经预装了 `uv`，亦可直接使用专属 Python 3.12 调用核心安装引擎：)*
```bash
# 自动根据内存推荐档位 (8GB=light, 16GB=balanced, 16GB+=quality)
uv run --python 3.12 python .agents/skills/speechrail-zero-setup/scripts/zero_setup.py

# 亦可显式指定需要的档位（如平衡档）：
# uv run --python 3.12 python .agents/skills/speechrail-zero-setup/scripts/zero_setup.py --preset balanced
```

> **自动化引擎幕后 100% 自动执行的闭环任务：**
> 1. 🛡️ **双重硬件与版本拦截**：检测 CPU 架构是否为 `arm64`，检测 Python 是否为 `3.12`；
> 2. 📦 **应用打包**：调用 `uv build` 构建干净的标准 wheel 产物；
> 3. 📥 **模型拉取与校验**：从 ModelScope 流式下载对应档位（ASR + TTS）权重，全量比对 SHA-256 哈希；
> 4. 🐍 **创建独立 Worker 环境**：基于 `runtime-lock.json` 在 `vendor/` 目录下构建完全隔离的 MLX 运行环境；
> 5. 🔒 **生成受管配置**：自动生成 `app_home/config/.env`（严格限制为 `0600` 私有权限）；
> 6. 🖥️ **生成双击设置程序**：在 App Home 生成无需开终端即可交互调用的 `SpeechRail 设置.command`；
> 7. 🔍 **执行服务 Preflight**：校验 Worker 模块 import、静态 ffmpeg 权限与配置完整性；
> 8. 🚀 **注册并启动守护进程**：生成并激活 `~/Library/LaunchAgents/com.speechrail.plist`；
> 9. 🎙️ **端到端冒烟测试**：有界轮询等待 `/readyz` 200，调用真实 TTS 合成一段测试音频，紧接着调用 ASR 接口转写验证闭环。

---

## 🛠️ 3. 分步手动执行 SOP (Step-by-Step for Audit)

如果你希望逐步审计每一步的执行细节，请按以下标准化步骤进行：

### Step 3.1: 架构核查与 Xcode CLT
```bash
# 1. 确认是否为 Apple Silicon
[ "$(uname -m)" = "arm64" ] || { echo "非 M 芯片，不支持"; exit 1; }

# 2. 检查或安装 Xcode 命令行工具
xcode-select -p >/dev/null 2>&1 || xcode-select --install
```

### Step 3.2: 准备 Homebrew 与 ffmpeg
```bash
# 1. 安装 Homebrew (如果未安装)
if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# 2. 固化 Apple Silicon 的 PATH 环境变量
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)"
grep -q '/opt/homebrew/bin/brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile

# 3. 安装音频处理工具
brew install ffmpeg git
```

### Step 3.3: 精准安装 Python 3.12 (通过 uv)
```bash
# 1. 安装 uv
command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.cargo/env" 2>/dev/null || export PATH="$HOME/.cargo/bin:$PATH"

# 2. 显式拉取标准的 Python 3.12 运行时
uv python install 3.12
```

### Step 3.4: 同步依赖与构建 Wheel
```bash
cd /path/to/SpeechRail
uv sync --python 3.12 --extra dev
uv build --no-sources --wheel
```

### Step 3.5: 执行受管服务安装 (Managed Install)
调用内建的 `install_managed` 完成安装：
```bash
APP_HOME="$HOME/Library/Application Support/SpeechRail"
PRESET="balanced"  # 可选: quality, balanced, light

uv run --python 3.12 python - <<PY
import os
from pathlib import Path
import httpx
from speechrail.service.modelscope import ModelScopeDownloader
from tools.install_macos import install_managed

app_home = Path(os.environ.get("APP_HOME", "$HOME/Library/Application Support/SpeechRail")).expanduser()
preset = os.environ.get("PRESET", "balanced")
wheel = sorted(Path("dist").glob("speechrail-*.whl"))[-1]

with httpx.Client(timeout=httpx.Timeout(connect=30, read=300, write=30, pool=30)) as client:
    res = install_managed(
        wheel,
        app_home=app_home,
        preset_id=preset,
        downloader=ModelScopeDownloader(client=client),
        enable=True,  # 自动安装并启用 LaunchAgent
    )
print(f"安装成功: {res.app_home}")
PY
```

---

## 🔍 4. 验证探针与冒烟验收 (Verification)

### 4.1 系统状态探针
```bash
# 1. 查看 LaunchAgent 常驻状态与 PID
uv run speechrail service status

# 2. 检查基础健康
curl -s http://127.0.0.1:8201/health | jq .

# 3. 检查推理 Worker 就绪状态 (HTTP 200 表示权重已载入统一内存)
curl -i http://127.0.0.1:8201/readyz

# 4. 检查可用音色与模型清单
curl -s http://127.0.0.1:8201/v1/models | jq .
curl -s http://127.0.0.1:8201/v1/voices | jq .
```

### 4.2 真实端到端推理闭环测试 (TTS + ASR)
```bash
# 1. 语音合成 (TTS): 生成一段测试语音
curl -s http://127.0.0.1:8201/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model": "tts-1", "input": "你好，SpeechRail 已经在你的 Mac 上就绪。", "voice": "serena"}' \
  --output test_speech.wav

# 2. 播放音频（macOS 原生播放命令）
afplay test_speech.wav

# 3. 语音识别 (ASR): 转写刚刚生成的音频
curl -s http://127.0.0.1:8201/v1/audio/transcriptions \
  -F file="@test_speech.wav" \
  -F model="whisper-1" | jq .
```

---

## 🎛️ 5. 日常运维与档位切换

服务安装为当前用户的 macOS LaunchAgent，开机自启、故障自愈。

### 常用服务命令
```bash
uv run speechrail service status    # 查看当前运行 PID 与端口状态
uv run speechrail service restart   # 重启服务
uv run speechrail service disable   # 临时停用服务
uv run speechrail service enable    # 启用常驻服务
```

### 运行档位切换与回滚
```bash
speechrail profile list               # 查看各档位下载体积与模型配置
speechrail profile apply balanced     # 切换至 balanced 档（自动冒烟与回退保护）
speechrail profile rollback           # 一键安全回滚至上一可用档位
```

桌面图形化设置：
直接双击打开 `$HOME/Library/Application Support/SpeechRail/SpeechRail 设置.command` 即可交互式调整档位。

---

## 🚨 6. 常见故障自愈决策表

| 故障现象 | 根因与判定依据 | 立即恢复操作 |
|---|---|---|
| `硬件架构不兼容: 检测到当前芯片架构为「x86_64」` | 该机器为 Intel Mac，硬件不支持 MLX 与统一内存 | 需使用配备 Apple Silicon (M1~M5) 的 Mac 运行 |
| `Python 版本不匹配: 当前运行解释器为 Python 3.9/3.13` | 用户使用了系统原生或 Homebrew 默认的 Python | 统一前缀 `uv run --python 3.12` 执行 |
| `command not found: brew` | Apple Silicon 未正确将 `/opt/homebrew` 加入 PATH | 执行 `eval "$(/opt/homebrew/bin/brew shellenv)"` |
| `/readyz` 返回 `503 backend_not_ready` | 首次模型权重载入统一内存需要 5~15 秒 | 稍等数秒重试，或查看 `tail -n 20 ~/Library/Logs/SpeechRail/service.stderr.log` |
| 语音转写报 `audio_decode_failed` | 系统中缺失 `ffmpeg` 解封装工具 | 执行 `brew install ffmpeg` |
| 下载 ModelScope 权重速度慢或连接中断 | 局域网访问外部源偶发抖动 | 重新运行安装脚本，引擎会自动校验已有本地文件并断点续传 |

---

## ✅ 7. 100% Done 验收标准 (Definition of Done)

只有同时满足以下所有条件，才算在全新 Mac 上搭建完成：
- [ ] `uname -m` 为 `arm64`，`ffmpeg -version` 正常工作；
- [ ] 当前执行环境为 Python 3.12 (`>=3.12,<3.13`)；
- [ ] `uv run speechrail service status` 显示服务正常常驻且有明确 PID；
- [ ] `curl -i http://127.0.0.1:8201/readyz` 返回 `HTTP/1.1 200 OK`；
- [ ] `curl http://127.0.0.1:8201/v1/voices` 成功列出 9 个预设角色；
- [ ] 使用 OpenAI SDK 或 cURL 成功生成一段非空语音并完成文本识别闭环。
