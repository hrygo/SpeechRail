# ADR-0018：Realtime current wire 与可插拔外部 LLM

## Status

Superseded by ADR-0019

This proposal was replaced before implementation. The accepted direction keeps
SpeechRail as a stateless speech plane and leaves LLM orchestration to callers;
no server-side external LLM provider is to be implemented from this ADR.

## Date

2026-09-20

## Context

SpeechRail 当前的 `/v1/realtime` 已经是唯一公共 Realtime 入口，但实现仍同时保留
legacy 与 current 两套事件/字段分支。`session.update` 的嵌套 current 形状只完成了部分解析，
`response.create` 仍依赖待合成文本，服务不会把 ASR 结果交给语言模型，因此当前能力是
ASR/TTS 子集，不是完整的 OpenAI Realtime conversation。

当前项目几乎没有需要保护的老用户。继续维护两套 wire 会让协议、状态机和测试继续分叉，
而且会掩盖 OpenAI SDK 真正看到的事件序列。与此同时，macOS App 已经有一个外部
OpenAI-compatible Responses provider，但 Python 服务侧还没有可注入的语言模型 port。

当前 OpenAI Realtime 文档以嵌套 `session.audio`、`output_modalities`、
`response.output_audio.*` 和 `response.output_audio_transcript.*` 为主要 wire；官方 Node SDK
也提供了 `OpenAIRealtimeWebSocket` 黑盒客户端。参考：

- [OpenAI Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations)
- [openai-node Realtime WebSocket example](https://github.com/openai/openai-node/blob/main/examples/realtime/websocket.ts)
- [openai-node v7.19.0 release](https://github.com/openai/openai-node/releases/tag/v7.19.0)

## Decision

1. 继续使用 ADR-0009 规定的唯一公共入口 `/v1/realtime`，但把当前实现视为 pre-GA
   contract reset：删除 legacy wire 分支，不再承诺旧版 SpeechRail Realtime 事件兼容。
2. 只保留当前 OpenAI wire。公共事件使用当前的 `.added/.done` 生命周期、
   `response.output_audio.*` 和 `response.output_audio_transcript.*`；不再发送
   `conversation.item.created`、`response.audio.*` 等旧事件。
3. 将 Realtime 分成两个明确会话类型：
   - `transcription`：ASR-only，不调用 LLM；
   - `realtime`：维护 conversation，支持外部 LLM 生成文本，再按 output modality 走文本或 TTS。
4. 在服务侧增加 vendor-neutral `RealtimeLanguageModel` port，首个 adapter 使用
   OpenAI-compatible Responses API 的 streaming 输出。外部 LLM 默认关闭，凭据只通过受控
   secret 引用解析，服务不上传原始音频、不记录完整 prompt 或转写正文。
5. `response.create` 可以消费已经提交的音频 conversation item，不再要求额外的文本 item。
   `response.cancel` 必须取消 LLM、句子缓冲和 TTS 的整个 response 链路。
6. OpenAI SDK 兼容性以官方 `openai-node` 当前版本的真实 WebSocket 连接作为黑盒门禁。
   计划编写时已核对官方 release 页面，第一版固定 `openai@7.19.0`；版本更新时重新运行
   同一 harness，不以本地单元测试代替 SDK 验证。
7. 首版只承诺已实现的 text/audio、manual/server VAD、PCM 音频和外部文本 LLM 能力。
   tools、image、semantic VAD 等未实现能力必须返回稳定的 `unsupported_operation` 或
   `invalid_value`，不得静默映射成不同语义。
8. 本 ADR 不删除 SpeechRail 自有能力：`/v1/voices*` 音色管理、VoiceDesign、Base
   reference clone、preview、quality-runs、voice revision、voice binding、render receipt
   以及 `speechrail.*` namespaced Realtime 扩展继续保留。current-only 只约束 OpenAI 标准
   wire，不把 SpeechRail 私有能力伪装成 OpenAI 标准字段。

## Alternatives Considered

### 保留 legacy/current 双 wire

- 优点：短期看似降低迁移风险。
- 缺点：维护两套事件生命周期，SDK 黑盒验证无法说明哪套是主契约。
- 拒绝：用户量不足以抵消长期协议分叉成本。

### 只在 macOS App 侧调用外部 LLM

- 优点：复用已有 `LLMProvider`，服务无需增加外部网络依赖。
- 缺点：任意 OpenAI Realtime 客户端无法获得完整 conversation；能力依赖 App。
- 拒绝作为主方案：App provider 保留为参考和 App 专用路径，服务侧仍需 provider port。

### 新增 `/v2/realtime`

- 优点：严格隔离破坏性 wire 变化。
- 缺点：OpenAI SDK 默认连接 `/v1/realtime`，需要额外自定义 URL，降低即插即用程度。
- 拒绝：ADR-0009 已明确唯一入口为 `/v1/realtime`，当前低用户量允许做 pre-GA contract reset。

## Consequences

- Realtime 客户端必须迁移到当前 OpenAI 事件和嵌套字段；不提供旧 alias。
- `compatibility`、`application`、ASR port、capability snapshot、契约文档和测试需要同步变更。
- 外部 LLM 配置增加网络、凭据、超时和隐私边界；未配置时只能声明 transcription/TTS 能力。
- Realtime 重构必须继续通过音色绑定、voice revision、clone/VoiceDesign 档位门禁和
  render receipt 回归；音色资产和管理 API 不因协议重构迁移或删除。
- 只有官方 SDK harness、fake backend 集成测试和契约检查全部通过后，才可以在文档中声明
  OpenAI SDK Realtime compatibility。
- 未来如果要支持 tools、semantic VAD 或其他 modality，必须新增能力矩阵和对应 SDK 黑盒用例，
  不能仅通过放宽 schema 验证宣称支持。
