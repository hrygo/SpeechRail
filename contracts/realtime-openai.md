# SpeechRail Realtime current-only 契约

> 契约版本：`4.0.0`；生效日期：2026-09-25。唯一机器 schema 是
> [`realtime-events.schema.json`](realtime-events.schema.json)，字段责任表是
> [`realtime-field-matrix.json`](realtime-field-matrix.json)。本版本直接切换，不提供旧事件、
> 旧字段、旧 profile alias 或 `/v2` 兼容层。

## 1. 责任边界

`WS /v1/realtime` 是本地 Speech Plane，只负责：

- 24 kHz mono PCM16 输入缓冲、手动或服务端 endpointing、ASR partial/final；
- 按任务请求可选的 Alignment 与匿名 Diarization 元数据；
- 调用方显式提交稳定文本后的增量 TTS；
- 资源准入、worker 生命周期、稳定错误 envelope 和身份校验。

调用方负责麦克风、AEC、播放、LLM、提示词、对话历史、工具、业务状态、句子队列和 barge-in。
服务端不创建 conversation、不执行 LLM、不保存跨请求历史、不播放音频。

连接：`ws://127.0.0.1:8201/v1/realtime`。配置 `SPEECHRAIL_API_KEY` 后使用 Bearer 握手；
query 不得携带 key。每连接有独立 session、epoch、sequence 与临时 item/response ID。

## 2. 音频边界

- wire PCM：`{"type":"audio/pcm","rate":24000}`，mono PCM16 little-endian。
- ASR 内核：16 kHz mono；24 kHz 到 16 kHz 使用连续有状态重采样和整数采样时间轴。
- `input_audio_buffer.append.audio` 是文件头之外的 Base64 字节，必须为非空偶数字节。
- 其他 wire rate 或编码在首个音频前拒绝为 `unsupported_audio_format`，不得按 16 kHz 误读。
- PCM、Base64、完整 prompt/transcript、embedding、实名 speaker 和绝对模型路径不得写日志或 fixture。

## 3. 会话配置

唯一会话更新事件是 `session.update`：

```json
{
  "type": "session.update",
  "event_id": "evt_1",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": {"type": "audio/pcm", "rate": 24000},
        "transcription": {
          "model": "<registered-speechrail-model>",
          "language": "zh",
          "keywords": ["SpeechRail"],
          "timestamp_granularities": ["segment"]
        },
        "turn_detection": null
      }
    },
    "speechrail": {
      "task": "caption",
      "alignment": {"enabled": false},
      "diarization": {"enabled": false}
    }
  }
}
```

- `audio.input.turn_detection` 首批仅接受 `null` 或 `"manual"`；未实现的其他官方 VAD 值明确拒绝。
- 服务端 VAD 使用 `session.speechrail.endpointing={"mode":"server_vad",...}`，与官方非空
  `turn_detection` 互斥，不把 Silero 冒充官方云模型能力。
- `session.speechrail.task` 为 `conversation`、`caption`、`transcription`、`render` 或
  `voice_design`。Alignment、Diarization、TTS 均为任务 opt-in，不随规格自动开启。
- 模型、语言、voice revision、能力与预算由统一 plan resolver 在首个工作前验证。未知模型、
  未知 voice、未知 revision、Q4/Q6、Design runtime voice 均 fail closed。
- 缺失字段使用服务端当前默认；显式 `null` 只对 schema 声明可空的字段有效，不能用 `null`
  删除有语义的字段。
- 更新确认是 `session.updated`。若候选配置失败，旧配置保持不变，不半应用。

## 4. 客户端事件

| 事件 | 必需字段 | 语义 |
|---|---|---|
| `input_audio_buffer.append` | `event_id`, `audio` | 追加 24 kHz PCM16 |
| `input_audio_buffer.commit` | `event_id` | 结束当前输入 turn，最多产生一个 ASR final |
| `input_audio_buffer.clear` | `event_id` | 清空未提交输入；不产生 final |
| `speechrail.tts.start` | `event_id`, `request_id`, `task`, `voice` | 开始一个增量 TTS utterance |
| `speechrail.tts.append_text` | `event_id`, `request_id`, `sequence`, `text` | 追加不可变稳定文本；sequence 从 0 连续递增 |
| `speechrail.tts.finish_text` | `event_id`, `request_id`, `last_sequence` | 关闭文本侧并以最后 ACK 序号为屏障 |
| `speechrail.tts.cancel` | `event_id`, `request_id` | 取消匹配 utterance；取消优先于音频和终态 |

`speechrail.tts.start` 还接受 `voice_revision`、`expected_model_revision`、`speed` 和仅能收紧的
`limits`。未知字段不是 no-op，返回稳定错误。`speechrail.tts.create`、
`transcription_session.update` 和 conversation/response 事件均已移除。

## 5. 服务端事件

基础事件都带 `event_id`、`session_id`、`sequence`。sequence 从 0 连续递增；缺口/回退由客户端
检测并关闭或重建会话。

### 5.1 ASR

- `session.created`、`session.updated`
- `input_audio_buffer.speech_started`、`input_audio_buffer.speech_stopped`
- `input_audio_buffer.committed`、`input_audio_buffer.cleared`
- `conversation.item.input_audio_transcription.delta`
- `conversation.item.input_audio_transcription.completed`
- `conversation.item.input_audio_transcription.failed`

hypothesis 可修订，使用 `speechrail.transcription.hypothesis`：

```json
{
  "type": "speechrail.transcription.hypothesis",
  "event_id": "evt_2",
  "session_id": "sess_1",
  "sequence": 6,
  "task_id": "task_1",
  "epoch": 0,
  "utterance_id": "utt_1",
  "revision": 3,
  "text": "你好世界",
  "sample_span": {"start": 0, "end": 24000},
  "stable_prefix_codepoints": 2
}
```

只有可证明的稳定前缀才能映射到官方 append-only delta；无法证明稳定时只发 hypothesis，
最终统一发 completed。一个 utterance 恰好一个 text final，重复 commit 不产生双 final。

### 5.2 Alignment 与 Diarization

- `speechrail.alignment.done` / `speechrail.alignment.failed`
- `speechrail.diarization.updated` / `speechrail.diarization.done` / `speechrail.diarization.failed`

辅助事件与 ASR final 分离：ASR final 成功后辅助可继续；辅助失败不改写 transcript。事件携带
`task_id`、`epoch`、`utterance_id`、`transcript_revision`、`metadata_revision`、sample/codepoint
span 或匿名 speaker units。旧 epoch、旧 revision 或不完整降级的回包必须丢弃。Diarization 只输出
session 内匿名 label，不保存声纹、embedding 或跨会话身份。

### 5.3 TTS

```text
speechrail.tts.start -> speechrail.tts.started
speechrail.tts.append_text* -> speechrail.tts.text_accepted*
speechrail.tts.audio.delta*
speechrail.tts.finish_text -> speechrail.tts.completed | failed
speechrail.tts.cancel -> speechrail.tts.cancelled
```

`started` 携带 `task_id`、`plan_id`、`request_id`、`voice_revision`、协商后的 `output_format`
和生效 `limits`。每个 `audio.delta` 带 `task_id`、`request_id`、`chunk_index`、`sample_offset` 与
Base64 PCM。TTS 只使用 SpeechRail namespace；不同时发送 `response.done`，每次 utterance 恰好一个
terminal：`completed`、`cancelled` 或 `failed`。取消后不得再投递旧音频。

## 6. 错误

```json
{
  "type": "error",
  "event_id": "evt_err_1",
  "request_id": "req_1",
  "session_id": "sess_1",
  "sequence": 18,
  "error": {
    "type": "invalid_request_error",
    "code": "unsupported_operation",
    "message": "response.done is not supported by SpeechRail"
  }
}
```

主要错误码：`invalid_event`、`unsupported_operation`、`model_not_found`、
`unsupported_audio_format`、`language_not_supported`、`backend_busy`、`backend_timeout`、
`backend_not_ready`、`tts_request_invalid`、`tts_in_progress`、`tts_not_active`、
`voice_not_found`、`voice_not_available`、`voice_revision_conflict`、
`model_revision_conflict`、`tts_sequence_invalid`、`tts_input_closed`、`tts_input_timeout`、
`tts_stream_limit_exceeded`、`tts_backpressure`、`tts_backend_failed`、`invalid_state`。

## 7. 明确拒绝项

`transcription_session.update`、`session.updated` 客户端事件、`conversation.*`、`response.create`、
`response.cancel`、`response.audio.*`、`response.audio_transcript.*`、旧根级 model/language/
audio_format、LLM tools/modalities/instructions、旧四档名、Q4/Q6、Design Q8/Design runtime voice、
旧平铺 `input_audio_format`、假 context 开关和未实现表达参数均明确拒绝，不提供 alias。

## 8. 验证入口

```bash
uv run --extra dev pytest --no-cov tests/test_realtime_current_schema.py
uv run --extra dev python scripts/check_realtime_contract.py
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
```

schema 与共享 fixture 同时由 Python、Swift 和脚本读取。契约、测试与实现必须同批更新；HTTP
OpenAPI 不复制 WebSocket schema。MCP 仍是 REST proxy，不转发 `/v1/realtime` WebSocket handle。
