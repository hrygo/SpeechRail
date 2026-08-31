# Changelog

## [0.1.0] - 2026-08-31

### Added

- 创建 SpeechRail 独立项目和 Python 3.12 包骨架。
- 冻结 OpenAI-compatible REST、Realtime WebSocket 与 WLK legacy 兼容边界。
- 写入 `voice-realtime` 吸收矩阵、QwenPaw/Hermes/voice-realtime 接入方案、
  运行时安全边界、迁移 Runbook、测试门禁和 ADR。
- 添加 FastAPI contract shell：`/health`、`/readyz`、`/v1/models`、
  `/v1/audio/transcriptions` 及两个 WebSocket 入口。

### Known limitations

- Qwen3-ASR 推理 worker 和 WLK adapter 尚未迁入；转写请求会安全返回
  `backend_not_ready`。
- 未启动真实模型、未切换任何现有客户端、未修改 `voice-realtime`。
