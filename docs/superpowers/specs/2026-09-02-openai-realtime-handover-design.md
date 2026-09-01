# SpeechRail OpenAI 标准实时协议交割实施设计

## 背景

根据 `voice-realtime/docs/operations/SpeechRail-OpenAI标准协议功能需求交割单.md`，将 SpeechRail 的 `WS /v1/realtime` 补齐为可供 voice-realtime 统一使用的 OpenAI-compatible ASR/TTS 协议。当前代码已经提供标准转写事件、TTS 生命周期、取消和 commit 基础链路；本次设计聚焦实时匿名分人、事件对账元数据、会话参数对齐及批量 diarized 输出。

## 目标与非目标

目标：

- `/v1/realtime` 支持 opt-in 的 session-scoped 匿名 diarization，并以 `conversation.item.input_audio_transcription.segment` 实时输出。
- 所有服务端事件带唯一 `event_id`、当前 `session_id` 和单调 `sequence`。
- 保证 ASR partial/final、EOF commit、TTS 流式输出和取消语义可由客户端对账。
- 对齐 `language`、`languages`、`keywords`、`timestamp_granularities`、`known_speaker_names` 和 `known_speaker_references` 的协议边界；不把这些字段误当作 prompt 或身份持久化。
- 批量 `/v1/audio/transcriptions` 在已有匿名领域模型基础上支持 diarized JSON 与 diarize model alias。
- 保留 `/v2/realtime` 兼容入口并标记 deprecated，迁移完成前不删除公共路径。

非目标：

- 不删除 `/v2/realtime`，不迁移会议、UI、播放、数据库或 LLM 编排。
- 不伪造 speaker label；没有可用 diarization profile 时显式返回 `diarization_not_available`。
- 不持久化音频、PCM、embedding、完整转写或已知说话人身份。
- 不承诺 fake backend 可以证明真实模型质量、TTFT/TTFA、DER/JER、峰值内存或并发性能。

## 设计

### 1. OpenAI realtime 路由

`create_openai_realtime_router` 接收现有 `AppServices.diarization_engine`。在 `session.update` 中解析 OpenAI transcription 配置和现有 `DiarizationConfig`，配置了 `enabled=true` 但 profile 不可用时立即返回 `diarization_not_available`。连接内创建一个 `DiarizationCoordinator`，在每个 `input_audio_buffer.append` 将 PCM 交给分人会话，在 ASR completed 事件到达后用其 `segments` 做校验和标注。

每个已标注 segment 发送：

```json
{
  "type": "conversation.item.input_audio_transcription.segment",
  "item_id": "item_...",
  "content_index": 0,
  "id": "seg_...",
  "text": "...",
  "speaker": "spk_01",
  "start": 0.0,
  "end": 1.2
}
```

`start`/`end` 从 `TranscriptSegment.start_ms/end_ms` 转为秒；`speaker` 仅来自已验证的 `DiarizationAssignment`。分人关闭时不发送 segment 事件，也不补单 speaker。

### 2. 事件元数据与并发

路由设置连接级发送器，在同一 `asyncio.Lock` 内分配 `sequence`、生成 `event_id` 并发送 JSON。所有主循环、ASR reader、TTS task 和错误路径都经由该发送器，避免并发任务导致事件号重复或发送顺序不可解释。原有 formatter 继续负责 OpenAI payload 形状，但不再依赖固定模板 `event_id`；错误事件保留触发它的客户端 `event_id` 作为错误字段关联信息。

### 3. EOF、取消与不可恢复会话

- `input_audio_buffer.commit` 先等待 ASR backend 的 commit 和事件 reader 终止，再发送最终转写事件；diarization finalize 结果只作为已完成 segment 的匿名补充，不改变完成事件的终态语义。
- `response.cancel` 取消当前 TTS task，抑制后续 audio delta，释放生成器/worker 资源，并发送明确的 cancelled response terminal event；同一连接不复用被取消的 response 上下文。
- WebSocket 断开时关闭并 release ASR/diarization/TTS 资源；服务端不恢复旧 audio 或 event。客户端重连得到新的 `session_id`，由客户端负责 source epoch 对账。

### 4. 参数与模型发现

OpenAI realtime adapter 接受协议文档列出的语言、关键词、时间戳粒度和已知说话人参考字段，在边界完成类型、长度和互斥校验；只有后端明确支持的字段影响推理，其他兼容字段不得进入日志或持久化。新增 `gpt-4o-transcribe-diarize` alias 仅在 diarization profile 可用时作为可用能力公开和接受，否则返回稳定错误，不回退到单 speaker 或本地替代模型。

### 5. 批量呈现与契约

批量路由复用 `TranscriptResult.segments`、`TranscriptSegment.speaker/speakers` 和现有 verbose formatter，补齐 diarized JSON 的稳定响应形状及 model alias 校验。OpenAPI 和 realtime 文档同步描述新增事件、参数、错误和 `/v2/realtime` deprecation 状态。

## 写入范围

- `src/speechrail/http/routes/realtime_openai.py`：接入 diarization、统一事件发送、EOF/取消生命周期。
- `src/speechrail/compatibility/openai_realtime.py`：新增 segment/取消 payload、参数解析和 alias/错误支持。
- `src/speechrail/http/routes/audio.py`、`src/speechrail/http/routes/system.py`：批量 diarized 响应和模型发现对齐。
- 必要时修改 `src/speechrail/domain/ports.py` 或新增窄的兼容类型；不改变 vendor-neutral 领域边界。
- `tests/test_realtime_openai.py` 及相关批量/契约测试：先写失败测试覆盖 R1–R10 中可自动验证部分。
- `contracts/realtime-openai.md`、`contracts/openapi.yaml` 与必要用户文档：同步公共契约。

## 验证策略

- RED/GREEN：新增测试先证明当前实现缺少 segment、sequence、唯一 event id、参数校验和取消语义，再实现最小改动。
- 针对性测试：`tests/test_realtime_openai.py`、批量转写和格式化测试。
- 完整 gate：`uv run --extra dev pytest`、`uv run --extra dev ruff check src tests`、`uv run --extra dev mypy src`、`npx @redocly/cli lint contracts/openapi.yaml`、`git diff --check`。
- 具备外部 runtime 和用户授权时，另行验证 `/health`、`/readyz`、`/v1/models`、真实 multipart 和 realtime smoke；不把这些环境依赖写入自动化测试。

## 回退

本设计及后续实现按独立 commit 保存。回退时只恢复本任务 commit，不触碰现有未提交文件、`.env`、外部 runtime、模型 snapshot 或用户数据；`/v2/realtime` 保留作为兼容回退路径。
