---
title: "SpeechRail macOS App AI 提词器"
status: active
version: "0.1.0"
date: 2026-09-20
---

# SpeechRail macOS App AI 提词器

AI 提词器是 macOS App 内的直播准备与跟读能力。它面向主播本人：用户在独立舞台窗口中看到稿件和跟读状态，直播软件只应采集摄像头或目标内容窗口，不采集提词器舞台或整屏。

## 产品边界

- 输入为用户粘贴的纯文本，或导入 `TXT` / `Markdown` 文件。
- AI 只在用户点击「AI 整理稿件」时调用一次；返回结果必须是可追溯到原稿 UTF-16 区间的 `teleprompter.analysis.v1` JSON。
- 用户必须先审阅并接受 AI 建议，活动版本才会用于跟读；无法使用 AI 时可使用本地确定性分段。
- 运行时复用现有 `MicrophoneCapture`、`RealtimeASRClient` 和 `SessionCoordinator`，但不创建 `SessionStore` 会话行，也不保存 PCM、摄像头画面、直播画面或完整 ASR 文本。
- 不包含 TTS、摄像头采集、直播推流、全局提词热键或云端稿件同步。

## 用户旅程

1. 从侧边栏打开「AI 提词器」，新建、粘贴或导入稿件。
2. 主动点击 AI 整理，逐段检查建议；AI 不能扩写事实，用户可编辑段落。
3. 点击「接受并生成活动版本」，稿件进入可跟读状态；也可直接采用纯文本分段。
4. 调整独立舞台的字号、透明度和显示段数，打开舞台并开始跟读。
5. 舞台接收 Realtime ASR 的 `partial` 作为预览，接收 `completed` 后只在高置信且相邻段落上前进。
6. 置信度不足时进入「请确认当前位置」，用户用方向键或按钮手动接管；暂停、恢复和结束都可随时执行。
7. 直播软件选择摄像头或目标内容窗口采集。提词器舞台使用 `NSPanel.sharingType = .none` 作为窗口级防误采集措施，但仍要求用户不要做整屏采集。

## 模块边界

| 模块 | 责任 |
|---|---|
| `TeleprompterDomain.swift` | 稿件、版本、段落、暂停提示、运行状态与对齐结果类型 |
| `TeleprompterNormalizer.swift` / `TeleprompterSegmenter.swift` | 中英文归一化、填充词过滤、确定性分段和 UTF-16 原文区间 |
| `TeleprompterAnalysis.swift` | AI prompt、严格 JSON decoder 和可注入 AI client |
| `TeleprompterStore.swift` | Application Support 下单稿件 JSON、原子保存、运行进度和 Markdown 导出 |
| `TeleprompterFollowController.swift` | partial/completed 事件与跟读、暂停、手动接管状态机 |
| `TeleprompterSession.swift` | MainActor 会话编排、服务/麦克风门禁、Realtime 生命周期和失败降级 |
| `TeleprompterView.swift` | 准备页、稿件编辑、AI 审阅和舞台设置 |
| `TeleprompterStageWindow.swift` / `TeleprompterStageView.swift` | 独立浮动舞台窗口、键盘控制和可访问状态反馈 |

`SessionCoordinator` 只负责设备占用。提词器调用 `sessionDidStartRecording(id: nil)`，因此可参与共享麦克风占用而不写入会话记录库；停止时由 coordinator 释放占用，提词器自己的 `TeleprompterRunState` 只保存稿件进度。

## AI 结果契约

AI 返回的顶层结构固定为：

```json
{
  "schema_version": "teleprompter.analysis.v1",
  "segments": [
    {
      "id": "segment-1",
      "source_start": 0,
      "source_end": 12,
      "text": "必须来自原稿对应区间",
      "keywords": ["关键词"],
      "match_phrases": ["可接受的口语表达"],
      "pause_hint": "short"
    }
  ]
}
```

Decoder 会拒绝 schema 版本错误、空段落、无效/重叠区间、无法在原稿中复原的 `text` 和未知的 `pause_hint`。未知字段可忽略。AI 调用使用现有 Responses-compatible `LLMProvider`，密钥仍只从 Keychain 读取，不进入稿件 JSON、日志或 prompt 之外的持久化数据。

## 跟读与安全降级

对齐器只搜索当前段和有限 lookahead；单次 completed 最多前进一段。候选置信度不足、相邻候选差距不足或出现跨段跳跃时，保持当前位置并进入不确定态，不自动跳过稿件。用户的暂停、手动上一段/下一段和「回到当前段」会清空旧 partial，避免迟到事件覆盖手动选择。

Realtime 连接失败、服务 busy、麦克风未授权或服务未 ready 时，停止采集、关闭连接并进入手动提词；最后一段位置保留在本机运行状态中。跟读过程中不会调用 LLM，不会播放音频，也不会启动摄像头。

## 设计 token 约束

所有提词器新增尺寸、字号、行距、透明度范围、窗口 autosave 名称均位于 `SpeechRailDesignTokens.Teleprompter`。页面复用现有 `Typography`、`Spacing`、`Color`、`Corner`、`speechRailSurface` 和系统按钮样式，不在视图中新增颜色、圆角或散落视觉常量。窗口以 macOS 26+ 的系统 `NSPanel`、`ultraThinMaterial` 和原生键盘快捷键为基线。

## 验收矩阵

| 维度 | 已验证方式 | 当前结论 |
|---|---|---|
| 归一化、分段、UTF-16 区间 | `TeleprompterNormalizerTests`、`TeleprompterAlignerTests` | 通过 |
| AI schema、原文追溯、错误拒绝 | `TeleprompterAnalysisTests` | 通过 |
| 单稿保存、加载、进度、导出 | `TeleprompterStoreTests` | 通过 |
| partial/completed、暂停、手动接管、不确定态 | `TeleprompterFollowControllerTests` | 通过 |
| Swift 6 / Xcode App 编译 | `scripts/macos_app_build.sh --configuration Debug` | 通过，2026-09-20 |
| 真实麦克风、Realtime 服务、OBS/直播软件、窗口可见性 | 需要用户明确授权的桌面/UI/真机验收 | 本轮未执行 |

当前功能工作量估算为 9–13.5 人日：核心领域与测试 2–3 日，存储/AI 适配 1.5–2 日，会话接线 2–3 日，舞台窗口与准备页 2–3 日，集成/回归/文档 1–1.5 日。若加入真实直播软件适配、屏幕采集白名单或多平台兼容，应另立范围与估算。
