# Changelog

## [0.1.0] - 2026-08-31

### Added

- 创建 SpeechRail 独立项目和 Python 3.12 包骨架。
- 冻结 OpenAI-compatible REST、Realtime WebSocket 与 WLK legacy 兼容边界。
- 写入 `voice-realtime` 吸收矩阵、QwenPaw/Hermes/voice-realtime 接入方案、
  运行时安全边界、迁移 Runbook、测试门禁和 ADR。
- 添加可测试的领域模型、模型 alias/capability registry、长度前缀 Qwen3 worker 协议、
  离线/MPS snapshot preflight、Realtime 状态机、WLK snapshot compatibility renderer、
  有界 admission queue、统一 REST formatter 与隐私安全观测边界。
- 接通 `json`、`verbose_json`、`text`、`srt`、`vtt` REST formatter，以及现代 Realtime
  与 legacy `/asr` 的有序协议测试路径。

### Known limitations

- 真实 Qwen3 snapshot、隔离 Python runtime 与 WLK sidecar 没有在本工作区配置；默认服务
  因而仍安全返回 `backend_not_ready`。真实 MPS/三方客户端 smoke 需要按 Runbook 在外部
  模型环境执行。
- 未启动真实模型、未切换任何现有客户端、未修改 `voice-realtime`。
