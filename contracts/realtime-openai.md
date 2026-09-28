# SpeechRail Realtime current-only 契约

> 契约版本：`4.2.0`；生效日期：2026-09-28。唯一机器 schema 是
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
- 更新确认是 `session.updated`。更新是原子的：候选配置先完整校验（revision、voice、
  VAD 与各能力初始化），成功后才一次性发布。若候选配置失败，旧 flags、config、输入缓冲
  与资源身份都不变，不留任何部分生效；候选持有的资源被关闭且只关闭一次，客户端改正后
  重发可以正常成功。

## 4. 客户端事件

| 事件 | 必需字段 | 语义 |
|---|---|---|
| `input_audio_buffer.append` | `event_id`, `audio` | 追加 24 kHz PCM16 |
| `input_audio_buffer.commit` | `event_id` | 结束当前输入 turn，最多产生一个 ASR final；`event_id` 会在对应终态原样回显 |
| `input_audio_buffer.clear` | `event_id` | 清空未提交输入；不产生 final |
| `speechrail.diarization.finish` | `event_id` | 关闭已 opt-in 的 diarization 会话；同 `event_id` 可重放，异 `event_id` 拒绝 |
| `speechrail.tts.start` | `event_id`, `request_id`, `task`, `voice` | 开始一个增量 TTS utterance |
| `speechrail.tts.append_text` | `event_id`, `request_id`, `sequence`, `text` | 追加不可变稳定文本；sequence 从 0 连续递增 |
| `speechrail.tts.finish_text` | `event_id`, `request_id`, `last_sequence` | 关闭文本侧并以最后 ACK 序号为屏障 |
| `speechrail.tts.cancel` | `event_id`, `request_id` | 取消匹配 utterance；取消优先于音频和终态（见 5.3） |

`speechrail.tts.start` 还接受 `voice_revision`、`expected_model_revision`、`speed` 和仅能收紧的
`limits`。未知字段不是 no-op，返回稳定错误。`speechrail.tts.create`、
`transcription_session.update` 和 conversation/response 事件均已移除。

## 5. 服务端事件

基础事件都带 `event_id`、`session_id`、`sequence`。sequence 从 0 连续递增；缺口/回退由客户端
检测并关闭或重建会话。

### 5.1 ASR

- `session.created`、`session.updated`
- `conversation.item.input_audio_transcription.delta`
- `conversation.item.input_audio_transcription.completed`
- `conversation.item.input_audio_transcription.failed`

服务端没有 `input_audio_buffer.speech_started` / `speech_stopped`，也没有
`input_audio_buffer.committed` / `cleared` 回执：`commit` 的可观察屏障是与该
`event_id` 关联的随后 transcription 终态。`clear` 是本地丢弃语义（其后的一次 commit
产生空 final）。

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
由客户端 `commit` 触发的 `completed` / `failed` 会带 `commit_event_id`；VAD 或 rollover
产生的终态不带该字段。调用方结束录音时必须等待与本次
`input_audio_buffer.commit.event_id` 相同的终态，不能用更早的在途终态判定尾句完成。
`completed` 只承载 `type`、`item_id`、`content_index`、`transcript` 与可选的
`commit_event_id`；对齐与匿名 speaker 归属随后以独立的
`speechrail.alignment.*` 与 `speechrail.diarization.*` 事件到达。

两条准入语义是调用方可以依赖的：

- **分包方式不改变内容。** 同一段音频无论整包发送、按 32 ms 切片还是不齐整的分包，
  admitted PCM 与样本顺序必须一致；句末（VAD 或显式 commit）之后**同一包内剩余的完整帧**
  属于下一个 utterance，不会被当作不足一帧的尾部丢掉或二次计分。调用方可以自由决定
  `input_audio_buffer.append` 的分包粒度。
- **每个 utterance 恰好一个终态。** commit 已 ACK 但后续读取挂起时，utterance 必须在
  deadline 后以 `failed` 收尾并释放资源，不得既无终态也不释放；读取成功后的错误不再产生
  矛盾的第二个终态。

### 5.2 Alignment 与 Diarization

- `speechrail.alignment.done` / `speechrail.alignment.failed`
- `speechrail.diarization.updated` / `speechrail.diarization.done` / `speechrail.diarization.failed`

辅助事件与 ASR final 分离：ASR final 成功后辅助可继续；辅助失败不改写 transcript。事件携带
`task_id`、`epoch`、`utterance_id`、`transcript_revision`、`metadata_revision`、sample/codepoint
span 或匿名 speaker units。旧 epoch、旧 revision 或不完整降级的回包必须丢弃。Diarization 只输出
session 内匿名 label，不保存声纹、embedding 或跨会话身份。

`session.speechrail.alignment.enabled` 与 `session.speechrail.diarization.enabled` 各自独立生效：
开启 alignment 即为本连接保留受界限的 PCM 并在每个 ASR final 后运行固定文本对齐，即使
diarization 关闭；关闭 alignment 则不保留 PCM，即使 diarization 开启。两者都只能在首个音频
帧之前改变。`speechrail.diarization.finish` 必须先等齐当前 item 尚在进行的对齐任务，再封存
归属账本，因此已 frozen 的文本不会出现“有 final 无归属”的封存结果；等待超过
`realtime_diarization_drain_deadline_seconds` 时按 `finalization_timeout` 降级。

对齐只有 `granularity` 一个会话级旋钮。对齐器精度由 active profile 在进程启动时固定，
不提供会话级 `precision`：单服务单 worker 的边界不允许按连接重建模型进程。

`speechrail.alignment.done` 的 `units[]` 必须与冻结文本 revision 一一对应，`text_start`/`text_end`
是**原始文本的 codepoint `[start, end)`**（不正规化后沿用旧偏移），`granularity` 必须是对齐器
实际给出边界证据的粒度：

```json
{
  "type": "speechrail.alignment.done",
  "task_id": "task_1",
  "epoch": 0,
  "utterance_id": "utt_1",
  "transcript_revision": 3,
  "metadata_revision": 1,
  "sample_span": {"start": 0, "end": 24000},
  "codepoint_span": {"start": 0, "end": 4},
  "units": [
    {
      "segment_uid": "seg_0000000000a1",
      "text_start": 0,
      "text_end": 2,
      "audio_start_sample": 0,
      "audio_end_sample": 12000,
      "timing_quality": "aligned",
      "granularity": "segment"
    }
  ],
  "event_id": "evt_7",
  "session_id": "sess_1",
  "sequence": 7
}
```

`granularity` 取 `segment` / `word` / `character`：中文按对齐器返回的汉字边界、英文按词边界；
没有对应粒度证据时必须报 `unsupported` 而不是把 phrase 均分伪装成 character。对齐失败发
`speechrail.alignment.failed`（独立状态，绝不用空 units 冒充成功）；ASR final 仍成功。

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

本节的三条时序是调用方可以依赖的契约，不只是当前实现细节：

1. **取消优先于音频准入。** `speechrail.tts.cancel` 不排在已入队的音频准入之后；即使有音频
   正在等待准入，cancel 也先执行。已经排队但尚未准入的用户音频不被 cancel 隐式清空。
2. **终态屏障。** terminal 在该 utterance 的 lane 资源回收**确认之后**才上 wire；取消路径
   同样如此。因此 terminal 之后立即发起的下一个 `speechrail.tts.start` 会成功，不会拿到
   `tts_in_progress`。回收无法确认时连接被关闭或该 lane 被隔离，不提前发 terminal 冒充
   “已可复用”。这条保证的是**终态之前不释放资源**，不是**终态一定先于下一条 started 到达**：
   已经越过准入的流水线式客户端可能在旧 utterance 的 terminal 之前就收到下一条
   `speechrail.tts.started`。依赖严格 before-terminal 顺序的调用方应当等待匹配
   `request_id` 的 terminal，而不是假定它排在下一条 `started` 之前。
3. **pending 预算按实际消费归还。** `started` 里的 `limits` 是执行层实际生效的预算，并通过
   IPC 传到 worker；被接受但尚未消费的字符继续占用额度，worker 消费掉的一批立即归还。
   累计可以超过首个 2048 的常量上限（总上限 4096 仍然有效）。消费水位只归还**文本**额度，
   不表示对应音频已被播放，也不改变 render receipt 的 `delivered` 口径。

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
