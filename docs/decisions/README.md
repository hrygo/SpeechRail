# Architecture Decision Records

| ADR | 决策 | 状态 |
|---|---|---|
| [0001](0001-independent-service.md) | ASR 独立服务与产品边界 | Accepted |
| [0002](0002-openai-compatible-contract.md) | OpenAI-compatible REST + Realtime | Accepted |
| [0003](0003-runtime-isolation.md) | 模型运行时隔离与离线准入 | Accepted |
| [0004](0004-wlk-legacy-compatibility.md) | 保留 WLK legacy `/asr` | Superseded by 0008 |
| [0005](0005-application-ownership.md) | 会议/音频/LLM 所有权留在 sona | Accepted |
| [0006](0006-public-asr-tts-runtime.md) | 公共 ASR/TTS runtime 与 Realtime 直迁移 | Superseded by 0009 |
| [0007](0007-public-speaker-diarization.md) | 公共 Realtime 匿名说话人分离与应用侧身份映射 | Superseded in diarization scope by 0012 |
| [0008](0008-remove-legacy-ws-endpoints.md) | 移除 legacy WS 端点与外部 WLK streaming 后端 | Accepted |
| [0009](0009-openai-realtime-only.md) | 移除 `/v2/realtime`，统一 OpenAI Realtime `/v1/realtime` | Accepted |
| [0010](0010-streaming-diarization-fix.md) | 修复流式路径说话人分离（segments 硬编码空 + Sortformer 解析） | Superseded by 0012 |
| [0011](0011-unified-runtime-model-tiers.md) | 统一 ASR/TTS 运行时、仅权重三档与可恢复本地切换 | Accepted（已在 v1.8.0 实施并在本机质量档验收通过） |
| [0012](0012-openai-native-coreml-diarization.md) | OpenAI 原生分人接口与唯一 CoreML 运行时 | Accepted |
| [0013](0013-realtime-vad-and-diarization-boundary.md) | Realtime endpointing 与 continuous diarization activity 分离 | Accepted |
| [0014](0014-source-built-managed-runtime.md) | 所有运行时变更必须从源码构建并经 managed release 部署 | Accepted |
| [0015](0015-tier-user-positioning-and-precision-policy.md) | 三档按用户定位重排与按档位精度策略 | Accepted |
| [0016](0016-configurable-heavy-compute-overlap.md) | 可配置的 ASR∥TTS 重计算重叠（声明字节 + 物理内存预算） | Accepted |

ADR 记录为什么这样设计；旧决策不删除，后续改变用新 ADR supersede。
