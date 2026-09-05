---
title: "SpeechRail × Sona 讲话人分离端到端设计"
status: under_review
audience: "SpeechRail 与 Sona 实施者、接口与质量评审者"
version: "1.0.0"
date: 2026-09-05
---

# SpeechRail × Sona 讲话人分离端到端设计

> 设计编号：`SPK-E2E-1`。本文是待实施的目标规格，新增字段、事件、参数和指标均不是当前服务承诺。用户已要求形成可执行文档；本文不代表已经授权部署、模型下载或数据迁移。

配套：[SpeechRail 实施计划](../superpowers/plans/2026-09-05-speaker-diarization-e2e.md)。Sona 配套文件为 `sona/docs/architecture/speaker-diarization-e2e-design.md` 和同日期实施计划；若两仓库同级检出，可直接打开 [Sona 设计](../../../sona/docs/architecture/speaker-diarization-e2e-design.md)。公共扩展以本文第 5 节为唯一设计事实源，实施后转入 `contracts/realtime-openai.md`，两仓不得分别发明字段。

## 1. 目标、边界与选择

目标：中文优先、1–4 位实际讲话人、单机连续两小时会议；字幕低延迟，讲话人归属可修订；重连不错误继承实名；会议结束得到可追溯的确认文本与归属。超过四人明确超出首期验收范围。Diarization 标记谁在何时说话，不分离干净音轨，不保证同时讲话内容都能被 ASR 识别。

| 决策 | 采用 | 未采用及理由 |
|---|---|---|
| 分人主链 | SpeechRail 持续 Sortformer 状态，独立于 ASR commit | 每句重新 `.diarize()`：局部槽位不是持续身份 |
| 标签稳定 | 会话内声学状态 + 可选 CAM++ 短时关联 | 永久声纹库、实名识别：超出项目职责与数据边界 |
| 长会议 | 有界在线处理，结束只冲刷尾部 | 整场 PCM 缓冲 + 会末重跑：耗时、截断、失败后无法恢复 |
| 对外演进 | `/v1/realtime` 显式 opt-in 加法扩展 | 重建私有 `/v2/realtime` 或向旧客户端广播新事件 |
| 资源 | 复用当前模型 owner；单个有界分人执行队列 | 新 HTTP 服务、复制 ASR worker、会中 batch ASR |
| 正文 | commit 的最终文本为唯一正文，时间戳必须与它一致 | 第二次解码悄悄替换正文；LLM 猜测讲话人 |

SpeechRail 管推理、匿名声学状态、接口和资源上限。Sona 管音频来源、会议时钟、持久化、人工更正、UI、纪要。PCM、embedding、模型 snapshot 和基准原始制品不得进入代码仓库；SpeechRail 不持久化 PCM/embedding/姓名，Sona 不持久化音频。本方案不改变 Python `>=3.12,<3.13`、单服务单 ASGI worker、请求路径离线和三档统一架构约束。

## 2. 调研基线与证据边界

2026-09-05 源码基线：SpeechRail `eb66f86`，Sona `54b34cf`。22:05 CST 的只读探针报告 SpeechRail `1.7.0`、`light`、`asr-0.6b-q8`，`/readyz.ready=true` 且 `diarization.ready=true`；未进行本轮多人录音、DER、CPU 或内存实测。部署中的 wheel 与工作区逐文件一致性未核验。不要从该探针推断 Sortformer 权重版本、CAM++ 已配置或性能已验收。

| 代码事实 | 依据 | 实施含义 |
|---|---|---|
| commit 触发额外解码获得时间戳 | `Qwen3Engine.align_session_audio`、`_handle_commit`，`src/speechrail/backends/qwen3_worker.py` | 不是已证明对固定正文进行的纯强制对齐，必须核对文本一致性 |
| 分人 adapter 消费并清空累积 PCM，调用 `.diarize()`；模型恢复到 CPU | `_NemoSortformerSession.annotate`、`NemoSortformerEngine._load_local_model`，`src/speechrail/backends/nemo_sortformer.py` | 尚非跨输入块保留 NeMo streaming state 的接法 |
| adapter 累加音频偏移，ASR commit 后关闭并重建会话 | 上述 adapter 与 `OpenAIRealtimeSession._commit_audio` | 第二个 commit 必须测试 item-local 与 session-global 时间基准 |
| `confidence` 是各 speaker 时间交集占比 | `_assign`，`src/speechrail/backends/nemo_sortformer.py` | 不是身份概率；单候选 1.0 不可视为绝对可信 |
| `speaker_count_hint` 接受 1–8，解析时过滤超出编号活动 | `domain/diarization.py`、`_parse_activities` | 不会让四槽位模型可靠识别八人，也不是人数约束推理 |
| CAM++ 收尾 mapping 存在，但 WS completed 发送路径只交付主 speaker | `application/diarization.py`、`application/realtime_openai.py` | remap、重叠和修订必须端到端接线 |
| Sona 严格拒绝未识别事件；EOF 当前为 commit→clear acknowledgment | `sona/speechrail/transcription_events.py`、`transcriber.py` | 扩展只能在协商成功后发送，不能默认广播 |
| Sona overlay 默认 1800 秒，裁剪后没有全局 offset；批接口还受各层长度限制 | `sona/config/meeting.py`、`meeting/diarization_overlay.py`；本仓 `domain/ports.py` | 不能将尾部结果套到整场，也不能从 HTTP upload 上限推断可处理整场 |

代码图 Tier 2 查询后，关键证据路径 coverage 返回 metadata_match、无记录缺口；这不是完整性证明。上述风险为源码推断，实施任务必须以回归测试证实并修复。旧 ADR/手册关于会话内稳定、全部模型均进程隔离或 remap 已闭环的概述，不替代当前 adapter 和 transport 代码。

## 3. 端到端不变量

1. 一个接收 PCM 样本只推进一次推理时间；VAD、commit、重采样块大小不能让后续样本回到零。
2. ASR 最终正文固定后，分人更新只能改归属，不能改正文、词边界和 segment 身份。
3. `speaker=null` 表示未知，不创建“第 0 位真人”；文字必须保留。
4. speaker ID 只在产生它的 session 内有效；跨 session 相同编号不证明相同人。
5. 重叠必须来自同一帧多个活动 speaker；一个词跨越 A→B 边界并不自动表示同时讲话。
6. 旧客户端看到旧事件集合；未协商的扩展拒绝或忽略必须按第 5 节定义，不能随机降级。
7. 冻结后的词不再自动改归属；会末不对整场发全量重写。
8. 所有缓存受时长、对象数、字节数上限约束，超限显式报错或结束分人，禁止静默丢 PCM。

## 4. 推理与时间设计

### 4.1 三条时间线

内部以整数 sample index 为主：16 kHz PCM16，`samples = len(pcm) // 2`。用累计样本计时，不累加每个小包四舍五入后的毫秒。

| 时间域 | 零点 | 转换责任 |
|---|---|---|
| ASR item-local | 本次 ASR 输入开始 | SpeechRail 记录 `item_start_sample`，将 vendor 时间加一次该偏移 |
| SpeechRail session-global | 此 WS 第一个接受的 PCM 样本 | 扩展事件 `audio_start_sample/audio_end_sample` 均使用此域 |
| Sona meeting-global | 会议采集开始 | Sona 维护 source epoch 的分段映射，将 session sample 转为会议时间 |

例：第一 item 接受 48,000 samples；第二 item 的词在本地 `[1600,4800)`，session 区间必须为 `[49600,52800)`，即 `[3100,3300)` ms。不能保持 `[100,300)` ms，也不能在 Sona 再加一次第一 item 偏移。

新协议下 Sona 只从 sample 字段换算，旧协议仍使用既有秒制兼容适配。禁止改变旧 `start/end` 的时间域来假装兼容。静音继续送入分人时钟；真实暂停/采集故障导致时间不连续时，Sona 关闭当前 epoch，新建 epoch，不拼接成连续录音。重放只覆盖尚未持久确认的后缀，详细算法见 Sona 规格。

### 4.2 一个权重实例，独立流状态

新增内部 `ContinuousDiarizationSession`，由 `DiarizationCoordinator` 持有，生命周期覆盖整个 WS 的分人阶段。ASR commit 只结束 ASR item，不 reset 分人状态。每个 session 独立持有前端特征缓存、Sortformer FIFO/AOSC、输出偏移和匿名标签；权重只加载一次。

```python
class ContinuousDiarizationSession(Protocol):
    async def append(self, pcm: bytes, start_sample: int) -> None: ...
    async def activities(self, through_sample: int) -> ActivitySnapshot: ...
    async def finish(self, through_sample: int) -> ActivitySnapshot: ...
    async def close(self) -> None: ...
```

以上为拟新增 port，非已存在接口。`ActivitySnapshot` 包含 `processed_through_sample: int`、`stable_through_sample: int`、`activities: tuple[SpeakerActivity, ...]`；`SpeakerActivity` 包含 `start_sample/end_sample: int`、`speaker: str`、`activity_score: float`。只返回调用方尚未消费的有界尾部，不能附带整场预测 tensor。

采用 NeMo 原生 streaming step，适配层固定经过核验的 NeMo 版本和本地模型 snapshot。官方 API 存在 `forward_streaming_step`/streaming state 路径，但不假定本机已安装版本同名同签名。先做 R1 探针：核对安装版本、前端增量特征处理、左右上下文、首尾 padding、offset 和状态释放；不能简单把每个 PCM 块独立算 mel 后拼起来。

首轮候选参数采用模型卡低延迟组合：`chunk_len=6`、`chunk_right_context=7`、`fifo_len=188`、`spkcache_update_period=144`、`spkcache_len=188`，单位是 80 ms 模型帧。其输入缓冲延迟 1.04 秒不含 CPU 计算。所有参数、实际 API、device 和模型指纹进入去敏的基准元数据。

如果本机锁定版本不能提供可靠增量调用，R1 判失败，不在生产中暗换 API、不复制上游整套语音 agent。可在离线实验中用 12 秒窗口/2 秒步长对比，但它不是本方案的自动运行时 fallback；达不到稳定性和实时门就维持旧版本并显示能力限制。

### 4.3 正文与对齐

`completed.transcript` 经既有轻量 ITN 处理后是唯一 canonical text。本期不新增强制对齐模型。现有二次解码可以提供候选 timestamps，但必须通过下列检查：

1. 使用同一 language、prompt/keywords 与 ITN 规则，禁止当前 `auto`/空 prompt 隐式丢弃上下文。
2. 对正文和候选分词构造保留索引映射的比较序列：NFKC，去空白与标点；不删数字、不做同音字替换、不用 LLM。
3. 比较序列完全一致，时间有限、单调且位于本 item 音频内，才将候选边界映射到 canonical text 的字符范围。标点并入前词，开头标点并入首词。
4. 归属单元携带 `text_start/text_end`（Unicode code point，左闭右开）并完整分割 canonical text；单元文字由 canonical text 切片得到，拼接须逐字等于全文。
5. 有任何不一致，该 item 使用一个 `timing_quality="unavailable"` 的未知归属单元，覆盖整段 canonical text；sample 区间为 item 音频范围，禁止当成词级精确时间。

这样牺牲局部可分人覆盖率，换取不丢字和不改字。未知率纳入质量门；未来固定文本 forced aligner 属于独立模型选型任务，不能在此默默加依赖。

### 4.4 归属、重叠与冻结

在连续活动区间上计算每个词的交集，输出 `coverage_ratio`（有活动覆盖/词时长）和候选 `support_ratio`（该 speaker 活动覆盖/词时长）。不同 speaker 的 support 可以同时较高，不做总和为 1 的伪概率归一化。

初始实验阈值：活动 onset/offset 为 0.60/0.40；最小活动 160 ms；`coverage_ratio>=0.60` 且第一/第二候选支持差 `>=0.20` 才给主 speaker。`overlap_ratio>=0.20` 标记真实重叠，不强行给唯一归属。阈值是开发集起点，正式值经 R5 验收写入版本化 preset。短插话不因时长单独归给邻人。

归属 `status` 为 `unknown | tentative | stable`。词结束后保留最多 3 秒的自动修订时间；当活动 watermark 覆盖词尾且该词在至少两个有效推理步归属一致时，可 stable。3 秒到期仍无足够证据则终止为 unknown。`stable_through_sample` 表示此时间以前不再自动修订（也包含终止为 unknown 的词），不是“以前全部正确”。EOF 冲刷后也遵守这一点。

### 4.5 CAM++ 和重连

CAM++ 在 Sortformer 已判定非重叠、无明显削波、累计有效语音至少 2 秒的片段上提取；每次最多 5 秒。一个匹配至少需要两段互不重叠的证据。初始余弦阈值 0.80、第一/第二候选差 0.10，仅作开发集参数；模型输出维度从其 manifest 校验，不能从其他 embedding 模型推断。

会话内优先使用连续 Sortformer 标签；CAM++ 不根据一个词重命名整场。匿名 group 由 Sona 从 owner scope 与 meeting UUID 派生，不能传姓名。服务内部以认证主体、group ID、模型指纹隔离（无鉴权 loopback 使用本地单用户主体）。短时 cache 保留质心和别名，不保留 PCM；TTL 沿用 900 秒，活跃输入更新存活时间，最长会议 2 小时范围内不因静音误过期。

每 group 最多 4 个 canonical 质心、每质心最多 8 个样本摘要、最多 4 个近期 session 的别名；group 总数继续使用现有有界配置。模型指纹改变、进程重启、TTL 到期后生成新的 `group_generation`，Sona 不跨 generation 自动关联。

公开 `speaker` 仍 session-scoped。重连只通过第 5 节显式 `speaker_links` 提供“同一讲话人”的声学建议；无证据保持新匿名人，绝不复用同名编号推断。group ID 与 generation 是隔离/失效机制，不是授权凭据或实名识别能力。

## 5. 公共扩展草案 SPK-E2E-1

### 5.1 协商与兼容

新增能力字符串 `speechrail.diarization.v1`，仅在增量 adapter 和契约实现均可用时列于 `session.created.capabilities`。Sona 必须先读能力，再显式设置；未知扩展不得先发送再试错：

```json
{
  "type": "session.update",
  "session": {
    "input_audio_transcription": {
      "model": "gpt-4o-transcribe-diarize",
      "language": "zh",
      "diarization": {
        "enabled": true,
        "group_id": "0123456789abcdef0123456789abcdef",
        "extensions": ["speechrail.diarization.v1"]
      }
    }
  }
}
```

`extensions` 为拟新增、去重且只允许登记值的数组。`session.updated` 增加 `diarization_contract`，包含 `version:1`、`timebase:"session_samples"`、`sample_rate:16000`、`max_speakers:4`、`max_revision_delay_ms:3000`、`group_generation`（无 group 为 null）。未成功回显即未启用。扩展只能在首个 PCM 前协商，流中修改返回 `invalid_state`。

旧客户端：保持现有 session/update/segment/completed/clear 行为，不发送新 type，不重新解释旧 start/end。新旧组合：新 Sona 连旧 Rail进入可见 legacy 模式；新 Rail 连旧 Sona保持 legacy。纯字幕、语音助手、REST 不受新协议影响。`speaker_count_hint>4` 在新扩展入口明确拒绝 `speaker_limit_exceeded`；旧入口保留兼容校验但文档声明真实上限。1–4 提示不再裁掉模型输出，也不被描述成准确人数。

### 5.2 固定文本和归属单元

新模式的 committed/item/completed 使用每次 commit 唯一 `item_id`。`completed` 保持 `transcript`，新增 `audio_start_sample/audio_end_sample`、`attribution_units`；后者定义稳定 segment UID、canonical text 范围和时间质量。此模式不再同时发送旧 `.segment`，避免双写；该差异必须通过显式扩展协商约定。

```json
{
  "type": "conversation.item.input_audio_transcription.completed",
  "event_id": "evt_example_1",
  "session_id": "sess_example",
  "sequence": 12,
  "item_id": "item_example_2",
  "content_index": 0,
  "transcript": "同意。",
  "audio_start_sample": 48000,
  "audio_end_sample": 56000,
  "attribution_units": [{
    "segment_uid": "seg_example_2_0",
    "text_start": 0,
    "text_end": 3,
    "audio_start_sample": 49600,
    "audio_end_sample": 52800,
    "timing_quality": "aligned"
  }]
}
```

`segment_uid` 在 session 内唯一，长度 1–128，ASCII 不透明 ID；Sona 不解析其格式。每 item 最多 4096 单元，字符范围必须无重叠无缺口；空 transcript 使用空数组。无有效对齐时整 item 单元 `timing_quality="unavailable"`。这些字段不可在归属修订中改变。

### 5.3 归属更新

新增 `speechrail.diarization.update`，只引用已经完成文本交付的单元。每消息最多 256 条更新，最多 16 条跨会话关联；同 segment 的 `revision` 从 1 严格递增，重复 revision 必须同内容。同连接 WebSocket 顺序交付，revision 只计该 segment 的归属更新，不与顶层 sequence 混用。

```json
{
  "type": "speechrail.diarization.update",
  "event_id": "evt_example_2",
  "session_id": "sess_example",
  "sequence": 13,
  "group_generation": "generation_example",
  "stable_through_sample": 52800,
  "updates": [{
    "segment_uid": "seg_example_2_0",
    "revision": 1,
    "status": "stable",
    "speaker": "spk_01",
    "coverage_ratio": 0.95,
    "overlap_ratio": 0.0,
    "candidates": [{"speaker":"spk_01","support_ratio":0.95}]
  }],
  "speaker_links": []
}
```

ratio 必须是有限 `[0,1]` 数字且不接受 bool；候选最多 4 位不同 speaker。`unknown` 主 speaker 必须 null，仍可附候选。`stable` 表示算法冻结，不表示人工确认或真实身份。

跨 session `speaker_links` 元素固定为 `{link_id, from_session_id, from_speaker, to_session_id, to_speaker, relation, similarity}`，`relation` 只允许 `same_speaker`；`link_id` 在 group_generation 内唯一，similarity 是余弦分数而非概率。两端必须属于同 group_generation，至少一端为当前 session，服务仅引用其仍持有的近期别名。它是不可传递放大的建议；Sona 处理人工命名冲突后才关联，不把 A≈B、B≈C 自动闭包成 A=C。首期不发全局 `raw_label→raw_label` merge 字典。

### 5.4 正常结束、取消与故障

1. Sona 停止新 PCM，发送最后一次 `input_audio_buffer.commit`。
2. 服务完成 canonical text 和初始归属；commit 不代表分人生命周期结束。
3. Sona 发送 `speechrail.diarization.finalize`，字段 `{event_id, finalization_id}`，ID 长度 1–128。服务串行处理此前输入，并固定 `through_sample` 为已接受样本数。
4. 服务进入 DRAINING，拒绝后续 append（`invalid_state`），冲刷声学尾部和待定单元；发送必要 update 后，发送 `speechrail.diarization.finalized`。
5. finalized 固定字段为 `{event_id, session_id, sequence, finalization_id, through_sample, stable_through_sample, status, reason, last_update_sequence}`。status 为 `complete | degraded`；reason 为 null 或第 5.5 节错误码。complete 时两个 through sample 相等；last_update_sequence 是最后一个 update 的顶层 sequence，无 update 为 0。
6. 同 finalization_id 重试只回显同结果，不再次推理；仅缓存当前 session 最后一个 finalization 结果。不同 ID 的第二次 finalize 返回 `invalid_state`。
7. Sona 等待所需更新持久化后，再发送 clear/关闭 WS；clear 是丢弃未提交输入与释放状态，不能替代 finalize。未 finalize 就 clear 或断线仅 close，不伪造 complete。

客户端等待上限使用现有 30 秒 finalization timeout；服务内部 drain deadline 20 秒，为持久化预留时间。超时若仍可发送，返回 degraded/finalization_timeout；不可发送则由客户端超时终止。取消 asyncio task 不证明 CPU 推理已经中止，底层线程未返回前继续占有模型 lease，拒绝下一次冲突推理，禁止懒加载第二份模型。

### 5.5 可恢复与不可恢复错误

| 条件 | 结果 |
|---|---|
| 无可用 profile / 不支持扩展 | 配置期拒绝 `diarization_not_available` / `unsupported_operation`，未接受 PCM |
| 不能匹配固定正文的时间戳 | 文本 completed 正常，unknown 单元；无错误断连 |
| 活动证据不足 / 重叠 | unknown 或 tentative，保留候选和文字 |
| 分人积压超过 5 秒或待修订单元超限 | 扩展状态 degraded，reason=`diarization_overloaded`；保留 ASR 文本，余下单元 unknown |
| native 推理异常、时间非法或维度不匹配 | degraded，reason=`diarization_invalid_output`；不输出无效标签 |
| finalize 超时 | degraded，reason=`finalization_timeout`，Sona 禁止将讲话人结果标为完整 |
| ASR 自身错误 / PCM 序号矛盾 | 既有稳定 error envelope；停止该 epoch，Sona 记录 gap |

进行中降级通过新的 `speechrail.diarization.status` 事件交付，字段 `{event_id, session_id, sequence, status:"degraded", reason, since_sample}`。它只在 opt-in 模式出现，每 session 只发生一次 active→degraded；后续 ASR completed 继续正常交付，必须仍给 unknown 归属单元。初始 profile 缺失不能自动开始假多人会议，Sona 只可由用户明确选择“仅转写”。

## 6. 资源、调度和音频所有权

- 单个有界 native 执行队列，推理调用串行，至少两 WS 的状态隔离经过 fake 测试；不承诺两个真实分人会议同时达到质量门。
- 原始 PCM ring 初始上限 30 秒，即 960,000 bytes/session；增量特征缓存和 AOSC/FIFO 单独计量；待修订最多 4096 单元、最长 30 秒，先达到任一限即执行明确降级。消息 max 256 更新分批发，不能把整场聚合成一个消息。
- 已稳定词和活动区间在发送并超过修订窗口后释放；服务不保存整场 transcript/total_preds。ASR 自身已有缓冲仍受原配置限制，不能把分人 ring 上限误当总内存。
- 若 native API 累积 total_preds，adapter 必须在消费后裁剪并保留全局 frame offset；两小时测试验证 tensor 元素数有界。
- 相邻纯静音保持时钟，减少无价值 CAM++ 提取；有 active lease 的模型禁止 idle eviction。回收必须同时考虑引用计数、队列任务和最后活动。
- 本期不要求新增独立分人进程。当前 NeMo adapter 通过线程调用 CPU 模型是源码现状；若实测需进程隔离，另立运行时 ADR 与部署回退方案，不能冒充现有 worker IPC 已包含分人。
- Sona 会议模式不同时启动助手麦克风消费；内心 OS/摘要不得拖垮 ASR 队列。batch ASR 必须在 streaming lease 释放后才能运行。

## 7. 模型选择与验收门

先修协议和状态，再比较模型。会议 ASR 质量基线用 balanced（1.7B q8）；quality 的 ASR 相同，仅为 TTS VoiceDesign 切换没有会议识别收益。本次不更改当前 light 档。Sortformer v2.1 为候选，不仅凭名称或官方 GPU RTF 判胜；pyannote Community-1 仅为未来复杂会后任务的候选，不进入首期依赖。

模型获取遵循项目 ModelScope 优先规则；只有目标版本/格式/完整文件不可验证时说明理由并回退官方源。下载、加载、改 profile 和发布属于后续运行态任务，执行前沿用项目 SOP。

### 7.1 评测集与计分

最低规模：12 段各 5 分钟的人工标注中文材料，加 1 次两小时 soak。六类各两段：单人、双人轮流、四人轮流、短插话/相似音色、重叠、远场/系统输出。每类一段仅用于调参、一段只用于验收；使用公开许可或授权非敏感材料，TTS 只用于协议 smoke，不替代真人质量验收。

保留真值 RTTM、逐字正文和词级/字级讲话人标签于仓库外；报告只含匿名 clip ID、聚合指标及 manifest 哈希。采用同一最优匿名标签匹配计 DER，不用每个片段重新匹配掩盖编号漂移。DER 主表 collar=0 且计 overlap，附表可给 250 ms collar，但不能混表比较。

| 指标 | 首期验收门（目标，非实测） |
|---|---|
| 确定性契约 | 时间偏移、文字丢失/重复、跨会话误继承、人工更正被覆盖均 0 |
| 人工真值 DER | 清晰 1–4 人非重叠集合 ≤15%；远场/重叠集合 ≤25%；同时不得差于旧链路 |
| 中文 CER | 不比同档纯 ASR 基线增加 0.5 个百分点以上 |
| 讲话人归属文字错误率 | 按字计归属错误和 unknown，清晰集 ≤10%；单列 unknown 占比 ≤5% |
| 字幕首次显示 P95 | ≤2 秒（从对应语音起点计，另报冷启动） |
| 稳定讲话人 P95 | ≤4 秒（从该词结束到客户端应用修订计） |
| 推理总忙时/音频时长 | ≤0.7；native 队列积压 P95 ≤2 秒，无持续增长 |
| 长会议 | 两小时含第 31/61/91 分钟边界、一次重连和一次 16 分钟静音；无历史错位、无长期 tensor 增长 |
| 内存 | 报物理 footprint；模型热身后最后 30 分钟相对首个稳定 30 分钟增长 ≤10%，所有逻辑缓存遵守硬上限 |
| 结束 | 正常情况 ≤30 秒得到持久化后的 complete/degraded；超时显式可见 |

若不同阈值的模型排名不一致，选择满足上述全部门且端到端误归属最少的组合。未过门不宣称“最佳”已验证；发布前可以经评审修改目标，但必须保留旧门及修改理由，不能测试失败后无记录降线。

## 8. 发布和回退

执行顺序：`R0 → R1 → (R2,R3 串行实现) → S0/S1 → S2 → R4/S3 → R5/S4`，任务定义见两份计划。此处表示依赖，不授权多 Agent 并行。

1. 两端先交付 legacy 修复与测试，不改当前服务配置。
2. 新 Rail 支持扩展但不默认启用；新 Sona 的扩展开关默认 false，先完成 schema 加法迁移与旧客户端兼容。
3. fake 四组合矩阵通过，再在受控会议中启用；关闭自动 batch overlay；通过真人与两小时门后才能改默认。
4. 回退先结束当前会议，关闭 Sona 扩展开关；保留新增数据库列/表和已记录未知状态，禁止逆向删除数据。确认新 Sona 可消费旧 Rail 后再按服务 SOP 恢复上一 wheel。
5. 发生重连，旧 PCM 若已丢弃无法从 journal 重建；如实保留 gap。回退不以恢复隐式联网、Sona 本地模型或会中 batch 模式实现。

## 9. 外部依据与未验证事项

来源核验日期 2026-09-05。官方模型卡的测试是其数据与硬件上的结果，不代表当前 Mac。

- [NVIDIA Sortformer v2.1 模型卡](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1)：四人上限、低延迟参数、输入延迟与计算耗时区别。
- [NVIDIA Streaming Diarization API](https://docs.nvidia.com/nemo/labs-voice-agent/nemo-voice-agent/nemo_voice_agent/pipecat/services/nemo/streaming_diar/)：每流 streaming state 和 step 调用结构。只作适配依据，不引入完整 Voice Agent 项目。
- [NeMo 模型 API](https://docs.nvidia.com/nemo/speech/nightly/asr/speaker_diarization/api.html)：低层增量接口；nightly 文档不能替代本机版本签名核验。
- [3D-Speaker](https://github.com/modelscope/3D-Speaker)：CAM++ 特征与声学聚类职责。
- [pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1)：未来会后对照候选，首期不安装。

仍需实测：本机 NeMo 增量 API/CPU 实时余量、CAM++ 是否已有完整本地制品、真人 DER/CER、正文一致性检查的未知率、两小时资源边界及真实设备回声。上述各项均有 R1/R5/S4 阻断门，不能被 readiness 或 fake 通过替代。
