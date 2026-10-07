---
title: "共享 ASR #336：冻结预设后的真实验收"
status: in_progress
audience: "SpeechRail 开发者与验收人员"
version: "0.4.0"
date: 2026-10-07
---

# 共享 ASR #336：冻结预设后的真实验收

本记录承接 [#336](https://github.com/hrygo/SpeechRail/issues/336) 与
[WP7 #253](https://github.com/hrygo/SpeechRail/issues/253)。
#245 已按实施完成结案；本记录只按本轮实际证据判定剩余验收，
不把历史 v8 结果或确定性测试转成最终主线的真实通过结论。

## 制品与测量边界

- 首轮测量源码：`ebe42872a792f4e5c60fb14fcc8365ce2aafce4a`，服务版本 `3.8.1`。
- wheel SHA-256：
  `625956251e5867b7466eaa4fbf6d5353ff67ebf77722ae245fca96d44ac6258f`。
  171 个 Python 生产模块与该源码逐字一致；安装后 196 个 wheel 文件逐字核对。
- 2026-10-07 后续核验发现远端 main 已推进至
  `48a0b72637cba3f1abb67bc6d76a3db454a2c2c1`，包括 #338 文档修订和
  #337 worker 回收失败隔离、物理 owner 保留及确认关闭后的准入恢复。
  首轮结果不能自动覆盖这些生命周期生产变更；后续制品须另记精确归属和复核范围。
- 上述 wheel 是冻结主线的测量对象，不包含本轮新增的 decoder 候选修正。
  Realtime benchmark 与 Swift Session 夹具另有文件哈希，不能仅以生产 commit
  代表这些工具修订；候选修正须以新 wheel 另行复测和记录。
- 预设沿用 #319：提词器 `500ms / 8s / streaming_finalize`，
  字幕 `500ms / 8s / full_segment`；助手分轮流、双工及会议预设保持冻结值。
  不采用已否决的 20 秒提词器方案。
- 真实推理走单实例 managed wheel 和公共 API，模型档位为 `quality/quality`；
  使用既有受校验素材，不下载模型、不另启源码服务或第二 worker。
- 原始音频、参考、转写、配置备份、日志和采样留在仓库外受限目录
  `benchmarks/asr-336-20261007/`。本文件只保留聚合统计与 digest。

## 本轮发现并修复的验收工具问题

### 长输入期间消费事件

原 Realtime benchmark 在全部 PCM 上传后才消费接收队列。超过 512 条事件的长输入
会填满客户端队列，即使服务端仍能跟上。现在在每次 paced append 前以及最后的
PCM 等待结束后处理已收到的事件，同时保留 512 条上限、准确 receipt 和输入区间门。
输入期间出现的服务失败也会提前结束上传。

反例用四次 paced packet 产生共 1200 次预览：旧实现第二包前尚未消费任何预览，
测试失败；修复后全部预览被评分，PCM 字节和最终水位不变。修复该工具问题时，Python 定向回归
166 项通过；全量为 3606 passed、1 skipped，coverage 83.37%，类型检查覆盖
171 个生产源文件。这些验证早于后续 decoder、回显与真实 LLM 夹具增量，
不能作为这些增量的通过证据。

### 固定会议回放的采集时间原点

首次临时维护中，助手消费门通过，会议的上传、PCM、区间、终态、识别、receipt
和资源释放门通过，但业务保存校验失败，因而停止后续测量并恢复原服务。
`maintenance-final-main/maintenance-outcome.json` 明确记录
`measurement_completed=false`、`original_restored=true`；这份失败材料保留。

原因是生产保存路径新增了 `clock.now()` 调用，旧夹具使用最后一次返回时间推算
整场输入区间，误把保存时刻当采集原点。夹具现在单独保存首次采集时间，
后续保存观测使用真实当前时间。反例证明后续时钟读取会移动旧原点；修复后的
时间原点和行归属回归通过。没有放宽时间容差或删除业务保存门。

相同 wheel 的第二轮 `maintenance-final-main-v2` 已完成四生产 Session 短回放：
助手一次回复、会议保存、字幕逐项归属、提词器实际推进与手动接管均通过。
这些证据使用真实 ASR 与生产 Session；采集、LLM、TTS 和播放为替身，无 UI 接管。
不证明真人恢复、真实设备、真实 LLM 体验或会议长稳。

## 正在真实对照的生产候选修正

`BoundQwen3Decoder` 原先以预览次数控制首次固定文本前缀。
锁定 vendor 的参考窗口为两次 2 秒解码，但项目预览可以每 250/500ms 到达，
因此两次更新并不代表已经积累 4 秒音频；latest-wins 调度跳过预览也会改变窗口。
候选修正将窗口绑定到上一假设实际解码的 16kHz 音频水位，默认 `64_000` samples。
上一假设尚未覆盖窗口时，即使本次音频突然增长，也不固定那份过早的假设。

预览频率、8 秒分段、`rollback_tokens=5` 和公共契约保持冻结值。
250/500/2000ms 预览、跳帧及跨窗口突增的 fake decoder 反例已用于确定性验证。
这些测试只证明窗口语义，不能证明真实 CER、标点或时延改善。
首轮主线 wheel 的实测结果不得归属于该候选。

助手夹具另增加显式启用的本机真实 LLM 模式，复用生产 `AssistantSession`
与 `LLMProvider`，核对正式终态按音频顺序完整进入唯一用户消息、
一轮一次调用和包含非空白正文的响应。流式错误不能计作完成；
证据写入或响应验证失败时等待会话结束，再向上报告失败。
采集、TTS 与播放仍为替身；
真实语义正确性和设备体验单独保留未验证。

## 新主线与候选的精确制品对照

新主线固定于 `48a0b72637cba3f1abb67bc6d76a3db454a2c2c1`，
wheel SHA-256 为
`1c5ba220dea3ff29762cd199511208e6378ce0deb4e924d314dae8ad13dadf97`。
候选固定于 `5f191cc1af7357d7952ca39192152af750afd991`，
wheel SHA-256 为
`73f4bafa0c1b929e971dbe41f931a149715f06f23ef76c6e4b98934e2dbdd8c3`。
两份 wheel 的包内容差异仅为 decoder 模块和 `RECORD`；
原生分人二进制逐字一致，其 SHA-256 为
`a0eac63b19bde19683b557d8d45c92b6f4eb92c731325e8cd98d9c1f36a87085`。
首次候选构建的原生二进制也有差异，未安装、未测量，不用于单因素结论。

2026-10-07 12:06 UTC，新主线完成四素材池的已知回退与控制样本、
字幕/提词器两预设，共 8 个矩阵、90 个计分请求。
所有计分请求严格保存并核验 `rollback_tokens=5`，
音频覆盖、分段预算、边界/终态计数与资源采样门通过。
相对于首轮 `ebe42872` 的同素材结果，90 个请求的字符错误数逐条一致。
这里的“不新增错误”通过只表示两份主线制品在这个子集上一致，
并未消除下文相对于历史基线的质量回退，也未复测全部 25 个矩阵。

本次 benchmark 源码 SHA-256 为
`ad5fd175ed6097e49a874720e97bd542bb16f4c31c8434877cc0321d96d73da4`。
`maintenance-frozen-main-probe-48a0b726/probe-outcome.json` SHA-256 为
`38169a9e590b54251a6e98cefdc1badd590473e5c825cb48c35dffcfcba3c46c`。
维护记录 `measurement_completed=true`、`original_restored=true`；
12:06:49 UTC 核验原 runtime、vendor、selection、generation 13、
`quality/quality`、ready、空闲与唯一监听恢复。
后续串行维护入口另核验私有配置、selection 与 LaunchAgent 的字节和权限一致。

4 秒水位候选的相同 90 请求对照已完成，逐条“不新增错误”门失败，未采纳。
提词器 `ami-meeting-06` 从 27 错降至 22 错，`fleurs-zh-05` 从 5 错降至 4 错，
但 `ami-meeting-01` 同时从 23 错增至 25 错；每个变化均在三次重复出现。
其余请求的字符错误数一致。改善不能抵消该新回退。
`maintenance-audio-watermark-probe-v1/probe-outcome.json` SHA-256 为
`b3876a71b4e5adc5b017d7a204dc0519cb05b63486afa05ccaaee775527e07b4`。
维护记录 `measurement_completed=true`、`original_restored=true`。

进一步的源码核验发现 `streaming_finalize` 的最终解码仍强制保留旧预览前缀。
新候选保留 4 秒预览窗口，并在最终解码时放开整段文本约束，仍只走流式 decoder，
不另调用完整段转写接口。四个反例覆盖固定语言/自动语言及 rollback 0/5，
旧实现均失败，修正后通过；158 项 decoder、worker、streaming、Realtime control
与策略定向回归通过，Ruff、decoder mypy 与 diff 检查通过。
公共契约与用户文档明确 rollback 调优作用于预览、最终结果可修正整段。
该候选固定于 `ccd68ba04edc39ccd6f7037dc577161be8c63c47`，wheel SHA-256 为
`646216d6524cac1ecb98b5c828c17e60795c72d496ba9d15d6c725eaebf9ee85`。
171 个生产模块与该提交逐字一致；与新主线 wheel 的包内容差异仍只有 decoder
和 `RECORD`，原生二进制相同，独立安装入口校验通过。
2026-10-07 13:22 UTC，90 请求真实对照完成，相对冻结 main `48a0b726` 的
逐条“不新增错误”门通过。以下提词器变化均在三次重复出现：
`ami-meeting-06` 27→22、`ami-meeting-01` 23→20、
`fleurs-zh-05` 5→4、`librispeech-poetry-121-123859-0001` 4→3；
其余请求字符错误数一致。历史质量回退仍未全部消除，不能据此判定完整质量门通过。

每臂每预设 45 请求的 nearest-rank p50 / p95：

| 预设 / 制品 | 首预览（s） | 回放结束后 commit 至最后终态（s，截零） |
|---|---:|---:|
| 字幕 / main48 | 0.491 / 0.510 | 0.131 / 0.271 |
| 字幕 / 最终解码候选 | 0.491 / 0.508 | 0.126 / 0.265 |
| 提词器 / main48 | 0.493 / 0.514 | 0.085 / 0.104 |
| 提词器 / 最终解码候选 | 0.492 / 0.522 | 0.106 / 0.233 |

上述第二项时延对应工具字段 `last_audio_to_final_seconds`。源码实际在按音频
时长等待回放结束后记录 `committed_at`，再以最后终态接收时刻减去该时刻，
负值截为 0；并未记录最后一包的上传时刻或声学结束时刻。因此不能精确称为
“最后上传至 final”或“末语音至 final”；绝对时延与资源门仍为
`unset`，候选未作为正式安装采纳。
`maintenance-final-redecode-probe-v3/probe-outcome.json` SHA-256 为
`7c498e856fa08c449001c198f9b39f21027831ba16322936ffb1841094832e33`。
维护记录 `measurement_completed=true`、`original_restored=true`；
13:22:32 UTC 核验原 runtime、vendor、selection、配置、generation 13、
`quality/quality`、ready、空闲和唯一监听恢复。

随后分支整合 main `3a4cb71357095cdb5a92d05630e86a07d4c9a27d` 的
TTS 准入与回收失败改动。上述候选制品仍归属 `ccd68ba0`，
不能自动覆盖整合后的生产源码；最新双臂矩阵与生产长会须另记制品身份。

新主线的完整矩阵、生产长会和真实本机 LLM 回放另行采集。
PR #340 保持草稿，#253 与 #336 保持开放。

最新双臂已冻结：main `3a4cb71357095cdb5a92d05630e86a07d4c9a27d`，
wheel SHA-256 为
`220e273288f1da6b09a894ebab6e589c7df7b945c6e7bcf0f585b003e05e457d`；
候选 `2aeb670cff791049fc28f592c59b258b3d4dc73f`，wheel SHA-256 为
`dbd03773e1e16038ef0cb9e14debb02b0152db387a11a466ec459dbb39b4d031`。
两臂各 171 个生产模块及 OpenAPI 与对应提交逐字一致；
包内容只差 decoder 与 `RECORD`，原生 helper 与上述 main48 一致。
最新主线已完成四生产 Session、真实 timeout/clear 释放与后继识别、
空成功探查和下述生产 Session 自然长会；完整双臂矩阵结果尚未产生。
真实本机 LLM 安排在两臂的 ASR 测量之后，避免其加载改变配对驻留口径。

### 最新 main：37 分钟生产 MeetingSession

2026-10-07 14:09 UTC，main `3a4cb713` 的真实 ASR、生产 `MeetingSession`
与临时 SQLite 回放完成。输入为同一份未经拼接或重复的自然会议，
音频 `2220.529s`、实际耗时 `2222.563s`。采集使用替身，无 UI 接管；
输入、素材、来源已交付和上传水位均为 `53_292_696` 个 24kHz samples，
结束原因为 `fixture_eof`，未合成尾部静音。

业务保存、采集释放、配置回显、执行、PCM 完整性、receipt、
非空识别、区间、终态及上传的 10 项适用门全部通过；
助手轮次和提词器推进两项不适用。观察到 164 个分段、165 个正式终态、
158 个非空成功与 7 个空成功，2050 次预览；失败终态和服务错误均为 0。
夹具按 item 核验每个已关闭分段恰有一个终态，
额外没有边界的终态只允许空成功；164 / 165 的差异符合这一计数口径。
质量没有唯一 CER gold，门保持 `unset`；真实麦克风和匿名分人均未测。

资源核验时间为 14:16 UTC：3878 个 tick 的采样完整性通过，
其中 3875 个包含生产消费者。每个 tick 按 PID 与启动时间核对，
没有重复计入同一物理进程。采样跨度 `2222.204s`，
最大单 tick 采集跨度 `0.524s`，最大 tick 起点间隔 `0.779s`。
同 tick 物理占用峰值为 `14_794_715_208` bytes（`13.779GiB`），
范围包含真实服务和在 RAM 中保留有限素材 PCM 的生产 Session 消费者。

首尾五分钟总物理占用中位数为 `11.895 / 12.639GiB`，
ASR worker 为 `5.491 / 6.148GiB`，消费者为 `0.020 / 0.107GiB`；
TTS 与 host 基本稳定。五分钟分箱显示 ASR 占用非单调波动，
最后不足五分钟的分箱中位数回到 `5.484GiB`。这些窗口不证明泄漏，
也不证明无泄漏；未设资源绝对阈值，采样不保证捕获每次瞬时峰值。

`maintenance-latest-main-v4/long-production-meeting-outcome.json` SHA-256：
`094af33a85c2d70f79e8be5ea4b561ab645a2fb513787ca374527aa26be7ab34`。
资源原始记录 SHA-256：
`07a7c5c28fc49903851050c1e72e9b12f5ef41857370927bae4820b69b960d31`；
聚合资源核验记录 SHA-256：
`3d9bd37f75de3fb0bc12d3b5591faabf78169d3ed7d5dc8300783af1b629d675`。
长会阶段完成不等于维护结束或原服务已经恢复；恢复另以该臂最终维护记录
和双臂串行入口的配置字节、权限及 managed 服务实测核验。

### 官方会议人工标点补充

标点补充素材从已校验的 AMI manual 1.6.2 官方人工标注中选择，
不生成或改写答案。现有 AISHELL-4 官方标注的 717 个非空区间没有问号或叹号，
不能据此补齐这两个类别。AMI 补充包含 3 个自然会议问句、4 个按时长配对的
句号对照，以及标注归档中唯一的短感叹句（连同紧随的句子保留完整上下文）。
共 8 个音频片段、25.95 秒，来自两份会议 headset 源录音；
每段由官方词时间区间和声道映射确定，
保留相邻停顿内 150ms 的自然音频，不合成音频、不注入参考文本。
HTTP byte range、源 PCM、WAV PCM 和样本区间逐项核对。
annotation archive SHA-256 为
`b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d`，
补充 manifest SHA-256 为
`7144a8b779a7b7d5070255675eabbc3b8991e26ecf5400f1a0d27620d91c943a`。
该素材已在首次推理前冻结，两臂的五预设分别 N=3，共每臂 120 请求。
这是官方正字法人工标注，尚无本轮新增听审；完整源 WAV 未下载和做整文件哈希，
只核验对应范围。感叹句只有一个很短的独立样本，重复不增加类别支持，
不能外推不同语速、情绪或完整可读性门。

2026-10-07 14:40 UTC，最新 main 的五个补充矩阵完成。各矩阵的音频覆盖、
分段预算、终态与资源采样门通过；14:43 UTC 的独立一致性检查另核验
请求身份、冻结策略、标点计数/F1、物理进程去重与峰值重算。
下面是 `human_punctuation_annotation` 的非配对基线观测，
尚不能判定 candidate 相对质量门：

| main 预设 | 逗号 F1 | 句号 F1 | 问号 F1 | 感叹号 F1 |
|---|---:|---:|---:|---:|
| 字幕 / 提词器 | 0.600 | 0.714 | 0.400 | 0.000 |
| 助手分轮流 / 双工 / 会议 | 0.600 | 0.769 | 0.400 | 0.000 |

每预设 N=3 的计分标记数为逗号 15、句号 15、问号 9、感叹号 3；
问号 true positives / false positives / false negatives 为 `3 / 3 / 6`，
感叹号为 `0 / 0 / 3`。问号和感叹号的不同支持片段仍只有 3 和 1，
不能把重复标记数称为独立支持。标点评分采用项目已声明的词法对齐方法，
不证明人工可读性；字幕换行和修订可读性仍未听审。
绝对标点门保持 `unset`，不据此宣布完整标点验收通过。

上述一致性记录同时覆盖已完成的五个朗读稿 QE 矩阵，共 10 个矩阵、
255 个请求；candidate 尚未进入这一阶段。
`latest-main-completed-qe-manual-audit-v4.json` SHA-256：
`b2f3764bf7ccf16e18b03304ee0810ee75e14972a70e8ecc228cac04425a2a63`。

### 先前 main48 的长会夹具失败与修正

先前 main `48a0b726` 的追加维护已通过四生产 Session 短回放、
真实生命周期与空成功探查，
但自然长会在输入前被测试夹具的 30 秒上限拒绝，未开始实际长会采集。
`maintenance-current-main-48a0b726/maintenance-outcome.json` 记录
`measurement_completed=false`、`original_restored=true`。
该轮后续 QE、完整矩阵及真实 LLM 阶段均未执行，失败材料保留。

夹具现提供显式的 `SPEECHRAIL_ASR_SESSION_LONG_FIXTURE=1`，最多读取一小时；
默认仍为 30 秒，采样率、声道、位深和重采样样本完整性要求不变。
31 秒确定性反例先证明旧上限拒绝显式长回放，修正后保留全部重采样样本；
非法预算在分配前拒绝。Swift 报告 48 项测试通过，其中一项 live 回放跳过。
这是输入读取与 gate 验证，不是自然长会、真实采集或 ASR 质量证据。
该夹具把有限音频保留在内存；后续资源报告须包含消费者进程并说明这一范围。

rebase 后当前增量的确定性验证为 309 项 Python 定向回归通过，
Ruff 通过、mypy 覆盖全部 171 个生产文件，Swift replay gate 编译并执行
44 项通过、1 项显式 live 回放跳过，版本一致性和 diff 检查通过。
这些验证不替代真实质量或消费者验收。

## 首轮冻结主线：600 请求质量与资源矩阵

2026-10-07 完成五素材池 × 五预设 × 三次重复，共 25 个矩阵、600 请求，
计分音频 `5988.69s`，不含预热和后续完整自然会议。
全部计分请求的音频覆盖、分段预算、边界与终态计数门通过；
全部矩阵的资源采样完整。25 个 manifest 的 200 个素材条目已逐一核对
音频 SHA、语言、规范化词法参考、标点参考种类与内容及唯一 ID。
三次重复增加复现证据，不增加不同计分片段数。下表共 40 个片段，
不能称为 40 份独立源录音；例如 AISHELL-4 的 6 个短片段来自同一自然会议。

下表为按字符数加权的 CER（%）。历史基线只用于精确素材配对的词法对照；
其驻留状态不同，不用于相减内存或宣称性能同口径。

| 素材池 | 不同计分片段数 | 历史基线 | 字幕 | 提词器 | 助手分轮流 / 双工 / 会议 |
|---|---:|---:|---:|---:|---:|
| core | 8 | 7.774 | 6.860 | 8.232 | 7.774 |
| ASCEND | 6 | 11.877 | 13.793 | 13.793 | 11.877 |
| AISHELL-4 短片段 | 6 | 6.024 | 5.422 | 4.819 | 6.024 |
| 诗文 | 10 | 0.844 | 0.690 | 0.920 | 0.844 |
| FLEURS 标点池 | 10 | 12.349 | 12.651 | 12.349 | 12.349 |

逐条“不新增错误”的词法门有 7 个矩阵失败。每个下列变化都在三次重复出现；
总体 CER 改善或持平不能抵消这些回退。

| 素材 ID | 预设 | 历史错误数 → 当前错误数（每次） |
|---|---|---:|
| `ascend-zh-en-01` | 字幕 / 提词器 | 9 → 15 |
| `ami-meeting-06` | 提词器 | 22 → 27 |
| `ami-meeting-01` | 提词器 | 20 → 23 |
| `fleurs-zh-05` | 字幕 / 提词器 | 3 → 4 / 3 → 5 |
| `fleurs-zh-10` | 字幕 / 提词器 | 15 → 16 |
| `librispeech-poetry-121-123852-0002` | 字幕 / 提词器 | 1 → 2 |
| `librispeech-poetry-121-123859-0001` | 提词器 | 3 → 4 |

延迟按每个预设的全部 120 次请求重新计算 nearest-rank 分位数，
不平均各素材池的 p95。第二列为上述回放结束后 commit 至最后终态的截零值；
音频没有声学结束标注，不能将其改称“末语音至 final”。
物理峰值为相关服务进程同一采样 tick 的
`phys_footprint` 总量，表中取该预设五个矩阵的最大值。

| 预设 | 首预览 p50 / p95（s） | 回放结束后 commit 至最后终态 p50 / p95（s，截零） | 采样物理峰值（GiB） |
|---|---:|---:|---:|
| 字幕 | 0.488 / 0.516 | 0.160 / 0.271 | 13.32 |
| 提词器 | 0.494 / 0.518 | 0.092 / 0.108 | 13.28 |
| 助手分轮流 | 0.797 / 0.819 | 0.238 / 0.397 | 13.54 |
| 助手双工 | 0.588 / 0.618 | 0.247 / 0.388 | 13.58 |
| 会议 | 0.997 / 1.026 | 0.226 / 0.388 | 13.57 |

本轮工具的策略回显未保存 `rollback_tokens`，精确安装源码的默认值是 5，
但这属于源码证据，不能补写为已保存的运行时回显。
后续测量须严格核验并保存该字段；当前绝对延迟、资源和完整标点门仍为 `unset`。
聚合记录 `scored-matrix-summary.json` 的 SHA-256 为
`9e34a7fdf81209ba1b79c72bb5966a3268aff2f50cb819c2b6af3c252b481351`，
每个原始结果与 manifest 的 digest 保存在仓库外的该记录与配对核验中。

## 首轮自然会议与恢复核验

同一首轮 wheel 完成 `2220.529s` 的完整自然 AISHELL-4 录音，
没有拼接或重复音频作为长稳替代。公共 Realtime API 的手动提交路径收到
112 个边界、112 个正式终态、2220 次预览和精确 `53_292_696` 个 24kHz
输入 samples 的 receipt；覆盖和分段预算门通过。
首预览 `1.007s`、回放结束后 commit 至最后终态的截零值 `0.088s`，
仅为一次长输入的观测值。

4435 个采样 tick 的角色覆盖与 active window 采样门通过，
采样物理峰值 `13.70GiB`。首尾五分钟物理占用中位数分别约 `12.88GiB`
与 `12.99GiB`；不能以这两个窗口的差值宣称没有泄漏。
采样 span `2230.375s`，最大单 tick 采集 span `0.827s`；
采样完整不等于捕获每个瞬时分配峰值。该长输入没有唯一质量参考，
CER 门保持 `unset`，也不证明生产 `MeetingSession` 的长会保存、
真实采集链或匿名分人质量。

长会原始结果 SHA-256：
`50bd9bad6a8cfe0f307c7b20465143868a91ab230cc01365c8a967f4a025baee`。
本轮维护记录 `measurement_completed=true`、`original_restored=true`。
2026-10-07 11:22 UTC 追加实测确认 runtime、vendor、selection 恢复，
私有配置和 LaunchAgent 与维护前备份逐字一致，generation 13、
`quality/quality`、ready、空闲和唯一监听通过。

恢复后，当前增量的 101 项 Python 定向回归通过；Swift replay gate
44 项执行通过、1 项显式 live 回放跳过，夹具编译成功。
相关 Ruff、decoder 单文件 mypy 和 diff 检查通过。
这些确定性验证不替代候选 decoder 的真实质量测试或真实 LLM 回放。

## #336 八项收口状态

| 项目 | 本轮状态 | 证据边界 |
|---|---|---|
| 最终主线与冻结预设复测 | 部分完成 | 首轮 600 请求有精确归属；最新 main/candidate 双臂已冻结，main 生产长会通过，完整双臂矩阵在执行 |
| 8 秒档质量回退 | 未通过 | 历史逐条回退未全部消除；最终解码候选 90 请求相对 main48 无新增错误，四个提词器样本改善；最新完整双臂另计 |
| 标点门 | 未通过完整验收 | 朗读稿与会议人工参考分开；main 官方人工补充五预设各问号 F1 0.400、感叹号 0；candidate 与完整可读性待验，类别支持限制保留 |
| 提词器恢复与时延 | 部分证据 | 短直读推进和接管已通过；即兴、重读、脱稿恢复及其延迟未验证 |
| 助手真实语义轮次 | 部分证据 | 生产 Session 的预算不抢答和一次调用通过；真实设备与 LLM 未验证 |
| 噪声、连续消费与会议长稳 | 部分证据 | 最新 main 的 37 分钟生产 MeetingSession 保存、消费、终态及释放通过；candidate、真实采集链、质量与匿名分人另计 |
| 延迟和资源门槛 | 未收口 | 采集 p50/p95 和同 tick 物理内存；未以观察结果倒设通过阈值 |
| 最终证据与关闭 | 未满足 | #253/#336 保持开放，最终需全部门通过 |

## 复现与回退

公共 ASR 测量入口如下；manifest 与输出必须位于仓库外，且输出文件不得预先存在：

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
CURRENT_PYTHON="$APP_HOME/runtime/current/.venv/bin/python"
"$CURRENT_PYTHON" examples/perf/bench_realtime_json.py \
  --asr-manifest "$FIXTURE_MANIFEST" --profile quality --sessions 3 \
  --app-home "$APP_HOME" --output "$NEW_RESULT"
```

测试进程单独复用锁定的 OpenAI SDK，不改变 managed runtime 的依赖。
无唯一人工参考的自然长会议使用 `--asr-resource-only`，
质量门保持 `unset`；预热取自前面的真实短样本，不重复整场长会作为预热。
首预览、回放结束后 commit 至最后终态的截零值和 receipt 时延
按各自原生字段报告。`last_audio_to_final_seconds` 没有保存最后上传时间，
没有声学结束标注时也不改称“末语音至 final”。

临时维护先保存并核对实际 runtime、vendor、selection、私有配置、PID、
listener 与受保护 metrics；仅经 controller/installer 进行停启和替换。
身份、资源空闲或恢复硬门失败即停止后续采集；独立场景验证失败保留失败材料，
只有在限时确认资源归零和唯一监听后才继续其他独立阶段，不能改记为通过。
最终恢复本轮开始时的
`speechrail-3.8.1-…-3786257a0ea7-py3147`、generation 13、`quality/quality`。
配置、模型与用户文字数据保留。工具修订可以独立撤销，不需要数据库迁移。
