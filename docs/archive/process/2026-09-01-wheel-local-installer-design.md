---
title: "SpeechRail wheel 与 macOS 本地安装器设计"
status: archived
date: 2026-09-01
---

# SpeechRail wheel 与 macOS 本地安装器设计

## 决策

SpeechRail 采用“wheel + 本地安装器 + 外部模型/runtime”的分层分发方式：

- wheel 只交付 Python 服务代码、CLI 和普通服务依赖；
- `tools/install_macos.py` 负责创建用户私有 app home、专用 venv、配置副本和 LaunchAgent；
- ASR/TTS vendor Python、模型 snapshot 和 `ffmpeg` 由本机单独准备并由 preflight 检查；
- 运行时仍是一个用户级 `LaunchAgent`、一个 ASGI 进程和每个 profile 一个 worker；
- 默认安装不启用服务，只有显式 `--enable` 且完整 preflight 通过后才启动。

## 目录布局

```text
~/Library/Application Support/SpeechRail/
├── config/.env
├── runtime/current -> runtime/releases/<release>
└── runtime/releases/<release>/.venv/
```

LaunchAgent 使用 `runtime/current/.venv/bin/python -m speechrail serve`，工作目录为 app home。
这样配置不依赖源码仓库；切换 `current` 即可在新 runtime 和旧 runtime 之间回退。模型不进入
release venv，避免重复占用磁盘和破坏 vendor runtime 生命周期。

## 安全边界

- 安装器不自动下载模型、访问远程音频或读取不透明输入引用；
- 已存在的 `.env` 不覆盖，写入的新配置设为 `0600`；
- plist 不包含 API key、完整环境变量或模型绝对路径；
- 所有子进程使用参数数组，不经过 shell，不要求 root；
- 新 runtime 在切换前完成 wheel 内容、CLI、plist、健康端点和 voices 目录检查；
- 真实 ASR/TTS smoke 只使用操作者有权处理的短音频，验收后删除临时音频。

## 取舍

不采用 PyInstaller 单文件、Docker、Kubernetes、系统级 LaunchDaemon 或自建 package server。
这些方案会把 MPS 权限、模型体积、vendor 依赖和本机服务生命周期绑定在一起，不符合本机单人
项目的最小设计原则。

README 不写死发布版本，避免文档腐朽；但 wheel 文件名、package metadata、release archive
和校验文件必须保留版本/构建身份，以支持升级、回滚和审计。

## 验收门

```bash
uv build --no-sources --wheel
uv run --extra dev pytest
uv run --extra dev ruff check src tests tools scripts
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

以上静态门通过后，必须在干净 runtime 中完成 LaunchAgent 状态、`/health`、`/readyz`、
`/v1/models`、`/v1/voices` 以及真实 ASR/TTS 闭环验收；静态测试通过不能替代模型真实性能和
质量验收。
