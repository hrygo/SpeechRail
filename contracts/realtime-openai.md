# SpeechRail Realtime ASR/TTS 协议契约

> 契约版本：`7.1.0`；生效日期：2026-10-23。唯一机器 schema 是
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
  启用语音准入时，Silero 单帧概率达到入口阈值即放行，并保留请求的前缀；能量 VAD
  仍需连续三帧确认。低于入口阈值的帧不能启动新话语；进行中的话语沿用较低的退出阈值
  和请求的静默时长，保留词尾。
- `session.speechrail.task` 为 `conversation`、`caption`、`transcription`、`render` 或
  `voice_design`。Alignment、Diarization、TTS 均为任务 opt-in，不随规格自动开启。
  分人策略支持可选的 `backend` 选择（见 §5.2 匿名分人后端与容量）。
  ASR 可选配置中立策略对象 `session.speechrail.asr`，或互斥地选用修订窗口策略 `session.speechrail.window`（见第 6 节）。
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
  连续分人独立消费会话音频，不额外缩短 ASR 段预算；固定文字对齐和归属登记支持最长
  30 秒单段，原有缓冲容量与准入限制仍生效。较长段可减少强制切断，但会延后正式文字
  与其说话人归属，并可能增加推理内存；需要更早定稿的客户端可显式请求较短段。
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

### 4.1 增量 TTS 的承诺点

本节说明既有字段的语义边界，不新增事件或字段。

契约定义的是**屏障**，不是首音延迟指标。`speechrail.tts.finish_text` 只关闭文本侧并以最后
ACK 序号为屏障，不会提前合成尚未追加的文本；消费额度的阻塞语义见下文「PCM 消费窗口」，
本节不重复。

延迟与韵律的取舍因此由调用方掌握：一次追加较长文本，合成器能看到更完整的上下文，韵律更
连贯，但首段音频更晚；频繁追加短文本能更早出声，代价是句内停顿与重音更容易被切碎。服务不
承诺固定首音延迟，也不替调用方选择文本粒度；需要可预测延迟的调用方应自行决定追加节奏，并
用 `audio_ack` 维持消费窗口。

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
重采样相位跨 client commit 连续保留。极短的新 wire 输入若未产生新的识别样本，提交仍返回
空 `completed`，不创建 `segment_closed`；完成屏障的 `accepted_samples` 仍统计全部 wire 输入。

### 转写终态的可选观测值

`conversation.item.input_audio_transcription.completed` 可带可选整数
`repetition_collapsed`：本条转写里被合并掉的解码回路重复段数量。**没有坍缩时该字段缺席**，
因此忽略它的客户端看到的事件与加入清理之前逐字节一致。它只是观测值：不参与准入、不参与
质量判定，也不承诺"文本一定是干净的"——修辞性重复（同一词说五遍）有合法用途，会被保留。

```json
{
  "type": "conversation.item.input_audio_transcription.completed",
  "event_id": "evt_9",
  "session_id": "sess_1",
  "sequence": 12,
  "item_id": "item_2",
  "content_index": 0,
  "transcript": "预算",
  "repetition_collapsed": 1
}
```

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

标准 ASR hypothesis 与 completed 的轻量数字规范化保留相邻非零中文数字形成的歧义数量，
例如“五六个人”“七八十个”“两三个”，不猜成 56、80 或 23。明确年份、小数及规范计数
仍可转换；已由模型输出的阿拉伯数字不会据此反推或改成概数。
“一点一点”“三点一线”“五点六点”“三点一刻”等普通表达或钟点表达保留原文，
不将词内的“点”猜成小数点；含多个“点”或以“点”结尾的百分比候选不转换为百分数。
“统一分配”“统一人员”等表达中的“统一”保留原文，不把词内的“一”当成带单位数量。
后处理只改写文本上唯一确定的数量：`七点四十`、`七点四十分`、`十点零五分`、
`九点九分` 等钟点保留；两位小数只有后接单位、百分号、`万/亿` 或范围连接词时
转换（`三点十四秒` → `3.14秒`）；单数字 `元` 没有 `钱/整/块` 或明确位数时保留
（`二元组`、`一元论`），`分` 只在
`分钟/分钱` 或明确评分上下文中转换（`二分`、`九点九分` 保留）；`下一次`、
`每一天`、`同一人`、`小一号` 等指示短语保留。`N次` 只在序数、边界或封闭计数
延续下转换，`二次感染/二次伤害/二次销售` 等复合词保留。`月/日` 只在明确的
月份、完整日期或封闭时间延续中转换（`三月份`、`三月二十三日`、`五日内`），
`二月二`、`六月飞雪`、`五日京兆` 等保留。完整用户可见边界见
`docs/users/api-contract.md`。

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

文字归属先按对齐区间内各说话人的活动并集覆盖判定。至少两位说话人的活动覆盖都达到
0.60 下限时，该单元属于重叠区域：服务用原生帧的独立分数复核，分别只统计各候选自己
处于 active 的帧，按时长加权求平均分，不以整个文字区间作分母，也不按说话人归一化。
平均分最高者须达到同一 0.60 下限且领先第二位至少 0.10 才能改写标签，因此覆盖差值即使
已经超过 0.10 也可能被更集中的活跃期置信度修订；只有一位说话人达到覆盖下限时，覆盖
标签不被分数推翻。复核只在 final 单元、无活动缺口等降级原因、相关帧完整连续且都有
分数时进行；缺帧、帧相互重叠或开放边界都不使用，证据不足仍为 unknown。覆盖本身不足
的单元仍先用按整个文字区间时长加权的分数判定初始化。成功修订后的 final 单元不再修订，
任何归属修订都不改写 ASR 正文。

单个对齐文字单元内部的无活动停顿可另行判定：整个区间只有一位 active 说话人，且区间
首尾均是该说话人活动时，按其 active 帧的实际时长计算独立分数均值，达到同一 0.60 下限
即可保留该文字归属。相关帧必须完整、连续、不重叠且都有分数、无降级原因；区间外的
邻词标签不作证据，不补齐发声活动，也不把重叠或说话人切换当作停顿。该规则仅处理
覆盖判定和多人分数辅助仍未确定的单元，不覆盖已确定或 final 归属。

相邻文字单元的连续发声可沿用前一 final 单元的匿名说话人：仅当当前单元仍为
`insufficient_evidence`、与前一个 final 单元的音频间隔不超过 0.50 秒、且该匿名说话人在
当前单元的活动并集覆盖达到同一 0.60 下限时生效。该规则不覆盖已有标签，不跨降级、缺帧或
不可用区间，不把静音补成发声；中间单元不会为更早的标签提供旁路，间隔或覆盖不足时仍为
unknown。

最终投影还可使用同一 ASR item 内确定性的双侧文本上下文：连续未知段只有在全部单元均为
`final + insufficient_evidence`，且紧邻其前后的单元也是 final、无降级原因并具有相同匿名
标签时，才继承该标签。孤立或连续未知段均可填充；provisional、其他 unknown 原因、item
边界和不同标签都会阻断。该规则只修正对外 speaker 投影，不改变 `active_speakers`、活动帧
或已有确定标签，也不使用参考文字、模型分数或新的阈值。

归属事件的身份取自对应 ASR final 冻结的 item，不使用后来正在接收音频的 item。
每个 `speechrail.diarization.updated` 只包含该 `utterance_id` 的 units；多个已完成 item 的
修订分别发送。`speechrail.diarization.done` 是会话收尾屏障，只携带最后一个已完成 item 的
快照；更早 item 的修订必须已通过 `updated` 发出，不能把整场 units 挂到最后一个 item。
没有已完成 item 时，`done` 的 units 为空。

`session.speechrail.alignment.enabled` 与 `session.speechrail.diarization.enabled` 各自独立生效：
开启 alignment 即为本连接保留受界限的 PCM 并在每个 ASR final 后运行固定文本对齐，即使
diarization 关闭；关闭 alignment 则不保留 PCM，即使 diarization 开启。两者都只能在首个音频
帧之前改变。`speechrail.diarization.finish` 必须先等齐已冻结 item 尚在进行的对齐任务，再封存
归属账本，并等待归属事件消费者发送完封存前的修订，最后发送会话终态。等待超过
`realtime_diarization_drain_deadline_seconds` 时按 `finalization_timeout` 降级。
原生 EOF 与活动事件排空受同一内部结束预算约束；任一阶段超时都保留
`finalization_timeout` 原因，不因取消引发的活动流错误改记为输出异常，已封存 ASR 正文仍有效。

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

供应商时间网格可能使某些 token 的起止落到同一个样本。在 `segment` 粒度，有相邻的
正时长单元时将这些 token 的原文范围与时间点并入相邻 segment，仍严格校验文本覆盖、
时间单调和冻结音频边界。全部 token 都没有正时长，或请求 `word` / `character` 而出现
这种时间分辨率不足时，返回 `alignment_time_resolution_insufficient`，不均分或虚构时间。

Qwen3 适配器从已加载模型配置读取时间格点宽度。原始时间全部有限、非负且单调时，若尾部
结束点恰好是冻结音频边界最近的格点，仅将这个格点与实际音频边界相交，最多调整半格；
区间内部的时间不移动。非最近格点、非格点越界、倒序与重叠仍交给严格校验拒绝。所有公开
时间范围均留在原冻结 PCM 范围内，格点处理不会增加模型能提供的时间精度。

失败的 `error.code` 区分 `text_mismatch`、`invalid_alignment`、`alignment_out_of_bounds`、
`alignment_not_monotonic`、`granularity_unsupported`、`alignment_time_resolution_insufficient`、
`alignment_pcm_mismatch`、`alignment_pcm_overflow`、`alignment_timeout`、`alignment_overloaded`、
`alignment_worker_failed`、`alignment_unavailable`、`alignment_stale` 与兜底 `alignment_failed`。
`error.message` 是按类别生成的安全说明，不携带转写正文、音频、模型路径或异常正文。

### 匿名分人后端与容量

`session.speechrail.diarization` 接受 `enabled` 和可选 `backend`，后者支持
`sortformer`、`meeting_dynamic`；省略时默认为 `sortformer`。`meeting_dynamic` 还接受
`max_speakers`（1–4 的整数或 null），表示本连接稳定身份预算上限；省略或 null 使用
认证容量。`sortformer` 不接受非空预算，不会静默忽略。音频输入开始后不能更换后端或预算；
音频前修改预算会重建匹配器，不能只改变回显。
同一次捕获仅运行所选的一种分人后端；分人不可用不会改写已确认的文字。

会话更新回显包含 `enabled/backend/max_speakers/system_cap`。能力发现对每个后端分别返回
`ready/reason/max_speakers/system_cap`，并与本地制品、对齐能力和实际准备状态一致。
`system_cap` 固定为 4，表示整场最多维护四位稳定匿名身份，不能作为准确率证明。
能力发现中 `meeting_dynamic.max_speakers` 是独立质量验收通过的稳定身份上限（1–4）；
未认证时为 null、生产 not-ready。请求预算不得超过认证容量，否则拒绝分人协商。
会话回显 `max_speakers` 为本连接实际预算，App 与 native preflight 都核对请求值，防止
旧制品仅回显或忽略约束。预算不修改共享认证策略或其他连接；填多不会强制创建身份，
填少或中途新增发言人时不放宽匹配阈值、不轮换已有身份，超额声音拒识。
它不是出席人数或实际开口人数的限制：超额与不确定声音
保持未识别，不建立第五个身份，不回收已有身份来轮换使用。原有 5–32 身份认证配置不再
满足该后端的生产准入；回退应使用成套旧 runtime 与匹配策略，不能只修改容量字段。
服务不会在请求中下载制品，也不会用四槽结果冒充多人识别成功。

动态活动使用私有 v2 IPC，Python 严格将全场 slot n 映射为 `S(n+1)`，不按到达顺序重新编号。
标签只在分人 session 内有效，不表示真实身份。App 为记录、连接与输入代次绑定新的本地 scope，
界面按首次出现显示「说话人 1–4」，不展示内部键。重连后的 S1 不能关联到旧人的保存行；
没有跨连接声音匹配证明时，新增自动归属保持未识别，旧行与人工标注保留。
原型与音频只保留在有界 RAM；不保存声纹库或跨会话身份。

未知活动原因限定为 `identity_uncertain/speaker_capacity/activity_gap/audio_expired/model_not_ready`。
任一词覆盖明确的拒识证据或跨越两位身份时，不以多数覆盖、概率或邻接文本补为已知。
未知与已知声部重叠时，未知不能被静默丢弃。匹配需足够的独占语音证据，且声音参考更新
和后续匹配均受最初参考约束，拒识片段不更新已确认身份。
对齐缺失、身份不确定和后台故障分别诊断；未知不能当作正确识别，也不能默认归给第一位说话人。
关闭等待结束不等于原生计算已停止；实际 child 回收未确认时保持资源所有权并隔离后续准入，
由操作者恢复服务，不循环重试。

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

`completed` 额外携带三个**可选**延迟观测字段：`ttfa_ms`（从 `start` 被接受到第一段
`audio.delta` 可用的毫秒数）、`audio_ms`（本 utterance 已交付音频的时长）、`rtf`（墙钟时间
除以音频时长）。三者都是**观测值**，不参与准入、重试、预算或质量判定；字段缺失表示"没测到"，
不等于 0。`rtf` 在增量路径上包含等待调用方消费窗口的时间，因此它是模型速度的下界，不是模型
基准。`cancelled` 与 `failed` 不携带这些字段。

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

<a id="revision-window-transcription"></a>
## 6. 修订窗口转写 (Revision window transcription)

转写会话可在音频输入前通过 `session.speechrail.window={"mode":"revision_window_v1","scene":"meeting"|"caption"}` 显式协商启用近期文字回溯。`window` 与 `asr` 策略互斥。仅当该能力、共享 Worker 窗口 IPC 及词级对齐均就绪时，服务端才在 `session.updated` 中回显 `window.policy`；缺少任一前置条件均在音频捕获前明确拒绝协商。客户端不可覆盖生效的窗口预算。该能力默认关闭。

| 场景 (`scene`) | 独占输入 (`Owned input`) | 复核宽限期 (`Review grace`) | 左侧上下文 (`Left context`) | 最长解码时长 (`Maximum decode`) | 预览间隔 (`Preview cadence`) | 封存预算 (`Finalization budget`) |
| --- | --- | --- | --- | --- | --- | --- |
| `meeting` | 20 s | 2 s | 2 s | 24 s | 1500 ms | 15 s |
| `caption` | 4 s | 8 s | 2 s | 14 s | 500 ms | 5 s |

上下文复核未完成时，服务可在原定封存截止时间内对独占 PCM 精确重试一次。该重试拥有全新的尝试标识符，不延长音频输入区间或时间预算。纯独占重试仍未完成、结果陈旧或超时将产生覆盖失败（failed coverage）；未完成的文本绝不执行封存。

所有公开的时间区间均为 24 kHz 样本的半开区间。在底层，每个 16 kHz 原始采样在进入语音准入前均写入连续内存环形缓冲区一次，预滚（pre-roll）决策均基于此环形缓冲区。静音前沿不得越过准入保留的输入或未打分的 VAD 残留帧。`silence/vad_not_admitted` 描述的是准入状态，而非人工声学真值标注。

`speechrail.transcription.window.updated` 携带完整的可变 `units` 快照（包含删除项）。三元组 `(session_id, input_epoch, window_id)` 在同一输入代次内固定。快照内容出现任何变更均递增 `window_revision`；客户端可以跳帧但必须丢弃更旧的快照。每个 unit 维护独立的 `text_revision`。该模式下不提供稳定前缀（stable partial-prefix）保证。服务端快照与事务包含可选布尔字段 `falling_behind`：在字幕场景中，若在至少 2 秒的已接受音频内，出现三次间隔至少 500 ms 的已准入语音且未展示预览，该字段置为 `true`；当预览或终态覆盖追赶上时清除。该字段为输入进度预警，非人工词级时间戳度量。状态变更即使未伴随文本变化也会触发新的 window revision。字幕场景在上下文复核到期前会先完成一次待处理的独占块预览，不会为了等待复核宽限期而延后显示块尾文字。

`speechrail.transcription.window.sealed` 与 `speechrail.transcription.window.failed` 携带 `transaction_id`、`closed_span`、`sealed_through_sample`、`remaining_units` 以及连续的 `coverage`；`.sealed` 携带 `final_units`，而 `.failed` 仅携带包含 `recovery_text` 及有界失败原因的 `failed_items`。封闭区间始于前一边界。任何事务均不得切断独占词/单元或改写已封存文字。被复核的空文本仍具有 coverage。客户端原子应用整个事务，并结合本地会话/连接绑定持久化冻结批次。事务内每个 item 随后输出官方 `segment_closed` 及一个 `completed` 或 `failed`，镜像事务内容且不制造重复记录。

可选输入完成屏障紧随所有冻结窗口事务及 item 终态到达。在此模式下，屏障回执额外要求 `window_revision`、`sealed_through_sample` 与 `failed_items_count`。该回执确认已接受音频退役（包含明确失败的 coverage）；数据库持久化确认与说话人收尾是彼此独立的屏障。投递失败的事件绝不会产生成功回执；丢失回执绝不授权投机性 clear。

窗口硬限制：最多 32 个可变 units，每个 unit 最多 8192 Unicode 码点，整窗口总计不超过 32768 码点；单个事件不超过 256 KiB；标识符长度 1–128 码点；保留 16 MiB PCM 拷贝容量。整数字段拒绝布尔、小数和不安全数值。单连接内保留最近 64 个指纹用于重复提交检测；断线重连不恢复旧窗口。上下文裁剪需要完整的词级对齐证据；模糊边界允许在同一截止时间内进行一次无前缀的纯独占重识别。失败保留恢复文本而非伪造时间戳。

## 7. 错误

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

## 8. 明确拒绝项

`transcription_session.update`、`session.updated` 客户端事件、`conversation.*`、`response.create`、
`response.cancel`、`response.audio.*`、`response.audio_transcript.*`、旧根级 model/language/
audio_format、LLM tools/modalities/instructions、旧四档名、Q4/Q6、Design Q8/Design runtime voice、
旧平铺 `input_audio_format`、假 context 开关和未实现表达参数均明确拒绝，不提供 alias。

## 9. 验证入口

```bash
uv run --extra dev pytest --no-cov tests/test_realtime_current_schema.py
uv run --extra dev python scripts/check_realtime_contract.py
swift test --package-path macos/SpeechRailApp --filter RealtimeContractTests
```

schema 与共享 fixture 同时由 Python、Swift 和脚本读取。契约、测试与实现必须同批更新；HTTP
OpenAPI 不复制 WebSocket schema。MCP 仍是 REST proxy，不转发 `/v1/realtime` WebSocket handle。
