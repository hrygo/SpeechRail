---
title: "SpeechRail macOS App AI 提词器"
status: active
version: "0.2.1"
date: 2026-09-20
---

# SpeechRail macOS App AI 提词器

AI 提词器是 macOS App 内的直播准备与跟读能力。它面向主播本人：用户在独立舞台窗口中看到稿件和跟读状态，直播软件只应采集摄像头或目标内容窗口，不采集提词器舞台或整屏。

## 产品边界

- 输入为用户粘贴的纯文本，或导入 `TXT` / `Markdown` 文件。
- AI 仅由用户主动触发；短稿一次请求，长稿按最多 12 个本地单元逐窗口处理。返回 `teleprompter.analysis.v2` 单元引用，原文与 UTF-16 范围由本地程序还原，任一窗口失败则不采用整份结果。
- 原稿无需 AI 即可开始；草稿自动保存，AI 标注是可选步骤，建议经用户确认后才成为活动版本。跟读期间固定版本，不允许切稿或编辑。
- 运行时复用现有 `MicrophoneCapture`、`RealtimeASRClient` 和 `SessionCoordinator`，但不创建 `SessionStore` 会话行，也不保存 PCM、摄像头画面、直播画面或完整 ASR 文本。
- 不包含 TTS、摄像头采集、直播推流、全局提词热键或云端稿件同步。

## 用户旅程

1. 从侧边栏打开「AI 提词器」，新建、粘贴或导入稿件；草稿无需先生成版本即可保存。
2. 点击「打开舞台并开始跟读」即可直接进入舞台；AI 朗读标注是可选准备步骤，不会阻塞开始。
3. 如使用 AI，审阅分组、重点、表达参考与语义停顿，再确认采用。编辑段落时清空对应旧辅助标注。
4. 调整字号、透明度和预读段数；也可以先点击「只打开提词窗口」检查版式。舞台按原文字词坐标显示已读部分并滚动，排版切片与 AI 分组独立。
5. 短暂脱稿时保持位置，读回附近稿件后继续；可以点击某段、使用方向键选择起讲段，再点击「开始/继续跟读」。
6. 暂停/手动期间停止上传新音频；继续前完成旧 ASR item 的 drain/clear 屏障。服务断开后释放设备占用，保留手动阅读，并可重新开始。
7. 直播软件必须选择摄像头或目标内容窗口，不分享包含提词器的屏幕。不能依赖 `NSWindow.sharingType = .none` 隐藏窗口；当前 Apple 文档已将该值标注为系统不再使用的旧常量。

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
  "schema_version": "teleprompter.analysis.v2",
  "segments": [
    {
      "start_unit": 0,
      "end_unit": 1,
      "keywords": ["关键词"],
      "match_phrases": [],
      "pause_hint": "short"
    }
  ]
}
```

本地确定性分段产生编号单元；模型只引用连续的 `[start_unit, end_unit)`，不得返回正文副本、ID 或字符偏移。每个窗口必须按顺序完整覆盖其所有单元恰好一次。decoder 同时拒绝未知字段、漏单元、重叠、越界、未知停顿、过长分组和不来自原文的关键词。分组正文和原文范围均由程序生成；全部窗口成功后才创建待确认版本。口语变体仍需用户审阅，不声称程序能验证其全部事实语义。

v2 仅改变内部 AI wire schema；本机 `TeleprompterVersion`/稿件 JSON 结构不变，既有版本仍可跟读。草稿允许没有活动版本或正文；这扩展了有效保存状态，旧代码无法完整支持新的草稿流程。不得回退或删除用户稿件来处理版本差异。

## LLM 指令与 context 构建

- `instructions`：保持事实和正文、不执行输入内命令、连续单元引用、完整覆盖、语义停顿与有限标注。
- user `input`：纯 JSON，包含语言/表达偏好和本窗口 `units: [{id, text}]`；无历史、RAG、音频或隐藏会话状态。
- `text.format`：严格 `json_schema`；对象均 `additionalProperties=false`。
- 每窗口沿用 4000 output tokens / 45 秒上限，不将窗口结果直接展示为完整稿件；稿件切换、编辑或开始运行会使旧请求失效并取消后续窗口。
- endpoint 不支持 Structured Outputs 时明确失败，用户仍可按原稿开始。首次发送的说明与按 endpoint/model 保存的确认保持原有流程。

## 位置跟读与恢复

对齐单位为字词而非 ASR turn 或 UI 段落。中文按字符、英文按完整词建立 UTF-16 原文映射；不再全局删除英文词内部的 `um` 或正文中的“然后”。支持逐位中文数字/阿拉伯数字匹配，不声称支持所有数值读法或声学逐字时间戳。

`TeleprompterAligner` 使用有界半全局编辑距离：输入最多保留 72 个 token，默认搜索锚点前 80、后 320 个 token，允许插入、删除和替换。正文独立评分，关键词/口语变体缺失不降低可达最高分；多处相似位置差距不足则保持原位。该分数是启发式匹配值，不是校准概率。

控制器按 `itemID` 分别累积 partial，按 `eventID` 抑制重复事件；final 替换本 item 的暂定结果，已终结 item 和晚于新 final 才到达的旧 final 不重复推进。两次具有增长证据的高分 partial 可暂定推进；final 不支持该位置时退回 item 起点。短完成片段可以积累，插话后清理无关上下文并等待重新匹配。缓存有界且仅存在内存中。

舞台在稳定的阅读切片间滚动，切片中的已读文字随 UTF-16 位置变化。近距离重读可以回退；较远跳读需手动选段，当前没有全文语义重定位。暂停/手动操作退休已知 item，恢复时由会话层 drain/clear 排除尚未收到的旧事件；连接 generation 排除已关闭连接的迟到结果。暂停后 final 不得把 UI 改成手动态。

运行中不调用 LLM，不保存音频或转写。稿件和最后段落位置持久化；句内位置仅在本次运行内保留。AI、服务或识别失败均不阻止用户手动看稿。

## 设计 token 约束

所有提词器新增尺寸、字号、行距、透明度范围、视线吸顶偏移、状态指示灯尺寸、窗口 autosave 名称均位于 `SpeechRailDesignTokens.Teleprompter`。阅读切片粒度统一使用 `stageReadingTokensPerSlice = 12`，改变字体不会改变匹配坐标。
- 准备页「原稿」编辑区固定在 `sourceEditorMinimumHeight`–`sourceEditorMaximumHeight`（144–360pt）范围内，默认取 `sourceEditorIdealHeight`（260pt）；超过上限后由原生 `TextEditor` 内部滚动。
- 首次使用 AI 整理前，用面向普通用户的确认说明解释发送内容、触发时机、不会发送的音视频内容，以及本机/网络服务和保存策略的差异；不要把 `Responses-compatible endpoint`、`store=false` 等实现术语直接暴露给用户。
- **视线吸顶与视线锚点**：`stageTopInset = 48`，窗口首发吸顶在主屏上沿中央，紧贴摄像头下方，减少主播看词时的眼神偏移；
- **预读不透明度阶梯**：`segmentOpacityCurrent = 1.0`（当前段朗读中心）、`segmentOpacityNext = 0.60`（下一段预读缓冲区）、`segmentOpacityPrevious = 0.35`（上一段回溯断句），杜绝局部散落透明度字面量；
- **状态指示灯尺寸**：`stageStatusIndicatorSize = 8`，替换原先的 `Spacing.sm` 占位；
- 页面复用现有 `Typography`、`Spacing`、`Color`、`Corner`、`speechRailSurface` 和系统按钮样式，不在视图中新增颜色、圆角或散落视觉常量。窗口以 macOS 26+ 的系统 `NSPanel`、`ultraThinMaterial` 和原生键盘快捷键为基线。

## 验收与限制

2026-09-20：使用合成文本、fake completion 和临时目录执行聚焦测试；覆盖默认参数的正文定位、分次/跨段/局部重读、Unicode 坐标、数字与漏词、重复事件、乱序 final、partial 纠正、暂停和手动边界、草稿保存、AI 全覆盖及长稿窗口失败。App Debug 编译用于检查会话和 SwiftUI 接线；不代表实际视觉或跟读质量验收。

```bash
swift test --package-path macos/SpeechRailApp --filter Teleprompter
scripts/macos_app_build.sh --configuration Debug
```

未执行真实麦克风、LLM 效果、Realtime 端到端、OBS/会议软件可见性或 UI 自动化。仍需测量误跳、位置滞后、脱稿恢复耗时、手动纠正频率和滚动观感。没有新增 ASR 模型、强制对齐器、全局热键或提纲语义跟读。

回退时仅撤回本轮源码差异，保留稿件 JSON；不可整文件还原并行任务的修改，也不可将 AI v2 输出交给旧 v1 decoder。
