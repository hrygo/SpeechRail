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
- 默认服务现在会在配置外部 snapshot 与专用 Python runtime 后启动单一 Qwen3 worker，
  使用固定 `ffmpeg` argv 解码上传音频，并验证 worker 的 MPS/float16 身份。

### Known limitations

- WLK sidecar、Hermes 与 `voice-realtime` 的真实切换/回滚仍待分别按 Runbook 验收。
- 没有配置 snapshot 或专用 runtime 的部署仍安全返回 `backend_not_ready`；本机 runtime
  配置保留在被忽略的 `.env`，不提交绝对模型路径或任何凭据。
- 未启动真实模型、未切换任何现有客户端、未修改 `voice-realtime`。
