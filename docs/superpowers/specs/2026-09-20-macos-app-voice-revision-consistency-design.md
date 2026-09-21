---
title: "macOS App 音色 revision 一致性与文档一致性收敛"
status: approved
date: 2026-09-20
related:
  - docs/superpowers/specs/2026-09-20-stateless-speech-plane-caller-orchestration-design.md
---

# macOS App 音色 revision 一致性与文档一致性收敛

## 1. 设计结论

SpeechRail 已经提供 `effective_capabilities_v1`、`voice_revision`、TTS
`catalog_revision`、REST revision pin 和 Realtime `expected_voice_revision`。当前 macOS
App 只把 TTS model revision 接入了 Realtime，REST creator 与 Realtime 的 voice revision
没有贯穿到最终请求，导致同一份能力快照不能稳定约束发声请求。

本次修复由调用方完成 pin：App 在发起 TTS 时从当前有效能力快照读取 voice/model revision，
通过既有 `SpeechRailRequestOptions` 或 `SpeechRailTTSCreate` 传递给 SpeechRail。服务端仍保持
无状态，不新增隐藏会话状态、不改 `/v1/realtime` 版本、不新增 MCP 状态。

当能力快照没有可用 revision（例如 legacy voice、不可用音色或尚未完成发现）时，App 保持
兼容的无 pin 请求；不得从 voice 名称、模型名或本地时间推断 revision。

## 2. 目标与非目标

### 目标

1. Realtime Assistant 的每一次 `speechrail.tts.create` 都携带当前选定 voice 的有效 revision（若可用）。
2. Realtime 切换音色时同时更新 voice 与 revision，下一句使用同一绑定。
3. REST creator 的试听和作品生成都通过 `SpeechRailRequestOptions` 传递 voice/model revision。
4. 现有 fake client、legacy voice 和没有 capability snapshot 的场景继续可编译、可运行。
5. active 文档统一描述当前 revision/CAS/rollback/revoke 能力、历史证据和未完成的声学验收边界。

### 非目标

- 不修改 Python 服务端 revision 语义、MCP 无状态边界或公共路由。
- 不把 revision 缓存到跨会话持久化数据，不保存 PCM、embedding 或实名身份。
- 不把 `available=true` 解释为 warm、质量通过或请求必然成功。
- 不运行 UI 自动化、真实模型/音频 smoke、benchmark 或服务安装启停。
- 不覆盖当前工作树中与本任务无关的未提交改动。

## 3. 责任边界与数据流

```text
effective_capabilities_v1
        │
        ├── AppModel / AssistantSession
        │      ├── REST: SpeechRailRequestOptions
        │      │          ├── SpeechRail-Expected-Voice-Revision
        │      │          └── SpeechRail-Expected-Model-Revision
        │      └── RealtimeASRClient
        │                 └── speechrail.tts.create.expected_voice_revision
        │
        └── 无 revision 时：显式保持 nil，走服务端普通协商
```

`effective_capabilities_v1` 是同一代发现的来源。voice 通过 `id` 或 `aliases` 匹配；只有
voice 可用、对应 operation 支持且 `voice_revision` 非空时才 pin。model revision 取 TTS
model 的 `catalog_revision`，不可用时同样保持 nil。

## 4. Native 实现设计

### 4.1 Realtime

- `RealtimeASRClient` 增加可变的 `expectedVoiceRevision`，初始化时接收首个 voice 的 revision。
- `sendTTSCreate` 将它传给已有的 `SpeechRailTTSCreate`。
- `updateVoice` 接收 voice 与可选 revision，并在同一个异步操作中更新两者；revision 缺失时
  清空旧值，不能把旧 voice 的 revision 带到新 voice。
- `AssistantSession` 增加 `realtimeVoiceRevision` provider，并在初始建连和换音色时从 AppModel
  的当前 snapshot 查询。
- revision provider 只返回 `available=true` 且 `operations["realtime_speech"]` 存在的 voice
  revision；未命中返回 nil。

### 4.2 REST creator

- 将 `SpeechRailCreatorClient.createSpeech` 收敛为唯一的带 `SpeechRailRequestOptions` 的标准
  requirement；删除旧的无 options requirement、`SpeechRailRevisionAwareCreatorClient` 和
  动态类型转换 fallback。当前 App 内部调用方必须显式传入 options；没有 revision pin 时传入
  空的 `SpeechRailRequestOptions`。
- `ServiceAPIClient.createSpeech` 将 options 原样传给已有的 `synthesize`；不复制 header 拼装逻辑。
- `AppModel` 的试听和作品生成从选中的 `CreatorVoice.revision` 与有效 TTS model catalog
  revision 构造 options。
- fake/unavailable creator 实现显式接受 options 但不消费它；不改变测试替身的业务行为。

### 4.3 并发与生命周期

`AssistantSession` 与 AppModel 的 provider 继续使用现有 `@MainActor` 边界。不得新增
`Task.detached`、全局可变 revision、锁外共享状态或跨会话缓存。Realtime 客户端只在当前连接
内持有 revision；关闭连接后随客户端释放。

## 5. 测试设计

先添加失败测试，再实现：

- Realtime contract test：`SpeechRailTTSCreate` 编码 `expected_voice_revision`，并覆盖
  `RealtimeASRClient` 初始 voice/revision 与换音色清空旧 revision 的行为（不接管 UI）。
- REST request test：`createSpeech(options:)` 把 voice/model revision 变成正确的
  `SpeechRail-*` headers。
- App-level pure test：snapshot 中 voice 通过 id/alias 命中时返回 revision；不可用、operation
  缺失、voice 不存在或 revision 缺失时返回 nil。
- 现有 Python MCP/contract 测试只在相关代码改变或验证需要时运行，不扩展为完整 gate。

验证范围限于纯 Swift 测试、非 UI App build、相关 Python 静态检查和文档/link/diff 检查。

## 6. 文档一致性收敛

同步以下 active 文档，使它们区分“当前契约”“历史运行证据”“尚未完成的质量/迁移工作”：

- Realtime/API/App 开发文档：说明 voice pin 与 model pin 的关系、fallback 边界和 App 行为。
- 音色架构文档：将 revision history、CAS update、rollback、revoke 标为已实现；将旧资产迁移、
  声学身份验收和跨模型兼容性保留为明确的 pending 工作。
- 运维验收文档：将旧 runtime 版本快照标为历史证据，不冒充当前运行态。
- 架构目录与音色管理设计：修复编号、鉴权措辞和 legacy/namespaced API 的权威关系。
- 集成/根入口文档：保持简洁，仅补一致性文档入口，不复制实现细节。

历史 implementation ledger 不重写成当前承诺；仅在必要处补当前 head 的 reconciliation 说明。

## 7. 回退与风险

- 代码回退只需恢复 App 的可选 options/revision 传递，不触及服务端数据、模型或运行态配置。
- revision mismatch 由服务端稳定错误返回；App 不自动用旧 revision 重试。
- 最大风险是 App snapshot 与服务端在请求间发生变化。pin 的作用是让这种变化显式失败，不能
  消除服务端更新本身。
- 本次不承诺真实音色质量、跨长时会话稳定性或 acoustic identity proof；这些结论需要独立基准/验收。

## 8. 验收标准

1. Realtime TTS 请求在可用 snapshot 下包含 voice revision，换音色不会沿用旧 revision。
2. REST creator 的试听与作品生成携带与所选 voice 同代的可用 pin。
3. legacy/no-snapshot 场景仍能走 nil fallback，且无编译回归。
4. 相关纯 Swift 测试与非 UI build 通过；UI automation 明确未运行。
5. active 文档不再把已实现 revision 管理描述成未来能力，也不把历史运行快照描述成当前状态。
