---
title: "共享 ASR #336：冻结预设后的真实验收"
status: in_progress
audience: "SpeechRail 开发者与验收人员"
version: "0.12.0"
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
空成功探查、下述生产 Session 自然长会及 35 个矩阵。
两臂完整配对与最终恢复见下文；candidate 词汇、标点类别和长会资源门仍失败。
真实本机 LLM 在 candidate 的 ASR 测量之后执行，避免其加载改变配对驻留口径；
本轮 main 阶段清单没有真实 LLM 阶段，不能声明该项双臂完成。

### 最新 main：35 矩阵与历史质量回退

2026-10-07 16:26:13 UTC，冻结 main `3a4cb713` 完成 35 个矩阵、
855 个计分请求：原 25 矩阵 600 请求、朗读稿 QE 135 请求、
官方会议人工标点补充 120 请求。五预设分别测量，每素材各三次；
重复不增加独立素材支持。

35 矩阵的请求身份、策略、WAV 时长和音频 digest、CER/F1 计数、
终态与边界、覆盖与预算、资源采样一致性核验通过。
这只证明执行及证据一致性，完整质量门仍未通过。
原 25 矩阵另核验 200 个素材条目与历史 manifest 的音频、语言、
规范化词汇参考、标点参考及 gold kind 一致。

相对于历史词汇基线，以下七个矩阵仍有逐条额外字符错误：
`ascend-caption`、`ascend-teleprompter`、`core-teleprompter`、
`fleurs-punctuation-caption`、`fleurs-punctuation-teleprompter`、
`poetry-caption`、`poetry-teleprompter`。例如提词器
`ami-meeting-06` 三次均为历史基线 22 错、最新 main 27 错。
总体 CER 或其他样本改善不抵消逐条回退；candidate 结果尚待采集。
历史对照仅用于词汇质量，不把驻留口径不同的历史内存直接相减。

2026-10-07 18:08 UTC，已完成的 candidate core 子集另作配对核验，
五预设共每臂 120 请求；完整 candidate 仍在测量。
素材全部参考与来源字段、请求身份、固定策略、CER 与资源一致性通过。
core 子集相对历史基线没有逐条额外字符错误，
但相对本轮冻结 main 的逐条“不新增错误”门已失败：
提词器 `fleurs-zh-04` 三次均由 main 的 1 错变为 candidate 的 2 错，
历史基线为 3 错。不能用优于历史基线替代相对当前 main 无回退。

提词器另外三个变化也都在三次重复出现：
`ami-meeting-01` `23→20`（历史 20）、
`ami-meeting-06` `27→22`（历史 22）、
`librispeech-5639-40744-0030` `2→0`（历史 5）。
其他 core 请求的字符错误数一致；改善不能抵消 `fleurs-zh-04` 的新增错误。
该样本两臂均为 `9.6s`、42 参考字符、两分段/两终态，
固定 `500ms / 8s / streaming_finalize / rollback_tokens=5`，
覆盖与预算门通过；这证明执行口径一致，不定位新增错误的具体字符或分段。
现有计分结果只保存聚合指标，没有完整转写或逐字符定位，
后续诊断需在原串行 driver 完成与恢复后，另做受限的同制品探查。

core 子集记录 `latest-v4-completed-core-paired-proof.json` SHA-256：
`b0977f2e1a43d55a653802fbe0e25101ae925faa46bdfbdaf1d01fc0c2362058`。
该证据不代表原 25 矩阵、全部 35 矩阵或最终恢复完成；
候选保持未采纳，不能因旧 90 请求通过而放行当前新增回退。

仓库外诊断工具已准备：复用当前 CER 归一化与评分，公共事件原有门通过后，
附加分段水位、整段 digest、归一化字符位置和编辑类型，不保存转写。
只选择一条最优文本对齐；重复字词的路径歧义与跨分段零宽删除明确标记，
归一化跨分段组合时拒绝位置归属，不把文本位置推断为声学时刻。
诊断输出另用 `speechrail-asr-segment-diagnostic` 命名，
保存源工具 schema 与源码摘要，不混入冻结矩阵，也不把 fake/失败材料改成通过。
20 项合成文本、事件和替身 runner 定向测试与 Ruff 通过；
新增反例先失败后通过。这些验证不加载模型、不接管 UI，
尚未运行真实探查或定位 `fleurs-zh-04` 的具体错误。
原型验证记录 SHA-256：
`5979a6a3ee3d00be1d7b5e6b53ca52fcdd1470c1efc77bd44a46c594fc015032`。
真实探查待原串行 driver 完成并核验恢复后，以同制品、同工具和完整
core 提词器原顺序分别复现两臂，不能按单个素材添加解码规则。

16:26:30 UTC，main 臂结束并恢复原 runtime、vendor、selection、
generation 13、`quality/quality`、唯一监听与空闲。串行 driver
另核对私有配置、selection 与 LaunchAgent 的字节及权限一致。
随后进入 candidate 臂；该记录只证明 main 臂结束时恢复，
本轮最终恢复须待 candidate 结束后另行核验。

main 历史质量汇总 SHA-256 为
`3c8645255a95f3b458600c6bcb68aa105021d16b23f81507e4d31b3b2ffaa2b0`；
35 矩阵一致性证据 SHA-256 为
`90491e0739850f4b69d6e9647d63fa54e4c0802f5e8c401b605332943f8fb4be`。
原始音频、参考和结果保持在仓库外。

离线审计器已覆盖 manifest 可选时长缺失、奇数采样帧重采样舍入、
截断、空与错误格式 WAV 等正反例，34 项检查通过。
时长以 WAV 样本帧数为准，16→24kHz 重采样只容许一个 wire sample
的差异；完整汇总固定要求 35 矩阵及每臂 855 请求，
未完成的双臂或恢复记录不得产生完整通过结论。
历史汇总仅比较原 25 矩阵，新增 10 矩阵由 main/candidate 配对汇总覆盖。
审计器 SHA-256 为
`69089ce45d4ba084a6aa13d6eae5aba0d11801aa1c036c9b0b43bbf65baa34fc`。
这些修改只作用于仓库外离线工具，未改变本轮测量源码。

远端 PR #340 于 15:05 UTC 合入 main `4d109a47`，HEAD 为 `2f3ca71b`。
该 HEAD 的 `src/speechrail`、`contracts`、`examples/perf`、`native`
与冻结 candidate `2aeb670c` 一致；macOS 提词器选择、保存及 UI 有变化。
本机 292 个冻结 macOS/benchmark 文件重新逐一核验未变，
工作区保持冻结，双臂结束后再 fast-forward 并补当前消费者验证；
既有 Session 证据不自动覆盖新消费者源码。
该 HEAD 的完整 CI `37649053407` 于 16:08:38 UTC 七项 job 全成功。
原 PR run 遇到 GitHub Internal server error，不作为代码失败证据；
确定性 CI 不替代真实质量验收，PR 继续保持草稿。

### 仓库外计时修订：已验证，尚未应用

为补齐当前工具没有保存最后上传时间、且对 commit 差值截零的缺口，
已在独立源码副本准备 ASR benchmark 结果 `schema_version=2`。
副本记录同一单调时钟下的上传起止、名义回放结束、回放等待返回、
commit 起止、最后终态及 receipt 接收时刻，公开结果仅保存相对回放起点的偏移。
最后上传的数据区间另按 24kHz wire 半开区间记录。

副本以有符号差值分别输出 `last_upload_to_last_terminal_seconds`、
`nominal_playback_end_to_last_terminal_seconds`、
`commit_to_last_terminal_seconds`，保留 `barrier_seconds` 的 receipt 口径；
移除误导的旧字段 `last_audio_to_final_seconds`。
上传返回只证明客户端 SDK 调用返回，不证明服务端接收或声学语音结束，
因此 `acoustic_speech_end=not_observed`，不生成“末语音至 final”指标。
缺失、非有限、布尔伪装与已定义的时间顺序冲突均拒绝。

计时反例在原工具上为 21 项失败、42 项既有回归通过；
另四个合成 WAV 反例复现截断 PCM 和声明半个采样帧的问题。
修订副本在重采样前检查实际 PCM 字节数与头声明帧数一致。
最终 67 项定向 fake 测试、Ruff 和补丁可应用性检查通过，
补丁 SHA-256 为
`d65308dd7fb73464ac55988d84a4111492947546c4c53bbbb46594787bb3f973`。
这些是仓库外副本验证，尚未应用到正在测量的源码，
不能作为新时延实测、正式制品或模型质量通过证据。
须待串行 driver 完成、最终恢复核验和当前远端源码核对后再应用；
历史 schema 1 结果及其原始计时定义保留，不重新解释。

离线 v4 审计器也补齐报告工具/版本和半个采样帧的拒绝门，
37 项正反例及 main 的 35 矩阵一致性检查通过。
其 SHA-256 为
`a2e36143624cf1eb1b1a07bc56f6aa2f97c302365a9c13539f3be464316e0637`；
上节 34 项检查及 `69089ce4` 工具源码快照与旧证据均保留。
本轮配对汇总只接受原工具的 schema 1，防止混入新口径结果。

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

### 最新 candidate：长会消费者通过，资源采样门失败

2026-10-07 17:29 UTC，复核 candidate `2aeb670c` 的同素材长会材料。
生产 `MeetingSession` 测试通过，10 项适用消费者门全部通过；
fixture、输入、来源已交付和上传水位均为 `53_292_696` samples，
`fixture_eof` 正常结束、未合成尾部静音，采集、协调器、客户端与事件镜像
的释放标记均为 true。164 分段、165 终态、158 非空成功、7 空成功、
2050 预览，失败终态和服务错误均为 0。

长会整体资源门失败，`sampling_complete=false`。3938 个 tick 中，
只有最后一个 tick（index 3937，`2222.182–2222.455s`）缺少
`production-session-consumer` 的 RSS 与 physical footprint；该消费者
共出现 3935 个 tick，3934 完整、1 不完整。活动窗口内部缺口为 0，
退出边界缺口为 1。采样器先发现进程再逐项读取，而监督脚本在消费者退出后
才停止采样；结合正常完成的测试日志，这支持“退出边界观察竞争”的推断，
不构成已经修复或允许忽略缺口的证据。

四个服务进程的 PID 与启动时间身份在全程稳定；同 tick 无重复物理进程。
两个 TTS 角色标签有交换，不能据标签交换判断新增 worker 或混入离线测试。
完整 tick 的观察峰值为 `14_740_844_352` bytes（`13.728GiB`）；
全局采样未完整，不据此宣称相对 main 内存改善或资源验收通过。
`active_window_sampling_complete=true` 不替代失败的全局门。

监督脚本在资源完整性断言处失败，
`long-production-meeting-outcome.json` 未生成；保留原始失败材料，
没有补写通过 outcome。后续矩阵继续运行只表明监督入口允许采集独立证据，
不改变长会资源失败或该时点候选尚未最终恢复的状态。

Swift schema 5 的 `final_after_last_audio_ms` 也须限定口径：
它从源帧 `yield` 后记录的时刻到最后终态接收时刻计算，并截零；
未保存最后上传返回时刻，也未观察声学结束。
该字段不能用于“末语音→final”或“最后上传→final”验收；
上文 Python 计时修订尚未修复 Swift 计时缺口。

消费者结果 SHA-256：
`041f795fde9a97c0ff60bff4d9deb2facc0449c2561c7e51a1230a26c1e5aefa`；
资源原始记录 SHA-256：
`f902de799433c6168ffec08f8d864c226538b7a167ef4298549c8134a1857f2d`；
独立失败诊断 `candidate-long-meeting-resource-failure-diagnosis-v4.json`
SHA-256：
`b6343bd74d79f39878835c5bfa625a63137099443c1941ecec06c280461d6f82`。
诊断逐 tick 重算缺口、进程身份及峰值，核对适用门与释放水位，
并在写出前确认原始文件 digest 未变。拟修复采样停止与消费者退出的协调，
随后使用同一新夹具对 main/candidate 重新配对；截至本次复核尚未实施。

仓库外 Python 监督器随后完成确定性原型验证：先等待 nonce 绑定的 ready，
停止并 join 采样线程、保存原始资源材料，再原子发布 release，最后核验
消费者退出码。正在读取的 tick 不会因为提前放行消费者而丢失；
采样或材料保存失败不发布成功 release，已有 marker 不覆盖。
资源失败原样保留，不能通过握手变成通过。
旧退出顺序的反例为 9 failed / 1 passed；最终 15 项定向 fake 测试与 Ruff
通过，移除失败路径保存 callback 的两项反例也按预期失败。
验证包含冻结的真实采样器实现，进程身份与读数为替身；
没有加载模型、重新测量或接管 UI。
原型验证记录 SHA-256：
`00a62d80e976ddba172fc404828fb8fe4c5c14bb7f08d2282881b8f578f0f019`。
19:08 UTC，仓库外另准备 Swift 握手 helper、回归测试与基于远端
`2f3ca71b48a3d144f092419614abd07537642090` 的接入补丁；
`git apply --check` 通过，尚未应用、编译或运行 Swift 测试。
helper 草稿将 ready 原子发布并拒绝覆盖，限时等待同一 UUID 的 release；
测试覆盖部分配置、路径冲突、仓库内目录、已有与悬空 marker、
错误 UUID、额外字段、布尔/整数混淆、超大或非普通文件、超时与取消。
准备的消费者接入点位于回放排空、释放、结果写入与原有断言之后，
不会把 marker 当作消费者或资源门通过。
补丁 SHA-256：
`7ec5ce2a9435a497a4f68042633915f49f48bffc8f9c134307fe0f8f92195dee`。
Swift 握手尚未接入消费者或当前 driver；
原串行 driver 结束及最终恢复核验前，冻结的夹具和 benchmark 保持不变。
因此长会资源门仍失败，真实双臂重跑仍是未完成工作。

原 driver 结束、最终恢复和安全 fast-forward 后，Swift 消费者已接入可选握手。
回归加入现有回放门测试文件，Xcode/SPM 清单覆盖检查通过；
新增 helper 只在三个变量完整配置且 E2E opt-in 时使用，
消费者结果写入与原有断言之后等待采样停止。
首次接入编译发现测试宏内缺少显式 `try`，已修正。
随后定向 Swift 汇总为 145 项 / 16 suites、无失败；
其中一项真实 Session 回放因未启用 live 开关而明确跳过，
不能算作新真实回放。范围包含握手、回放门、当前选择逻辑与提词器生命周期。
集成验证 SHA-256：
`e33ff4c0370612e63949c08ee35f123201b78b87604960094f06029a75961d12`。
外部长会监督器尚未接入并执行新协议，原长会资源失败不变；
精确计时和同新夹具双臂重跑仍待完成。本次 helper 接入没有改变服务运行态。

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

上述 14:43 UTC 一致性记录同时覆盖已完成的五个朗读稿 QE 矩阵，共 10 个矩阵、
255 个请求；该时点 candidate 尚未进入这一阶段。
`latest-main-completed-qe-manual-audit-v4.json` SHA-256：
`b2f3764bf7ccf16e18b03304ee0810ee75e14972a70e8ecc228cac04425a2a63`。

### 已完成的 QE / 人工标点双臂子集

2026-10-07 17:54 UTC 起核验最新两臂已完成的 10 个补充矩阵，
每臂 255 请求。逐项核对素材 digest、fixture 全部参考与来源字段、
语言、gold kind、请求身份、固定预设、CER/F1 计数与资源采样。
255 个对应请求字符错误数全部一致，子集无新增词汇错误；
该范围不含尚在执行的原 25 矩阵，也不包含候选最终恢复。

| 素材 / 预设 | main 与 candidate CER | 两臂总体标点 F1 |
|---|---:|---:|
| QE 朗读稿：字幕 / 提词器 | 2.273% | 0.667 |
| QE 朗读稿：助手分轮流 / 双工 / 会议 | 0.758% | 0.737 |
| AMI 人工标点：字幕 / 提词器 | 9.091% | 0.600 |
| AMI 人工标点：助手分轮流 / 双工 / 会议 | 7.343% | 0.621 |

总体 F1 相同不表示各类别一致。QE 提词器的句号 false positives
由 main 的 30 增至 candidate 的 36，句号 F1 `0.375→0.333`；
逗号 false positives `15→9`、F1 `0.857→0.909`，
因此总体 F1 仍同为 `0.667`。不能用逗号改善抵消句号类别回退。

五预设各自的 QE 问号 F1 为 1、感叹号为 0；AMI 人工标点各自
问号为 0.400、感叹号为 0。每预设 N=3 的 QE 问号/感叹号支持标记为
9 / 18，人工会议为 9 / 3；独立素材仍分别只有 9 个朗读片段与
8 个会议片段，三次重复不增加独立支持。
朗读稿与人工会议参考保持分开；绝对标点阈值及人工可读性仍未通过收口。

配对子集记录 `latest-v4-paired-followup-subset-proof-v2.json` SHA-256：
`056bccd5f9d01e408a4a9c885329bfe4e44b0feffcab21157b076e710ba277ff`。
先前子集 v1 保留；v2 显式增加逐类别变化，防止总体 F1 隐藏类别回退。
这份子集报告不是完整 35 矩阵或最终恢复证明。

19:20 UTC 前，完整配对汇总入口也补齐独立的逐类别比较器。
它校验两臂 gold kind、类别、支持数、TP/FP/FN、总计与 F1 一致性，
逐项列出误插与漏标变化；即使某类别 F1 提高，新增漏标仍明确记录。
未观察到的类别不作质量通过声明，朗读稿和自然会议保持独立口径。
13 项定向合成测试与 Ruff 通过；省略类别变化的反例为 1 failed /
12 deselected。比较器另重算已完成的 10 个补充矩阵，仍确认
`qe-teleprompter` 的句号类别回退。
这项核验没有执行完整汇总或改动冻结测量源码，绝对标点阈值仍未设定。
核验记录 SHA-256：
`cedba46e3f5b8ea1307eacf35215a7b1ad09faa14fb79f41493f421706efeaef`。

### 冻结 v4 双臂完整配对与最终恢复

2026-10-07 19:25 UTC，原串行 driver 退出；独立核验两臂维护记录、
原 runtime/vendor 指针、配置/selection/LaunchAgent 字节与权限。
原服务恢复为 `quality/quality`、generation 13、auto off；
8201 只有一个 listener，无已建立客户端连接，活动与待处理请求计数为零，
ready 与身份、模型/音色 catalog 摘要一致。292 个冻结文件逐一哈希未变。
该恢复证明不表示测量门通过，也不覆盖随后新消费者代码或新夹具。
恢复记录 SHA-256：
`36a986b8181059ba31e60569434a1445fd6ceeae6ffc4265d7e404c9258f9c65`。

完整一致性审计与配对汇总确认两臂各 **35 矩阵 / 855 请求**，总计 1710；
对应素材字节、fixture 全部参考与来源字段（除本机路径）、有效策略、
请求身份、覆盖、预算、终态、CER、标点计数与矩阵资源记录一致性通过。
原 25 矩阵的 candidate 历史对照另核验 600 请求、200 个 fixture/矩阵配对；
这些重复和同素材跨预设配对不增加独立素材支持。
一致性审计 SHA-256：
`0b1923d856be79678712721b09a8531dab035e8d64d19fb42f66bec568463a62`。

**candidate 相对本轮 main 的逐条词汇门失败**，回退均在三次重复中一致：

| 矩阵 | 素材 | main → candidate 字符错误 |
|---|---|---:|
| AISHELL-4 提词器 | `aishell4-zh-meeting-02` | 3 → 4 |
| core 提词器 | `fleurs-zh-04` | 1 → 2 |
| FLEURS 标点提词器 | `fleurs-zh-04` | 1 → 2 |
| FLEURS 标点提词器 | `fleurs-zh-07` | 7 → 8 |

合计三个矩阵、四个素材/矩阵对、12 请求出现新增错误，
其中 `fleurs-zh-04` 是同一素材在两个矩阵的重复覆盖，不能算两个独立素材。
六个素材/矩阵对的 18 请求有改善，包括既述 core 三素材、
FLEURS `fleurs-zh-05` 与两个诗文素材；改善不抵消新增回退。
candidate 相对历史仍有六个失败矩阵：
ASCEND 字幕/提词器、FLEURS 标点字幕/提词器、诗文字幕/提词器。
main 相对历史的七矩阵失败记录继续保留；两种比较口径不得混用。

标点类别另有两处回退：AISHELL-4 提词器逗号 TP `21→18`、FN `9→12`，
F1 `0.583→0.545`；QE 提词器句号 FP `30→36`、F1 `0.375→0.333`。
朗读稿与人工会议参考分开。完整配对汇总 SHA-256：
`507a2e309883802c5d798c1cd59923ca75bddb77f5bc7df912e555f0d4ab1d80`。
绝对标点、声学时延、资源阈值仍未设定，完整矩阵一致性通过不表示这些门通过。

candidate 阶段台账确认短 Session、生命周期、空成功、QE、原矩阵和真实
本机 LLM 阶段执行完成；唯一阶段执行失败是上述长会资源采样门。
因此外层 `maintenance-outcome.measurement_completed=false`、
内层 `evidence-outcome.all_stage_execution_gates=fail` 原样保留；
不得因为 35 矩阵齐全或服务恢复而改写总体失败。

candidate 单次真实本机 LLM 证据通过正式输入与非空响应门，
一轮只有一次 stream 且完成，`received_final_to_llm_seconds=0.002434667`；
该单值不是 p50/p95，也不证明首 token 或语义正确。
范围是实际 ASR + 生产 `AssistantSession` + `LLMProvider`，
采集、TTS 与播放仍为替身；语义正确性门为 unset。
本轮 main 阶段清单没有 `real_llm`，不能将 candidate 单臂结果写成双臂 LLM 验收。
该 LLM 记录 SHA-256：
`dc13c67a3c9059b37745a709a920086dfc73a91731c46c5315e0b76f1475ccc7`。

候选仍未采纳，#253/#336 保持 OPEN，PR #340 保持 DRAFT。
下一步为将已验证的 Swift 握手接入新长会监督器、修订精确计时、
核验当前消费者的真实回放、同新夹具重新配对长会，以及受限诊断上述真实新增错误。
原始音频、参考、转写、配置、日志与结果继续保留在仓库外；
真实设备、人工语义/可读性和提词器恢复门仍未完成。

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
| 最终主线与冻结预设复测 | 部分完成 | 冻结双臂各 35 矩阵 / 855 请求完整配对且最终恢复通过；新消费者与修订夹具尚待验证 |
| 8 秒档质量回退 | 未通过 | main 相对历史有七个矩阵回退，candidate 有六个；candidate 相对本轮 main 的三个提词器矩阵新增错误，旧 90 请求不外推 |
| 标点门 | 未通过完整验收 | 完整配对有 AISHELL-4 提词器逗号及 QE 提词器句号类别回退；人工会议问号 F1 0.400、感叹号 0；可读性与绝对门待验 |
| 提词器恢复与时延 | 部分证据 | 短直读推进和接管已通过；即兴、重读、脱稿恢复及其延迟未验证 |
| 助手真实语义轮次 | 部分证据 | candidate 单次真实 ASR/LLM 正式输入与非空完成流通过；采集/TTS/播放为替身，main 本轮无 LLM 阶段；真实设备与语义未验证 |
| 噪声、连续消费与会议长稳 | 部分证据 | 两臂 37 分钟生产 MeetingSession 的消费者门通过；candidate 最后 tick 资源缺口使全局采样门失败；真实采集链、质量与匿名分人另计 |
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
