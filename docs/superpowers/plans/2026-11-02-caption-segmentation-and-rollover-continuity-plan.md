---
title: "实时字幕软水位寻谷切段与跨段无缝续接优化方案"
status: completed
version: "1.0.0"
date: 2026-11-02
author: "SpeechRail Team"
---

# 实时字幕软水位寻谷切段与跨段无缝续接优化方案

## 1. 问题诊断与根因总结

在影视解说、纪录片旁白或连续快语速口播（约 6.5–7 字/秒、停顿短于 650 ms 或带背景音乐）场景下，实时字幕浮层出现「词中强制断句并补句号」的严重伪影：

> 1. `…而这就是今天要说的《霍比特人》一意外。`
> 2. `之旅故事要从中土北面的孤山说起…这里曾经是中土大陆最重要的贸易。`
> 3. `中心之一，无数商队从四面八方赶来…而在河谷镇的。`

### 1.1 服务端根因：8 秒机械字节硬切（`budget_rollover`）+ 模型 EOF 自动补句号
1. **8 秒硬上限**：`ASRScenePreset.swift` 将 `.caption` 的 `maxSegment` 设为 `8_000` ms，`silenceDurationMilliseconds` 设为 `650` ms。当连续语音中停顿不足 650 ms 时，`realtime_asr.py` 的 `_feed_admitted_pcm` 每满 8.000 秒（约 50–56 汉字）即触发 `commit(reason="rollover")`，直接从词组或助词中间一刀切断。
2. **断口伪句号**：`qwen3_worker.py` 在 `finish_streaming` 中将每段被切开的 8 秒音频视作独立完整音频解码，ASR 模型在音频 EOF 处自动补上终结句号 `。`。

### 1.2 客户端根因：`CaptionParagraphAssembler` 的四重拦截
1. **丢失 `budget_rollover` 信号**：服务端通过 `speechrail.transcription.segment_closed` 下发了 `reason: "budget_rollover"`，且 `TranscriptPreviewLedger` 已保存在 `Boundary.reason` 中，但 `CaptionSession.acceptTranscript` 入队时未将 `closeReason` 传入 `TranscriptPersistenceQueue.Command`、`CaptionSession.Line` 和 `CaptionParagraph`。
2. **200 ms 宽限期提前关门封口**：`CaptionSession.registerParagraphLineInMemory` 要求 `paragraphs[index].id == openParagraphID` 才允许合并。第 1 段在 `t = 8s` 定稿后因句尾带 `。`，仅等 `200 ms` 即调用 `flushOpenParagraph()` 将 `openParagraphID` 置为 `nil`；而第 2 段在数秒后才定稿到达，此时第 1 段早已封口，彻底失去合并机会。
3. **12 秒时长上限过短**：`CaptionParagraphAssembler.maximumDuration = 12` 秒，两段 8 秒（或更长）的连续段合计超过 12 秒，被 `shouldMerge` 直接拒绝。
4. **伪句号拦截与中文悬空词尾缺失**：由于前后两段都被模型补了 `。`，`bothTerminal` 为 `true`，导致哪怕音频零间隔（`gap == 0`）也无法获得紧邻加分；同时 `strongIncompleteEnding` 缺少中文高频悬空结构助词/介词（`的`、`之`、`在`、`从`、`把`、`被`、`对`、`向` 等）及书名号后悬空数词（如 `《霍比特人》一`）。

---

## 2. 工业界最佳实践与架构设计

结合流式语音识别（SimulStreaming / Whisper-Streaming）与广播级实时字幕分割（Soft/Hard Watermark Valley-Seeking Endpointing）的最佳实践，采用**「服务端软水位微气口寻谷切段 + 客户端 Rollover 跨段原位续接」**双层协同架构：

```
[音频流 16kHz]
      │
      ▼
┌─────────────────────────────────────────────────────────────┐
│ 第一层：服务端 SpeechAdmission 软硬双水位寻谷切段            │
│  • 常规区 (0 ~ 7.5s)：维持 650ms (21帧) 静音门限，防句中误切 │
│  • 软水位寻谷区 (7.5s ~ 14s)：                              │
│      - 动态放宽退出阈值，捕捉微弱换气谷底                    │
│      - 微气口门限降至 160ms (5帧)                            │
│      - 若最新 partial 末尾已带标点 (，。！？；)，降至 96ms   │
│  • 硬水位兜底 (14s)：极端无气口时触发 budget_rollover        │
└─────────────────────────────────────────────────────────────┘
      │
      ▼ (segment_closed: vad / budget_rollover + completed)
┌─────────────────────────────────────────────────────────────┐
│ 第二层：客户端 CaptionSession + CaptionParagraph 无缝续接    │
│  • 完整透传 closeReason (.vad / .clientCommit / .budgetRollover)│
│  • 解耦「首次翻译触发」与「段落续接窗口」：                  │
│      - 200ms~750ms 到期照常触发首次翻译，保证译文低延迟上屏  │
│      - 下一行到达时若满足 shouldMerge，仍可并入末段并重翻    │
│  • 断口伪句号剥离：trimTrailingPunctuation 抹除段内伪句号    │
│  • 中文语法启发式增强：覆盖助词/介词/书名号数词与零间隔续接  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 具体实施方案

### 3.1 服务端：软水位微气口寻谷切段（`speech_admission.py` & `realtime_asr.py`）

1. **`SpeechAdmission` 扩展软水位寻谷能力（`src/speechrail/realtime/speech_admission.py`）**：
   - 新增可选构造参数（默认 `None`，保持现有默认调用 100% 兼容）：
     - `soft_max_samples: int | None = None`：进入软水位寻谷区的连续语音采样数阈值；
     - `soft_stop_frames: int | None = None`：软水位区内的微停顿闭合帧数（如 `5` 帧 = `160 ms`）；
     - `punctuation_stop_frames: int | None = None`：当进入软水位区且最新识别预览末尾已处于标点边界时的闭合帧数（如 `3` 帧 = `96 ms`）。
   - 新增状态同步方法：
     - `advance_segment_start(sample_offset: int)`：当外层发生 `budget_rollover` 时推进当前段起点采样游标，使下一段重新从 0 计算软水位时长，并在闭合时产出准确的当前段范围；
     - `set_punctuation_boundary_hint(at_boundary: bool)`：由 `RealtimeAsrOwner` 在收到 `partial` 时根据末尾标点（`，。！？；：、,.!?;:`）更新。
   - 在 `_process_frame` 中：
     - 当活跃段长 `frame_end_sample - self._current_utterance_start_sample >= self._soft_max_samples` 时，动态采用 `_effective_stop_frames()`（优先 `punctuation_stop_frames`，否则 `soft_stop_frames`），并将软水位区内的退出概率阈值平滑上移至 `(threshold + stop_threshold) / 2`（例如从 `0.35` 提升至 `0.425`），以便在背景音乐（BGM）垫音下也能敏锐捕捉解说员的微弱换气谷底。

2. **`RealtimeAsrOwner` 接线软水位与标点提示（`src/speechrail/application/realtime_asr.py`）**：
   - 在 `prepare_endpointing` 中，当 `effective_segment_ms() >= 8_000` 且 `stop_frames > 5` 时，为 `SpeechAdmission` 配置：
     - `soft_max_samples = int(min(8_000, max(5_000, int(effective_ms * 0.55))) * 16)`；
     - `soft_stop_frames = min(stop_frames, 5)`（160 ms）；
     - `punctuation_stop_frames = min(stop_frames, 3)`（96 ms）。
   - 在 `_drain_asr_events` 收到 `partial` 时，检查 `current_text` 末尾是否为分句/句末标点，实时调用 `self._speech_admission.set_punctuation_boundary_hint(...)`。
   - 在 `_commit_audio_once` 发生 `reason == "rollover"` 时，调用 `self._speech_admission.advance_segment_start(self._item_end_kernel)` 重置当前段计时起点与标点提示。

### 3.2 客户端：预设调优与跨段原位续接（`ASRScenePreset.swift`、`CaptionParagraph.swift`、`CaptionSession.swift`）

1. **上调 `.caption` 最大段长（`ASRScenePreset.swift`）**：
   - 将 `.caption` 的 `maxSegment` 从 `8_000` ms 提升至 `14_000` ms（预览间隔保持 `500` ms，静音窗口保持 `650` ms）。结合服务端 7.7s 软水位寻谷，绝大多数长句会在 7.7s ~ 14s 之间的第一个分句气口自然闭合。

2. **全链路透传 `closeReason`（`AssistantInputPersistenceQueue.swift`、`CaptionSession.swift`、`CaptionParagraph.swift`）**：
   - 在 `TranscriptPersistenceQueue.Command`、`CaptionSession.Line` 中新增可选字段 `closeReason: TranscriptPreviewLedger.SegmentCloseReason? = nil`；
   - 在 `CaptionParagraph` 中记录 `lastLineCloseReason: TranscriptPreviewLedger.SegmentCloseReason?`，每次 `append` 更新为最新一行的 `closeReason`。

3. **增强 `CaptionParagraphAssembler` 语义与声学合并判据（`CaptionParagraph.swift`）**：
   - 将 `maximumDuration` 从 `12` 秒提升至 `28` 秒，允许合并 2～3 段连续快语速长句；
   - **识别被动截断与零间隔紧贴**：
     - 当 `paragraph.lastLineCloseReason == .budgetRollover` 时，说明上一行末尾句号是硬截断伪影，直接赋予 `+4` 分，且不将上一行视为真实 `endsWithTerminalPunctuation`（跳过 `bothTerminal` 拦截）；
     - 当两行存在真实时间码（`paragraph.end != nil && line.start != nil`）且声学间隔 `gap <= 0.12` 秒（≤ 120 ms 零停顿紧贴），且上一行带有未完成特征或下一行紧接词尾时，同样跳过伪句号拦截。
   - **扩充中文未完成词尾与续接词头**：
     - 在 `strongIncompleteEnding` 中补充中文高频悬空助词、介词与连词：`的`、`地`、`得`、`之`、`在`、`从`、`向`、`往`、`把`、`被`、`对`、`于`、`由`、`给`、`与`、`和`、`跟`、`同`、`比`、`为`、`着`，以及书名号/引号后紧跟孤立数词或连接符（如 `《霍比特人》一`、`》一意外`）；
     - 在 `continuationStart` 中补充中文常见被切开的复合词尾/后置成分开头：`之旅`、`之一`、`之中`、`之上`、`之下`、`之间`、`之后`、`之前`、`中心`、`方面`、`部分`、`时候`、`地方`、`过程`。

4. **解除「200 ms 提前封口」对后续行合并的阻断（`CaptionSession.swift`）**：
   - 在 `registerParagraphLineInMemory` 中：不再要求 `paragraphs[index].id == openParagraphID` 才能合并！只要 `paragraphAssemblyEnabled` 开启，且最后一段 `paragraphs[index]` 与新到达的 `line` 满足 `CaptionParagraphAssembler.shouldMerge(paragraphs[index], line, observedAt: observedAt)`，即允许并入最后一段：
     - 自动通过 `CaptionParagraph.append` 的 `trimTrailingPunctuation` 消掉前一行末尾的伪句号（如 `…《霍比特人》一意外。` + `之旅故事…最重要的贸易。` + `中心之一…` $\rightarrow$ `…《霍比特人》一意外之旅故事…最重要的贸易中心之一…`）；
     - 若该段此前已在 200 ms 宽限期满时触发过单行翻译，并入新行后重新将该段设为 `openParagraphID` 并按新文本调度完整段落重翻，确保双语模式下译文同步更新为完整句译文。

---

## 4. 验证计划

1. **Python 服务端单元测试**：
   - 运行 `pytest tests/test_speech_admission.py tests/test_realtime_admission_commits.py`；
   - 新增测试用例验证：
     - 软水位前（< 7.5s）短停顿（5 帧 = 160ms）不会误切；
     - 超过软水位后（≥ 7.5s），5 帧微气口或带标点提示的 3 帧微气口立即触发 `end` 闭合，避免走到硬 `budget_rollover`；
     - 触发 `advance_segment_start` 后软水位起点正确重置。
2. **Swift 客户端单元测试**：
   - 更新 `ASRScenePresetTests.swift` 并运行 `CaptionSessionLifecycleTests`；
   - 新增针对截图真实案例（《霍比特人》三段连续硬切字幕）的回归测试：验证含伪句号的 `.budgetRollover` 断句以及跨越 200ms 宽限期后到达的后续断句均能无缝合并为单一段落，断口伪句号被剥离，且已触发翻译的段落能自动重新翻译完整段落。
