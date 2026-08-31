---
title: "SpeechRail 当前边界与剩余风险"
status: active
date: 2026-08-31
---

# SpeechRail 当前边界与剩余风险

这里记录已经作出的工程选择和仍需真实运行验证的事项，避免未来代理把推断当成事实。

## 已决定

1. 产品名、仓库名和服务名统一为 `SpeechRail` / `speechrail`；中文名为“声轨”。
2. 公共文件接口使用 OpenAI-compatible `/v1/audio/transcriptions`。
3. 新实时接口使用 `/v1/realtime`；旧 `voice-realtime` 使用 `/asr` 兼容层。
4. 默认 loopback；LAN 必须 Bearer key；不允许把长期 key 放在 WS URL。
5. 模型 ID 使用 `speechrail/qwen3-asr-1.7b`，兼容 alias 不等于真实模型身份。
6. 模型/音频不进入 Git，不在请求期间下载或访问远程 URL。
7. 会议、Sortformer、PostgreSQL、AudioHub、TTS、LLM 和 UI 留在 `voice-realtime`。
8. QwenPaw/Hermes 先走 batch REST，`voice-realtime` 先走 realtime/legacy WS。
9. 首发一台机器一个 supervisor，一个推理槽位；不通过 ASGI worker 复制模型。

## 必须实测后才能宣称

- Qwen3-ASR snapshot 在当前本机环境的精确加载耗时、峰值内存和 RTF。
- Qwen3 native worker 是否适合所有目标文件长度和语言组合。
- WLK compatibility 与当前 `voice-realtime` 的每个可观察事件是否完全 parity。
- `/v1/realtime` 事件与 Qwen3 windowed streaming 的 delta 粒度和延迟。
- 两个 runtime 同时加载时的内存和实时余量。
- Hermes 当前安装环境是否完整读取 `STT_OPENAI_BASE_URL`，以及是否需要重启进程。
- QwenPaw 当前发行版在 `8201` 和 canonical model ID 下的 UI 保存/重载行为。
- LAN 模式的 CORS、TLS/反向代理和多客户端限流策略。

## 有意不做

- 不把 LM Studio 作为 ASR server 的强依赖。
- 不在 SpeechRail 内加入通用摘要、翻译、TTS、会议存储或 Agent orchestration。
- 不在同一个模型请求中偷偷切换 Qwen3、Whisper 或 SenseVoice。
- 不为兼容旧客户端而把 Qwen3 伪装成可验证的 Whisper 模型。
- 不在没有 benchmark 证据时宣称质量、延迟或并发提升。

## 发布前决策门

只有通过以下门禁，SpeechRail 才能取代 `8001` 的旧 WLK：

- REST OpenAPI 契约测试全绿。
- Realtime 和 legacy WS 契约测试全绿。
- 真实 Qwen3 MPS smoke 全绿。
- QwenPaw、Hermes、`voice-realtime` 三方集成全绿。
- 回滚演练通过。
- 运行清单和安全日志检查通过。
