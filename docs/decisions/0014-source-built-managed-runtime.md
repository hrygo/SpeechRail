---
title: "ADR-0014：源码构建与 managed runtime 发布不变量"
status: accepted
date: 2026-09-09
---

# ADR-0014：源码构建与 managed runtime 发布不变量

## 决策

SpeechRail 的所有修复、协议和 worker 变更必须先落在源码仓库。发布时从源码构建 wheel，通过 `tools.install_macos.install_managed` 创建候选 release，执行 preflight 和公共 smoke，成功后原子切换 `runtime/current`；失败则保留或恢复上一 release。

禁止直接编辑 managed `runtime/current`、release venv、worker 安装目录或运行中的进程文件。运行时目录是部署产物，不是源代码仓库。

## 背景

直接修改 managed runtime 虽能短暂改变行为，但无法审计、无法在下一次升级保留，也容易造成源码、wheel、health 和实际运行版本不一致。SpeechRail 同时包含 Python ASR/TTS、CoreML diarization executable、外部模型 snapshot 和私有配置，必须由 managed installer 统一完成版本与回退边界。

## 后果

- 每次变更都可通过 git diff、wheel metadata、release 路径和 health version 追溯。
- 代码修复必须经过源码质量门和真实目标 smoke；“运行时已经改了”不再视为交付完成。
- managed installer 需要继续保留旧 release，确保 VAD、diarization、ASR、TTS 任一 preflight 或 smoke 失败时可回退。
- 私有 `.env`、模型 snapshot 和运行态配置不进入源码 wheel，也不在文档中记录密钥或完整绝对路径。
