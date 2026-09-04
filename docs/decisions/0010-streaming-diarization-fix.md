# ADR-0010：修复流式路径说话人分离（segments 硬编码空 + Sortformer 解析 bug）

## Status

Accepted — 2026-09-04（流式分人修复已实现并验证，工作交接转为落地记录）

## Context

`sona` 会议助手与实时字幕通过 SpeechRail OpenAI Realtime `/v1/realtime` 消费
流式 ASR。会议助手需要在**页面实时呈现多说话人标签**（Speaker 1/2/3，会话内匿名
label），并在最终纪要中保持高精度分人。

实测发现两条独立缺陷组合导致流式分人**永远不生效**，且会议侧表现为「说话人恒为
`speaker:0`、历史被最新句覆盖」：

### 缺陷 1：流式 `completed` 事件硬编码 `segments: []`

链路根因（唯一瓶颈，位于 SpeechRail 内部）：

1. `src/speechrail/backends/qwen3_worker.py:434` —— `_handle_commit()` 发送
   `kind="completed"` 时**硬编码 `"segments": []`**，而 `finish_streaming()` 只返回
   `(text, language)` 二元组（见 `Qwen3Engine.finish_streaming`，line ~685）。
2. `src/speechrail/backends/qwen3_streaming.py:387-394` —— `_to_event()` 读取
   `frame["segments"]` 构造 `StreamingAsrEvent.completed.segments`；因上游恒为空，
   `segments` 永远为 `()`。
3. `src/speechrail/application/realtime_openai.py:426-451` —— WS 应用层：
   ```python
   segments = event.segments
   if self._diarization is not None and segments:
       segments = await self._diarization.annotate(segments)
       ...
       await self._send(transcription_segment(..., speaker=segment.speaker, ...))
   ```
   `annotate()` 与带 `speaker` 的 `transcription_segment` **只在 `segments` 非空时触发**。
   因 `segments` 恒为 `()`，`annotate` 从不执行，带 `speaker` 的 segment 事件
   从不发出。

**结论**：WS 应用层的流式分人机制（`DiarizationCoordinator.annotate` → 带 speaker
的 `transcription_segment`）本身完整可用，唯一断点是 `qwen3_worker._handle_commit`
不下发真实 segments。

### 缺陷 2：`_parse_activities` 解析 Sortformer 输出失败（已在工作区修复，随本 PR 提交）

`src/speechrail/backends/nemo_sortformer.py` 旧实现（`ast.literal_eval`）：

```python
start, end, speaker = ast.literal_eval(encoded)
```

假定 Sortformer `.diarize()` 返回 Python 元组字面量（如 `[0.0, 2.32, 0]`），但
**实测 Sortformer 返回的是空格分隔字符串**，例如：

```
"0.000 2.320 speaker_0"   "4.240 8.070 speaker_0"   "2.560 4.160 speaker_1"
```

`ast.literal_eval("0.000 2.320 speaker_0")` 抛 `SyntaxError` → 被捕获后
`raise DiarizationError("diarization returned an invalid activity", code="diarization_invalid_output")`
→ 非流式 `/v1/audio/transcriptions` + `gpt-4o-transcribe-diarize` 稳定返回 **HTTP 502**。

该 bug 已在本机运行时 site-packages 实测修复（新增 `_parse_activity_token` /
`_speaker_index` 支持空格分隔）并通过真实双音色对话验证，输出词级 `spk_01/spk_02`
正确分离。**该修复已在工作区落地（`_parse_activity_token` / `_speaker_index`，含
`tests/test_nemo_sortformer.py`），随本 PR 提交，无需再回填。**

## Decision

### 1. 让流式 `completed` 携带真实分段（核心）

流式路径必须能不依赖 `finish_streaming` 的文本结果，为 commit 时已累积的会话音频
产出**有词级时间戳的 segments**，供 WS 层 `annotate()` 消费。

推荐实现（按优先级）：

- **方案 A（首选，已实现）— 流式结束时对缓冲区做一次 forced alignment**：在
  `Qwen3Engine.open_session` 时同步维护该 session 的**有界 PCM 缓冲**
  （`_align_buffers`，以 `MAX_PCM_BYTES` 为界），`_handle_commit` 在
  `want_segments=True` 且 `text` 非空时调用 `Qwen3Engine.align_session_audio(session_id)`
  （弹出缓冲 → 复用 `Qwen3Engine.transcribe(..., include_timestamps=True)` → `_segments` →
  `_to_streaming_segments`）产出词级时戳，构造 `segments` 随 `completed` 返回。
  词级源复用批量 `transcribe`（`return_timestamps=True`），即 `/v1/audio/transcriptions`
  已长期运行的同一路径，**无需单独的 forced aligner 模型或额外准入门禁**。
  **注意单位换算**：批量 `_segments(result)` 产出 `{text, start, end}`（浮点秒），
  `qwen3_streaming._segments` 解析 `{text, start_ms, end_ms}`（毫秒），必须经
  `_to_streaming_segments` 换算，否则读到 `start_ms=0`（字段名不匹配走 `or 0`）。
- **方案 B（未采纳的兜底）— `finish_streaming` 返回三元组 + 区间伪分段**：扩展
  `finish_streaming` 返回 `(text, language, segments)`，在 worker 端把 `segments`
  填入 `completed` frame，对齐模型/延迟受限时用**区间伪分段**（`{text, start_ms, end_ms}`）
  使 WS 层 `annotate()` 有非空 segments。
  **本实现未采用方案 B**：单个跨整窗的伪分段的 `_assign` 会与所有 activities 重叠、
  合并出单一声源归属（近似等于伪造单一 speaker），违背 ADR-0007 的 fail-closed 原则；
  实际改为**对齐失败时 fail-closed 返回空 segments**（`align_session_audio` 捕获异常
  返回 `[]`），该 commit 跳过 diarization，而非用不可信的伪分段替代。

无论 A/B，`completed` frame 的 `segments` 结构须保持
`[{text, start_ms, end_ms}]`（`qwen3_streaming._segments` 已按此解析）。

### 2. 落盘 `_parse_activities` 解析修复（已实现，随本 PR 提交）

已把实测可用的 `_parse_activity_token` / `_speaker_index` 支持合并进
`nemo_sortformer.py`，替换 `ast.literal_eval`（该修复已在工作区及配套测试中）：

- 支持空格分隔格式 `"0.000 2.320 speaker_0"` → `(0, 2320, 0)`；
- 兼容 Python 字面量 `(0.0, 2.32, 0)` （向后兼容，避免破坏旧 mock/fixture）；
- 解析 `speaker_N` / `spk_N` / 裸数字；
- 非法输入仍抛 `DiarizationError(code="diarization_invalid_output")`，但**绝不因
  格式分支抛 SyntaxError**。

### 3. 验证标准（对接 sona 验收）

修复后须满足：

- 非流式 `/v1/audio/transcriptions` + `verbose_json` + `timestamp_granularities=segment`
  + `model=gpt-4o-transcribe-diarize` 返回词级 segments，每项含 `speaker=spk_XX`
  （不再 502）。
- 流式 `/v1/realtime`（开启 diarization profile）在 commit 后向客户端下发
  `conversation.item.input_audio_transcription.segment` 事件，且每项含
  `speaker` 字段（不再只下发无 speaker 的 `completed`）。
- 双音色（warm/bright 不同 voice）TTS 交替说话，两端收到不同 `speaker` label。

## Consequences

- `sona` 侧**无需再自行缓冲 PCM 做非流式分人回流**——流式 WS 自带 speaker 后，
  会议页面实时分人与最终纪要分人由同一条流式链路提供，最简、最一致。
- `speaker_key` 命名空间维持 `group:{id}:speaker:{n}`；`annotate` 输出的
  `spk_01/spk_02` 由 sona 的 `_speaker_key` 位映射到该命名空间。
- 流式分人对 `mlx_qwen3_asr` 有新增内存/计算需求（每会话一个 `_align_buffers` 有界
  缓冲 + commit 时一次批量对齐重解码），须在本机基准证明实时余量后上线；内存以
  `MAX_PCM_BYTES` 有界约束，`finish_streaming`/`close_session` 释放缓冲。
- 若 commit 时对齐失败，**fail-closed 返回空 segments**——该 commit 跳过 diarization，
  不伪造单一 speaker；质量由对齐成功路径补齐，后续可用流式原生 segments 进一步省列
  重解码。
- 本 ADR 不改变分人所有权（ADR-0007 不变）：SpeechRail 只提供匿名 label，
  实名声纹与身份映射仍在 sona。
