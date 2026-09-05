#!/usr/bin/env zsh
# ==============================================================================
# SpeechRail 空白 MacBook 一键基座环境准备与自动化安装脚本 (Bootstrap)
#
# 支持系统: macOS 14+ (Sonoma, Sequoia 等)
# 硬件要求: Apple Silicon (M1 / M2 / M3 / M4 / M5 全系)
# ==============================================================================

set -euo pipefail

# 颜色定义
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

echo -e "\n${BLUE}======================================================${NC}"
echo -e "${BLUE}   SpeechRail Apple Silicon Mac 从零环境初始化脚本    ${NC}"
echo -e "${BLUE}======================================================${NC}\n"

# ------------------------------------------------------------------------------
# 1. 硬件架构前置检查 (绝对拦截非 M 芯片 Mac)
# ------------------------------------------------------------------------------
ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
  echo -e "${RED}[ERROR] 硬件架构不兼容：检测到当前机器架构为「$ARCH」。${NC}"
  echo -e "${RED}SpeechRail 的推理引擎（Qwen3-MLX）高度依赖 Apple Silicon 统一内存与 Metal 硬件加速。${NC}"
  echo -e "${RED}目前仅支持配备 M 系列芯片（M1/M2/M3/M4/M5 等）的 Mac，不支持 Intel (x86_64) Mac。${NC}\n"
  exit 1
fi
echo -e "${GREEN}[1/6] 硬件架构检查通过: Apple Silicon ($ARCH)${NC}"

# ------------------------------------------------------------------------------
# 2. macOS 系统版本检查 (要求 macOS 14+)
# ------------------------------------------------------------------------------
OS_VER=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
if [[ "$OS_MAJOR" -lt 14 ]]; then
  echo -e "${RED}[ERROR] 系统版本过低：检测到当前 macOS 版本为 $OS_VER。${NC}"
  echo -e "${RED}SpeechRail 依赖 macOS 14.0 (Sonoma) 及以上版本的统一内存分配与 Metal API。${NC}"
  echo -e "${RED}请先在「系统设置 -> 通用 -> 软件更新」中将系统升级后再试。${NC}\n"
  exit 1
fi
echo -e "${GREEN}[2/6] 操作系统版本检查通过: macOS $OS_VER (>= 14.0)${NC}"

# ------------------------------------------------------------------------------
# 3. Xcode Command Line Tools 检查与引导
# ------------------------------------------------------------------------------
if ! xcode-select -p >/dev/null 2>&1; then
  echo -e "${YELLOW}[!] 检测到未安装 Xcode Command Line Tools，正在触发系统安装...${NC}"
  echo -e "${YELLOW}请在弹出的系统对话框中点击「安装」，安装完成后请重新运行本脚本。${NC}"
  xcode-select --install
  exit 1
fi
echo -e "${GREEN}[3/6] Xcode Command Line Tools 已就绪${NC}"

# ------------------------------------------------------------------------------
# 4. Homebrew 与 ffmpeg 检查与自动安装
# ------------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  echo -e "${YELLOW}[!] 未检测到 Homebrew，开始自动安装 Homebrew...${NC}"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# 确保 Apple Silicon 默认安装路径 (/opt/homebrew) 立即在当前环境生效
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)"
if ! grep -q '/opt/homebrew/bin/brew shellenv' ~/.zprofile 2>/dev/null; then
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo -e "${BLUE}[+] 安装音频解码核心工具 ffmpeg...${NC}"
  brew install ffmpeg
fi
echo -e "${GREEN}[4/6] Homebrew 与音频解码器 (ffmpeg) 已就绪${NC}"

# ------------------------------------------------------------------------------
# 5. uv 与 Python 3.12 精准准备 (彻底解决用户机器 Python 版本不对的问题)
# ------------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  echo -e "${YELLOW}[!] 未检测到 uv，开始自动安装现代 Python 包管理器 uv...${NC}"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# 载入 uv 环境变量
if [[ -f "$HOME/.cargo/env" ]]; then
  source "$HOME/.cargo/env"
elif [[ -d "$HOME/.cargo/bin" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

echo -e "${BLUE}[+] 自动下载并锁定标准的 CPython 3.12 运行时...${NC}"
# 无论用户系统当前是什么版本的 Python，通过 uv 自动准备隔离的 Python 3.12
uv python install 3.12
echo -e "${GREEN}[5/6] uv 与专属 Python 3.12 已就绪 (无需担心系统 Python 版本)${NC}"

# ------------------------------------------------------------------------------
# 6. 同步项目依赖并调起核心安装引擎 zero_setup.py
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"

cd "$REPO_ROOT"
echo -e "${BLUE}[+] 基于 Python 3.12 同步主工程依赖...${NC}"
uv sync --python 3.12 --extra dev

echo -e "\n${GREEN}[6/6] 基座环境已全部准备完毕！进入 SpeechRail 自动化安装与校验流程...${NC}\n"
# 强制指定由 Python 3.12 执行，完全避免调用错误版本
uv run --python 3.12 python "$SCRIPT_DIR/zero_setup.py" "$@"
