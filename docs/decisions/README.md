# Architecture Decision Records

| ADR | 决策 | 状态 |
|---|---|---|
| [0001](0001-independent-service.md) | ASR 独立服务与产品边界 | Accepted |
| [0002](0002-openai-compatible-contract.md) | OpenAI-compatible REST + Realtime | Accepted |
| [0003](0003-runtime-isolation.md) | 模型运行时隔离与离线准入 | Accepted |
| [0004](0004-wlk-legacy-compatibility.md) | 保留 WLK legacy `/asr` | Accepted |
| [0005](0005-application-ownership.md) | 会议/音频/LLM 所有权留在 voice-realtime | Accepted |
| [0006](0006-public-asr-tts-runtime.md) | 公共 ASR/TTS runtime 与 Realtime 直迁移 | Superseded by 0009 |
| [0007](0007-public-speaker-diarization.md) | 公共 Realtime 匿名说话人分离与应用侧身份映射 | Accepted |
| [0008](0008-remove-legacy-ws-endpoints.md) | 移除 legacy WS 端点与外部 WLK streaming 后端 | Accepted |
| [0009](0009-openai-realtime-only.md) | 移除 `/v2/realtime`，统一 OpenAI Realtime `/v1/realtime` | Accepted |

ADR 记录为什么这样设计；旧决策不删除，后续改变用新 ADR supersede。
