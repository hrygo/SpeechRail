---
title: "共享 ASR #245：实施与验收记录"
status: in_progress
audience: "SpeechRail 开发者与验收人员"
version: "1.5.0"
date: 2026-10-06
---

# 共享 ASR #245：实施与验收记录

2026-10-06 后续交付链核验：App 消费替代 PR #291 已合入 `b6eada5b`，
证据工具替代 PR #292 已合入 `84330d9c`；原 #278/#280 均已关闭。
下方原 PR 表与 CI 记录保留为历史来源。#290 的输入归属修复仍待交付和真实复测；
#249/#253/#245 保持开放，App 实施 Issues 已关闭不代表真实业务验收完成。

实施依据为 [完整方案](2026-10-05-multiscene-asr-luna-guide.md)，交付跟踪为
[#245](https://github.com/hrygo/SpeechRail/issues/245) 及 #247–#253。
原实施源码基点 `65df3aa6`，工作分支 `codex/multiscene-asr-245`。
交付切片基于更新后的主线 `8e11b84a`，独立工作树保留主线新增内容，
原实施工作树与仓库外可恢复源码快照均保留。
本记录区分 fake 回归、当前已安装服务实测和候选验收；尚未满足总 Issue 的关闭条件。

## PR 交付与独立边界

用户已授权按数个可独立交付的 PR 提交、推送。按下表顺序评审与合并，
每个后续 PR 的 base 是前一个分支；合并后需按仓库线性历史规则更新剩余依赖。
不使用 `Fixes` 自动关闭仍待真实验收的 Issues。

| 切片 | PR / 分支 | 提交 | 内容与依赖 |
|---|---|---|---|
| 空成功终态 | [#276](https://github.com/hrygo/SpeechRail/pull/276) / `codex/asr-empty-terminal-247` | `ed3e8600` | #247，三个文件；base 为 main，可独立先合并 |
| 共享策略与内核 | [#277](https://github.com/hrygo/SpeechRail/pull/277) / `codex/asr-shared-kernel-245` | `edde6dae` | #248/#249，严格策略与实际执行一同交付；依赖 #276 |
| 四场景 App 消费 | [#278](https://github.com/hrygo/SpeechRail/pull/278) / `codex/asr-scene-consumers-245` | `1d115241` | #250/#251/#252，transport、预设与消费者编译一致；依赖 #277 |
| 基准工具与证据 | [#280](https://github.com/hrygo/SpeechRail/pull/280) / `codex/asr-evidence-253` | v7 源 head `4e513ea1`，后续补证据 | #253/#245，评分/资源模式、实施方案和证据；依赖 #278 |

策略若单独先交付会出现“接受并回显但未执行”的公共行为，因此与内核作为一个
可运行切片；App Event、preset 与四个消费者共同组成一个可编译切片。
App 与服务公共契约需配套部署，逐 PR 合并不等于可混用旧 App / 新服务。
这四个 PR 提供可评审源码，不代表候选真实场景质量已验收。

2026-10-06 后续远端核验：#276 已以 `d89e067a` 合入 main；
原 #277 CLOSED，替代 #289 已以 `a8d4fb2d` 合入 main，保留期限时钟修复。
原 #278 CLOSED，消费端须追踪后续实际交付；#280 在本次核验时仍 OPEN。
上表和下方 CI 是原切片的历史证据，不代表当前合并链。
本任务未执行 main 合并；精确分包修复在独立工作树实施，保留原证据分支的改动。

2026-10-06 在各 PR 边界重新验证：

- #276：空成功反例修复前 2 failed / 3 passed，修复后相关 worker、streaming、
  isolation 三个文件 93 passed；CI run `37423915342` 为 success。
- #277：20 个核心 Python 文件 482 passed，Swift RealtimeContractTests 43 passed，
  Ruff、Mypy 164 files、Schema 52 fixtures / 45 fields、用户文档契约通过。
- #278：相关 XCTest 119 passed、Swift Testing 69 passed / 6 suites，
  另 AssistantDrainTests 5 passed；含主线新增 V16 测试。包装 Debug build 成功，
  临时 DerivedData 复查已移除，macOS test target coverage 通过。
  构建日志 SHA-256：
  `f9ee46147802bc27a6e55b26ffd77a205ebbf82998ac54219416dfbf40c06ba8`。
- 主线新增 FullTextReceiptCheck / FullTextPlaybackGate 的 Xcode 登记及助手 V16
  分组测试均保留。staged whitespace 与新增凭据模式检查通过。
- 基准工具/评分/profile contract：在本 PR 工作树重新运行，78 passed；
  Ruff、版本一致性、staged whitespace 与新增凭据模式检查通过。

CI 只自动匹配 base 为 main 的 PR。初始 #277/#278 的全量 CI 暴露六个 Python
旧时序断言，以及 App 的两个 TTS handshake fake 缺少有效 ASR 回显。
这些失败没有跳过：分人测试精确检查新增 ASR 边界，助手跨语言共享 fixture
记录边界顺序、精确区间和关联 ID；TTS fake 从实际请求构造回显，
助手 caller fixture 显式使用 assistantTurnTaking。
进一步反例暴露对齐尾部逆映射越过 item 一采样点，现以冻结 item 的精确 wire
起止点和局部 rate map 投影对齐/分人 unit。相邻采样长度及连续两段反例
修复前 2 failed / 1 passed；五个 Python 回归文件修复后 162 passed，
caller/Schema 53 passed，Swift 共享助手 fixture 41 passed，App TTS 7 passed。
Ruff、Mypy 和 contract checker 通过。
这些修复以追加提交纳入原 PR，未 force-push。App 通过依赖合入保留已发布历史，
尚未执行受保护 main 的合并；后续合并必须符合主线线性历史规则。

#277 的 run `37427042514` 在 Python、质量、App build 与 wheel 门通过后，
暴露一个独立切片 fixture 比较失败：新 App 请求形状提前进入了服务端 PR。
追加 `6d119a9` 将其保留在 App 切片；服务端独立 TTS 7 passed、
caller/Schema 53 passed。最终服务端 head 的 CI run `37427924683` 已 success，
质量、全量 Python、Swift、App build、wheel 和 Gate Summary 均通过。

#278 的 run `37427316390` 已 success，Python、Swift、质量、App build 和 wheel
均通过；对应 head `0ce9be3`。最终 `ce0975d` 仅接入服务端依赖历史，
其 Git tree 与该通过 head 完全相同：
`5419d4a5c6e512726de0ccea53d91ca0ff9a4024`，复用了仍有效的通过证据。

#280 代码 head `da85b5475b4cd4510daf395108ce6c577dd8dd27` 的 CI run
`37428267452` 已 success，质量、全量 Python、Swift、App build、wheel 和
Gate Summary 均通过。该记录对应修复期限时钟前的代码；
下方记录的 v7 新增协调器时钟修复与两个反例，不能复用旧 CI 声称新 head 已通过。
四个 PR 已逐一回读 OPEN、MERGEABLE、base/head；没有执行合并。
原实施工作树的 68 个归属文件复核仍与保存的源码 snapshot 逐字一致。
以上新主线证据与下方原实施工作树验证分开，不用旧日志证明中间 PR 可运行。

## 当前实现与公共影响

- ASRPolicy 定义中立策略及严格校验；Python、Realtime Schema 和 Swift typed builder
  使用同一字段语义。服务回显有效段预算和最终期限，有保留输入时拒绝改变策略。
- worker 只保留一个已加载的模型。累计 PCM 生成可修订预览，预览的水位来自实际解码音频；
  `full_segment` 使用同一 Session 复核完整段，`streaming_finalize` 收尾累计快照。
  截断或非 EOS 结果不作为成功终态。
- 单 lane coordinator 将采集与推理解耦，保留 current 加最多两个 pending。
  PCM 有总量与单段上限，预览请求合并；final deadline 覆盖 admission、connect、
  已运行的 preview 和 final。实际 teardown 失败时隔离 owner、保留资源，成功重试才释放。
  unregister、scheduler context exit 和 mode lease release 分阶段完成，失败不丢句柄；
  Resource Governor 将全部 ASR 请求串行准入同一 lane，heavy overlap 只允许独立 TTS lane。
  重复 close 与取消 close 等待者共用受 shield 保护的清理任务，不重复取消真实 teardown，
  不在 worker 回收前释放 PCM 或 lease。
- Realtime 在 sample 边界拆分大包；`segment_closed` 在对应终态之前给出 item、
  输入区间、关闭原因和可选 client commit ID。空成功发 `completed(text="")`；
  有效段恰一个文字终态。clear 丢弃未冻结输入；已报告边界而未完成的段得到一次失败终态，
  同时隔离旧代次、旧重采样尾部及辅助任务。
  排空完成任务时显式从 pending 集合移除，避免依赖异步 callback 的忙循环阻塞事件循环。
  异步 create/connect 失败保留 `language_not_supported` / `queue_full` 等稳定终态代码；
  下一次准入先等待失败 item 的真实清理结果，再移交输入身份，不复用失败段或取消其 teardown。
  手动输入保持精确 wire 游标；失败恢复与连续 commit 不逆算 kernel 起点。
  单采样点完全驻留重采样尾部时仍准入 ASR，恢复时等待旧终态发送完成后再移交 item。
  `wait_finalized` 仅在真实 worker 回收、注销与 lease 释放后完成。
  commit 的 EOF 或 timeout 不再被合成终态掩盖；同一输入代次及其重复请求不能取得成功回执，
  新输入代次在真实清理完成后可恢复。明确 failed 终态且真实 commit 成功返回仍可完成回执。
- App 采用唯一 ASRScenePreset。助手跨 budget rollover 组装业务输入轮次；
  会议与字幕按连接、代次及 item 消费，时间来自输入区间；
  提词器使用 streaming finalize，并对音频水位、文本修订和手动接管做门禁。
  会议与字幕停录先上传已缓冲音频，再 drain、关闭与等待事件泵消费；合法连接代次保持至尾句保存。
  首次迟到 speaker attribution 成功写库后才登记已应用，避免更新被提前去重。

可修订文字使用 SpeechRail hypothesis，不能把可回退快照当成官方 append-only delta。
调用方需要处理新增边界事件；本次没有保留旧静音配置构造接口或第二套预设。
更新后的 Swift 客户端要求服务返回有效 ASR policy；旧服务缺少该回显时会拒绝解析，
因此 App 与服务须使用配套契约。当前正式安装 App 和服务均未替换。
没有变更 SQLite 格式、迁移历史记录或保存 PCM。根 README 未修改。

## 确定性验证

2026-10-06 在原实施工作树已实际执行；更新后主线的 PR 边界证据见上一节：

| 检查 | 当前证据 | 限制 |
|---|---|---|
| ASR policy、coordinator、decoder、worker/IPC、Schema、caller wire、分包与尾部、基准工具、ASR mode/shared owner、Batch backend、音频 timeline、Resource Governor | 最终 20 files，426 passed，4.91s | 不含完整 `test_realtime_openai.py`；一条既有 `asyncio.iscoroutinefunction` 弃用提示 |
| 完整相关 Realtime OpenAI 回归 | `tests/test_realtime_openai.py`，120 passed | 含 EOF/timeout 回执、rollover/tail、错误恢复；fake backend |
| Streaming 回收完成屏障 | 47 passed，1.15s，且包含于上方批次 | blocked fake reap 未放行时 finalized waiter 不完成、lease 不释放 |
| Resource Governor single ASR lane、队列/FIFO/aging、独立 TTS lane | 33 passed，0.38s | fake backend，不是真实并发吞吐测量 |
| REST busy 错误契约 | 6 passed，86 deselected，0.32s | 仅相关 busy 用例 |
| PCM buffer / windows | 14 passed，0.14s | 合成 PCM，不是真实采集质量证明 |
| ASR 基准评分/资源模式 | 24 passed，包含于上方批次；新增 7 项回归 | 默认要求人工参考；资源模式不评分 CER，且不放宽输入/终态/回执门 |
| Mypy | 164 source files，无问题 | 不代表真实 vendor 推理或 Swift 验收 |
| Realtime contract checker | 52 fixtures、45 tracked fields | Swift 消费端另做编译及回归 |
| 用户文档 contract checker | 39 paths、21 error codes、9 model aliases | 不是运行态能力证明 |
| 版本一致性 | 全部镜像位置一致，3.7.1 | 未 bump 版本，候选必须用 wheel digest 区分 |
| Swift 新增共享单元 | presets 2、assembler 7、ledger 4，全通过；根独立复跑 | 非 UI 确定性测试 |
| Swift 生产消费 | AssistantSession 42、AssistantDrain 5、MeetingSessionLifecycle 27、CaptionSessionLifecycle 3、Teleprompter 54 全通过 | fake-client production Session gate；不代表真实 LLM、设备或 UI 验收 |
| Swift Realtime 契约 | XCTest 46 与 Swift Testing 2 全通过 | 有效回显与缺失回显拒绝 |
| 正式 App Debug 编译 | 包装脚本 exit 0，`BUILD SUCCEEDED`；临时 DerivedData 已移除 | 未导出、安装、启动 App 或执行 UI 自动化 |

最终 Ruff（src/tests/tools/examples/perf）、Mypy、contract/doc/version checker
和 `git diff --check` 均已通过。
相关 Realtime 回归和会议/字幕保存与排空确定性门已完成。
App 构建日志 SHA-256：
`ac08af47beca394916d4a4f0205fdf0b6fc27d4963ca88523f81390d3c6039d7`。
此构建基于 drain 修复后的最终 App 源码，包装脚本 exit 0、`BUILD SUCCEEDED`，
日志中的临时 DerivedData 目录复查已不存在。
Swift Package 提示 17 个未处理文件，未阻断筛选测试或正式 App 编译。

## 候选制品

已构建未安装的
`speechrail-3.7.1-cp314-cp314-macosx_26_0_arm64.whl`，
当前 v6 SHA-256 `5b6a61f2e85c2979d5dd2b1c6a52b168a0dccee9fff13de2cf672673d945eb2e`。
wheel 中 10 份关键源码/资源逐字匹配构建时源文件，包含 arm64 Mach-O 分人 worker；
metadata 为 speechrail 3.7.1、Python `>=3.14,<3.15`。
在仓库外独立环境中执行该 wheel 的 `speechrail install --help` 成功；
没有执行安装、启停、档位变更或 App 替换。
版本未 bump，必须以该完整 digest 区分候选与现有 3.7.1。
v6 包含 EOF/timeout 回执、worker 回收屏障及本轮 CI 暴露的对齐/分人 wire 边界修复；
v2/v3/v4/v5 均已失效，
不得作为完整验收候选安装。独立安装入口验证仅执行 `install --help`，未安装服务。
原实施源码基点完整 ID 为 `65df3aa623042329e94990be401f7da971269519`；
原工作树变更与候选制品的可恢复源码快照另保留在仓库外。
v6 构建源 head 为 `0ce9be3ca143e03b22e2e84825c493716d283faf`；
10 份关键源码/资源与交付工作树逐字一致，包含更新后的 Realtime 边界修复。
安装前仍须按最终 PR head 重新核对制品身份；旧日志或版本号不能独立证明一致。

## 公开音频与现有实现基线

用户授权自行取得权威外部音频。素材来自
[AISHELL-1 / OpenSLR 33](https://www.openslr.org/33/) 与
[LibriSpeech / OpenSLR 12](https://www.openslr.org/12/)。
AISHELL-1 使用 Apache 2.0，LibriSpeech 使用 CC BY 4.0。
短样本经官方 WeNet fixture 获取，固定 commit
`d17059667d6afe0680d19b3a4948ab825ef25105`；其余英文样本从官方 test-clean
压缩包流式选取。保留许可、来源、人工参考文本与每份落盘音频 SHA-256。
未下载完整 test-clean 包，因此未声称校验整个压缩包的 MD5。

仓库外 evidence set 为 `asr-245-20261006`，含 14 段、110.806 秒：
中文 1 段、英文 13 段，时长范围 1.740–22.285 秒。
原始音频、参考正文、结果 JSON 和逐进程采样都保留在仓库外受限目录，
本记录不复制参考正文、转写或私人绝对路径。

| 制品 | SHA-256 |
|---|---|
| manifest.json | `841539bebe0784de74835891cac34d91684d6ca66ff44565d11707a283270928` |
| baseline-identity.json | `a41ce709e090491c6b1c97b4c64e72950f33722d69eb9b12a1eb7f1e986374f6` |
| baseline-warm-n5-result.json | `94374fc09677354b38ad90be781b86394d27ccc83174da381c73532430420930` |
| baseline-realtime-n3-result.json | `7d387bec192e7e8307c35863fa5b3b2cc3791f4f2a72798decfbac562e15ce83` |

实测服务为已安装 **3.7.1、quality/quality**；
ASR 为 `speechrail/qwen3-asr-1.7b`、`asr-1.7b-q8`、
`mlx-community/Qwen3-ASR-1.7B-8bit`，8 bit、group 64、MLX。
已记录实际 runtime revision。硬件为 Apple M5 Max、128 GiB 物理内存、
Darwin 27.0.0、arm64。推理只调用现有公共 API，没有启动源码服务或第二个模型 worker。

| 指标 | Batch warm N=5 | Legacy Realtime warm N=3 |
|---|---:|---:|
| 成功并可评分的请求 | 70/70 | 42/42 |
| 加权 CER | 0.226% | 19.127% |
| 参考字符数 / 字符错误数 | 6640 / 15 | 3984 / 762 |
| 中文参考字符数 / 错误数 | 60 / 0 | 36 / 21 |
| 英文参考字符数 / 错误数 | 6580 / 15 | 3948 / 741 |
| 请求延迟 p50 / p95 | 0.220 / 0.574 s | N/A |
| 首次预览 p50 / p95 | N/A | 1.003 / 1.029 s |
| 最后音频至文字终态 p50 / p95 | N/A | 0.064 / 0.081 s |
| 同 tick 总 phys_footprint 峰值 | 12,036,516,592 bytes | 12,665,187,080 bytes |
| sampling_complete | true | true |

CER 使用 NFKC、casefold 及字母/数字/组合标记归一化，不评分标点；
加权 CER 为字符错误总数除以参考字符总数。
这两列是不同 API 行为，不能称为候选改进幅度。
峰值包含当时 resident TTS 与服务父进程，不能称为 ASR 单组件内存峰值。
Realtime p95 使用 nearest-rank。旧服务可能同时发 snapshot 与 delta；
本次原始工具的预览计数/修订字符数包含镜像事件，不能用来作候选修订频率对照。
工具现已补充 snapshot 优先去重回归，未事后改写原始实测 JSON。

Batch 原入口的完整 release gate 为 false，原因包含未测 cold、soak、switch，
以及入口所需完整质量/身份材料；实际身份另存，不回填伪造 gate。
当前基线不是发布验收。

另取得 [Google FLEURS 官方数据卡](https://huggingface.co/datasets/google/fleurs)
固定 revision `70bb2e84b976b7e960aa89f1c648e09c59f894dd` 的普通话 dev 集：
10 段、91.180 秒，4.740–15.580 秒，按官方 gender 与时长分层选择；
TSV 不提供 speaker ID，因此未声称说话人多样性。官方数据卡声明 CC BY 4.0。
流式选集未校验完整压缩包，每份转换为 16 kHz mono PCM16 的音频独立校验 SHA-256。
manifest SHA-256：
`682325bf0a2a49b308748bb86c570984323b0b938f3ba0ea0469c1ccf02e63d8`。

会议素材来自 [AMI 官方下载页](https://groups.inf.ed.ac.uk/ami/download) 和
[官方许可页](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml)，音频与人工标注均为 CC BY 4.0。
选择 ES2002a 的四个匿名 headset channel，按人工 word timestamps 提取 8 段、
99.820 秒自然会议语音，边缘各保留 150 ms。使用 HTTP range 获取 PCM，验证 Content-Range、
WAV 格式和样本数，并保存片段 SHA-256；未声称验证完整来源 WAV。
人工标注 v1.6.2 ZIP SHA-256：
`b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d`；
manifest SHA-256：
`8e5d957412ae69a32f27856675e87834308d9d59e63116c8f0a38b482255b6ed`。

补集的当前已安装服务实测（与原 14 段证据分开保存）：

| 指标 | FLEURS Batch N=5 | FLEURS Realtime N=3 | AMI Batch N=5 | AMI Realtime N=3 |
|---|---:|---:|---:|---:|
| 成功并可评分请求 | 50/50 | 30/30 | 40/40 | 24/24 |
| 字符错误 / 参考字符数 | 205/1660 | 285/996 | 705/6605 | 960/3963 |
| 加权 CER | 12.349% | 28.614% | 10.674% | 24.224% |
| 请求延迟 p50 / p95 | 0.240 / 0.345 s | N/A | 0.464 / 0.697 s | N/A |
| 首次预览 p50 / p95 | N/A | 0.983 / 1.000 s | N/A | 1.001 / 1.047 s |
| 最后音频至终态 p50 / p95 | N/A | 0.062 / 0.109 s | N/A | 0.056 / 0.100 s |
| sampling_complete | true | true | true | true |

FLEURS 与 AMI 的 90 次 Batch 共用一个测量窗口，总 phys_footprint 峰值为
11,778,206,424 bytes；FLEURS Realtime 为 12,385,102,576 bytes，
AMI Realtime 为 12,993,162,016 bytes。三个原始 result SHA-256 分别为
`4cf469150ce0b2874a3168b9c7cac3297ea026b2ac0cc8dfb20c08c03ab3eb26` 和
`cd04f77fe7557f88add1b25a475a0e8a40406d3f27cb9a1dfed3876f98d344d7`、
`bffd821ec2de0fbdcf8a5aff74aab1bdd73c0da5f9af0d2ca9db6864326d4959`。

以上素材 32 段、301.806 秒，包括公开朗读与自然会议片段。
这些样本仍不证明中英混合、远场噪声、会议长时稳定性、
提词器重读/手动恢复或原私人问题已复现；headset 片段也不是分人质量门。
候选仍需使用相同字节与参考文本实测，不能据此冻结预设。
候选推理之前预选固定 8 段、79.776 秒对照子集（中文 4、英文朗读 2、自然会议 2），
包含短句与超过 8/20 秒段预算的样本；32/32 来源 fixture 已再次校验 SHA-256。
五个预设的独立 manifest 已准备好，均使用相同字节、参考文本及 warm N=3；
配对旧 Realtime 基线为 24 次、357/1968 字符错误、CER 18.140%。
该入口使用 manual endpointing 比较 decoder/policy，不能替代生产 VAD、LLM 编排、
字幕标点或提词器业务跟随验收。基准期间并行执行过 fake 开发回归，
未证明全机后台负载静默；这些是工程基线，不是正式发布性能门。

基准完成后再次实测：原服务 PID 2864、8201 唯一 listener、无 ESTABLISHED 客户端；
protected metrics 的 batch/realtime active requests 与 realtime sessions 均为 0；
health/readyz 为 200，仍为 3.7.1、quality/quality。没有停服、切档、安装或模型下载。

另补充 [AISHELL-4 官方 OpenSLR 111](https://www.openslr.org/111/) 中文自然会议素材，
官方 `AISHELL/AISHELL-4` mirror revision 固定为
`aada72727856313b19d4a030383c426364931dbf`。音频采用
`test/wav/S_R003S01C01.flac` 的 channel 0，人工参考来自官方 TextGrid，
选择 6 条非重叠发言并各保留 150 ms padding，共 38.890 秒。
许可依据采用 OpenSLR 官方页的 CC BY-SA 4.0；mirror 数据卡元数据标为 Apache 2.0，
存在差异，因此未将 mirror 元数据作为较宽松许可的依据。保留来源、许可页、
下载 prefix、完整标注和逐片段 SHA-256；未验证完整来源 FLAC 的 SHA-256。

AISHELL-4 manifest SHA-256：
`f98e67fe42fce7dde9ad469e4fb91f3d597f474a5c64e12824656e7bea54ef75`。
在原已安装服务上实测 Realtime warm N=3：18/18 成功可评分，
171/498 字符错误，加权 CER 34.337%；首预览 p50/p95 0.999/1.035 s，
最后音频至终态 p50/p95 0.061/0.077 s；sampling_complete=true，
同 tick 总 phys_footprint 峰值 11,830,881,056 bytes，包含既有 resident TTS。
原始 result SHA-256：
`ecac966b73ea52e6185b3f5938cb42a07def8dcf67d5744afb9d503dbf785ad2`。
测前测后 runtime revision 与 quality/quality 身份一致，active/pending/session 均为 0。
旧协议无 segment boundary，sample coverage gate 保持 unset。

加入 ASCEND 前，可评分素材为 38 条、340.696 秒。另已准备同来源 180 秒连续中文会议，
SHA-256 `66e0bdbf52196df61ee4261d7e9869f68f7560b112e2b2354763bd666157554a`；
多说话人重叠没有唯一参考顺序，仅用作连续输入、边界、尾部与资源门，
不计算 CER。该连续片段与 6 条短发言重叠，不能相加宣称更多独立素材，
三分钟也不能作为会议长时 soak 验收。
五份独立中文补集 manifest 和一份 resource-only manifest 已准备，
候选推理尚未执行。上述资料尚不覆盖中英混合、远场噪声、提词器重读/脱稿恢复
或原私人问题的真实重现，因此不能冻结预设。

### ASCEND 中英混合自发口语补集

继续按授权取得作者发布的
[CAiRE/ASCEND 官方数据卡](https://huggingface.co/datasets/CAiRE/ASCEND)，
固定 revision `b65b9bb87a0412eb94a659660819060825e74b9f`。
仅下载 test 分片 `main/test-00000-of-00001.parquet`：
105,756,434 bytes，完整文件 SHA-256
`a4c81d2b5ed6124f052089a695972808c16e0ce0c365ec9773c5d1a8fcf043a7`
与作者 LFS metadata 一致；固定版本数据卡及来源 metadata 留在仓库外。
作者声明 CC BY-SA 4.0，逐字转写保留口语形式。
解析使用仓库外隔离环境 `pyarrow==20.0.0`，没有修改项目依赖或 managed runtime。

从 1315 条 test utterances 中，固定筛选 `language=mixed`、至少 8 个汉字、
3 个英文词、3–15 秒；每位符合条件的匿名 speaker 在 3–5、5–8、8–15 秒
各取一条。按 source ID 的固定 SHA-256 顺序选择覆盖四话题的首个组合，
未参考任何模型输出。最终 6 条、44.110 秒，4.820–10.890 秒，
覆盖 2 位匿名 speaker 及 education/persona/sports/technology。
该 lexical 筛选后只有 2 位 test speaker 符合条件，不能据此宣称覆盖整个说话人群体。
六份音频均为来源原始 16 kHz mono PCM16 WAV，未重采样；
逐文件 SHA-256 与 sample count 已校验。原人工正文没有归一化改写或注入模型 prompt。

manifest SHA-256：
`8e3c5a5795b988a654685e7a691d199350c3c3c8cd326611d87ee30381ac62ac`。
原服务基线 manifest 与五个候选 preset manifest 均通过正式加载器及音频哈希检查；
候选 manifest 使用相同音频和参考，语言为 `auto`，不强制单一语言。
补集没有可靠标点或语义轮次 gold，短句也没有保留完整多轮停顿；
标点 F1、思考停顿、助手一次回复、提词器恢复及长时门仍需独立证据。
全部可评分素材现在为 **44 条、384.806 秒**；连续会议的重叠来源仍不额外计数。

2026-10-06 对同一份六条素材实测原已安装服务；Realtime 先预热后 N=3，
Batch 单独保留每条一次的暖场结果，再以显式重复清单执行 N=5。
正式 Batch 入口的 `warm` phase 每条 fixture 仅执行一次，不自动重复五次；
重复清单的 30 个请求仍只代表 6 条独立音频，没有扩大素材计数。

| 指标 | ASCEND Batch warm N=5 | ASCEND Legacy Realtime warm N=3 |
|---|---:|---:|
| 成功并可评分请求 | 30/30 | 18/18 |
| 字符错误 / 参考字符数 | 155/1305 | 333/783 |
| 加权 CER | 11.877% | 42.529% |
| 请求延迟 p50 / p95 | 0.191 / 0.269 s | N/A |
| 首次预览 p50 / p95 | N/A | 1.006 / 1.039 s |
| 最后音频至终态 p50 / p95 | N/A | 0.061 / 0.074 s |
| 同 tick 总 phys_footprint 峰值 | 11,550,108,424 bytes | 11,904,756,536 bytes |
| sampling_complete | true | true |

原始 Batch result SHA-256：
`6fe2df28002a6e3293d16b96a6bd3ebb9b39e1e3b04aaf1a6204c72ffb8471a9`；
Realtime result SHA-256：
`f1e63be69095b8668310b4d3ae2372ec0a11cd815d5b9ce72e288086ec7020ca`。
两组测前测后 version/profile/runtime revision/ASR ready 一致，
PID 2864、8201 唯一 listener、无 ESTABLISHED 客户端，active/pending/session 均为 0。
Realtime 的 `streaming_state` 从 warm_standby 变为 active，属于观察到的生命周期状态变化；
制品身份并未改变，没有将所有 health 字段整体相等作为身份判据。
峰值仍包含父进程和 resident TTS。旧协议没有 item boundary，
sample coverage、标点、业务场景和候选对照门保持 unset。
Batch `release_pass=false`，缺少 cold、完整模型身份、完整质量、soak 与 switch 证据；
没有用单次测量或单独保存的身份材料回填发布门。
两种 API 行为不可直接称为候选改善，也没有据此冻结预设。

## Issue 验收矩阵与未验收项

### v7 完整串行对照与后续边界发现

v7 wheel SHA-256：
`245857d92c875b998ac852877121ef5d40c98fc1bd6184f9ec9690e2d778db3a`，
源 head `4e513ea1`。164 份 Python 模块逐字匹配源码，安装态 189 份文件匹配；
保持 quality/quality、同一模型和精度，零模型下载。原始音频、参考、维护日志、
逐请求结果及回退备份均保存在仓库外。
时钟修复后的原交付 head CI run `37434825821`（内核）、`37434829883`
（消费端）、`37434833184`（证据）全部 success，均为历史 head 的证据。

`maintenance-v7` 完成 **301/301** 正式请求、2621.640 秒测量音频：
core 8 条 × N3 × 5 预设共 120 次，AISHELL-4 与 ASCEND 分别
6 条 × N3 × 5 预设各 90 次，另一次 180 秒连续会议资源测试。
每份 manifest 的暖场请求不计入 301。重复测量没有扩大独立素材数。
16 份结果均完成资源采样，每个完整 tick 恰一个 ASR worker，
同组 worker incarnation 未变化。维护结果明确
`measurement_completed=true, original_restored=true`。

| 预设 | core CER（旧 18.140%） | AISHELL-4 CER（旧 34.337%） | ASCEND CER（旧 42.529%） |
|---|---:|---:|---:|
| assistant-turn-taking | 7.774% | 6.024% | 11.877% |
| assistant-duplex | 7.774% | 6.024% | 11.877% |
| meeting | 7.774% | 6.024% | 11.877% |
| caption | 6.860% | 5.422% | 13.793% |
| teleprompter | 7.774% | 5.422% | 14.943% |

首预览 p95 范围为 0.399–1.039 s，末音频至 final p95 为 0.099–0.467 s；
core 完整段复核三个预设收尾 p95 为 0.450–0.467 s，旧基线为 0.090 s。
准确率改善伴随收尾延迟增加，不能称为所有指标无退化。
ASCEND 字幕与提词器 CER 高于同候选完整段复核的 11.877%，仍需评估段预算及收尾取舍。
可评分组同 tick 总 phys_footprint peak 为 13,908,536,120–14,448,782,136 bytes。
core 的旧资源峰值来自三个较大的测量池，不是精确八条配对子集的峰值；
不把它用于完全同组资源增量声明。峰值包含服务父进程与 resident TTS。

180 秒连续会议记录 4,320,000 accepted wire samples、9 个边界、9 个终态、
180 次预览，peak 为 14,530,325,304 bytes。没有唯一参考，质量门 unset；
三分钟不构成长时 soak。
原评分器的唯一终态、公开区间连续及尾部覆盖检查全部通过，
但后续检查发现首段 wire span `0...482400` 对应 20.1 s，超过有效 20 s 预算。
**这些 coverage pass 不能证明实际逐段 PCM 和公开区间归属一致。**

确定性反例在更新后的 main 上复现该根因：先将新包 accepted 水位写入
当前 item，再为已经满预算的旧段 rollover。100 ms 分包使旧段边界多出下一包；
1 s 分包可进一步漏发一个有效段的边界。强化的回归同时核对每段实际 PCM
和精确 wire 区间，2400 / 24000 wire-sample 分包修复前失败。
独立只读审查进一步发现 legacy VAD 停止分支也提前覆盖末端，补充反例修复前失败；
隔离修复移除 append、client 尾部和该 VAD 分支的提前覆盖，区间只随实际准入 PCM 推进。
四个相关 Python 文件 157 项通过；完整 Python 回归为 3405 passed、1 skipped、
3 warnings（41.61 s），Ruff、Mypy 164 source files 及 whitespace 通过。
修复已以 `6157e33c` 提交到独立 [PR #290](https://github.com/hrygo/SpeechRail/pull/290)，
尚待真实连续输入复测，v7 原始结果保留，不回填为新候选证据。
完整 Python 回归日志 SHA-256：
`68d509f702fdff64fff357beb616f514758870dbd0a809b631b9f14a110cb787`。

`maintenance-v7-lifecycle` 的 1 ms final deadline 探针得到一次
`backend_timeout` 失败终态，关闭后约 0.455 s 观察到 active/pending/session 全 0、
无 ESTABLISHED 连接；紧接新真实识别成功并再次释放资源。
clear 探针收到 completed，错误为 `cancel_probe_final_won_the_clear_race`，
因此取消门未通过，静音空成功探针也未执行。
源码核查表明显式 client commit 在同一传输队列等待 final，clear 会排在其后；
还需用传输层反例和修复验证。该次维护结果为
`measurement_completed=false, original_restored=true`。

汇总 SHA-256：
`87f24a3d451b3a0218f71fe2f7dba3c646fc6a2635de8f2bdc0759da291142b9`；
主维护 outcome：
`809a708b4b346d3d519b4bda98d2ed156e538b0d2b19f94796883520c9f74cfc`；
生命周期部分结果：
`1f630f10a9c7ac0789abba69852c9f054ed48e2229cca9290eae4e3262be2a67`；
生命周期 outcome：
`8b5b6b4572604dd74eeb4c0736c2b10d07a46f1a51d3acf12fae116413d21e5c`。
以上证明测试实际执行及恢复结果，不证明所有业务场景已验收。
助手语义轮次、会议/字幕实际消费与保存、字幕标点、提词器重读/脱稿恢复、
取消、空成功与长时门仍待完成；预设未冻结，#245 及剩余验收任务保持开放。
2026-10-06 已将以上新结果、限制和回退发布并逐字回读：
[#249](https://github.com/hrygo/SpeechRail/issues/249#issuecomment-6013397822)、
[#253](https://github.com/hrygo/SpeechRail/issues/253#issuecomment-6013398768)、
[#245](https://github.com/hrygo/SpeechRail/issues/245#issuecomment-6013399281)。
#249 因新边界缺陷重新打开；三项核验为 OPEN。原有已合入子项与历史评论保留。

| Issue | 当前交付 | 仍需完成 |
|---|---|---|
| [#247 证据](https://github.com/hrygo/SpeechRail/issues/247#issuecomment-6010521881) | 空成功终态、重复终态、回收完成屏障与 release 回归 | 候选真实集成验收与交付 |
| [#248 证据](https://github.com/hrygo/SpeechRail/issues/248#issuecomment-6010537698) | 中立策略、Schema、有效回显、边界事件、typed Swift 与跨语言回归 | 候选服务有效策略实测与配套交付 |
| [#249 证据](https://github.com/hrygo/SpeechRail/issues/249#issuecomment-6010538278) | 累计 decoder、两种收尾、有界 lane、分包尾部、deadline/quarantine | 候选真实质量、延迟、资源对照 |
| [#250 证据](https://github.com/hrygo/SpeechRail/issues/250#issuecomment-6010538890) | 唯一预设、助手轮次聚合、生产 Session 一轮一次回复/恢复回归 | 真实场景语义轮次与候选质量实测 |
| [#251 证据](https://github.com/hrygo/SpeechRail/issues/251#issuecomment-6010539617) | 会议/字幕 item 账本、区间归属、停录 drain/迟到 attribution 回归、App 编译 | 真实服务和设备下的连续消费/保存验收 |
| [#252 证据](https://github.com/hrygo/SpeechRail/issues/252#issuecomment-6010540143) | 提词器水位、修订与手动接管保护，54 项相关回归 | 候选及时性、实际推进与重读/脱稿恢复 |
| [#253 证据](https://github.com/hrygo/SpeechRail/issues/253#issuecomment-6010540799) | 44 条公开可评分素材、连续会议资源素材、现有服务基线 | 候选真实对照、剩余场景代表性、预设冻结 |
| [#245 证据](https://github.com/hrygo/SpeechRail/issues/245#issuecomment-6010541418) | 核心和消费端实现及确定性集成门完成 | 所有子项与真实集成门通过才关闭 |

2026-10-06 已向上述 8 个 Issue 发布范围精确的证据评论，并逐字回读核验正文、
评论 URL 和 OPEN 状态。原评论附实测、未验收项、当时源码范围及回退说明；
PR 提交状态通过追加评论更新，历史评论不改写为当时已提交。
没有关闭任何子项或总 Issue，也没有勾选尚未验收的质量门。

随后按新增 PR 提交授权，向同一组 Issue 追加交付记录并逐字回读；
旧评论作为历史证据保留。新评论包含 PR、实测/回归、未验收项与逆序回退：

| Issue | PR 交付更新 |
|---|---|
| #247 | [评论](https://github.com/hrygo/SpeechRail/issues/247#issuecomment-6011378837) |
| #248 | [评论](https://github.com/hrygo/SpeechRail/issues/248#issuecomment-6011379552) |
| #249 | [评论](https://github.com/hrygo/SpeechRail/issues/249#issuecomment-6011380309) |
| #250 | [评论](https://github.com/hrygo/SpeechRail/issues/250#issuecomment-6011381007) |
| #251 | [评论](https://github.com/hrygo/SpeechRail/issues/251#issuecomment-6011381777) |
| #252 | [评论](https://github.com/hrygo/SpeechRail/issues/252#issuecomment-6011382486) |
| #253 | [评论](https://github.com/hrygo/SpeechRail/issues/253#issuecomment-6011383238) |
| #245 | [评论](https://github.com/hrygo/SpeechRail/issues/245#issuecomment-6011383891) |

预设当前是候选参数，没有实测无退化结论。用户于 2026-10-06 明确授权执行下方
service-only 临时维护和测量，成功或失败均恢复原服务。候选通过受管 installer 替换服务。
不通过另启源码服务、第二 worker 或偷偷切档绕过这一边界。
UI 自动化、真实 App 控制链路和发布未执行；远端 Git 提交/推送与 PR 已按新增授权执行。

## 已授权的候选服务维护与期限时钟修复

目标单元为唯一 `com.speechrail` managed 服务，最初候选为上述完整 digest 的 v6 wheel。
保持现有 quality/quality、同一 ASR 模型、精度、重采样链和无词表条件。
计划预留约 55–75 分钟，包含两次受管停启及 301 次串行测量请求：
五份固定 manifest 各 8 段、warm N=3（120 次），五份中文补集各 6 段、
warm N=3（90 次），五份 ASCEND 混合补集各 6 段、warm N=3（90 次），
以及一次 180 秒会议 resource-only Gate。
测量音频播放本身共 2621.640 秒，另有暖场、加载、推理和恢复开销；
该时间是计划窗口，不是实测耗时承诺。

1. 重新核对 app home、旧 runtime、selection、PID、listener、active requests、
   realtime sessions 和外部连接；有其他客户端时不关闭其连接，也不开始替换。
2. 保存旧 release/selection 的精确回退点，用 controller 停止旧实例，
   确认父进程、worker、端口与锁释放，再由该 wheel 自带的 managed installer 安装候选。
3. 启动唯一候选服务，核对 wheel 源码、profile、实际模型身份与 ready；
   不因同为 3.7.1 而把版本字符串当作制品身份。
4. 顺序执行五份原固定配对 manifest、五份中文补集、五份混合补集和连续会议资源门，
   核对有效 policy、每 item 唯一终态、sample span 连续和尾部完整性，
   保存 CER（连续门除外）、预览/收尾延迟、资源采样和失败材料。
5. 结束后通过受管流程恢复旧 release/selection 并核对原身份、ready 与空闲状态；
   任一候选启动或 hard gate 失败即停止后续候选测量并按同一回退点恢复。

本维护阶段是 service-only 临时验收，不替换 App、不接管窗口、不发布。
manual endpointing 对照不能完成所有业务质量门；会议连续长稳、字幕标点、
提词器即兴/重读恢复、实际场景语义轮次仍需独立证据。未通过门不冻结 preset，
不关闭子 Issue 或总 Issue。

### v6 真实失败、根因和回退

2026-10-06 16:06（Asia/Shanghai），v6 受管安装成功，189 个 wheel 文件逐字核对，
quality/quality、ASR runtime revision、模型与音色 catalog 一致，模型下载为零。
首个 4.281 秒暖场音频在提交时失败；没有正式测量样本，不能报告候选 CER 或延迟。
16:08 的单项诊断复现同一失败，捕获稳定代码 `backend_timeout`。
两轮均停止后续请求并恢复旧 runtime/vendor/selection；原 generation 13、
quality/quality、配置、模型身份、唯一监听、ready 和空闲验证通过。

根因由本机实测及确定性反例共同确认：uvloop 的 `loop.time()` 比
`time.monotonic()` 大约 16,553 秒。新 ASR 协调器用后者计算绝对期限，
却交给 `asyncio.timeout_at` / `Timeout.reschedule` 使用，提交时立即误超时。
修复将期限计算及排队过期检查统一为事件循环时钟，不调整公共字段或预设。
两个反例覆盖已准入和等待准入的段；修复前 2 failed，修复后四个相关 Python
文件 83 passed，Ruff、Mypy 164 source files 和 whitespace 检查通过。
内核修复 commit 为 `edde6dae02f36d3a1a33d4bafd781f1dcfa8e088`，
当时已同步 #277/#278/#280，尚未合并 main；后续 #289 的合入状态见上方记录。

v7 wheel SHA-256：
`245857d92c875b998ac852877121ef5d40c98fc1bd6184f9ec9690e2d778db3a`；
源 head `4e513ea142781b19e9cf0c2a9df700ba64af39cc`。
164 个 Python 模块逐字匹配，arm64、metadata、版本检查及仓库外安装入口核验通过；
相对 v6 仅协调器源码与 wheel RECORD 变化。16:16 受管安装后再次核验
189 个文件、零模型下载、原档位与 catalog，固定矩阵开始正式测量。
原始证据位于仓库外 `maintenance-v6`、`maintenance-v6-diagnostic`、
`maintenance-v7`、`candidate-v7-wheel` 和 `source-evidence/clock-*.log`。

对应追踪评论已逐字回读：
[#249](https://github.com/hrygo/SpeechRail/issues/249#issuecomment-6012250858)、
[#253](https://github.com/hrygo/SpeechRail/issues/253#issuecomment-6012251316)、
[#245](https://github.com/hrygo/SpeechRail/issues/245#issuecomment-6012251810)。
新 CI run `37434825821`、`37434829883`、`37434833184` 分别对应内核、
App、证据三个新 head，2026-10-06 回读均为 completed / success；
Quality、Python、Swift Package、App build、wheel 和 Gate Summary 全部通过。
该 CI 核验时真实固定矩阵仍在执行；最终结果见上方 v7 段落，
其终态和业务验收结果与上述 CI 分开记录。

## 回退与复现

### 独立段预算验收门

`ASREvidence.score` 新增 `segment_budget_gate`，以已校验的策略回显
`effective_max_segment_ms` 限制每个 24 kHz wire span。允许重采样锚点最多一个
wire sample 的舍入，不允许整包音频延长旧段。质量模式与 resource-only 模式均
执行该门；缺少有效预算或未要求边界时保持 `unset`。

两个模式的红反例均确认：此前连续区间门会接受首段 482,400 samples
（20.1 s），即使回显预算为 20,000 ms。新增预算门拒绝此反例，另覆盖
0/1 sample 舍入允许、2 samples 超限拒绝以及正式 runner 接线。
2026-10-06 基于 #292 主线的评分、工具与 profile contract 回归为
83 passed；Ruff 与 whitespace 检查通过。

新门回放旧 v7 连续资源制品，原连续/尾部覆盖为 pass，而段预算校验明确失败。
原制品 SHA-256 为
`6595d70e35de76e686774fb1540f89aa60df89fccae2d5aaefb92532cc251c1f`，
仓库外回放记录为 `source-evidence/historical-boundary-budget-replay.json`。
没有改写原始结果或追认 v7 的逐段输入归属。该工具补丁可独立回退；
新 wheel 实测通过之前，逐段预算门仍属未验收项。

源码已按上述依赖切片提交或准备为本 PR。源码回退按依赖逆序撤销各 PR 的提交；
原实施工作树未提交差异保留。不得使用
`git reset --hard` / `git checkout --` 清除共享工作区。
已保留本轮误置的旧测试副本到仓库外，正式测试在 Swift Package 目录中。
v6 两次临时维护、v7 主矩阵与生命周期探针均已恢复旧服务。
安装候选前保存旧 runtime/vendor/selection；失败只按 managed controller/installer
回退该服务单元，保留模型、配置、文字数据库和原始证据。

可移植的定向验证入口：

```bash
uv run --extra dev pytest --no-cov -o addopts= -q \
  tests/test_asr_policy.py tests/test_asr_turn_coordinator.py \
  tests/test_qwen3_stream_decoder.py tests/test_qwen3_worker.py \
  tests/test_qwen3_worker_isolation.py tests/test_qwen3_streaming.py \
  tests/test_realtime_multiscene_asr.py tests/test_realtime_admission_commits.py \
  tests/test_realtime_current_schema.py tests/test_realtime_caller_wire.py \
  tests/test_profile_benchmark_contract.py tests/test_asr_quality_metrics.py \
  tests/test_realtime_asr_benchmark.py
uv run --extra dev mypy src
uv run python scripts/check_realtime_contract.py
uv run python scripts/check_user_doc_contract.py
```

ASR-only Realtime 证据使用新增的正式入口参数：

```bash
"$CURRENT_PYTHON" examples/perf/bench_realtime_json.py \
  --asr-manifest "$FIXTURE_MANIFEST" --profile quality --sessions 3 \
  --app-home "$APP_HOME" --output "$NEW_RESULT"
```

`CURRENT_PYTHON` 是当前 managed Python，manifest 与输出都必须在仓库外；
不得覆盖原证据。manifest 可带中立 `asr_policy`，工具校验有效回显、item 唯一终态、
连续输入区间及精确 commit barrier 水位。参考文本仅本地评分，不作为模型 prompt。
基准进程还需已锁定的 OpenAI SDK；当前 managed runtime 不带该开发依赖，
本轮只在基准进程中复用工作树锁定的 SDK 3.20.0，没有给 managed runtime 安装新包。
冷态、标点和业务场景 gate 缺项必须保持 unset。

没有唯一人工参考的连续会议只走显式资源模式：

```bash
"$CURRENT_PYTHON" examples/perf/bench_realtime_json.py \
  --asr-manifest "$RESOURCE_ONLY_MANIFEST" --asr-resource-only \
  --profile quality --sessions 1 --app-home "$APP_HOME" --output "$NEW_RESULT"
```

该参数只能配合 `--asr-manifest`。资源模式仍校验有效策略、paced 输入、
逐 item 唯一终态、连续 sample spans 和精确 commit barrier，并记录资源采样；
不在制品中保留转写正文、不计算 CER，quality gate 必须为 unset。
默认评分入口仍严格要求每条音频有人工参考，不能用空参考伪造质量验收。
