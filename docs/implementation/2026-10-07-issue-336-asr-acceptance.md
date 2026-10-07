---
title: "共享 ASR #336：冻结预设后的真实验收"
status: in_progress
audience: "SpeechRail 开发者与验收人员"
version: "0.2.0"
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
该候选尚未构建和真实复测，质量与额外生成的收尾时延成本不能由 fake 测试推断。

新主线的完整矩阵、生产长会和真实本机 LLM 回放另行采集。
PR #340 保持草稿，#253 与 #336 保持开放。

新主线追加维护已通过四生产 Session 短回放、真实生命周期与空成功探查，
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
三次重复增加复现证据，不增加独立素材数。

下表为按字符数加权的 CER（%）。历史基线只用于精确素材配对的词法对照；
其驻留状态不同，不用于相减内存或宣称性能同口径。

| 素材池 | 独立录音数 | 历史基线 | 字幕 | 提词器 | 助手分轮流 / 双工 / 会议 |
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
不平均各素材池的 p95。音频没有声学结束标注，因此只报告最后上传至 final，
不能将其改称“末语音至 final”。物理峰值为相关服务进程同一采样 tick 的
`phys_footprint` 总量，表中取该预设五个矩阵的最大值。

| 预设 | 首预览 p50 / p95（s） | 最后上传至 final p50 / p95（s） | 采样物理峰值（GiB） |
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
首预览 `1.007s`、最后上传至 final `0.088s`，仅为一次长输入的观测值。

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
| 最终主线与冻结预设复测 | 部分完成 | 精确 wheel、四生产 Session 短回放和 600 请求矩阵已采集，长会与候选修正另计 |
| 8 秒档质量回退 | 未通过 | 7 个矩阵出现稳定逐条回退；4 秒水位候选新增回退未采纳，最终解码候选待测 |
| 标点门 | 未通过完整验收 | 既有朗读稿与会议人工参考分开统计；问号/叹号成对 gold 仍缺 |
| 提词器恢复与时延 | 部分证据 | 短直读推进和接管已通过；即兴、重读、脱稿恢复及其延迟未验证 |
| 助手真实语义轮次 | 部分证据 | 生产 Session 的预算不抢答和一次调用通过；真实设备与 LLM 未验证 |
| 噪声、连续消费与会议长稳 | 部分证据 | 首轮 37 分钟公共 API 连续输入完成；生产 Session 长会、真实采集链与匿名分人另计 |
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
首预览、最后上传音频至 final 和 receipt 时延按各自原生字段报告；
没有声学结束标注时不改称“末语音至 final”。

临时维护先保存并核对实际 runtime、vendor、selection、私有配置、PID、
listener 与受保护 metrics；仅经 controller/installer 进行停启和替换。
任何硬门失败即停止后续采集，最终恢复本轮开始时的
`speechrail-3.8.1-…-3786257a0ea7-py3147`、generation 13、`quality/quality`。
配置、模型与用户文字数据保留。工具修订可以独立撤销，不需要数据库迁移。
