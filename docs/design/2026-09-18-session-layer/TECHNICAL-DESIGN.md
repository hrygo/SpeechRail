---
title: "SpeechRail 会话层技术方案（终态）· 语音助手 / 会议助手 / 实时字幕"
status: active
audience: "SpeechRail macOS App 实现者、服务维护者、设计评审"
version: "3.0.0"
date: 2026-09-20
---

# 会话层技术方案（终态）

> **当前公共契约覆盖（2026-09-20）**：本文继续约束 Native 的会话、采集、播放、记录和应用所有权，
> 但所有 Realtime wire、TTS 入口、取消语义和责任边界以
> [无状态 Speech Plane 与调用方编排设计](../../superpowers/specs/2026-09-20-stateless-speech-plane-caller-orchestration-design.md)
> 与 [`contracts/realtime-openai.md`](../../../contracts/realtime-openai.md) 为准。本文旧示例中的
> `session.update`、`conversation.item.create`、`response.create/cancel`、`response.audio.*`、
> 服务端自动 barge-in 和“普通 SDK 无需迁移”均为历史设计，不得实现或恢复；当前 Native 在本地
> 持有 LLM、history、memory、tool calling、播放队列和 barge-in 决策。

## 0. 发布说明

**这一版是什么。** 它是语音助手、会议助手、实时字幕三条能力的**终态技术方案**：描述三者同时在位时系
统由哪些部件组成、每个部件归谁、数据长什么样、失败时退到哪、按什么判据验收。读它是为了**直接开工**，
不是读一份待办清单。

**它不是什么。** 它不是产品口径与界面规格（在
[`../2026-09-17-live-sessions/SESSIONS-SPEC.md`](../2026-09-17-live-sessions/SESSIONS-SPEC.md)），
不是画板清单（[`../2026-09-17-session-closures/`](../2026-09-17-session-closures/)），
也不重复服务既有契约（`contracts/`）。它只回答一个此前没有文档回答的问题：**哪些归 macOS 原生、
哪些归 Python、边界处的规矩是什么**。

**版本关系。** v1.0.0 是分工初稿（proposed）；v1.1.0 收入用户 2026-09-18 的「按功能启用、功能离开释放」；
**v2.0.0（active）是通读全部设计包、并按本地与外部证据复核后的终态**。与 v1.1.0 的实质差异见
§13.3。**v2.1.0 记录 `T1`–`T5` 五条技术裁决（用户 2026-09-18「全面采纳」）**，其中 `T5` 的三条 schema
加法已并入规格 §15.7 的 R2。**v2.2.0 增加 `T6` 存储分区与重装契约**（§6.6）。**v2.6.0 补 §5.5.1
「系统上下文分层」（语音契约 → 人设/记忆 → 历史），并补 2026-09-19 的语音场景本机实测（§13.2）。**
**v2.7.0 将助手默认音频链路落成 `AudioEngineSession`：采集与 TTS 共用一个 engine，对讲模式
在 input/output I/O node 同时启用 voice processing，并实现设备配置变化后的重建（2026-09-19）。**
**本版无待裁决项。**

**与相邻设计包的关系。** 产品口径以 SESSIONS-SPEC 为准。本文对它**只做两处补充**：已写入的 §5.3.1
（设备按功能启用，2026-09-18 用户裁决）与已并入的 §15.7（R2，见 §6.3）。其余地方只引用、不重叠。

**读法。** 改界面读 SESSIONS-SPEC；改采集与设备看 §3；改服务契约看 §4；改数据看 §6；开工照 §10；
验收照 §11；没把握的地方先查 §12。

## 1. 终态总览

```
┌─ macOS 原生（App 进程 + 一个 XPC 采集服务）───────────────────────────────┐
│  CaptureHelper（XPC，按需启动 / 空闲退出）                                  │
│      └ process tap（限定输出设备 + 指定 App）→ 16k mono s16le + host time   │
│  AudioEngineSession（只在会话期间存在的 AVAudioEngine）                     │
│      ├ 麦克风输入（voice processing 可开 → 系统回声消除）                    │
│      ├ TTS 播放（同一 engine：AEC 的 far-end 参考）                         │
│      └ 混音 / 归一 → 线上唯一格式：16 kHz mono PCM16                        │
│  CaptionBandWindowController(NSPanel：非激活 / 全空间 / 全屏共存)           │
│  GlobalHotKey(Carbon) · MenuBarExtra · 通知 · Spotlight / AppIntents        │
└──────────────┬──────────────────────────────────────────────────────────────┘
               │ PCM 上行 · 事件下行（WebSocket，loopback）
┌──────────────▼──── Python 服务（SpeechRail）───────────────────────────────┐
│  /v1/realtime：流式 ASR · TTS 子集 · barge-in · 分人扩展 · 语音准入          │
│  /v1/models /readyz /metrics /v1/audio/* /v1/voices                         │
│  模型 · worker · 队列 · ResourceGovernor · worker lease（全部既有）          │
│  **不承载**：LLM、会议持久化、UI、用户资产（红线，§4.2）                     │
└──────────────┬──────────────────────────────────────────────────────────────┘
┌──────────────▼──── 客户端会话层（App 进程内的模块，不是新进程）────────────┐
│  SessionCoordinator（所有权与状态机）   RealtimeASRClient（WS）             │
│  AudioSourceCoordinator（来源多选与自动合流 + 设备获取/释放）               │
│  AssistantSession（Responses 编排）  MinutesGenerator（后台 + 租约）         │
│  InnerOSSession  MemoryStore  SpeakerLabeling  Exporter                     │
│  SessionStore（系统 SQLite3 + WAL）  KeychainStore（LLM 密钥）              │
└─────────────────────────────────────────────────────────────────────────────┘
```

三条能力的终态：

| 能力 | 终态 | 唯一的外部前提 |
|---|---|---|
| 实时字幕 | ⌘⇧L 唤起一块非激活的半透明字幕带，贴在任何画面上；定稿的行进记录库，可回看、星标、导出 SRT | 服务就绪 + 麦克风授权（**不需要大模型**） |
| 会议助手 | 按来源（麦克风 / 本机音频按 App / 混音）把一段多人谈话变成带说话人标签的转录与多版本纪要（可选分人） | 服务就绪 + 所选来源的授权；纪要另需大模型 |
| 语音助手 | 一问一答（外放，半双工）或实时对讲（耳机，可打断）与本机大模型对话；人设会话内锁定、音色随时可换、记忆跨轮次 | 服务就绪 + 麦克风授权 + **一台兼容 OpenAI 且支持 Responses API 的服务** |

## 2. 归属规则（终态判据）

四条判据按顺序问，先命中先归。任何新能力先过这四问，再谈实现。

| 顺序 | 判据 | 归属 | 一句话理由 |
|---|---|---|---|
| **R1** | 需要**系统身份或实时约束**吗？（TCC、音频设备、Core Audio 实时回调、窗口层级、全局输入、系统通知） | **macOS 原生（Swift）** | 只有原生进程能持有这些身份；搬进 Python 要么拿不到权限，要么把实时线程与崩溃面带进业务运行时（Sona ADR-010 的既有代价） |
| **R2** | 跑**模型**或决定**语音会话事实**吗？（ASR、TTS、分人、endpointing、会话水位、资源准入） | **Python 服务** | 现有职责与既有契约；多客户端共享一个事实源 |
| **R3** | 是**用户资产**或**外部大模型编排**吗？（记录、纪要、记忆、导出、LLM prompt） | **客户端会话层（App）** | 不是语音引擎的能力，是产品行为；`docs/architecture/product-scope.md` §3 红线明写禁止把会议持久化、UI 与 LLM 编排放进服务 |
| **R4** | 占用**设备或系统资源**吗？ | **按功能启用、功能离开即释放** | 用户 2026-09-18 裁决；与 Apple HIG 隐私条款同向——「只申请功能真正需要的数据，**不要在用户表现出兴趣之前就申请**」 |

三条推论：

1. **三条能力不是"服务新增一个模块"，而是 App 长出的一层**：服务守住 R2，只在两处边界补契约（§4.3）。
2. **PCM 的路径由 R1 与 R4 共同决定**：设备 → 原生采集/混音/归一 → App 的 WS 客户端 → 服务；
   全程**不落盘、不进 Python、不常驻**。
3. **界面在场 ≠ 设备在场**：浮层、菜单栏、热键都可以在，唯一决定占用的是会话（`SessionCoordinator`）。

### 2.1 逐项分工总表（终态）

| 组件 / 能力 | 归属 | 终态落点 | 依据 |
|---|---|---|---|
| 麦克风采集（会话） | 原生 | `AudioEngineSession` 的输入节点（当前实现位于 `AssistantAudioSession.swift`） | 与播放同引擎才拿得到系统 AEC（§3.3） |
| 麦克风采集（音色克隆） | 原生 | 既有 `VoiceRecordingController`（`AVAudioRecorder`，**刻意不启用** AEC/AGC） | 克隆要的是用户本来的音色；两条通道目的不同（§3.1） |
| 本机音频采集 | 原生 | `CaptureHelper`（XPC）的 process tap | 设备绑定 + TCC 身份 + 崩溃隔离（§3.2） |
| 混音与格式归一 | 原生 | `AudioEngineSession`（host time 对齐） | 服务只收 16k/24k PCM16；统一 16k 以免换设备改格式 |
| 回声消除 | 原生（系统能力） | `voice processing` | 系统 AEC 只在原生栈；不手写回声抑制（§3.3） |
| TTS 播放 / 打断 / 输出设备 | 原生 | `AudioEngineSession` 的播放节点 | 服务不碰扬声器 |
| ASR / TTS / 分人 / VAD / 准入 | Python | 现有 `/v1/realtime` | R2 |
| 会话编排（回合、epoch、水位、断点、EOF 屏障） | 客户端会话层 | `SessionCoordinator` + `RealtimeASRClient` | R3；realtime session 不可恢复，编排属调用方 |
| 对话 / 纪要 / 内心 OS 的 LLM 调用 | 客户端会话层 | `AssistantSession` / `MinutesGenerator` / `InnerOSSession` | R3 + 红线 |
| 记录、纪要、记忆、标注（SQLite） | 客户端会话层 | `SessionStore` | 用户裁决 D8（§6） |
| 说话人显示名 | 客户端会话层 | `SpeakerLabeling` | 服务只出 session-scoped 匿名 label |
| 导出 | 客户端会话层 | `Exporter` + 系统保存面板 | 产品行为 |
| 字幕带浮层 | 原生 | `CaptionBandWindowController`（`NSPanel`） | 需要非激活 + 全空间 + 全屏共存（§3.7） |
| 全局热键 | 原生 | `GlobalHotKey`（Carbon `RegisterEventHotKey`） | 不需要无障碍/输入监控授权 |
| 菜单栏 / 通知 / Spotlight / AppIntents | 原生 | 既有 `MenuBarExtra` + 新增动作 | 系统身份 |
| 权限申请与受阻话术 | 原生 | `AudioSourceCoordinator` + 三页受阻态 | 授权属于 App 身份 |
| 备份 / 迁移 / 移除记录 | 客户端会话层 | `SessionStore`（`VACUUM INTO`、`user_version`） | §6 |

## 3. macOS 原生层终态

### 3.1 两条麦克风通道，故意不合并

| | 音色克隆（既有） | 会话（本方案新增） |
|---|---|---|
| 设备与 API | `AVAudioRecorder`，48 kHz 单声道，写临时文件后立刻删除 | `AVAudioEngine` 输入节点，连续流，只进内存 |
| 处理链 | **刻意关闭** AEC / 降噪 / AGC（要的是用户本来的音色） | 对讲模式下**必须开启** voice processing（要的是回声消除） |
| 生命周期 | 按下录制 → 停止 | 会话获取 → 会话释放（R4） |
| 不合并的理由 | 两者对"干净"的定义相反：克隆要"未经处理的你的声音"，会话要"只剩你在说话"。共用一条链必然牺牲其中一边 | |

现有实现里有一条必须继承的教训：`AVAudioRecorder` 内部是 AudioQueue，`record()` 是同步 CoreAudio 调用，
本机首次冷启动实测最坏阻塞 **36.3 秒**（`docs/developers/macos-app-audio-capture.md` §2）。会话侧的
`engine.start()` 与 tap 建立同理——**都在专用线程上等，主线程只收状态**。

### 3.2 系统音频：`CaptureHelper`（XPC 采集服务）

**它做什么**：按目标输出设备建 `CATapDescription` → `AudioHardwareCreateProcessTap` → 挂进私有
aggregate device → 实时回调只写预分配 SPSC ring → 工作线程做格式归一 → 交给 App。

**它不做什么**：不做会话决策、不解析文本、不落盘、不联网、不持有播放。

| 决策 | 终态选择 | 理由与来源 |
|---|---|---|
| 采集路径 | Core Audio process tap（macOS 14.2+） | Apple 官方示例文章明确 tap 是作为 HAL aggregate device 的输入使用，可按进程/进程组指定范围（§13.1 来源 1） |
| 按 App 抓 | `CATapDescription.bundleIDs`（macOS 26.0+） | 本机 SDK 实测标注；与项目 macOS 26 基线一致 |
| 来源 App 重开 | `processRestoreEnabled`（macOS 26.0+） | 同上；语义为"来源 App 重启后自动接回"，**真机行为未验证**（§12） |
| 不改变听感 | `muteBehavior` 保持默认 `CATapUnmuted` | SDK 默认值；抓取不应改变用户听音 |
| 载体 | **App 内 XPC 服务**（`T1` 已裁决，2026-09-18） | Apple 官方指南：加 XPC Service target、服务名用其 bundle identifier，**由 launchd 在客户端连接时启动**该进程——天然是按需启动、空闲可退出的形态，同时保留崩溃隔离（§13.1 来源 2） |
| 回退路径 | `ScreenCaptureKit`（`capturesAudio` macOS 13+ / `captureMicrophone` 15+） | 仅当设备限定 tap 在某些端点上不可靠时才启用；**权限范围更大，不作为默认** |
| 不做 | 不装虚拟声卡、不改系统输出路由、不抓整机 | 用户 2026-09-17 裁决；Sona ADR-010 同结论 |

**权限**：Info.plist 声明 `NSAudioCaptureUsageDescription`；Apple 说明"第一次从带 tap 的 aggregate device
开始录制时，系统提示授予系统录音权限"。**按 R4，只在用户第一次选「本机音频」来源时才触发**——只用字幕的
用户永远看不到这个弹窗。

### 3.3 音频引擎与回声消除

`AudioEngineSession` 是会话期间唯一的音频引擎，输入与输出**在同一个 engine 上**：

```
inputNode ──(voice processing 可选)──┐
                                     ├─ 混音/归一 → RealtimeASRClient（16k PCM16）
playerNode( TTS 24k PCM ) ───────────┘
```

**为什么必须同引擎**：Apple WWDC 2019 session 510 的原话是——voice processing mode「用于 VoIP 类应用」、
「在 manual rendering 模式下不支持」、「设在输入或输出任一节点上」，而**「要做回声消除，输入与输出节点
会同时处于 voice processing 模式」**。把麦克风交给另一个进程（或 Python）就再也拿不到系统 AEC，只能回去
写文本级回声抑制——那正是 Sona 走过的路（`interaction/echo.py` 的拼音相似度 + 能量门 + 尾巴宽限），
它的代价是**可能把用户的话当回声丢掉**，我们不复制这条路。

| 模式 | 采集门 | 引擎配置 | 打断 |
|---|---|---|---|
| 一问一答（外放，半双工） | 播放期间**闭麦**（本地门闩） | voice processing 可不开 | 闭麦天然挡住自激；不需要 barge-in |
| 实时对讲（耳机，全双工） | 全程开麦 | **voice processing 开启** | 服务端 `speech_started` → 原子取消 TTS，随后 250 ms 冷却（契约默认值） |

第二道防线只保留一条**极窄**规则：正在播放、且这一句与刚播出的文本高度重合（同一句话），才丢弃；
每次丢弃必须留下可查记录，避免静默吃掉用户的话。**不做**拼音相似度与能量自适应门那套。

### 3.4 格式、混音与时钟

- **线上格式唯一：16 kHz 单声道 PCM16**。契约允许 16k/24k，且"首个 PCM 之后不得改格式"；把归一放在
  原生层并固定 16k，则**换设备、切对讲模式都不会改变线上格式**，不必因为格式而重开 ASR 会话。
- **混音在 host time 域完成**：两路来源（麦克风 near-end、本机音频 far-end）各自带 `host time` 与
  `discontinuity` 标记；缺口补静音并标记，而不是把两路硬拼。
- 设备变更监听 `AVAudioEngineConfigurationChangeNotification`（SDK 已确认存在）：引擎配置变化后按
  §3.5 的规则**重建**，不静默续用旧图。

### 3.5 设备与权限生命周期（R4 的落地）

**占用从「会话提交」开始，到「会话离开」结束。** 五个动作全在 `SessionCoordinator` 上：

| 时点 | 动作 | 失败处置 |
|---|---|---|
| 用户点开始 | 申请尚未授予的权限 → 获取麦克风 / 建 tap 与 aggregate device → `engine.start()` | **不提交会话、不建记录**；受阻行 + 出口（系统设置 / 换来源 / 结束） |
| 提交前 | 确认真的在出样本（电平非恒定、无回调超时） | 同上：宁可没开始，也不要一条空记录 |
| 会话中 | 持有；换设备/换模式只**重建**，不额外新增占用 | 重建失败 → 中断（§5.5） |
| 结束（`processing` 之前） | 停引擎、销毁 tap 与 aggregate device、关闭 voice processing、`CaptureHelper` 退出 | 失败要记诊断；下次获取前先清理残留 |
| 空闲 | 不打开麦克风、不建 tap、不跑引擎 | — |

权限矩阵：

| 权限 | 何时申请 | 键 / 机制 | 备注 |
|---|---|---|---|
| 麦克风 | 第一次开始任一会话 | `NSMicrophoneUsageDescription`（现有文案是音色克隆专用，**必须改**；新文案以规格 §16.8 为准） | 今天写在三个 build configuration 里 |
| 系统录音 | 第一次选「本机音频」来源 | `NSAudioCaptureUsageDescription`（文案见规格 §16.8） | Apple 明确第一次录制时提示 |
| 屏幕与系统录音（回退路径） | 仅当启用 ScreenCaptureKit 回退时 | 系统"屏幕与系统录音"授权 | 默认不启用 |
| 无障碍 / 输入监控 | **永不申请** | 全局热键走 Carbon `RegisterEventHotKey` | 知名实践：不引发权限弹窗 |

打包侧必须一起处理的三件事（来自 `macos-app-audio-capture.md` 的既有结论）：
① `Entitlements/SpeechRailApp.entitlements` 今天是空 dict，**Distribution 开 Hardened Runtime 后**内置麦克风
采集需要 `com.apple.security.device.audio-input`；② ad hoc 签名 + 每次重建会重弹 TCC，排障时不要当成故障；
③ 系统「麦克风模式」（语音突显/宽谱）在 App 之外处理输入，会话音质结论要在同一模式下比较。

### 3.6 播放与打断

- TTS 音频（24 kHz PCM）经 `playerNode` 播放；**同一 engine**，因此对讲模式的 AEC 有 far-end 参考。
- 打断：服务端检测到人声即原子取消当前 TTS 响应（契约「全双工打断」），App 侧丢弃未播缓冲、
  把这一句标 `interrupted`、保留已生成正文并允许重播——**被打断不是错误**。
- 打字提问**不朗读**回复；每条回复仍可点重播。

### 3.7 窗口、热键与系统集成

| 件 | 终态 | 依据 |
|---|---|---|
| 字幕带 | `NSPanel`：`.nonactivatingPanel`（不激活宿主 App，仅对 panel 有效）+ `.canJoinAllSpaces` + `.fullScreenAuxiliary` + `NSFloatingWindowLevel`；材质用系统浮动层（`NSVisualEffectMaterialHUDWindow`，或 macOS 26 的 `glassEffect` / `GlassEffectContainer`） | 本机 SDK 实测以上 API 均存在 |
| 默认位置 | 主屏底部居中，距底 96pt；宽度可拖 420–1200；位置**每屏一套**（`@AppStorage`） | 产品规格 §6.3.1 |
| 三档字号 | 紧凑 17 / 标准 20 / 大字 26 | 稿上两档文本样式 + 既有 `Title / Page` 相邻档 |
| 全局热键 | `⌘⇧L` 字幕 · `⌘⇧N` 会议 · `⌘⇧.` 结束 · `⌘⇧I` 内心 OS | Carbon；不需要额外授权 |
| 菜单栏 | 既有 `MenuBarExtra` 增量加「会话」组与状态行 | 既有实现 |
| 通知 | **只在「中断需要人决定」这一件事上发**，默认关、前台不发、正文不带转录原文 | 产品口径见规格 §6.8；会话结束与纪要就绪留在 App 内说 |
| Spotlight / AppIntents | 只暴露无参动作（开始会议 / 开始字幕） | 会话状态不索引 |

### 3.8 无障碍与文案

四条必须实现（规格 §8 已定，这里给工程口径）：① 字幕带的礼貌播报用**合并播报**而不是每字播报
（按行/按句聚合，避免刷屏）；② 人设的只读用 `.accessibilityValue` 说明"本轮已定，只读"；
③ "被打断"用非错误的播报语义；④ 内心 OS 区域带"只有你看得到"的描述。

文案规矩沿用 `SESSIONS-SPEC §16.8`：**界面写现象，机制写规格与注释**。三个能力的受阻永远是"同一条结论条
+ 一个出口"，形状不变、措辞随能力变。

## 4. Python 服务层终态

### 4.1 承载（全部既有，不改语义）

| 能力 | 契约入口 | 本方案用到的事实 |
|---|---|---|
| 流式转写 | `input_audio_buffer.append` / `commit` · `…completed` / `failed` · `…delta` / `…segment` | PCM16、16k 或 24k、首个 PCM 后不得改格式；`server_vad` 可配 `threshold` / `prefix_padding_ms` / `silence_duration_ms` |
| TTS | 调用方生成文本后发送 `speechrail.tts.create` · `response.output_audio.delta`/`done` | 24 kHz PCM16；voice/revision 在 render request 上校验，失败返回稳定错误，不隐式换音色 |
| 打断 | `input_audio_buffer.speech_started` 事实 → 调用方显式 `speechrail.tts.cancel` | SpeechRail 不拥有播放队列，也不自动取消 TTS |
| 分人 | `transcription_session.update.session.speechrail.diarization.enabled`（首个 PCM 前 opt-in）→ `…updated` / `…status` / `…finish` / `…done` | 归属修订事件带 `stable_through_sample`；`done` 带 `through_sample`、`status: complete \| degraded`、`last_update_sequence` |
| 准入 | 最多 `SPEECHRAIL_REALTIME_MAX_SESSIONS`（源码默认 3，区间 1–8）个 backend 会话；超限 `backend_busy`，session 保持可用 | 契约「连接与认证」 |
| 观测 | `/metrics` 已有 `speechrail_realtime_active_sessions`、`speechrail_realtime_sessions_total`、`speechrail_realtime_turn_commits_total`、`speechrail_realtime_bargein_events_total`、`speechrail_governor_queue_rejections_total`、`speechrail_worker_evictions_total` | 本机源码实测（`observability/rollup.py`） |

### 4.2 明确不做（红线复述，防止下一轮评审再提）

LLM 推理或代理端点 · 会议/字幕/对话的持久化 · UI · 声纹库与跨会话身份 · 音频落盘 · 用户资产 API。
依据：`docs/architecture/product-scope.md` §3 与 `contracts/realtime-openai.md`（realtime 只承载 ASR/TTS 子集）。

### 4.3 本方案要求服务侧补的两条契约（都是加法）

| # | 条款 | 形态 | 不做的后果 |
|---|---|---|---|
| **S1** | **长会话重连语义**：把"session 不可透明恢复"扩写成可操作的条款——新连接 = 新 source epoch；时间按样本重算；上一次 `through_sample` 是水位；标签只在同一 session 内稳定 | 文档 + 事件字段说明（`contracts/realtime-openai.md`） | 每个客户端各写一套 epoch 换算，出现"接得上/接不上"的三种解释 |
| **S2** | **跨客户端运行态可见性**（`T2` 已裁决：**v1 不做**）：让用户看得出"麦克风现在是 Sona 在用，不是这个 App" | 先复用 `/metrics` 既有指标；确有困惑再考虑 additive 只读端点（不含用户内容） | 机器上两个客户端抢麦时，用户只能看到 `backend_busy` |

**不新增**任何涉及用户内容的接口。

## 5. 客户端会话层终态

### 5.1 模块与依赖

```
SessionCoordinator ──┬── SessionStore（SQLite）        ── 一切持久化的唯一入口
                     ├── AudioSourceCoordinator ──┬── MicCapture（AVAudioEngine 输入）
                     │                            ├── CaptureHelperClient（XPC → 系统音频）
                     │                            └── SpeechPlayer（AVAudioEngine 输出）
                     ├── RealtimeASRClient（WS → /v1/realtime）
                     └── 三条业务：
                          AssistantSession · MeetingSession · CaptionSession
                          └── AssistantSession ── LLMProvider（Responses API）
                                MinutesGenerator / InnerOSSession / MemoryStore 共用它
```

依赖是单向的：**业务层不直接碰设备，也不直接碰 SQLite**；设备经 `AudioSourceCoordinator`，持久化经
`SessionStore`。这三条限制就是 R1/R3/R4 在代码里的形状。

### 5.2 `SessionCoordinator`：所有权、状态机、账本

```
idle → preparing → recording → processing → archived
                 ↘ interrupted ↗（继续 = 新 epoch）
```

| 状态 | 进入条件 | 库里 | 设备 |
|---|---|---|---|
| `preparing` | 服务 `/readyz` 与 `/v1/models` 已读；**设备已获取**；WS 已建但未发 PCM | 无行 | 已获取 |
| `recording` | 首个 PCM 已发送 | `state='recording'` | 持有 |
| `processing` | 收声停止 + EOF 屏障（分人 `finish` → `done`） | `state='processing'` | **已释放** |
| `archived` | 转录封存完成 | `state='archived'`、`ended_at`、`end_reason` | 无 |
| `interrupted` | 四类中断之一（§5.6） | `session_interruption` 一行 | 已释放 |

**账本规则**（每条都由一条既有事实推出）：

1. 一个 WS 连接 = 一个 **source epoch**；epoch 内以"已发送样本数"为唯一时间轴，转写时间戳换算成
   相对 `session.started_at` 的秒（`line.t_start/t_end`）。
2. 幂等靠会话内单调的 `line.ordinal` 与 epoch 内序号，**不靠墙钟**；重复的 `completed` 不产生第二行。
3. **断线不重放 PCM**：丢的音频就是真的没录上，写 `session_interruption`，不做"回源补全"。
   （这是与 Sona 的 `revision gap → resync_required` 机制的分水岭：它的前提是服务端持有事实源，
   我们的记录由客户端写、PCM 实时不回放，所以那套对账机器在这里没有对象。）
4. `backend_busy` 是准入结果而不是异常：不显示原始错误码（进 Inspector），走会话占用守卫。
5. **第一个 PCM 之后不得改格式** ⇒ 原生层把线上格式**固定为 16 kHz mono PCM16**，换设备只重建引擎、
   不重开会话（新行标 `device_switch = 1`，缺口补静音）；真要让格式变（例如提到 24 kHz）才是新会话。
   这条正是 §3.4 "把格式归一放在原生层"的目的——把契约里那条硬约束变成**结构上碰不到**的情况。

### 5.3 `RealtimeASRClient`

- `URLSessionWebSocketTask`；只走 loopback；认证用现有配置的 Bearer（若已配置 key）。
- 会话配置一次成型：`input_audio_format=pcm16`、`16000`、`turn_detection=server_vad`，
  静音窗口按模式取值（**字幕 400 ms / 会议 900 ms**，与既有服务侧策略一致）；分人按开关在同一次
   `transcription_session.update` 里 opt-in（**首个 PCM 之前**）。
- 事件处理：partial 只进内存（供字幕带与"正在识别"行）；`completed` 才落库；
  分人的 `updated` 只改归属列（`speaker_label`），**从不改写正文**。
- 取消与关闭：调用方用 `speechrail.tts.cancel` 打断 TTS；结束走 `speechrail.diarization.finish` 等 `done`（EOF 屏障）。
- 重连：新 epoch；不重放；写中断区间（§5.6）。

### 5.4 `AudioSourceCoordinator`

| 来源 | 需要什么 | 失败时 |
|---|---|---|
| 麦克风 | 麦克风授权 + `AudioEngineSession` 输入 | 受阻行 + 系统设置出口 |
| 本机音频 | 系统录音授权 + `CaptureHelper`（tap + aggregate device） | 受阻行 + 系统设置出口；不回退去抓整机 |
| 多来源合流 | 勾选多个来源（麦克风 + 若干本机 App）时自动走这一路：上述两者 + host time 对齐。**「合流」是行为，不是用户要选的第三个模式**（2026-09-18 第十一轮统一口径） | 单路可用时**不静默降级**，按实际可用来源继续并如实标注 |

职责边界：它是**获取/释放与来源选择的唯一入口**（R4），不做 endpointing、不做文本、不碰播放音量。
被 tap 的来源 App 退出时按 bundle id 自动接回（`processRestoreEnabled`），录制不打断，只记一条区间。

### 5.5 `AssistantSession`：编排、人设锁与前缀

回合流程：

```
用户说话 → 服务端 VAD → completed 转写
   → AssistantSession 调 Responses（流式）
   → 句子切分 → speechrail.tts.create（TTS）
   → 播放；若用户插话：调用方根据 speech_started 发送 speechrail.tts.cancel，line.interrupted=1
```

**prompt 结构（前缀稳定性是硬约束）**：

```
[developer 消息 · input_text：人设 persona]   ← prompt_cache_breakpoint 1
[developer 消息 · input_text：记忆 active 项] ← prompt_cache_breakpoint 2
[历史回合（只追加，从不重写）]
[本轮输入 / 内心 OS 的转录上下文]             ← 动态内容一律在后
```

请求级设置：`prompt_cache_options.mode = "explicit"`；断点标在**支持的 content block** 上
（`prompt_cache_breakpoint: {"mode": "explicit"}`）；每个请求最多 4 次 cache write。

落地四条（外部依据见 §13.1 来源 7）：

1. **顶层 `instructions` 不能带显式断点**——要打点的人设文本必须放进 developer 消息的 `input_text` 块。
   这条决定了上面的 prompt 形状，不是风格选择。
2. 人设与记忆**只在会话开始那一刻写入**；会话内对"改人设"的请求返回 `persona_locked` 与出口
   （新开一轮），不静默忽略。
3. **冻结会改写前缀的设置**：顶层 `reasoning.effort`、`text.verbosity`、`text.format`、以及 `tools`
   的名称/顺序/描述，在会话内都不动。若端点支持 `configuration_update` 输入项（文档口径：GPT-6 及
   以后），改 effort 走**追加该项**、顶层设置保持原值；不支持就不提供这个开关。
4. **观测 `cached_tokens`**，把它当作"这条链有没有真的在省"的唯一证据；不拿"听起来变快了"当结论。

**端点能力差异必须如实表达**：显式断点只在部分模型族上可用（文档口径：**GPT-5.6 及以后支持；
GPT-5.5 与更早的模型不支持**，只有隐式断点 + `prompt_cache_key`）。所以"人设锁"是**我们的结构选择**
——它保证前缀稳定、不白花算力；**不是"一定有缓存收益"的保证**。设置页的「检查连接」不承诺缓存命中，
只在诊断里显示 `cached_tokens`。

其余规则：打字提问进同一条编排（`role='user'`，来源记为打字）但**不朗读**回复；换音色走下一次
`speechrail.tts.create.voice`，**下一句生效**并落一条 `session_change(kind='voice', at_ordinal)`；
被拒时返回可读原因与可用内置声音列表，不隐式使用旧音色重试。

#### 5.5.1 系统上下文分层：语音契约在前，人设风格在后

`instructions` 这个名字在链路上出现两次，指的是两件事，必须分清（`LLMProvider.swift` 的注释里也钉了一遍）：

| 层 | 放在哪 | 它管什么 | 是否变化 |
|---|---|---|---|
| **语音对话契约** | Responses 顶层 `instructions` | 说什么、说多长（朗读优先） | 会话内逐字节不变，**每轮重发** |
| **人设 / 记忆** | developer 消息的 `input_text` + 显式断点 | 性格、语气、称呼、默认长度偏好 | 会话开始时定，中途只读（规格 §14.4） |
| TTS 的 voice/revision | `speechrail.tts.create`（调用方提供） | 怎么发声：音色与版本 | 下一条 render 生效 |

三条落地规则：

1. **契约必须每轮重发。** 顶层 `instructions` 不参与续轮继承：本机实测（2026-09-19）用
   `store=true` + `previous_response_id`，续轮带得动对话内容（问"我姓什么"答得出"您姓王。"），
   却带不动上一轮的 `instructions`（"每句以「喵」开头"没生效）。而助手一律 `store=false` + 全量重发，
   连可继承的服务端状态都没有——漏发一次，那一轮就没有任何契约。
2. **优先级由结构表达，不靠措辞。** 顶层 `instructions` 排在渲染前缀最前面，且**不能带显式断点**
   （本节落地四条的第 1 条），所以人设与记忆只能待在 developer 消息里。人设块再用
   `VoicePrompt.styleBlock` 包一层"与语音对话契约冲突时以契约为准"，让位关系在文本里也写着。
3. **契约不保证格式，读之前还有一道清洗。** 契约能明显压住会被逐字念出来的形状（本机 A/B：同一个
   "请用编号列表列出三种降噪耳机"的问题，带契约 2/2 没有任何编号与加粗，不带契约 2/2 都是
   `1. **…**` 三点列表），但不保证——所以进 TTS 前过 `VoicePrompt.spokenText`：只清排版语法
   （代码围栏、`**`、行首编号、行首 `#`/`>`、表情、多余换行），**不改写措辞**（改措辞是模型的活，
   清洗只负责别把符号念出来）。首次朗读与「重播」走同一条口径。

契约自身的分节（身份与模态 / 输出契约〔长度·可听性·节奏〕/ 语言 / 输入契约〔ASR 容错〕/ 优先级）
只在 `VoicePrompt.swift` 一处维护，单元测试钉住"语音优先"这几条不被删掉或挪到人设之后。
关 thinking 的 `chat_template_kwargs.enable_thinking=false` 与它的"被拒就退化"路径见 §13.2。

### 5.6 `MeetingSession`

| 关注点 | 终态 |
|---|---|
| 来源与每行标签 | `session.audio_source` + `line.source`（同源 / 本机音频 / 混音），导出物保留该列 |
| 分人 | 与字幕**同一条链路**：同一扩展、同一套会话内匿名标签、同一处改名、同一套降级话术 |
| 结束 | `finish` → `done` 屏障；未对齐时保留正文并标 `timing_quality='unavailable'` |
| 说话人标注 | 会中：表头 `标注说话人` + 行内 chip；会后：右栏批量面板（改名 / 合并 / 拆出 / 标记为「我」） |
| 中断 | 四类，见下 |
| 内心 OS | 贴底抽屉组件，收起态一行常驻，展开为"历史 + 答案"两栏（§5.9） |

**四类中断（不静默续录）**：

| reason | 触发 | 处置 |
|---|---|---|
| `service_lost` | WS 断开或服务不可达 | 停收声，正文保留；「继续这一段」= 新 epoch |
| `sleep` | 系统睡眠/合盖 | 醒来即中断态；麦克风与 tap 都要重拿，不自动续 |
| `source_lost` | 被 tap 的 App 退出；**或采集流自己结束**（设备被拔 / 引擎停了，§9 第 13 行未实装） | 前者**唯一自动接回**：按 bundle id 接回，只记一条区间、不进中断态；后者进中断态，「继续这一段」= 新 epoch。两件事都落 `source_lost`，区别写在中断行的 note 里，界面按 note 说话 |
| `unexpected_exit` | App 退出或崩溃 | 下次启动把 `recording`/`processing` 的行封存为 `archived`，`end_reason='unexpected_exit'` |

### 5.7 `CaptionSession` 与字幕带

- ⏎⌘⇧L 唤起 `CaptionBandWindowController`（App 可以不在前台）；浮层**不持有设备**，持有设备的是字幕会话。
- 未定稿的行走内存并显示「正在识别…」；**定稿即落库**。
- 上滚停止跟随并出现「回到最新」；`esc` 不关闭（它不持有焦点）；关闭浮层 ≠ 结束会话。
- 受阻四类共用同一条带子：麦克风未授权 / 服务未就绪 / 被别的会话占着 / **设备被别的 App 占着**；
  一律**保留最后一句字幕**（可读、可复制）。

### 5.8 `MinutesGenerator`

| 项 | 终态 | 依据 |
|---|---|---|
| 触发 | 转录封存后写 `minutes(status='queued', version=n+1)` | 与 Sona 的 `meeting_minutes` 同形（借用机制，不搬代码） |
| 执行 | Responses **background 模式**（`background: true`）+ 轮询状态；失败写 `failed` + 可读原因 | 长任务不应绑在界面前台（来源 8） |
| 并发 | 同会话单飞；claim 用租约（`lease_until` + `attempts`），超时可回收重试 | 租约式队列 |
| 恢复 | App 退出/崩溃后，过期租约在下次启动回收 | `unexpected_exit` 的同一套恢复 |
| 隐私 | 默认 `store=false`；不使用服务端会话状态 | **但要说清楚**：background 模式下即使 `store=false`，响应数据仍会临时落盘约 10 分钟以支持异步执行与轮询（文档口径）。这一条必须写进隐私说明，界面不许说成"内容没经过服务器" |
| 正文 | `json_schema` + `strict` 结构化字段 → App 渲染 Markdown | 结构化输出；拒答可程序化识别 |
| 版本 | 重新生成只**新增版本**，`is_latest` 指向最新，旧版仍可看可导出 | 产品规格 §6.2 |
| 超长会 | 只在需要时启用服务端压缩（`context_management`）；压缩会打断此前缓存，界面按"它得重读一遍开头"表达 | 来源 8 |

### 5.9 `InnerOSSession`（会中私密问答）

- 单查询、可取消；答案只回发起的那次请求：**不进会议音频、不进转录、默认不进纪要**。
- 上下文**只喂本场已确认的转录**（动态内容排在 prompt 末尾）；无证据就回答"没有证据"并给出已听时长与段数。
- 答案形状：证据（哪一段 / 谁 / 什么时间 / 引用原文）+ 事实 + 判断（带不确定度）+ 可直接念的措辞。
- 追问沿用同一上下文；"写进纪要"是显式动作（`in_minutes=1`），所以"默认不进纪要"是**结构决定**的。

### 5.10 `MemoryStore` 与 `SpeakerLabeling`

| 件 | 终态 |
|---|---|
| 记忆写入 | 助手在会话里**提议**，用户确认后落库；不静默积累 |
| 记忆生效 | **下一轮**（与人设同一条推理：它进的是同一段 system prompt，中途改会让前缀失效） |
| 记忆可见 | 助手页右栏"记录 / 记忆"两个标签；每条带来源会话，可停用或移除；移除记忆不动历史 |
| 说话人 | `speaker_name(label → display_name)` 只改显示名；正文与时间码从不改写；导出按当前名渲染 |

### 5.11 `Exporter`

Markdown / SRT / 纯文本 / JSON，四种都走系统保存面板；SRT 用 `ordinal` + **相对会话开始的秒**（不用墙钟）；
导出物保留来源列与说话人显示名；命名口径 `<kind>-<标题或首句>-<yyyyMMdd-HHmm>.<ext>`（文件名不用 UUID）。
**导出物里没有密钥、音频与完整 prompt**——因为库里本来就没有这些列（§6.3）。

### 5.12 设置（`LLMProviderSettings`）

服务地址（本机或局域网，URL 不带 key）· 接口（只读事实：`Responses · 必须`）· 模型（从该服务列表选）·
密钥（**只进钥匙串**）· `检查连接` 四种可判定结论：`已连接 · N ms` / `服务可达但模型没加载` /
`接口不对：没有 Responses API` / `连不上`。默认人设、默认音色、对讲模式、字幕字号与位置、分人默认值
属于"新会话预填值"，实际取值随每次会话落库。
另有一行 `中断时用系统通知告诉我`（默认关，口径见规格 §6.8）。

**不做端侧模型兜底**（`T4` 已裁决，2026-09-18）：外网不通时不给"另一个小模型也能答"的退路。
理由是它会分裂出第二套 prompt、第二套人设语义与第二套"记忆"，并直接破坏 §5.5 的前缀结构。
没有配置大模型时的正确行为是**受阻**（§9 第 15 行），不是换一个模型顶上。

### 5.13 Swift 侧并发模型

- UI 与状态：`@MainActor @Observable`（`SessionCoordinator` 是唯一的状态权威）。
- 音频：实时回调在 `nonisolated` 上下文里**只写预分配 ring**（不加锁、不分配、不做 I/O——WWDC 510 对
  source/sink 节点的原话就是"在实时约束下运行，不应做任何阻塞调用"）；向上层用 `AsyncStream` 交付。
- 阻塞式 CoreAudio 调用（`engine.start()`、`AVAudioRecorder.record()`、tap 建立）**一律离开主线程**；
  这条有本机实测教训（最坏 36.3 秒）。
- 持久化：`SessionStore` 单写者（串行队列/actor），读可并发（WAL 下读写互不阻塞）。

## 6. 数据模型终态

库的权威定义在 [`SESSIONS-SPEC.md`](../2026-09-17-live-sessions/SESSIONS-SPEC.md) §15（表结构、库文件、
打开方式、迁移、§15.4 不落库清单）与 §15.6 的增量 R1（中断）。本节不复制 DDL，只写三件只有在这里才
说得清的事：终态口径、状态映射、本方案要求补的三条加法。

### 6.1 终态口径

1. **一个入口**：所有持久化经 `SessionStore`。业务模块（助手 / 会议 / 字幕 / 内心 OS / 纪要）不持有
   连接、不写 SQL，只调用 §6.4 列出的动作。做到这一条，§5.2 的账本规则才可能成立。
2. **三种能力同表**：`session.kind` 区分，`line` 是同一种正文。三者的产物形状一样、只是来源不同；
   分开建表会把"从会议里挑一段进助手"这类后续需求变成一次数据迁移。
3. **再生成只新增版本**：`minutes.version` + `is_latest`，旧版本一直可看、可导出。
4. **不该存的东西没有列可写**：没有音频、embedding、实名、密钥、完整 prompt 的列（§15.3.4）。
   这是结构，不是纪律。

### 6.2 UI 状态 ↔ 库状态

两处各有一套状态词，映射必须写进代码注释，否则实现时会出现两种解释：

| `SessionCoordinator` | `session.state` | 其他行 |
|---|---|---|
| `preparing` | **无行** | —（R4：不建空记录） |
| `recording` | `recording` | — |
| `interrupted` | `recording`（不封存） | `session_interruption` 最后一条 `resumed_at IS NULL` |
| `processing` | `processing` | 设备已释放 |
| `archived` | `archived` + `ended_at` + `end_reason` | — |

**`interrupted` 故意不是 `state` 的取值**：中断是事件，不是阶段。它由「有未闭合的
`session_interruption` 行」推出，所以"这一段到底录没录上"能从库文件本身回答，而不是从界面记忆回答。
记录库列表里的「已中断」标识就是这条查询。

### 6.3 三条加法（`T5` 已裁决，并入 §15.7 的 R2）

**已落地。** 用户 2026-09-18「全面采纳」裁定并入规格，DDL 与理由见
[`SESSIONS-SPEC.md`](../2026-09-17-live-sessions/SESSIONS-SPEC.md) §15.7；本节只记它们与本文其他部分
的挂钩点，避免两处各写一份而漂移。

| # | 加法 | 为什么必须有 | 在本文的挂钩点 |
|---|---|---|---|
| ① | 把 `line_by_session` 索引升级为 `UNIQUE (session_id, ordinal)` | §5.2 账本规则 2「重复的 `completed` 不产生第二行」原先只是约定 | §5.2 规则 2、§6.4 的 `appendLine`（取号与插入同一事务） |
| ② | `minutes` 增加 `status`、`lease_until`、`attempts`、`failure_reason`；`body` 可空 | §5.8 的「排队 / 单飞 / 超时回收 / 失败写可读原因」在原表上没有落点——`body NOT NULL` 时"排队"无法表达 | §5.8、§6.4 的 `enqueueMinutes / claimMinutes / failMinutes`、§9 第 18 行 |
| ③ | `line.source` 增加取值 `'keyboard'` | 规格 §6.1 与 §16.2.1 的 E4 明确"打字是一条一等输入路径"（`role='user'` 且来源记为打字） | §5.5（打字不朗读回复）、§8.1 的数据流 |

`session.audio_source` 仍然**只有** `'microphone'|'system'|'mixed'`：它描述"这一次选的采集来源"，
而打字不改变采集来源。

### 6.4 `SessionStore` 的对外动作

业务层只允许用这张表里的动作。表里没有的写入需求，先改这里，再改代码。

| 动作 | 调用者 | 关键约束 |
|---|---|---|
| `createSession(kind:source:profile:persona:voice:)` | `SessionCoordinator` | 只在首个 PCM 已发送时建行；`persona_*` 一次写入，之后不接受更新 |
| `appendLine(…)`，返回分配的 `ordinal` | `RealtimeASRClient` | 单写者；取号与插入在同一事务（§15.7） |
| `attachSpeakerLabel(lineID:label:)` | 分人链路 | **只改 `speaker_label`**，正文不动 |
| `renameSpeaker(sessionID:label:name:)` | `SpeakerLabeling` | 只写 `speaker_name` |
| `noteVoiceChange(sessionID:atOrdinal:voice:)` | `AssistantSession` | 界面上的「第 N 句起」靠它 |
| `markInterruption / closeInterruption` | `SessionCoordinator` | 见 §6.2 |
| `finalizeSession(id:endReason:)` | 结束流程 | 封存：`archived` + `ended_at` + `end_reason` |
| `enqueueMinutes / claimMinutes(lease:) / finishMinutes / failMinutes` | `MinutesGenerator` | 租约 + 版本（§15.8） |
| `saveInnerOSExchange(…)` | `InnerOSSession` | 默认 `in_minutes = 0` |
| `upsertMemory / setMemoryActive / removeMemory` | `MemoryStore` | 只在用户确认之后调用 |
| `loadSession / listSessions(kind:) / searchLines(query:)` | 界面 | 只读 |
| `backup(to:)` | 设置页 | `VACUUM INTO` |

### 6.5 时间轴与检索（实现口径）

- `line.t_start / t_end` 是**相对 `session.started_at` 的秒**，由 epoch 内已发送样本数换算
  （§5.2 规则 1）。SRT 时间码与导出物一律从这里取；墙钟只用于列表排序与标题。
- `ordinal` 在会话内单调、跨 epoch 连续（续接不重置序号），所以"断点在哪"是一个可比较的位置。
- v1 检索用 `LIKE` + `line_by_session`；FTS5 是否可用尚未实测（§12），实测变慢之后再做一次迁移。

### 6.6 存储归属与重装契约（用户 2026-09-18 裁决）

**用户资产与服务运行材料必须能分开删。** 判据不是"是不是用户数据"，而是**能不能重建**（Apple 对
Application Support / Caches 的口径：后者"can be regenerated as needed"）。权威口径写在
[`docs/operations/runtime-deployment.md`](../../operations/runtime-deployment.md) 的
「app home 目录契约与重装语义」，这里只记它与三条能力的关系。

| 存储 | 归谁 | 终态位置 | 重装/升级 |
|---|---|---|---|
| 会话记录 / 纪要 / 记忆（`sessions.sqlite3`） | App | 数据区 | 不动 |
| 作品（`Works/works.json` + `<id>.wav`） | App | 数据区 | 不动 |
| 音色（`custom-voices.json` + `voices/`） | **服务** | 数据区（**从 `~/.speechrail` 迁入**） | 不动 |
| 私有配置（`config/.env`） | 服务 | 数据区 | 不动 |
| 运行时 / 模型 / vendor / state | 服务 | 可重建区 | 可删 |

三条推论：

1. **不合并成一张库**。音色是服务合成时要读的运行时资产，会话库是 App 的用户记录；合并意味着服务要
   读 App 的库（撞 R1–R3），而且一个损坏会同时拖垮两个子系统。跨存储只靠**快照**（记录里存 id + 名字）
   与**存在性检查**连接，不靠外键。
2. **时间点快照是历史事实**。`Works` 已同时存 `voiceID` 与 `voiceName`；`session` 表要补一个
   `voice_name`（与 `persona_id` / `persona_title` 对称）。这样音色改名或删除之后，旧记录仍然说得清
   "当时用的是谁"。
3. **音色被删不级联**。作品与会话里的 `voice_id` 允许悬空，用到时给一句可读结论；App 侧的
   「关联作品」已经用 `id` 或 `name` 双匹配（`CreatorSurfaceViews.swift`），不需要改。

**三项尚未实现，构成本轮之后的第一批维护项**（都不属于三条能力的功能范围，可独立排期）：
① 音色路径搬迁（**兼容逻辑必须先落地**：新路径优先、旧路径存在则自动搬一次并留日志、旧目录留空壳）；
② 数据区备份入口（现在设置里只有「备份库文件…」）；③ 可重建区的 Time Machine 排除
（`NSURLIsExcludedFromBackupKey`，macOS 10.8+）。

## 7. 从 Sona 借用什么、拒绝什么

Sona 是这套能力的**经验来源**，不是代码来源：借它的判断，不借它的进程结构与历史包袱。历史记录见
[`../2026-09-17-live-sessions/SESSIONS-SPEC.md`](../2026-09-17-live-sessions/SESSIONS-SPEC.md) §3。

### 7.1 借用（10 条）

| # | 借用的东西 | Sona 的出处 | 在 SpeechRail 的落点 | 形态差异 |
|---|---|---|---|---|
| 1 | 设备绑定的 Core Audio Tap 采集 | `docs/decisions/0010-physical-output-audio-capture.md` | §3.2 `CaptureHelper` | 载体换成 App 内 XPC，且按 R4 随会话进退，不做常驻 |
| 2 | 不暴露设备内部标识（opaque `device_ref`） | 同上 | 记录里只落 `session.audio_source` 的三种取值 | 更严：连设备 id 都不进库 |
| 3 | PCM 不落盘 | 同上 | 全局（§9、§15.3.4） | — |
| 4 | 按运行模式划分 VAD 归属，避免双重 endpointing | `docs/decisions/0013-vad-ownership-and-mode-boundaries.md` | §5.3 的静音窗口（字幕 400 ms / 会议 900 ms）；客户端**第二个 VAD 被明确禁掉** | 沿用结论 |
| 5 | 不可变正文 + 独立归属列 | `docs/superpowers/specs/2026-08-21-meeting-assistant-design.md` | `line.text` 从不改写；标签在 `speaker_label` / `speaker_name` | 沿用结论 |
| 6 | 版本化纪要 + 有界生成 | `docs/decisions/0007-bounded-meeting-summary-generation.md` | `minutes.version` + `is_latest`（§5.8） | 生成改到 Responses background；**不搬**它的分段收敛算法 |
| 7 | 私人频道（会中私密问答与正文分离） | `ui/src/features/innerOS/` + 会议设计稿 | `inner_os_exchange` / `inner_os_evidence` 与 `line` 分表（§5.9） | 形态改成贴底可展开抽屉 |
| 8 | 幂等事件账本 | `contracts/meeting-assistant/v1/` | 会话内 `ordinal` + epoch 内序号（§5.2 规则 2） | 我们不需要 `event_id` 去重：写入是单写者 |
| 9 | 「中断」是一个查得到的事实 | `event-resync-required` 的存在理由 | `session_interruption`（§15.6 R1） | 只借结论，不借机制（见 §7.2 第 6 条） |
| 10 | 客户端与语音服务只共享协议与准入 | `docs/decisions/0006-contract-first-meeting-assistant-separation.md` | R2：服务守 ASR/TTS 子集（§4） | 沿用并加强：把红线写进 §4.2 |

### 7.2 拒绝（7 条）

每一行都不是"它做得不好"，而是**它的前提在我们这里不成立**。

| # | 拒绝的东西 | Sona 的出处 | 拒绝的理由 |
|---|---|---|---|
| 1 | 把用户资产与大模型编排放进后端服务 | `docs/decisions/0009-*.md`、`src/sona/meeting/repository.py` | SpeechRail 的红线（§4.2）：服务只做语音，不做资产。放进去等于把"本机可用"绑上另一个进程 |
| 2 | PostgreSQL + 迁移框架 | `pyproject.toml`（`psycopg`）、架构文档的 `sona` schema | 桌面单机功能不该把门槛抬到"先建库"（D1/D8）；SQLite 库文件 + `user_version` 足够 |
| 3 | 浏览器 `getUserMedia` 采集 | `ui/` | 我们要的是系统级来源（腾讯会议 / QQ 音乐的声音），浏览器拿不到；也不为此引入 web 栈 |
| 4 | 客户端第二个 VAD | ADR-0013 的反面 | 双重 endpointing 会产出两套切句；客户端不做 endpointing（§5.4） |
| 5 | 文本级回声抑制（拼音相似度 + RMS 能量门 + 尾巴宽限） | `src/sona/interaction/echo.py` | 它可能把用户的话当回声丢掉。我们改用系统 AEC，只保留一条极窄规则并强制留痕（§3.3） |
| 6 | `revision gap → resync_required` 对账机器 | `contracts/meeting-assistant/v1/`、`ui/src/hooks/useMeetingSocket.ts` | 它的前提是服务端持有事实源。我们的记录由客户端唯一写入、PCM 实时不回放，那套对账在这里没有对象（§5.2 规则 3） |
| 7 | 前端持有会话所有权 | `ui/` | 所有权在 `SessionCoordinator`，与页面解耦（§5.2、规格 §5.4） |

### 7.3 一句话

借的是**判断**（tap 怎么用、VAD 归谁、正文不可改、中断要留痕），拒的是**它的历史包袱**（资产与服务
捆在一起、把对账当恢复手段、用文本去补音频）。凡是"它在 Python/PostgreSQL/浏览器里做"的分工，
在 R1–R4 四条判据下都要先问一遍归属。

## 8. 三条能力的端到端数据流

三条链共用同一段地基（§5.1）：**设备由 `AudioSourceCoordinator` 获取与释放，正文由
`RealtimeASRClient` 产出、`SessionStore` 落库，LLM 只在业务层出现。** 下面标出每条链上"唯一允许
降级"的位置——其余任何一环失败都是受阻，不是降级。

### 8.1 语音助手（一问一答 / 实时对讲）

```
用户点「开始对话」（人设、音色、模式已定）
  → AudioSourceCoordinator：麦克风授权 → AudioEngineSession 建图
      对讲模式：输入与输出同引擎，同时开 voice processing（§3.3）
      问答模式：播放期闭麦（本地门闩）
  → RealtimeASRClient：一次 transcription_session.update（pcm16 / 16000 / server_vad / 可选分人）
  → 说话 → input_audio_buffer.committed … completed
  → appendLine(role='user', source='microphone') 落库       ← 落库发生在「说」这一侧
  → AssistantSession 调 Responses（流式）
      前缀：developer(persona) → developer(memory) → 历史 → 本轮输入
  → 句子切分 → speechrail.tts.create → 24k PCM → playerNode
  → 插话：服务端 speech_started → 调用方 speechrail.tts.cancel → 丢弃未播缓冲 → line.interrupted = 1
  → 结束：EOF 屏障 → finalizeSession(endReason='user') → 无纪要

打字提问：同一编排；role='user'、source='keyboard'，**不朗读回复**，回复仍可点「重播」
```

唯一允许降级的位置：**TTS 被拒**（音色不可用）——这一句仍用旧音色说，记一条可读原因，会话继续。
大模型不可达不是降级：它是受阻（§9 第 15–17 行），因为助手没有第二套回答方式。

### 8.2 会议助手（含内心 OS）

```
用户点「开始会议」并选来源（麦克风 / 本机音频按 App，可多选；勾多个就自动合流）
  → 按来源申请权限（系统录音**只在选「本机音频」时**才申请）
  → 麦克风：AudioEngineSession 输入；本机音频：CaptureHelper 建 tap + aggregate device
  → 两路各带 host time → 混音/归一 → 16k mono PCM16（缺口补静音并标记）
  → transcription_session.update（pcm16 / 16000 / server_vad 900 ms / 分人按开关）
  → completed → appendLine(source='microphone'|'system'|'mixed')，带 speaker_label
  → 分人 updated → attachSpeakerLabel（**只改归属列**）
  → 内心 OS：用户提问 → 只喂本场已确认转录 → 答案进 inner_os_exchange（默认 in_minutes = 0）
  → 结束：speechrail.diarization.finish → 等 done（EOF 屏障）→ 释放设备 → archived
  → MinutesGenerator：enqueue（version = n+1）→ Responses background → 轮询 → finishMinutes
  → 出口：导出 MD/SRT/JSON、记录库回看、改名与合并、重新生成
```

唯一允许降级的位置：**分人**——正文继续写、标签停更、已给出的标签保留，`session.diarization`
记 `degraded` 与原因。纪要失败不是降级：转录已封存，用户可以只导出 SRT（§9 第 18 行）。

### 8.3 实时字幕

```
⌘⇧L（App 可以不在前台）→ CaptionBandWindowController 出现（非激活 / 全空间 / 全屏共存）
  → 用户点「开始」→ 麦克风授权 → AudioEngineSession 输入 → 同一套 RealtimeASRClient
      server_vad 静音窗口取 400 ms（字幕要快）
  → partial 只进内存，显示「正在识别…」                 ← 未定稿不进库
  → completed → **立即落库**（appendLine）
  → 上滚：停止跟随 + 出现「回到最新」；星标写入 line.starred
  → ✕ 结束：释放设备 → archived；关闭浮层 ≠ 结束会话
  → 记录库：回看、检索、导出 SRT（ordinal + 相对秒）
```

这是三条里**唯一不依赖大模型**的闭环，因此也是最先能不靠外部条件端到端走通的一条（§10 阶段 3）。
唯一允许降级的位置：**时间戳不可用**——正文照常落库，`timing_quality='unavailable'`，导出时说明。

## 9. 失败与降级矩阵

每一行都是"用户看到什么 / 系统做什么 / 库里留下什么 / 出口在哪"。**没有静默失败**：凡是不出声的
处置，都要在库里留一行，否则事后无法解释。

| # | 场景 | 用户看到 | 系统行为 | 库里 | 出口 |
|---|---|---|---|---|---|
| 1 | 语音服务未启动 / `/readyz` 失败 | 受阻条「语音服务没在运行」 | 不建会话、不取设备 | 无行 | 打开服务页 / 重试 |
| 2 | 模型未加载（`503 backend_not_ready`） | 受阻条「模型还没准备好」 | 同上 | 无行 | 重试 |
| 3 | 麦克风未授权 | 受阻条 + 说明 | 不建会话 | 无行 | 打开系统设置 |
| 4 | 系统录音未授权（选「本机音频」后拒绝） | 受阻条（**只在用本机音频时出现**） | 不建 tap；**不回退去抓整机** | 无行 | 系统设置 / 换来源 |
| 5 | 设备被别的 App 占着 | 受阻条「麦克风正被别的 App 使用」 | 不建会话（不做抢占） | 无行 | 等它释放 / 换来源 |
| 6 | 服务端准入满（`backend_busy`，通常是别的客户端占着） | 会话占用守卫（不显示原始错误码） | **不建会话、不取设备**——App 从不主动抢第二路 | 无行 | 结束另一个会话 / 稍后 |
| 7 | WS 断开或服务重启 | 中断态 + 时长 | 停收声；不重放 PCM | `session_interruption(service_lost)` | 「继续这一段」= 新 epoch |
| 8 | 系统睡眠 / 合盖 | 醒来即中断态 | 麦克风与 tap 都要重拿，**不自动续** | `session_interruption(sleep)` | 同上 |
| 9 | 被 tap 的来源 App 退出 | 无打扰，仅一条区间 | **唯一自动接回**：按 bundle id 接回 | `session_interruption(source_lost)` + `resumed_at` | — |
| 10 | App 退出 / 崩溃 | 下次启动看到「上次会议没有正常结束」 | 把 `recording`/`processing` 封存为 `archived` | `end_reason='unexpected_exit'` | 记录库可回看可导出 |
| 11 | 分人不可用（`light` 档 / profile 未就绪） | 开关置灰 + 原因（两侧说法一致） | 正文照常，不分人 | `session.diarization='unavailable'` | 换档位后新会话 |
| 12 | 分人运行中降级 | 标签停更，已给出的保留 | 继续转写 | `diarization='degraded'` + `diarization_note` | 结束后可人工标注 |
| 13 | 换输入设备（配置变化通知） | 当前这一轮标「换设备」 | 引擎重建；线上格式不变（恒 16k） | 新行 `device_switch=1` | — |
| 14 | TTS 音色被拒（`voice_not_found` / `voice_not_available`） | 一句可读原因 + 可用音色列表 | **这一句仍用旧音色说**，会话继续 | 不落 `session_change` | 换一个音色 |
| 15 | 未配置大模型 | 结论条 + 灰态对话流 + 禁用的控制行，**不弹窗** | 助手功能受阻，其余照常 | 无行 | 打开设置 → 会话页签 |
| 16 | 大模型不可达 / 超时 | 可读结论 + 重试 | 回合标记失败，正文保留 | 行保留（无回复） | 重试 / 换端点 |
| 17 | 端点不是 Responses API | 「接口不对：没有 Responses API」 | 拒绝保存为可用配置 | 无行 | 换端点 / 换模型 |
| 18 | 纪要生成失败（拒答 / 结构不合法 / 超时） | `纪要没整理出来 · 转录已经存好了` + 一句人话原因（文案见规格 §16.8） | 转录已封存，不动 | `minutes(status='failed', failure_reason=…)` | 重新生成（新版本） |
| 19 | tap 或 aggregate device 建立失败 | 受阻条（同第 4 行形状） | 结束会话，不留半条音轨 | 无行 | 换来源（麦克风）/ 重试 |
| 20 | 库文件不可写（磁盘满 / 只读） | 「这次内容没能保存」+ 原因 | **立刻停收声**：宁可没有这段，也不给用户一段会消失的记录 | 无行 | 释放空间后重试 |
| 21 | App 侧丢弃疑似回声的一句 | 无感 | 丢弃并留痕（§3.3 第二道防线） | **不写库**：只进本地诊断日志 | — |

第 20 行是有意选"早失败"的一行：记录是这个产品的资产，能录入但存不下比明确拒绝更糟。

## 10. 落地阶段与契约依赖

阶段的**顺序与归属以规格 §12 为准**；本节只补技术侧的前置、契约依赖与"什么时候退得回去"。
本轮不写任何代码，阶段表用于评审可行性。

| 阶段 | 内容 | 依赖的契约 / 事实 | 结束时可走通 | 回退 |
|---|---|---|---|---|
| 1 | 会话所有权地基：`SessionCoordinator` + 侧边栏占用行 + 路由 | 无（纯本地） | 走不通任何闭环；三条能力的受阻文案依赖它 | 删 4 处新增，不动既有页面 |
| 2 | 记录库：`SessionStore` + 记录库视图 | §15 + §15.6 R1 + §6.3 三条加法 | J2/J3 的回看、导出、移除（不依赖麦克风） | 删库文件 = 回到"没有记录" |
| 3 | Realtime 客户端与字幕带 | `contracts/realtime-openai.md`（既有） | **J3 全旅程**（唯一不依赖大模型的闭环） | 关掉浮层入口，页面退回纯记录库 |
| 4 | 分人（会议与字幕共用一条链路） | 契约的分人扩展（既有） | 两侧说法一致：同一扩展、同一处改名 | 关分人开关，正文照常 |
| 5 | 语音助手：`AssistantSession` + `LLMProviderSettings` + `MemoryStore` | **外部**：OpenAI Responses（`/v1/responses`、`store`、`reasoning.effort`）；**S1** | **J1 全旅程**（含打字输入与记忆的下一轮生效） | 助手页显示受阻态，不动服务 |
| 5.5 | **tap 取音 spike**（半天，成果可丢弃） | 本机 SDK 事实（§3.2）；Apple 官方 tap 文章 | 拿到 16k PCM、看到授权时点、确认 `processRestoreEnabled` 的真实行为 | 直接丢弃；不改任何既有文件 |
| 6 | 会议助手（含来源与中断） | 阶段 5.5 的结论 + **S1** | **J2 全旅程**（含四类中断） | 只保留麦克风这一路来源 |
| 7 | 内心 OS | 阶段 5 的 provider | J2 · E5 的一条（问到答案 → 写进纪要） | 隐藏入口，会议照常录 |
| 8 | 全局热键与菜单栏 | 无（Carbon，不需额外授权） | J3 · E1：⌘⇧L 在 App 不在前台时也成立 | 撤掉全局键，退回"前台生效"并在文案里如实说 |
| 9 | Token 与文案归口 | 设计系统文档 | — | 文档改动独立可回退 |

三条跨阶段的硬依赖：

1. **阶段 5.5 必须在阶段 6 之前**：会议助手的唯一新采集路径是 tap，它的授权时点、格式协商与
   自动接回行为都只能靠实跑确定（§12 第 3 条）。把它压进阶段 6 意味着在铺开会议 UI 的同时
   探索一个未知 API。
2. **S1（长会话重连语义）要在阶段 5 之前定稿**：助手与会议都按"新连接 = 新 epoch"实现；
   这条语义若在服务契约里写不清，客户端会各自发明一套换算（§4.3）。
3. **阶段 2 与阶段 3 可以并行**（写入范围不重叠）；其余阶段串行。

**不在上表的独立项**（用户 2026-09-18 裁决，见 §6.6）：音色路径搬迁（含旧路径兼容）、数据区备份入口、
可重建区的 Time Machine 排除。三者都不属于三条能力的功能范围，与阶段 1–9 解耦，可单独排期；唯一硬约束
是**音色的兼容读逻辑必须先于搬迁代码落地**，否则现有注册表会孤立在旧路径上。

## 11. 验收判据（可执行清单）

产品口径的判据在
[`../2026-09-17-session-closures/USER-JOURNEYS.md`](../2026-09-17-session-closures/USER-JOURNEYS.md) §10
与规格 §16.9；本节只补**技术侧必须自己判的那几组**，并说明每条怎么观测。每组都能独立执行，
不需要读别的文档。

### 11.1 设备与权限（R4，五条）

| # | 操作 | 应该看到 | 怎么观测 |
|---|---|---|---|
| A1 | 启动 App，什么都不做 | 系统不出现麦克风使用指示；侧边栏写「麦克风空闲」 | 菜单栏控制中心的麦克风指示；`AudioEngineSession` 未实例化 |
| A2 | 点「开始会议」 | 麦克风指示出现；本机音频来源额外触发系统录音授权 | 控制中心指示 + 首次弹窗只出现一次 |
| A3 | 结束会话（含中断） | **5 秒内**麦克风指示消失 | 秒表 + 控制中心指示 |
| A4 | 结束含本机音频的会话 | 采集 helper 进程退出；带 tap 的 aggregate device 消失 | 进程列表（`pgrep`，**只读**）+ 音频设备列表（`system_profiler SPAudioDataType`）前后对比；**聚合设备在系统列表里是否可见以实测为准**（§12 第 1 条） |
| A5 | 全程只用实时字幕、从不选「本机音频」 | **不出现**系统录音授权弹窗 | 系统设置 → 隐私与安全性 → 屏幕与系统录音，App 不在列表里 |

### 11.2 三条旅程（按 USER-JOURNEYS §10 逐条走）

J1 语音助手 5 条 · J2 会议助手 7 条 · J3 实时字幕 5 条 · J0 跨模块 3 条，共 20 条。本节不复制，
只强调其中**技术侧最容易假通过的两条**：

- 「实时对讲里插话 → 250 ms 内不再触发」要按**服务端 `speech_started` 到本地静音**的单调时钟测，
  不是按"听起来没有回声"判。
- 「重开 App 后记录、音色变更点、记忆都还在」要**直接查库**（`sqlite3 sessions.sqlite3`）而不是
  只看界面——界面可能是从内存快照渲染的。

### 11.3 体感延迟（口径先定，目标值待实测）

参考 OpenAI voice-agents 指南给的度量方式：按**单调时间轴**记录三个量，而不是只测端到端平均。

| 量 | 定义 | 用在哪条能力 |
|---|---|---|
| 首次可听响应 | 用户说完（`committed`）到第一个音频帧开始播放 | 语音助手（对讲） |
| 打断让位 | 服务端 `speech_started` 到本地播放静音 | 语音助手（对讲） |
| 不必要的静默 | 一轮内在没有用户说话的情况下，输出中断超过阈值的事件数 | 助手 / 会议纪要 |

**三个量的目标值不在本文定**：它们取决于模型、档位和具体机器，只能在阶段 5/6 用真实会话测出
基线后再写回本节。现在写死一个数字，等于给自己造一个假通过。

### 11.4 数据与隐私（查库能回答的问题）

| # | 问题 | 期望 |
|---|---|---|
| D1 | 这条记录是谁在什么时候录的、用的哪个档位与来源 | `session` 一行回答 |
| D2 | 这一段音频在哪 | **哪儿都没有**：库里无音频列，磁盘上无 PCM 文件 |
| D3 | 我那次被打断说了什么 | `line.interrupted = 1` 的那一行，正文仍在 |
| D4 | 第 13 句起为什么换了声音 | `session_change(kind='voice', at_ordinal=13)` |
| D5 | 纪要改过几版 | `minutes` 按 `version` 多行，`is_latest` 只有一行 |
| D6 | 内心 OS 问过什么、有没有进纪要 | `inner_os_exchange`，默认 `in_minutes = 0` |
| D7 | 改名会不会改到正文 | `line.text` 与 `inner_os_evidence.quote` 未变，只有 `speaker_name` 变 |
| D8 | 哪一段没录上 | `session_interruption`；导出物里时间码在断点处是跳的 |
| D9 | 大模型密钥在哪 | 钥匙串；库里只有 `llm_endpoint`（不含密钥）与 `llm_model` |
| D10 | 重装 / 升级之后这些东西还在不在 | 在。`sessions.sqlite3`、`Works/`、`voices/`、`config/.env` 都在**数据区**，换版本、重装 App、`service uninstall` 都不动它们（§6.6） |

### 11.5 文档与契约同步（阶段 9 之前必须完成）

- ✅ `AGENTS.md:33` 已改写为「采集与播放**只发生在会话语境**（语音助手 / 会议助手 / 实时字幕 /
  音色克隆）且**按功能启用、功能离开即释放**」（`T3` 的执行结果）。
- ✅ `docs/developers/macos-app-audio-capture.md` 补了 §3.7 会话级采集与 §3.7.1 本机音频
  （进程 tap、XPC 载体、合流口径、缺口计数、设备生命周期），未验证项也写进了 §6。
- ✅ `docs/architecture/current-boundaries.md` 在「明确限制」里记了一条 2026-09-18 的边界变更：
  App 侧新增会话采集与 XPC 采集服务，**服务契约不变、不新增接口**。
- ✅ 规格 §5.3.1 与本文 §参考号一致（`v2.2.0` 与规格 v1.6.0 对得上）。
- ✅ `UX-UI-SPEC` §13 的未决项 2（会话组进 `AppRoute`）与 4（实现侧 token 补齐）本轮结清。

**实现状态**：阶段 1–9 的代码与文档都已落地（`macos/SpeechRailApp`，2026-09-19）。助手的
`AudioEngineSession` 已接入 `AssistantSession` 默认链路；本轮已完成 App Debug 构建、测试 bundle
编译与 SwiftPM target 构建，但尚未把真机声学测量写成通过结论。需要单独说明的差距：

1. **阶段 5.5 的 tap spike 没有单独跑过**。本机音频那条路直接落成了代码，§12 第 1、2 条
   （授权触发点、`bundleIDs` 是否真按 App 生效、`processRestoreEnabled` 的真实行为）
   **仍然是未验证**；这三条正是这条来源的全部前提。它是这份方案里剩下最该先做的一件事。
2. **会议/字幕的既有 `MicrophoneCapture` 仍未实现 §9 第 13 行的 `device_switch = 1`**：今天这些
   能力设备被拔仍表现为采集流结束并落一条中断。助手的 `AudioEngineSession` 已实现配置变化后的
   input tap / converter / player 重建，但没有新增 `device_switch` 记录行。

## 12. 未验证清单

本轮把 v1.1.0 的 10 条与这一轮新出现的合并为 17 条。**没有一条能在文档里被当成已成立**；
每条的验证时机写在最后一列，"谁来验"不写，因为都由实现者在本机验。

| # | 未验证的事 | 影响 | 何时验 |
|---|---|---|---|
| 1 | 本机音频 tap 未真机跑过：授权弹窗的实际触发点、`bundleIDs` 限定是否真按 App 生效 | 阶段 6 的整个来源模型 | 阶段 5.5 spike |
| 2 | `processRestoreEnabled`（来源 App 重启后自动接回）是 SDK 标注语义，**不是实测行为** | §5.4「唯一自动接回」这条承诺 | 阶段 5.5 spike |
| 3 | `AVAudioEngine` 上「输入 + 输出同引擎开 voice processing」在 macOS 26 的真实 AEC 收敛效果 | 实时对讲能不能外放用；§3.3 是整套设计的枢纽 | 阶段 5 |
| 4 | `realtime_max_sessions` 的**源码默认值**为 3（`src/speechrail/config/__init__.py:104`），示例 env 已与其对齐；本机部署的显式覆盖值仍需按部署配置只读核对 | 能同时开几条会话；准入受阻态的频繁程度 | 阶段 1（只读核对部署配置） |
| 5 | 按会话配置 `server_vad` 静音窗口（字幕 400 / 会议 900 ms）是否真的被服务端接受并生效 | 字幕的即时感与会议的切句粒度 | 阶段 3 |
| 6 | 目标大模型端点的**前缀缓存**行为：整段前缀完全匹配、显式断点是否可用、最小可缓存前缀长度 | 人设锁与前缀结构的价值成立与否 | 阶段 5 |
| 7 | 端点是否支持 Responses **background** 模式与 `store=false` | 纪要的长任务形态与隐私承诺 | 阶段 5/6 |
| 8 | 端点对 `json_schema` + `strict` 的真实支持度 | 纪要正文的可渲染性；不支持时要退到"纯文本 + 后校验" | 阶段 6 |
| 9 | `realtime_vad_bargein_cooldown_ms` 的 250 ms 默认值在本机外放场景够不够 | 自激风险 | 阶段 5 |
| 10 | FTS5 是否可用（§15.5）；v1 先用 `LIKE` | 检索性能，不阻塞功能 | 阶段 2 |
| 11 | 内心 OS 的上下文窗口与截断阈值（§15.5） | 超长会议的答案质量 | 阶段 7 |
| 12 | 字幕带 `NSPanel` 在"其他 App 全屏 + 多显示器 + 多 Space"下的实际层级 | 字幕能不能真的贴在腾讯会议全屏画面上 | 阶段 3/8 |
| 13 | `engine.start()` 是否也会复现音色克隆那条 **36.3 秒**冷启动阻塞 | 开始会话是否必须做成可取消的异步动作 | 阶段 3 |
| 14 | 目标端点**是否支持显式 cache breakpoint**（文档口径：GPT-5.6 及以后支持，GPT-5.5 与更早不支持） | 若只支持隐式断点，"人设锁换缓存收益"这条推理在兼容端点上不成立，界面也不能暗示它成立 | 阶段 5 |
| 15 | 目标端点是否支持 `configuration_update` 输入项（文档口径：GPT-6 及以后） | 决定"会话内能不能改 reasoning effort 而不破前缀"这个开关给不给 | 阶段 5 |
| 16 | 全局热键的**安装时机**（2026-09-18 改口径）：接线已从"挂在 `MenuBarExtra` 的 label 上"移进 `App.body`（`SpeechRailApp.wireGlobalShortcuts()`）——label 由系统单独承载，挂在其上的 `.environment(...)` 不生效，那天就是这样崩的（`d6bb7cdf`）。`body` 在启动时求值，所以"关着窗口"不再影响安装；但四个键"按下去真的触发"没有真机验证过 | 关着窗口时 `⌘⇧L` / `⌘⇧N` 是否可用 | 阶段 8 真机走查（关窗后按一次） |
| 17 | 2026-09-18 对着 4K 导出稿补的三处交互没有真机验证：菜单栏状态项三态（会话名 / 琥珀点 / 红点）、「停止整理」的取消链路（取消 → `failMinutes` 记一条"你停下了"）、撤掉分段控件定宽后的观感 | 菜单栏能不能如实反映会话与受阻；取消整理会不会在库里留下正确的状态 | 阶段 8 真机走查 |
| 18 | 会议页录制态**缺稿上的「静音麦克风」**（2026-09-19 走查发现）：**实现已补**（采集侧等长静音闸 + `MeetingSession.toggleMicrophoneMute()` + 页头一处按钮，口径见 `SESSIONS-SPEC` §12.1.4），但"静音时真的送静音、真不记缺口、分人链路不受影响"只能在真机会话里看 | 会中想把房间里的话挡在外面时没有出口；它同时是 `SESSIONS-SPEC` §8 表里的 `M` 键 | 一次真实的麦克风会话（只差这一验） |

**2026-09-19 更新**：对三条闭环做了一次逐屏真机走查（只按 AX 元素、不占前台、不开会话），
修掉 8 处缺陷并复验，逐条记在 `../2026-09-17-live-sessions/SESSIONS-SPEC.md` §12.1.4。
对照上表只挪了两处，其余不变：第 17 条的第三项（分段控件观感）随逐屏走查一起看过，
前两项（菜单栏三态、停止整理的取消链路）仍未验；新增第 18 条。

**2026-09-19 补记**：第 18 条留的两处缺口已写进代码——`AudioSourceCoordinator` 多一道麦克风静音闸
（**等长静音**而不是丢块：丢块会被混音器按 40 ms 栅格补静音并记进 `gapCount`，
状态带就会把"我主动不说"说成"N 处补过静音"），`MeetingSession` 多一个 `toggleMicrophoneMute()`
（只在 `phase == .recording` 且来源含麦克风时生效），页面按稿把开关放在页头一处。
`M` 键（静音麦克风）**没有**接线：`GlobalHotKeyCenter` 今天只注册四个键
（`⌘⇧L` / `⌘⇧N` / `⌘⇧.` / `⌘⇧I`，`GlobalHotKey.swift:11`），`M` 是会话页内的键，
按它的口径要挂在有焦点的页面上（§8），与第 16 条那套"装在哪才生效"是同一类问题。

**2026-09-19 第二轮补记**：对「录制 / 整理 / 归档」三态逐屏回读了代码与稿（当时这台 Mac 锁屏，
没有真机走查），找出并修掉四处**功能不可达**：会议页四个状态都没有导出出口（记录找不到地方拿走）、
录制中打不开「标注说话人」（会中的第二条标注路径不存在）、三处文案承诺了"逐行标出来源"
（合流是一条流，`line.source` 只能是 `mixed`——见下一条）、归档页头缺「重新生成纪要」。
逐条实证与处置写在 `../2026-09-17-live-sessions/SESSIONS-SPEC.md` §12.1.5。

**新增第 19 条**：

| # | 未验证的事 | 影响 | 何时验 |
|---|---|---|---|
| 19 | **转录行的来源标签能不能真的逐行给出**：稿逐行画 `· 本机音频` / `· 麦克风`，而 `StreamMixer` 合完的那一块不再携带来源（`AudioSourceCoordinator.swift:342` 起），`line.source` 因此只能整行写 `mixed`。要真做，得让混音器按 40 ms 记"这一块哪一路更响"、按行的时间窗多数表决（`line.source` 的取值域不用改，仍是四值） | 会议回看时能不能分清"对方说的"与"屋里说的"；两边同时说话时的误判率 | 一次同时开麦克风 + 本机音频的会话（D11 裁决之后） |

**2026-09-19 第三轮补记（语音助手）**：同一套逐屏回读又补了三处**功能不可达**——
「继续这一轮」四处被承诺、一处按钮都没有（`SessionPreferences.prefill(from:)` 写好却无人调用），
记录的`重命名`与`从记录库移除`两颗按钮缺失（`setSessionTitle` / `removeSession` 两个后端也都没有调用点），
回看页头缺`导出…`与`新建对话`。逐条实证见 `../2026-09-17-live-sessions/SESSIONS-SPEC.md` §12.1.6。
它同时暴露一条**稿与规格互相矛盾**：稿的记录卡页脚说"不会新建一段记录"，规格 §15 的 E7 说是"新 session 行、
可以换人设"——按规格实现，稿侧待同步。

**2026-09-19 第四轮补记（语音场景的系统上下文）**：把语音对话契约从"没有"补成显式一层
（§5.5.1），并修掉一个**会被念出来的缺陷**——此前请求不带 `chat_template_kwargs`，本机 oMLX 默认
开 thinking，预算打满时整段思维链会进正文，被 TTS 逐字朗读（§13.2 有实测数字）。**新增第 20 条**：

| # | 未验证的事 | 影响 | 何时验 |
|---|---|---|---|
| 20 | **契约在第三方端点上的强度**：A/B 只在本机 oMLX 的 `Qwen3.6-35B-A3B-MLX-6bit` 上做过（带契约 0 处列表标记 / 不带 2 例各 3 处）；CLIProxyAPI 的 `gpt-5.6-luna` 只验了请求形状与缓存命中，**没验格式服从**，也没验"关 thinking 被拒后按退化形状发"的那条路 | 契约 + `spokenText` 清洗这两道防线在非 Qwen 模型上够不够；清洗只清排版语法，模型真要长篇讲，助手会照着念完 | 配到第三方端点之后，各跑 2–3 轮真实问答（含一次"用列表回答"的诱导） |

**新增第 21 条（2026-09-19，助手共享音频引擎）**：

| # | 未验证的事 | 影响 | 何时验 |
|---|---|---|---|
| 21 | `AudioEngineSession` 已在 input/output I/O node 同时调用 `setVoiceProcessingEnabled(true)`，但尚未在本机外放与耳机组合上量化 AEC 的 ERLE、双讲收敛、尾音残留与设备切换后的连续性 | 实时对讲是否真的比当前闭麦方案少回采；是否需要按路由禁用 duplex 或调整服务端 250 ms barge-in 冷却 | 真机声学验收：内置麦克风 + 内置扬声器、3.5 mm/USB/Bluetooth 耳机各至少一轮，分别测单讲、双讲、插拔设备 |

## 13. 来源与裁决

### 13.1 外部来源（全部 2026-09-18 抓取）

| # | 来源 | 用它证明了什么 |
|---|---|---|
| 1 | Apple · *Capturing system audio with Core Audio taps*（官方文档文章） | tap 作为 HAL aggregate device 的输入使用、可按进程/进程组限定范围、需 `NSAudioCaptureUsageDescription`、**第一次从带 tap 的 aggregate device 开始录制时**系统提示授权 |
| 2 | Apple · *Creating XPC services*（官方文档） | XPC Service 的服务名用其 bundle identifier，**由 launchd 在客户端连接时启动**——按需启动、空闲退出的形态由系统提供 |
| 3 | Apple · WWDC 2019 session 510（讲稿） | voice processing「用于 VoIP 类应用」、**manual rendering 不支持**、设在输入或输出任一节点；**要做回声消除，输入与输出节点会同时处于该模式**；source/sink 节点在实时约束下运行，**不应做阻塞调用** |
| 4 | Apple · HIG Privacy | 「只申请功能真正需要的数据；**不要在用户表现出兴趣之前就申请**」——R4 的外部同向依据 |
| 5 | OpenAI · voice-agents 指南 | 三种架构（chained pipeline 适用于"要检查/改写中间文本、组件可独立替换"）；按**单调时间轴**测首次可听响应、打断让位、不必要的静默 |
| 6 | OpenAI · realtime-vad 指南 | `server_vad` 与 `semantic_vad` 的差别；`create_response` / `interrupt_response` **只在 conversation 模式**可用——转写会话里 VAD 只负责切分 |
| 7 | OpenAI · prompt-caching 指南（本轮二次核） | 缓存复用要求**整段渲染前缀完全匹配**；`prompt_cache_options.mode = "explicit"` + content block 上的 `prompt_cache_breakpoint`；每请求最多 **4 次 cache write**；**顶层 `instructions` 不能带显式断点**（要放进 developer 消息的 `input_text`）；会改写前缀的设置包括 `tools` / `parallel_tool_calls` / `text.format` / `reasoning.effort` / `text.verbosity`；`cached_tokens` 可观测；**显式断点仅 GPT-5.6 及以后**，GPT-5.5 与更早只有隐式断点 + `prompt_cache_key`；GPT-6+ 可用 `configuration_update` 输入项在不动顶层设置的前提下改 effort |
| 8 | OpenAI · latency-optimization / background / conversation-state / structured-outputs / production-best-practices | 动态内容放 prompt 靠后；长任务用 `background: true` + 轮询；**background 下即使 `store=false`，响应数据仍临时落盘约 10 分钟**（显式 `store=true` 才在轮询期之后保留）；自管历史要保留整个 `output` 数组；`json_schema` + `strict`；密钥管理 |
| 9 | SQLite 官方文档 | WAL（读不阻塞写、写不阻塞读）、`VACUUM INTO`（在线一致快照，目标文件不能已存在）、FTS5 虚表模块 |
| 10 | 第三方（仅印证，不作依据） | `sindresorhus/KeyboardShortcuts`：Carbon 仍无现代替代且**不引发权限弹窗**；`pipecat-ai/pipecat`：AEC/降噪交给专门组件而非自研 |

### 13.2 本机实测（2026-09-18，macOS 26.6.2 · Xcode 27.0 · macOS 27 SDK）

**SDK 事实**：`AudioHardwareCreateProcessTap`（14.2+）· `CATapDescription.bundleIDs` 与
`processRestoreEnabled`（**26.0+**）· `CATapMuteBehavior` 默认 `CATapUnmuted` ·
`SCStreamConfiguration.capturesAudio`（13.0+）/ `captureMicrophone`（15.0+）· `voiceProcessingEnabled` /
`setVoiceProcessingEnabled`（在 `AVAudioIONode.h`）· `NSWindowStyleMaskNonactivatingPanel` /
`.canJoinAllSpaces` / `.fullScreenAuxiliary`（14.7+）· `NSFloatingWindowLevel` ·
`RegisterEventHotKey`（Carbon HIToolbox）· `NSVisualEffectMaterialHUDWindow`（10.14+）·
`glassEffect` / `GlassEffectContainer`（在 **SwiftUICore**，不在 SwiftUI）·
`AVAudioEngineConfigurationChangeNotification` 存在。

**本仓源码事实**：`src/speechrail/config/__init__.py:104` `realtime_max_sessions` 默认 **3**（区间 1–8）·
`:123` `realtime_vad_bargein_cooldown_ms` 默认 250（区间 0–5000）·
`src/speechrail/observability/rollup.py` 的指标名 `speechrail_realtime_active_sessions` /
`speechrail_realtime_sessions_total` / `speechrail_realtime_turn_commits_total` /
`speechrail_realtime_bargein_events_total` / `speechrail_governor_queue_rejections_total` /
`speechrail_worker_evictions_total` · `configs/speechrail.example.env:116` 写的是
`configs/speechrail.example.env` 同样示例为 `SPEECHRAIL_REALTIME_MAX_SESSIONS=3`；部署可显式覆盖，不能把覆盖值当作源码默认。

**Sona 侧读取的事实**（仅作为经验来源，不是本仓契约）：ADR-010（设备绑定 tap）、ADR-0013（按模式划分
VAD 所有权）、ADR-007（有界纪要生成）、ADR-0009（共享本地推理层，已 superseded）、ADR-0006（契约优先）、
`src/sona/interaction/echo.py`（文本级回声抑制）、`contracts/meeting-assistant/v1/schemas/event-resync-required.schema.json`、
`pyproject.toml` 的 `psycopg` 依赖。

**2026-09-19 语音场景实测（本机 oMLX `Qwen3.6-35B-A3B-MLX-6bit` @ `127.0.0.1:8000` ·
CLIProxyAPI @ `127.0.0.1:8317`）**——§5.5.1 的证据，全部是本次直连实测，不是文档推断：

- **思维链默认开着，而且会进正文**：不带 `chat_template_kwargs` 时，思维链先以
  `response.reasoning_summary_text.delta` 流出，`max_output_tokens` 打满后同一段内容又落进
  `response.output_text.delta`（同一次请求实测 **1111 字符**思维链进了正文）；带上
  `chat_template_kwargs.enable_thinking=false` 后同一个问题只回一句口语，正文里没有思维链。
- **`chat_template_kwargs` 不是通用参数**：CLIProxyAPI 对同一字段直接回
  **400 `{"detail":"Unsupported parameter: chat_template_kwargs"}`**（`gpt-5.6-luna`）。
  所以它只能"发一次、被拒就记下来、之后按不带它的形状发"，不能当成通用请求形状。
- **显式断点在 CLIProxyAPI 上真的命中**：同一请求连发三次，
  `usage.input_tokens_details.cached_tokens` 依次 **`0 → 1792 → 1792`**（`input_tokens` 2495）；
  `usage.attribution` 里人设块 1470、`tools` 296、`instructions` 26。**`instructions` 也在被缓存的
  渲染前缀里**——这就是它在会话内必须逐字节不变的原因（改一个字，命中区间从它之后整段失效）。
- **续轮不继承 `instructions`**：`store=true` + `previous_response_id` 能续对话内容
  （问"我姓什么"答"您姓王。"），但上一轮的 `instructions` 没生效（"每句以「喵」开头"未出现）。
- **契约 A/B**：同一个问题（"请用编号列表列出三种降噪耳机，每种加一句说明"，`enable_thinking=false`，
  300 token 预算），带契约 2/2 无编号也无加粗，不带契约 2/2 都是 `1. **…** / 2. **…** / 3. **…**`。
  带契约那两条里有一条以"抱歉，我无法使用列表格式进行回复"开头——**长度与格式压得住，机械客套
  只是被削弱、不是被消除**，所以界面上不能把这条契约说成"保证"。

### 13.3 与 v1.1.0 的实质差异

v1.1.0 是"分工初稿 + 用户裁决落地"。v2.0.0 通读了全部设计包、按本地与外部证据复核，实质变化是：

| 处 | v1.1.0 | v2.0.0 | 为什么改 |
|---|---|---|---|
| 结构 | 判据 3 条 + 分工表 + 三层设计 | 判据 **4 条**（新增 R4 设备规则）+ §5 客户端会话层展开到 13 个模块 | 用户裁决 R4 是一个**横切判据**，不是某条能力的细节 |
| 系统音频载体 | 未定 | **App 内 XPC 服务**（`T1`），并给出为什么它天然满足 R4 | Apple XPC 指南：launchd 按需启动——把"按需"交给系统而不是自己写生命周期 |
| AEC | 提到用系统 AEC | 写成**硬约束**：输入与输出必须同一 `AVAudioEngine`，并据此否决"把麦克风交给 Python" | WWDC 510 原话 + Sona 的 `echo.py` 作为反例代价 |
| 回声第二道防线 | 未限定 | 收敛为**一条极窄规则 + 强制留痕** | 避免把 Sona 的整套文本级抑制悄悄搬回来 |
| 格式 | 16k/24k 都可 | **线上唯一 16 kHz mono PCM16** | 契约不许首个 PCM 后改格式；固定 16k 后换设备/切模式不必重开会话 |
| 数据模型 | 只引用 §15 | 补 **三条加法**（唯一序号 / 纪要队列列 / 打字来源取值），已并入规格 §15.7 | 通读后发现三处"规格要求了但表上没地方放" |
| 借/拒对照 | 12 条，借与拒混在一张表里 | **10 借 + 7 拒**，每条带 Sona 出处与本仓落点 | 让"借的是判断、拒的是包袱"可逐条核对 |
| 验收 | 分散在相邻文档 | 新增 §11：设备五条 + 查库九问 + 延迟三量的**定义** | 让验收不必跨三份文档拼 |
| 未验证 | 10 条 | 15 条（新增：生效档位、按会话 VAD、端点缓存能力差异与 `configuration_update`、background 的临时保留、严格 schema、NSPanel 层级、`engine.start()` 阻塞） | 这些都是"照文档写会假通过"的点 |
| 前缀缓存 | 只写了"整段前缀完全匹配 + `instructions` 不能带显式断点" | 补齐**明确字段名与模型族差异**，并写明"人设锁是我们的结构选择、不是缓存收益的保证" | 第二轮核实文档后发现显式断点只在部分模型族可用；不写清会让人误以为换了端点也一样有收益 |
| 纪要隐私 | "默认 `store=false`" | 补上 **background 模式下仍会临时落盘约 10 分钟** | 这是文档明写的口径；漏掉就等于在界面上做了不成立的隐私承诺 |
| 存储与重装 | 未涉及（只在 §15.4 列了"不落库的东西"） | 新增 **§6.6 存储分区与重装契约**：数据区 / 可重建区 / 模型区，以及音色路径、备份范围、Time Machine 排除 | "记录是资产"只在"重装不丢"成立时才有意义；而当时音色既不在备份里也不在卸载面里 |

**没有变**的：R1–R3 三条判据、服务不动的结论（R2 + 红线）、三条能力的终态定义、SQLite 的落点与
迁移策略、四类中断的处置。

### 13.4 技术裁决（`T` 系列，已全部裁定）

**用户 2026-09-18「全面采纳」，本版无待裁决项。** 编号与规格 §13 的 `D` 系列**不共用**：
`D` 是产品裁决（界面、口径、数据模型取舍），`T` 是本方案提出的**技术裁决**。规格 §13.2 的 D11 / D12
与本表无关；规格 §13.3 是同一组结论的产品侧登记。

| # | 结论 | 执行时点 | 采纳的理由（一句话） |
|---|---|---|---|
| **T1** | 系统音频采集用 **App 内 XPC service**（§3.2） | 阶段 6 | 唯一的形态同时满足三件事：TCC 归属宿主 App、launchd 按需启动、崩溃隔离 |
| **T2** | 跨客户端运行态可见性 **v1 不做**，先复用 `/metrics` | 不执行 | 它不阻塞任何阶段；先看真实困惑再决定要不要加只读端点 |
| **T3** | `AGENTS.md:33` 改写为「只在会话模块与音色克隆页采集；播放只用于会话与试听」 | **阶段 9**（与实现一起，不提前） | 现在就改会让仓库指令描述一个还不存在的能力；阶段 9 改则文档与代码同时到位 |
| **T4** | 端侧模型兜底（`FoundationModels`）**v1 不做** | 不执行 | 见 §5.12 末尾：它会分裂出第二套 prompt 与人设语义 |
| **T5** | §6.3 的三条 schema 加法 **并入规格 §15** | **已完成**（规格 v1.6.0 §15.7 R2） | schema 尚未实现，加法无迁移成本；不并入则阶段 2 会在三处与规格不符 |
| **T6** | 存储分区与重装契约（§6.6） | **分批**：目录契约已写进 `docs/operations/runtime-deployment.md`；音色搬迁、数据区备份入口、Time Machine 排除三项待实现 | 桌面 App 的用户资产只有"重装不丢"才成立；音色现在既不在备份里也不在卸载面里 |

**T3 为什么不在本轮执行**：`AGENTS.md:33` 今天写的是「不采集/播放音频」，而 `macos/SpeechRailApp`
里确实还没有会话采集代码。此刻改写会让仓库指令与实现相反地不成立——下一轮做阶段 1–3 的会话在实现时
一并改，那才是它成立的那一刻。这条差距已经写进阶段 9，不会被漏掉。
