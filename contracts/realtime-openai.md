# SpeechRail Realtime ASR/TTS 协议契约

> 契约版本：`6.3.2`；生效日期：2026-10-07。唯一机器 schema 是
> [`realtime-events.schema.json`](realtime-events.schema.json)，字段责任表是
> [`realtime-field-matrix.json`](realtime-field-matrix.json)。

本文定义 SpeechRail `/v1/realtime` 的 ASR/TTS 协议，包括采用的 OpenAI Realtime 事件子集与
`speechrail.*` 扩展。支持的事件与字段以本契约及配套 schema 为准；未列出的事件、字段和
兼容别名不受支持。服务不提供旧事件翻译、旧字段或 profile alias、双协议分支或 `/v2` 兼容层。
契约版本标识具体协议规则；服务端与客户端须遵循相同规则，不进行隐式协议降级。

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
      "asr": {
        "preview_interval_ms": 1000,
        "max_segment_ms": 20000,
        "finalization": "full_segment",
        "final_deadline_ms": 10000
      },
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
- `session.speechrail.asr` 是可选的中立策略对象：`preview_interval_ms` 默认 `1000`，范围
  `100...5000`；`max_segment_ms` 默认 `20000`，范围 `1000...30000`，且不得小于预览间隔；
  `finalization` 默认 `full_segment`，只接受 `full_segment` / `streaming_finalize`；
  `rollback_tokens` 默认 `5`，范围 `0...32`，为累计音频预览重解码时保留可修订前缀的回退
  token 数（调优点，不是正确性证明）。`streaming_finalize` 的最终解码使用完整的有界段音频，
  不强制保留预览文本前缀；此时即使 `rollback_tokens=0`，正式结果仍可修正整段预览。
  它沿用流式 decoder，不另调用完整段转写接口；`full_segment` 则调用完整段转写接口复核。
  `final_deadline_ms` 为正整数并不得超过当前 request timeout；省略时沿用该 timeout。
  这些字段必须用 JSON 整数值，不接受布尔值或小数形式。
- 成功的 `session.updated` 回显所请求的 ASR 策略和 `effective_max_segment_ms`。有效段预算是
  请求值、服务资源上限、能力上限与解码器上限的最小值；超出请求或无效字段直接拒绝，
  不静默夹取。场景预设由客户端选择，服务端不依据 task 推断策略或自动打开其他能力。
- `session.created` 和每个成功的 `session.updated` 都必须回显完整的有效 ASR 策略。默认值为
  `preview_interval_ms=1000`、`max_segment_ms=20000`、`finalization=full_segment`、
  `rollback_tokens=5`、`final_deadline_ms=120000`、`effective_max_segment_ms=20000`；
  该默认值与 `task` 无关。
- `session.speechrail.expected_asr_revision` 只绑定连接的 ASR 模型身份，在 `session.updated`
  回显。TTS opt-in 只启用能力，不选择音色或绑定 TTS 模型。
- 模型、语言、能力与预算在首个工作前验证；TTS 音色与 revision 在每次
  `speechrail.tts.start` 验证。未知模型、voice、revision、Q4/Q6、Design runtime voice 均 fail closed。
- 缺失字段使用服务端当前默认；显式 `null` 只对 schema 声明可空的字段有效，不能用 `null`
  删除有语义的字段。
- 更新确认是 `session.updated`。更新是原子的：候选配置先完整校验（ASR revision、
  VAD 与各能力初始化），成功后才一次性发布。若候选配置失败，旧 flags、config、输入缓冲
  与资源身份都不变，不留任何部分生效；候选持有的资源被关闭且只关闭一次，客户端改正后
  重发可以正常成功。

## 4. 客户端事件

| 事件 | 必需字段 | 语义 |
|---|---|---|
| `input_audio_buffer.append` | `event_id`, `audio` | 追加 24 kHz PCM16 |
| `input_audio_buffer.commit` | `event_id` | 结束当前输入 turn，最多产生一个 ASR final；`event_id` 会在对应终态原样回显 |
| `input_audio_buffer.clear` | `event_id` | 丢弃尚未冻结的输入；已发段边界但尚无终态的冻结段以 `failed` 收尾 |
| `speechrail.diarization.finish` | `event_id` | 关闭已 opt-in 的 diarization 会话；同 `event_id` 可重放，异 `event_id` 拒绝 |
| `speechrail.tts.start` | `event_id`, `request_id`, `task`, `voice`, `audio_window_bytes` | 开始一个有界消费窗口的增量 TTS utterance |
| `speechrail.tts.append_text` | `event_id`, `request_id`, `sequence`, `text` | 追加不可变稳定文本；sequence 从 0 连续递增 |
| `speechrail.tts.finish_text` | `event_id`, `request_id`, `last_sequence` | 关闭文本侧并以最后 ACK 序号为屏障 |
| `speechrail.tts.cancel` | `event_id`, `request_id` | 取消匹配 utterance；取消优先于音频和终态（见 5.3） |
| `speechrail.tts.audio_ack` | `event_id`, `request_id`, `sample_offset` | 归还匹配 utterance 的累计 PCM 消费额度 |

`speechrail.tts.start` 还接受 `voice_revision`、`expected_model_revision`、`speed` 和仅能收紧的
`limits`。未知字段不是 no-op，返回稳定错误。`speechrail.tts.create`、
`transcription_session.update` 和 conversation/response 客户端事件均不受支持。

TTS 身份只属于本次 start 请求：`voice` 必填，两个 revision pin 从同一 effective capability
snapshot 的对应 voice 读取。系统音色校验 CustomVoice 制品，克隆音色校验 Base 制品；
`voice_revision_conflict` / `model_revision_conflict` 在开流前拒绝该次请求。每次请求独立校验，
不继承 session 或上一 utterance 的音色与模型 pin；省略 pin 时使用该音色当前版本。
`session.speechrail.expected_tts_revision`（包括 `audio.input.speechrail` 中的同名字段）
不受支持，返回 `unsupported_operation`，失败不部分启用 TTS。TTS pin 只能由带有音色身份的
`speechrail.tts.start` 事件携带。

## 5. 服务端事件

基础事件都带 `event_id`、`session_id`、`sequence`。sequence 从 0 连续递增；缺口/回退由客户端
检测并关闭或重建会话。

### 5.1 ASR

- `session.created`、`session.updated`
- `speechrail.transcription.segment_closed`
- `conversation.item.input_audio_transcription.delta`
- `conversation.item.input_audio_transcription.completed`
- `conversation.item.input_audio_transcription.failed`

服务端没有 `input_audio_buffer.speech_started` / `speech_stopped`，也没有
官方 `input_audio_buffer.committed` / `cleared` 回执。普通 `commit` 保持原有终态行为；
需要可靠结束录音的调用方应使用下述可选 SpeechRail 完成屏障。
`clear` 丢弃尚未冻结的输入，不为这些字节创建 item、边界或终态。若某个非空段已发出
`segment_closed`、但其 ASR 终态尚未发送，`clear` 不能撤回该边界，必须为该 item 发送唯一的
`conversation.item.input_audio_transcription.failed`，错误码为 `backend_error`，说明该段因
clear 取消。此后对空缓冲区执行一次 `commit` 会产生空 `completed`。
已提交但仍在等待前序 final 的空终态也必须在 clear 时发送唯一的 `failed`；
尚未完成的提交屏障返回关联原 commit ID 的 `invalid_state`，不发送完成回执。

`session.speechrail.asr` 在首个 PCM 前原子更新；当前或待处理输入非空时拒绝更新。每个冻结的
非空段在文字终态前发送 `speechrail.transcription.segment_closed`，报告该 item 的
24 kHz wire 样本半开区间 `[start, end)` 和关闭原因 `vad`、`client_commit` 或
`budget_rollover`。只有 client commit 关闭可选带 `commit_event_id`。预算切段仅说明输入段
冻结，不代表语义结束，也不应单独触发调用方的一轮回复；空输入不创建虚假的样本区间。

```json
{
  "type": "speechrail.transcription.segment_closed",
  "event_id": "evt_3",
  "session_id": "sess_1",
  "sequence": 7,
  "item_id": "item_2",
  "sample_span": {"start": 24000, "end": 48000},
  "reason": "budget_rollover"
}
```

### 可选输入完成屏障

`input_audio_buffer.commit` 可附带 `"speechrail":{"request_receipt":true}`，且必须有
1–128 字符的 `event_id`。服务端按音频入站 FIFO 在 commit 锁内冻结此前已接受的输入，
随后释放该锁并等待对应转写 `completed` 或 `failed` **发送完成**及 ASR 清理后，发送：

```json
{"type":"speechrail.input_audio_buffer.committed","commit_event_id":"commit_1","accepted_samples":24000}
```

它仍带公共 envelope 的 `event_id/session_id/sequence`。`accepted_samples` 是该 commit 冻结时
当前连接累计接受的 **24 kHz 单声道 PCM 样本数**（字节数除以 2），不是 kernel 样本数、音频时长或
转写成功量；`clear` 不归零，新连接从零开始。调用方收到回执前先处理其前面的文本终态。
失败转写也可结束输入屏障，不能把回执当作转写成功证明。

空输入、已经自动提交的输入和重复 commit 都返回本次 `event_id` 的回执，**不重复文本 final**。
相同 ID 的重试可重复回执；调用方以关联 ID 幂等消费。缺省或 `request_receipt:false` 不发新增
回执。未知扩展字段、非布尔值或请求回执却没有 ID 会拒绝。

仅 worker EOF、commit 超时/取消不构成完成证据；没有文本终态的 EOF 返回 `backend_error`。
失败后同一代输入的重复屏障仍拒绝，直到明确 clear 或新输入开始下一代，不能通过重试伪造回执。
WebSocket 断开会取消处理并释放资源，未完成屏障不发回执。追加与 commit 在同一入站队列保持
顺序；客户端开始收尾后必须停止追加，按关联 ID **及累计样本水位**确认，再 clear/close。
模型收尾等待不会占住入站队列；clear 仍按 FIFO 执行，不越过此前的 append。
同一连接最多有 16 个尚未完成的提交屏障，超限返回关联 commit ID 的 `queue_full`。
同一次显式提交覆盖的自动切段若超时或缺少完成证据，不能被后段成功或重复提交掩盖；
新输入开始下一次提交范围后可恢复。

macOS 客户端始终请求此屏障。服务没有该扩展时，客户端有界超时并关闭连接，**不发送
clear**；不能以转写终态替代回执。缺少完成屏障时，客户端不能宣称输入已可靠收尾。

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
产生的终态不带该字段。结束录音应使用上面的可选输入完成屏障；单个旧文本终态
不能证明稍后追加的 PCM 已完成，空/重复 commit 也可能没有新文本终态。
`completed` 只承载 `type`、`item_id`、`content_index`、`transcript` 与可选的
`commit_event_id`；对齐与匿名 speaker 归属随后以独立的
`speechrail.alignment.*` 与 `speechrail.diarization.*` 事件到达。

三条准入语义是调用方可以依赖的：

- **分包方式不改变内容。** 同一段音频无论整包发送、按 32 ms 切片还是不齐整的分包，
  admitted PCM 与样本顺序必须一致；句末（VAD 或显式 commit）之后**同一包内剩余的完整帧**
  属于下一个 utterance，不会被当作不足一帧的尾部丢掉或二次计分。调用方可以自由决定
  `input_audio_buffer.append` 的分包粒度。
- **每个 utterance 恰好一个终态。** commit 已 ACK 但后续读取挂起时，utterance 必须在
  deadline 后以 `failed` 收尾并释放资源，不得既无终态也不释放；读取成功后的错误不再产生
  矛盾的第二个终态。`clear` 若取消已经冻结但仍未发送终态的段，也必须发送唯一 `failed`
  终态；仍未冻结的输入只是被丢弃，不创建 item。
- **空 final 不等于"用户没说话"。** 空 `transcript` 有两个来源：`clear` 之后的那一次
  commit（此时确实没有可提交的语音），以及语音已经准入、但 ASR 终态文本经轻量 ITN
  之后为空。调用方无法从事件本身区分这两者，因此**已经向用户展示过该 item 的
  hypothesis 文字时，不得在空 final 上静默丢弃它**：要么按未完成保留并明确告知用户，
  要么给出可读的失败提示。把"用户说过的话"连同界面上的半句一起清掉且不给任何提示，
  是调用方实现错误，不是本契约允许的正常路径。

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

### PCM 消费窗口

`start.audio_window_bytes` 必填，是 `2...1_440_000` 范围内的偶数；`started.audio_window_bytes`
回显生效窗口。服务端发送但尚未获消费确认的 PCM 不超过该窗口，涵盖调用方事件流、FIFO、
在途入队和播放器中的同一批音频。窗口耗尽时等待消费进度，不把正常的快速生成视为错误。
`limits.max_pending_audio_bytes` 仍然是 worker/传输预算，传输发送完成即可归还；它不表示调用方
已经消费。生效 worker chunk 上限进一步收紧至窗口内，单块一定可被准入。
macOS 助手默认预取最多 30 秒（1,440,000 bytes），播放器短队列与 worker 默认
48,000 bytes 预算独立。生产 completed 后释放合成资源，客户端继续排空自己的队列。

调用方只在确实释放本地音频容量后发送消费确认：

```json
{"type":"speechrail.tts.audio_ack","event_id":"ack_1","request_id":"req_1","sample_offset":1920}
```

`sample_offset` 是该 request 从零起累计消费的 PCM16 样本数（exclusive end），必须是非负
安全整数，不能超过服务端已发送水位。重复水位幂等；回退或超前返回 `tts_audio_ack_invalid`，
不改变窗口。播放调用方在本代渲染完成回调释放容量后归还，文件/内存消费调用方在交给其有界
下游后归还；接收数据本身不等于释放容量。消费确认不更改 receipt 的 transport `delivered`
边界，也不证明用户听到了音频。

消费确认与 cancel 使用独立控制队列，不排在等待中的 append/音频准入之后。文本 ACK 在
backend 接受 append 后独立发送，不等待输出窗口；不能用消费确认替代文本 ACK 或提前 finish。
取消和断线关闭窗口、唤醒发送者、丢弃未发送 PCM；资源回收确认后才发送 terminal。消费长期
无进展时使用生效 `slow_consumer_seconds` 返回一次 `tts_backpressure` 失败。消费等待与
网络写入使用独立 deadline：实际消费水位前进续期，重复 ACK 不续期；累计健康等待可以
超过单次 deadline。worker 输出预算满时暂停模型推进，writer 实际交付后恢复，
不因瞬时满队列失败。正常 completed
不等待最终消费确认：调用方继续排空本地音频，已知退役 request 的迟到 ACK 被忽略，未知
request 返回 `tts_not_active`，绝不归还到新 request。

`audio_window_bytes` 是 start 的必需字段：缺少时请求被拒绝，不提供无流控模式或 alias。
服务与直接 WebSocket 客户端须遵循相同的消费窗口规则；REST/MCP 一次性合成不使用这些事件。

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
`tts_stream_limit_exceeded`、`tts_backpressure`、`tts_audio_ack_invalid`、`tts_backend_failed`、
`invalid_state`、`asr_policy_invalid`、`asr_policy_unsupported`、`asr_buffer_overflow`。
策略形状、范围或 deadline 无效时返回 `asr_policy_invalid`；后端不支持所请求策略时返回
`asr_policy_unsupported`；无法在有界资源内接纳音频时返回 `asr_buffer_overflow`。
资源回收未确认导致 lane 隔离时，后续 TTS 准入（以及串行策略下受阻的 ASR 准入）返回
`backend_reclamation_failed`。它不是可退避重试的 `queue_full`：调用方须停止重试，
由操作者恢复 runtime 后再请求；能力发现成功不证明隔离已解除。

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
