# SpeechRail Open Issues ROI Plan

**核验日期：** 2026-10-17（Asia/Shanghai）；本日重新读取 GitHub 开放列表，共 16 项，原有开放总数未变化。
**目标：** 从 GitHub `hrygo/SpeechRail` 的 16 项开放 issue 中，按用户收益、紧迫度、下游阻塞、工作量和所需验收证据排序，并推进 ROI 最高的五项。

## ROI 排序

| 排名 | Issue | ROI 判断 | 关键依赖或验收边界 |
| --- | --- | --- | --- |
| 1 | [#369](https://github.com/hrygo/SpeechRail/issues/369) 重采样停止尾部冲刷与六类性能观测 | 有明确、局部的代码缺口；尾部风险影响所有非同采样率采集；同时为性能验收提供观测，解锁后续工作。 | 确定性合成 PCM、有限 EOS 冲刷、六个 owner 边界及对应 Swift suites；不宣称真实硬件音质或 CPU 已验收。 |
| 2 | [#308](https://github.com/hrygo/SpeechRail/issues/308) TTS 偶发慢放 | 已记录多次真机异常，最长约 2.2 倍时长，直接拖慢用户朗读；根因尚未由当前代码证实，修复与验证成本有不确定性。 | 先定位服务端路径，再按 issue 的至少 30 次合成要求复核；不以合成耗时或合成转写替代听审。 |
| 3 | [#371](https://github.com/hrygo/SpeechRail/issues/371) App 性能、硬件音频与长稳验收 | App 性能改造已进入当前 HEAD，但改前后实际收益尚无配对数据；该项能决定大型优化是否解决目标问题。 | 依赖 #369；要求同设备、同输入的多次配对 Release 测量和进程归属，未实测项保持未验收。 |
| 4 | [#372](https://github.com/hrygo/SpeechRail/issues/372) 实时字幕延迟与回溯质量 | 当前缺少端到端延迟与纠错质量证据；字幕策略是否带来收益直接影响用户对实时文字的信任。 | 需冻结基线/候选、人工时间与文字参考、分层统计；候选不通过时不得默认启用。 |
| 5 | [#370](https://github.com/hrygo/SpeechRail/issues/370) 会议转写与分人质量 | 会议记录准确性与说话人归属价值高；按产品目标先认证最多 4 人，再评估是否支持更多人。 | 第一阶段验证现有 Sortformer 1–4 人路径，独立报告转写、分人和联合归属指标；第二阶段才评估 5 人以上动态分人。保留开发/留出隔离，不把容量上限当质量承诺。 |

第 6–16 名按剩余工作的边际 ROI 排序；不表示这些产品能力长期价值较低：

| 排名 | Issue | 排在前五之后的原因 |
| --- | --- | --- |
| 6 | [#373](https://github.com/hrygo/SpeechRail/issues/373) 性能改造交互验收与 App/helper 交付 | 复用 #371 的候选和采样准备，但还要独立完成前台 UI、安装与回退验收；排在真实性能证据之后。 |
| 7 | [#374](https://github.com/hrygo/SpeechRail/issues/374) 会议与字幕联合长稳 | 基础路径可先执行，但最终候选压力依赖 #370/#372 冻结策略；部分采样可与 #371 共用。 |
| 8 | [#253](https://github.com/hrygo/SpeechRail/issues/253) 四场景 ASR 总体验收 | 总范围覆盖助手、会议、字幕和提词器，适合汇总专项目证据，不能替代各专项质量门，且依赖多条前置。 |
| 9 | [#118](https://github.com/hrygo/SpeechRail/issues/118) 提词器设备拔插与长时运行 | 独有的真实设备断连与连续跟随证据有价值，但需要麦克风/设备和至少 60 分钟前台活动，工作面窄且运行成本高。 |
| 10 | [#257](https://github.com/hrygo/SpeechRail/issues/257) 完整文本 adapter 评审与实现 | 有助手闭环价值，但需先证明 receipt、取消和有界接收屏障；质量评审未通过前必须保持关闭，实施与回退成本高。 |
| 11 | [#268](https://github.com/hrygo/SpeechRail/issues/268) 完整文本与增量分组对照 | 依赖 #257 的安全边界和 adapter，且主要验收需要同文本真实合成与人工听审；前置未完成时投入无法形成结论。 |
| 12 | [#256](https://github.com/hrygo/SpeechRail/issues/256) 长停顿、自纠正与关键歧义真机对照 | 关键事实错误后果高，但该 issue 聚焦声学端点真实对照；fake 回归不能覆盖目标，需多设备/噪声等实测。 |
| 13 | [#258](https://github.com/hrygo/SpeechRail/issues/258) 助手 M4 质量、取消、设备恢复与长稳 | 汇总质量、恢复、稳定性多个门，依赖 #256/#257，最终运行矩阵宽且需真实模型、设备与 UI 证据。 |
| 14 | [#259](https://github.com/hrygo/SpeechRail/issues/259) 会议知识后续验收 | 同时包含输入法接线、语义召回和分层真实评估，授权、数据与实现前置不同，单次推进难形成完整关闭证据。 |
| 15 | [#79](https://github.com/hrygo/SpeechRail/issues/79) 全 App UI/UX 审查与优化 | 覆盖全 App 页面、键盘、无障碍和文档一致性；范围大且与 #373 的性能交互验收有部分重叠，适合作为单独规划周期。 |
| 16 | [#95](https://github.com/hrygo/SpeechRail/issues/95) ASR/TTS 目标架构落地 | 架构收益覆盖面大，但 issue 汇集协议、模型、运行时、构建和真实认证等多条主线，剩余范围需先拆解才能估算投入。 |

前五项的选择依据是剩余工作的预期收益、紧迫度、可证实性、可复用性和投入/前置约束的综合判断。#373 依赖 #371 的同一候选制品并包含独立前台 UI、安装和回退验收；#374 的最终候选压力依赖 #370/#372。#308 排第二是按其已记录的重复慢放和直接用户影响计分；当前没有本地可证实根因，故本轮先做边界定位，根因未明前不引入启发式补丁。真实运行/语料和前台自动化授权不构成 ROI 加分项，未获授权的对应证据保持 blocked/not_run。

## 执行顺序

### Task 1 — #369：确定性音频尾部与观测

**范围：** `AudioCaptureDrain` 在正常停止时向 `AVAudioConverter` 明确发送 EOS，有限地读取尾部输出；只处理已接受的有限输入。取消、格式变化、丢样、转换错误和无进展不得报告成功。尾部 chunk 使用最后已接收源帧的时间，保留唯一 source sequence，不伪造新的采集时刻。

**状态（2026-10-17）：** 代码、metrics 边界、指定 SwiftPM 回归、target coverage 与文档更新已完成。定向 filter 通过 5 个 XCTest 和 56 个 Swift Testing 用例（8 suites）；后续修正了 Helper/App 共享 metrics sink 的 Xcode target 集成，当前 Release App/Helper 构建与 XPC packaging verification 通过。未做真实硬件、性能或 UI 验收。

为 `dubbingExport`、`captureEnqueue`、`mixerTick`、`captureStop`、`teleprompterMatch`、`transcriptPublish` 接入现有 `AppPerformanceMetrics`。每个值在真实 owner 边界计量；统计保持固定容量、无文本/路径/音频内容，不增加实时 tap 中的任务、I/O 或动态采样器。

**测试：** 先增加 24 kHz、44.1 kHz、48 kHz 的合成 PCM 回归，覆盖短尾、部分块、正常停止、取消和失败；将拼接输出与相同 converter 配置的完整输入参考比较，验证尾部数量、无重复/静音补齐、源时间、sequence 和唯一终态。用现有定向 metrics / capture suites 覆盖 operation 边界与禁用状态。

**完成证据：** Issue #369 指定的 SwiftPM 定向 suites、测试 target 注册检查、`git diff --check`；更新性能手册与验收记录，将实际性能和 UI 结果继续标为未验收。

### Task 2 — #308：TTS 慢放根因与有界复核

检查真实服务端合成与 WAV/PCM 交付的采样率、速度参数及状态传递，建立能区分模型生成慢、采样率误报和音频封装错误的定向回归。只有根因由证据定位后才改实现；再按 issue 的重复合成与 V16 记录要求复核。

**状态（2026-10-17）：** 当前源码审查未定位 SpeechRail 本地慢放触发点。`runtime-lock.json` 指向仓库内 `mlx_audio-0.5.6-py3-none-any.whl`（SHA-256 与 lock 相符），其身份为上游 revision `4ab7e6f7` 加固定 patch；不是直接运行未修改的 PyPI wheel。SpeechRail 的 `_generate` 将校验后的 `speed` 传给顶层 `generate()`；该 wheel 的文档标明 `speed` 尚未实现，CustomVoice 路由调用 `generate_custom_voice()` 时也不转发它。这说明速度控制字段没有在 vendor 层生效，但不能解释 `speed=1.0` 下的随机慢放。`_to_pcm` 校验采样率后做 PCM16 转换和末尾静音裁剪，不改变发声时长。TTS 交付只设 encoded-byte 总上限并记录 PCM 时长/推理时长，没有按文本长度校验发声速度；现有 `generation_token_budget` 是 `clamp(24 + 5 × text length, 32, 1200)` 的 token 预算，不是语速门。上游 [mlx-audio#1002](https://github.com/Blaizzy/mlx-audio/issues/1002) 最新记录称逐请求设置采样 seed 后，同一 worker、相同参数仍同时产生正常和慢放；未给出根因或修复。fake-model 用例定向运行 12 项通过，只证明参数传递，不证明音频时长稳定。任意文本时长阈值可能误拒正常长句或截断内容，当前没有依据支持本地启发式防护；未执行真实模型复现。满足前置后再跑 issue 要求的同文本至少 30 次验证并更新 V16。

**本次执行结果（2026-10-17）：** 未声称找到 vendor 根因；采用 issue 的替代验收门——同一 V16 请求在缺省 CustomVoice 路径连续 30 次 0 个 >14 秒输出，并验证 sampler receipt 实际报告派生 seed。验收方法、运行时身份和限制见本计划底部及 M4 矩阵；这是 V16 限定的本地完成证据，不外推为其他文本的质量保证。

### Task 3 — #371：配对性能与硬件验收

依赖 Task 1 的代码与观测。冻结改前/改后构建、同设备和同输入条件，按 issue 的场景、重复次数和进程角色记录 CPU、主线程、RSS、队列与释放时间。性能原始制品保留仓库外；未运行或证据不完整的场景列为未验收。

**初始构建状态（2026-10-17）：** 基线 `bedabb6a93669144c12a4e8dba6c5305f4503128` 与当前 `da18da8a80ec2fbd5827148c42537024656e5f18` 加当前 #369 worktree diff 均通过 Release App/Helper 构建及 XPC packaging verification；两套二进制均为 arm64。构建产物位于仓库外：

| 构建 | App 主程序 SHA-256 | CaptureHelper SHA-256 |
| --- | --- | --- |
| 基线 `/private/tmp/speechrail-perf-baseline-candidate-20261017/SpeechRail.app` | `2c4569622baa6e12bff66c53901de8dfef24a408153c682e0f2620e99275b97b` | `d335ed9487c5e25a8d28174ac0efe7a90780136a5c7ce99173600e7ba05239bb` |
| 当前候选 `/private/tmp/speechrail-perf-candidate-20261017-after-shared-sink/SpeechRail.app` | `5422bf67eaca0857bd6bb37dc5a052d6e8de85fa3048518c1808055ec40a1dd9` | `ce4b0322e81ba1d157bf7d345d0aa358f19e9daed183609b3bd1520ec65cb030` |

这些制品只证明编译与封装。初始记录时验收表没有配对 Release 测量；后续 idle pair1 与 pair3 结果及当前缺口见本计划末尾和[性能验收记录](../../audits/2026-10-16-app-performance-acceptance.md)。真实硬件音频、长稳和其余交互没有证据。#369 的代码、合成回归与 target 集成已验证，但不替代 CPU/RSS、主线程、队列和释放时间测量。没有正式安装 App；后续只在隔离目录启动临时 Release 副本采样。

### Task 4 — #372：字幕质量与延迟

按 issue 的独立留出集、人工字词时间、首字/持续文字延迟和回溯改写统计执行。不得用模型对齐或 WebSocket 收包时间代替人工时钟；质量门未通过则保留现行策略。

**状态（2026-10-17）：** 已有材料只是一个开发片段的探索回放；旧路径 CER 16.3913%、候选 CER 17.0870%，未组成完整配对矩阵。人工音频词尾时钟、纠错/误改统计与真实 UI 延迟仍缺，现行候选继续 no-go，不满足关闭条件。

### Task 5 — #370：会议质量与动态分人

分阶段按 issue 的会议级配对指标和留出集执行。第一阶段优先认证最多 4 人的现有 Sortformer 路径，分别报告 ASR 转写错误、分人错误与端到端 speaker-attributed 错误；如未达门槛，先根据分项结果优化算法、模型或工程路径，再评估测试方案。第一阶段通过后，第二阶段再研究 5 人以上的动态分人。区分主要讲话人与短插话，单列局部声学错误与覆盖损失；未找到合格候选时保持 no-go，不以全部 `unknown` 或工程容量宣称质量通过。

**状态（2026-10-17）：** 现有开发集试验未找到同时达到质量门的候选（`production_certified=false`、无 winner）；留出集仍锁定，安装态独立评估未完成。本轮未加载模型或读取外部语料，不能据此关闭 issue。

### 2026-10-17 范围更新：先认证最多 4 人

用户提出调整实施顺序：先保障最多 4 人会议的分人准确率，达标后再决定是否扩展到更多人。这个顺序不降低既定质量阈值，也不解锁 R004。

- 当前 R003 的 8 场会议均为 5–6 人；既有校准走 `meeting_dynamic`，只能支持动态分人候选在该开发集上的结论。它没有评估最多 4 人的 Sortformer 路径，不能推断该路径达标或不达标。
- 第一阶段应使用现有 Sortformer（`system_cap=4`）路径，以 1、2、3、4 人分层统计；保持已有逐场门槛。最多 4 人时，top-four 覆盖包含全部参考说话人；“其他说话人最低覆盖”在该范围内记为不适用，超过 4 人后仍按原门槛检查。
- ASR CER/WER、分人 DER/JER/说话人覆盖与准确率、speaker-attributed cpWER/tcpWER（或项目的 cpCER）分项并列报告。分项定位根因，联合指标衡量“谁说了什么”的整体结果；不得仅凭联合指标归咎于 ASR 或分人。
- 先盘点非留出、可合法使用的 1–4 人开发样本；官方 AISHELL-4 覆盖 4–8 人、AliMeeting 覆盖 2–4 人，但本地 R003 只含 5–6 人。新开发样本与留出划分须先锁定并留存摘要；不得读取、评分或用于选型 R004。
- 若 1–4 人评估未达门槛，依据 ASR-only、diarization-only 与联合结果定位声学、聚类、说话人排序/匹配及工程接线问题，优先改进系统并在开发样本上复核；只有系统问题被排查后，才复核验收方法。第一阶段全部门槛通过后，另行规划 5 人以上动态路径，不外推 4 人结果。

行业证据支持这种分层诊断：CHiME-8 同时报告 speaker-attributed tcpWER 与 speaker-agnostic tcORC-WER，并以 tcpWER 排名；2025 年方法论文将 cpWER/tcpWER 与忽略说话人归属的 WER 分开定义，并提出 DI-cpWER 分析说话人混淆对联合错误的贡献。NOTSOFAR-1 的总结指出 DER 更低不必然带来 tcpWER 更低。模块化与联合建模的比较也发现，联合模型在真实会议数据微调后可以更好，但未经过该微调时模块化系统更好；这说明分人和转写错误在最终体验上耦合、诊断上仍需分开测量，且联合模型并非无条件优势。来源：[CHiME-8/NOTSOFAR 结果](https://www.chimechallenge.org/challenges/chime8/task2/results)、[多说话人长音频 WER 指标论文](https://arxiv.org/abs/2508.02112)、[NOTSOFAR-1 总结](https://www.sciencedirect.com/science/article/pii/S088523082500021X)、[模块化与联合 SA-ASR 对比](https://arxiv.org/abs/2107.02852)。语料覆盖来源：[AISHELL-4](https://arxiv.org/abs/2104.03603)、[AliMeeting/M2MeT](https://arxiv.org/abs/2110.07393)。以上来源于 2026-10-17 核验。

## 工作约束

- 当前 worktree 与主仓库在基线 SHA `da18da8a80ec2fbd5827148c42537024656e5f18` 一致，开始时干净；所有修改留在此 worktree。
- 依次执行，沿用每个 issue 的具体规格；如排序依据被当前代码或新证据推翻，先更新此计划再继续。
- 计划制定时不提交、不推送、不关闭或评论 GitHub issue，不安装 App，也不改变服务运行态。用户随后明确授权全权执行后，按 #308 需要使用受管 installer 安装本地 wheel 候选；旧 runtime release 保留回退。没有安装 App，也没有进行 GitHub 远端写入。
- 真实音频、语料、模型与性能原始制品不进入仓库；确定性回归使用合成数据。

## 2026-10-17 授权执行跟进

本节更新上述 Task 状态快照；保留原计划与早先证据，不把局部测量提升为 issue 关闭结论。2026-10-17 04:34（Asia/Shanghai）只读复核时，#308、#369、#370、#371、#372 仍全部为 OPEN；没有评论、关闭或其他远端写入。

- **#369 — 本地代码与确定性回归完成。** 见本机[性能验收记录](../../audits/2026-10-16-app-performance-acceptance.md)中 2026-10-17 的代码/测试段。该 issue 没有在 GitHub 关闭；实际硬件与性能验收由 #371 继续跟踪。
- **#308 — 探索性真实模型复测复现了时长异常，但未定位根因。** 已用 managed runtime 的公共 REST API，在 `3.11.1`、`quality/quality`、`speechrail/qwen3-tts`、`serena`、`speed=1.0` 下，对一个 43 字匿名数字/否定文本做 1 次预热和 30 次串行请求。WAV 时长 p50 9.80 秒、p95 13.552 秒、最大 14.80 秒；1/30 超过历史 14 秒标记，2/30 超过该批中位时长的 1.4 倍。请求耗时 p50 2.471 秒、p95 3.422 秒，与输出时长 Pearson `r=0.9978`。音频只在内存中解析并未落盘；本次未保存音频、人工听审或转写，因此这里只证明时长离群，不能宣称复现并确认 0.45x 慢读或正文正确。公开 [mlx-audio#1002](https://github.com/Blaizzy/mlx-audio/issues/1002) 仍为 OPEN（上次更新 2026-10-06）。原复现脚本和 WAV 已不在现有临时目录，GitHub issue 没有原始全文；该文本与历史 43 字文本不可配对，未作本地修复。
- **#371 — 新增临时 Release 副本的空闲前台/隐藏态各一组配对样本，issue 仍未通过。** 旧的正式 App 静止前台样本仍是 `3.11.1 (54)`、300.19 秒、footprint 159.345 MiB 与 control-agent 4.016 MiB；它不与本次临时副本合并比较。本次源码基线 `3.10.0 (52)` / 候选 `3.11.1 (54)` 的前台 CPU p50/p95/max 均为 `0.0/0.0/0.2%`，footprint 分别 `82.5/103.7/103.7` 与 `82.2/103.4/103.4 MiB`；隐藏态 CPU 均为 `0.0/0.0/0.0%`，footprint 分别 `99.3` 与 `99.1 MiB`。所有样本 300 秒、60 个 CPU tick 和 30 个 footprint tick 完整。该单次配对未显示有意义的空闲资源变化，且隐藏态预热历史略有不同；没有活跃音频、CaptureHelper、主线程 profile、尾音/metrics 负载或长稳验证。临时数据与 SHA-256 见[性能验收记录](../../audits/2026-10-16-app-performance-acceptance.md)。临时进程已按精确 PID 退出，bundle 条目已注销；正式 App 与服务未改动。
- **#372 — 未完成端到端验收。** 没有 UI/声学字词时间、首字与持续字延迟或纠错/误改统计；当前 App 有既有工作区打开，本轮只读检查并取消了临时菜单，没有切换页面、创建会话或写入数据。官方 Realtime benchmark 在 managed runtime 启动时因缺少 `openai` Python 包而失败，未通过安装依赖或非正式替代脚本伪造验收。既有探索结果继续 no-go。
- **#370 — 只新增短样本批量 ASR 结果。** `bench_profiles.py` warm phase 跑现有 AISHELL-4 六条短会话 fixture：38.890 秒、6/6 HTTP 200、加权 CER `8/166 = 4.8193%`、单次延迟 p50/p95 `0.2033/0.6786 s`、RTF p50/p95 `0.0325/0.1030`；`sampling_complete=true`，但只观察到 warm phase 且整体 `release_pass=false`。这不是整场会议或分人验收；开发集 8 场/24 策略仍无 winner，`production_certified=false`，holdout 继续锁定。

真实采样前后，服务都保留在 `quality/quality` generation 13；鉴权 `/metrics` 显示 realtime active sessions 与 batch/realtime active requests 均为 0，未发现外部 ESTABLISHED 客户端。没有停服、切档、安装、模型/语料下载、修改用户记录或写入原始音频。脱敏外部结果只在本计划和对应验收记录保留 artifact id 与 SHA-256；原始 JSON 不入仓库。

**阶段结论（2026-10-17 此次跟进前）：** 五项 ROI 排序保持有效；#369 的代码与回归工作完成，#308/#371/#372/#370 的 issue 级验收仍未完成。随后对 #308 恢复了精确 V16 输入并进行了追加复测，更新见下方；不把单次空闲性能样本、探索性字幕结果或短会话 ASR 提升为 issue 级通过。

## 2026-10-17 follow-up: #308 上游修复核查

2026-10-17（Asia/Shanghai）重新核查 SpeechRail #308 的全部三条评论与上游 [mlx-audio#1002](https://github.com/Blaizzy/mlx-audio/issues/1002)，其状态仍为 OPEN、没有上游回复。#308 评论记录的 `/tmp/v16_repro*.py`、`/tmp/v16_half*.py` 与对应 WAV 当前均不存在。该次搜索也未在本地找到历史 43 字原文；后续扩大到验收矩阵后发现精确文本仍保存在 `docs/plans/2026-10-06-assistant-m4-acceptance-matrix.md`，见下方 follow-up。历史音频和脚本仍无法恢复。

上游在 2026-10-13 发布 `mlx-audio v0.5.9`，其中合入 [PR #1003](https://github.com/Blaizzy/mlx-audio/pull/1003)，修复 Qwen3 `DecoderBlockUpsample.step` 重叠区间重复叠加卷积 bias 的音频数值误差，并增加流式/整段解码形状一致的回归。静态 diff 显示改动校正流式解码的样本值，不改变解码帧数；因此它不能单独证明 #308 的 1.5–2.2 倍发声时长异常已解决。这是源码与上游测试范围推断，未在本机真实模型上应用或测量。

本机受管运行时仍固定 `mlx-audio 0.5.6` 加项目补丁；该次没有升级依赖、修改运行配置或执行新的 TTS 复测。上游没有针对随机慢速生成的根因结论或修复，不能用 #1003 的解码数值修正替代慢放验收。

## 2026-10-17 follow-up: #308 synthetic seed probe

2026-10-17（Asia/Shanghai）为响应上游 issue 中的 seed / 其他文本复现建议，使用当前受管 `quality/quality` TTS API、模型 revision `08b854525817066e04ef6b6430a3faa0eebd24d2`、`serena`、`speed=1.0` 与 WAV 输出，测试一条新构造的 43 codepoint 中文日期/金额/号码/否定合成句；它不是无法恢复的原 V16 文本。API 输出为 24 kHz mono PCM16。

- 同一 seed `1729` 连续合成 5 次，五个 WAV 均为 12.40 秒、595,244 bytes，SHA-256 完全相同（`85faa950aa9e1fbff7f2ef4e779f8e254b2c20696e1d9f385a9e1794b4f8c5de`）。
- 30 个不同 seed 的时长范围为 8.96–13.20 秒，中位数 10.20 秒，0/30 超过原 issue 的 14 秒慢放标记。
- 同一测试句未指定 seed 连续合成 30 次，时长范围 8.16–17.12 秒，中位数 10.56 秒；14.08 秒与 17.12 秒两次超过 14 秒（2/30）。之后为获取可分半诊断的 outlier 再试 30 次，没有新样本超过 14 秒。

这些是服务端合成返回波形时长的观测。它们表明当前服务上显式固定 seed 对此文本可复现，且未指定 seed 时出现超过 14 秒的长尾；不能证明这些长尾就是约 0.45x 慢放，也不能确定触发机制。没有保留 WAV，未进行人工听审、分半转写或 vendor token-count 记录；本次 synthetic probe 使用的新文本并非 V16。执行该探针时尚未找到本地 V16 原文，后续在验收矩阵中恢复，详见下方 follow-up。因此新结果不满足 #308 的修复与同文本验收门，不以固定 seed 作为未经验证的全局 mitigation，也未改依赖或运行配置。

脱敏统计 JSON 留在仓库外，artifact id `speechrail-issue308-synthetic-seed-probe-20261017`，SHA-256 `bcb5963886b57dba2206cec641a60772a8c8557546cc850098f88ec9acd5bd89`；所有临时 WAV 已删除。探针结束后的新 `describe()` 显示 profile 仍为 `quality/quality` 且一致，TTS 状态为 `active`（由本次合成加载），未重启服务、切换 profile 或修改配置。

## 2026-10-17 follow-up: #308 exact V16 seed reproducibility

初始搜索之后，在 `docs/plans/2026-10-06-assistant-m4-acceptance-matrix.md` 找回 issue 所述精确 43 字 V16 输入；原复现脚本和历史 WAV 仍缺失。使用当前受管 `quality/quality` 服务、模型 revision `08b854525817066e04ef6b6430a3faa0eebd24d2`、`serena`、`speed=1.0`、24 kHz mono PCM16 WAV，未将输入文本或转写写入报告/制品。

- 三批各 30 次未设 seed 的合成合计 90 次，时长范围 7.36–15.76 秒，中位数 9.60 秒，p95 12.88 秒；2/90 超过 issue 的 14 秒慢放标记。两条异常输出为 15.76 秒与 14.96 秒。
- 固定 seed `[0…27, 1729, 4294967295]` 的 30 次 sweep 中，3/30 超过 14 秒（seed 5/16/23，时长 14.32/16.88/17.28 秒）。各异常 seed 又各重合成两次，完整 WAV SHA-256 与原输出逐一相同；因此 seed 确定地选择输出，固定 seed 本身并不能排除慢样本。
- 对两个未设 seed 异常样本及 seed 23 的 17.28 秒样本做整段和分半 ASR：整段保留 V16 的全部核验事实；前半仅包含开头部分，后半包含尾部部分，没有两半各自重复整句的证据。此次新样本未人工听审，ASR 分半只支持“非整句重复”的判断，不独立证明耳感语速或 0.45x 慢放。

上述结论截至后续 request-derived 默认策略实施之前。90 次未设 seed 样本的发生率不能与历史约 7–8% 作可靠优劣比较；没有记录 vendor `GenerationResult.token_count`，因此未推出跨文本时长阈值或通用检测。

脱敏逐次时长、seed 与输出哈希保存在仓库外，artifact id `speechrail-issue308-exact-v16-seed-probe-20261017`，SHA-256 `8472b81a018778c3e105d6dea5723a835609a99062a24db63ac83fe11baf686e`。新生成的完整与分半 WAV 均已清理；服务 profile 保持 `quality/quality`，没有重启服务或更改配置。

**当前执行结论：** #369 的本地实现、确定性回归与构建验证已完成；#308 的 request-derived 默认路径已安装，并按精确 V16 文本完成 30 次无 seed header 验收，输出一致且未超过 14 秒，回执也记录了实际策略和 seed。它没有定位 vendor 慢放的通用根因，人工听审未重复执行；issue 状态仍待根据公开验收门与当前 GitHub 状态处理。#371/#372/#370 仍缺 issue 要求的配对硬件/交互性能、字幕人工时序与回溯质量、会议级开发/留出集质量证据。

## 2026-10-17 follow-up: #308 request-derived default acceptance

首次探索所用 seed `3288020616` 是从 43 codepoint 原始文本计算的显式 seed；API 规范化会补句末标点，因此当前实现对实际 44 codepoint 的规范化文本派生 seed `4004728035`。经受管 `quality/quality` API、`serena`、`speed=1.0` 与 WAV 输出，对同一精确 V16 输入连续发出 30 次**不带 `SpeechRail-Seed`** 的请求。30/30 时长均为 11.52 秒、WAV 553,004 bytes、24 kHz mono，SHA-256 均为 `22d0689c775d35f2ede982d7894941684be0a2d88bc3f740e3342dd485639385`，0/30 超过 issue 的 14 秒标记。

定向 ASR proxy 对相同 SHA 的一份输出核验了日期、地点、改期、金额与号码段；转写和音频均未保留。integrity receipt 记录 `seed_policy=request_derived`，`observed_sampling_parameters.seed=4004728035`；receipt state 仍为 `partial`，所以不宣称其余 recipe 字段齐全。为使生产 receipt 看见 worker 实际采样信息，`Qwen3TtsCapabilityRouter` 新增按 response ID 转发 sampler observation，配套回归验证 `bind_tts_execution` 将 router 识别为 sampling reader。

当前 managed service 安装的是本地候选 wheel，语义版本仍为 `3.11.1`；profile 保持 `quality/quality` generation 13，preflight、`/health`、`/readyz` 和唯一 listener 核验通过。旧 runtime release 保留可回退；未下载或修改模型、selection 以外的用户配置、音频或记录。候选 wheel SHA-256 为 `e310c5cb2048a7981a97c9679f6fb66dc845aba49ff902043f187ea43ac79e9b`。

脱敏 JSON 保存在仓库外，artifact id `speechrail-issue308-exact-v16-seed-probe-20261017`，SHA-256 `46ad2ed012f0fd2027d71ed0f1dece20cf6d6b1ff05b624801505783253f81ae`；此前 90 次未设 seed、explicit-seed sweep、分半 ASR 和探索 seed 的结果仍保留在同一制品中。没有重新人工听审，不能据此宣称 vendor 根因已修复或对其他文本提供“无慢放”保证。

## 2026-10-17 follow-up: #371 isolated Release idle repeat

用户明确授权全权执行后，补做了同设备 Release pair3 的前台与隐藏 idle 采样。基线 `3.10.0 (52)` 与候选 `3.11.1 (54)` 都以同一辅助功能树预检查后测量前台 300.005 秒；CPU p50/p95/max 分别为 `0.0/0.0/0.2%` 与 `0.0/0.0/0.0%`，RSS p50 为 `178.3/179.1 MiB`，footprint p50 为 `79.2/79.3 MiB`。隐藏态各 300 秒；CPU p50/p95/max 均为 `0.0/0.0/0.2%`，RSS p50 为 `193.6/194.2 MiB`，footprint p50 为 `97.5/97.3 MiB`。这组 idle 对照显示两版本空闲资源相近。

pair1、pair3 与 pair4 共三组 idle 前台/隐藏态比较；pair2 因预检查不一致排除，idle 场景的重复数量达到 3 组。pair4 中前台 baseline/candidate 的 CPU p50/p95/max 为 `0.0/0.0/0.2%` / `0.0/0.0/0.2%`，footprint p50 为 `79.1/79.3 MiB`；隐藏态 CPU 为 `0.0/0.0/0.4%` / `0.0/0.0/0.2%`，footprint p50 为 `97.5/97.6 MiB`。采样没有启用真实音频、CaptureHelper 或会议/字幕会话，也没有 1 秒 CPU、wakeups、主线程栈、队列/取消释放和 1 h/4 h 长稳证据。catalog、audiobook、export、LLM、capture、capture-failure、teleprompter、transcript 与 waveform 场景未测，#371 继续 no-go。完整制品身份、原始数值 JSON 摘要与 SHA-256 见[性能验收记录](../../audits/2026-10-16-app-performance-acceptance.md)中的 pair3/pair4 附记；服务验收后仍 `/health=200`、`/readyz=200`、batch/realtime active requests 为 0，临时 App 已退出并注销。

## 2026-10-17 follow-up: #371 UI test discovery attempt

用户授权后，使用仓库包装脚本尝试 `SpeechRailAppUITests.SpeechRailAppUITests.testControlCenterHonorsRequestedWindowSizes`。Xcode 在测试发现阶段 exit 70，错误为 `No test bundle product for testingSpecifier`；错误 `.xcresult` 显示 0 tests、result `unknown`。日志同时报告 CoreSimulator `1171.7.0` 低于 Xcode 要求的 `1174.9.2`。测试 target、scheme 与 test plan 在源码中均存在，故该结果是工具链/测试发现阻塞，不是用例失败；没有产生 UI 交互验收证据。

## 2026-10-17 follow-up: #370 reconstructed AISHELL-4 development calibration

原 8/4 场 AISHELL-4 source manifest 与完整源注释在本机不可用，故从官方 [OpenSLR AISHELL-4 test archive](https://www.openslr.org/111/) 重建新 split；官方许可为 CC BY-SA 4.0。归档 SHA-256 `7e5d306b5f18ab66fcd7e0380c90979b47fd9576bfa8e67e6353bdec7c14a35a`，source manifest SHA-256 `2961588e1ec9bc34429a9db25c57e7c6dbc8e5ef7a549def66b03f49a5fdb277`。按文件 ID 预先锁定 8 场 R003 开发集（M/L/S 房间，共 82.51486 分钟、5–6 名本地 speaker ID）和 4 场 R004 留出集；开发 manifest SHA-256 `ff3df5d28862fb5c2c73f597a98d4e204248121fc39994b412cf0513968c01cd`，留出 manifest SHA-256 `574a2822d28ea35deb38c91e584586c6e908623810437f5d99863d0825714d13`。这是独立重建 split，与历史 8 场/24 策略试验不可直接比较；所选开发集没有 ≤4 人会议。

同一开发 manifest、SDK revision `5c19d5e12320e22bbfb7a1877b089d2665a69add`、model revision `7eab74f3463c736418d0eb10296261ae581146c9` 串行运行默认设置与校准专用 `zero_vote_reembed`，每组比较 24 个匹配策略。两组均为 0/24 feasible candidates，8/8 开发场次质量门失败，没有 winner，也没有 `selected-candidate.json`；`production_certified=false`。最佳观察策略只用于开发诊断：known accuracy 场均 89.61% / 89.65%，known coverage 89.42% / 90.20%（基线/zero-vote）。没有候选通过，因此 R004 留出集保持锁定、未评分，未进行安装态 API 验收；本轮也未运行整场会议 ASR 候选 CER/关键事实词评分。#370 继续 no-go。

校准入口锁定八场开发 manifest、拒绝重复/非字符串 ID 和留出会议，只有全部开发门通过才会冻结候选；`zero_vote_reembed` 限制在 calibration worker。定向 Python 24 项、Ruff、mypy、Swift Release worker build 与 diff 检查通过。

脱敏开发集汇总制品留在仓库外，artifact id `speechrail-issue370-reconstructed-dev-calibration-20261017`，SHA-256 `2809619b2b8192a8f1d1d168e1628f55ea5a1b90b105f6dc9fadad842702843c`。原始音频、标注、活动帧与完整逐场结果不入仓库。

## 2026-10-17 follow-up: #372 word-boundary source check

发现 Sinica MCDC8 作为词边界候选：官方资料列出 8 小时会话语音与 signal-aligned word boundaries；方法论文说明其采用自动 syllable alignment/word segmentation 并做人工词边界核验，故在核对实际样本前仍不能认定满足 #372 的独立人工时钟要求。语料来自台湾华语会话和安静录音环境，代表性有限。ACLCLP 公布的申请要求机构证明与三份签署原件，费用从海外非营利学术机构 US$2,000–2,100 到其他海外机构 US$6,000–6,400；许可 PDF 返回 HTTP 403，协议条款及适用类别未核实。本次没有联系、申请、下载或付款。MagicData-RAMC 官方说明含人工转写及说话人活动时间，但未声明人工词边界。来源核验与准确边界见[会议字幕验收记录](../../implementation/2026-10-16-meeting-caption-acceptance.md)；#372 仍缺人工 token/时钟、端到端 UI 延迟及纠错质量证据，保持 no-go。

## 2026-10-17 follow-up: #308 controlled seed duration and content probe

在当前 managed `quality/quality` generation 13 上，以 `/v1/audio/speech`、`speechrail/qwen3-tts`、`serena`、`speed=1.0` 和 V16 精确输入，串行测试 `SpeechRail-Seed` 0–31；模型、文字、音色、采样率与输出格式固定，只改变 seed。32/32 请求成功，PCM 只在内存中统计字节数，没有保存音频、正文或转写。3/32 seed 超过 issue 的 14 秒慢放标记：seed 5 为 14.32 秒、seed 16 为 16.88 秒、seed 23 为 17.28 秒；32 个输出时长范围 8.40–17.28 秒，中位数 9.52 秒，p95 16.88 秒。TTS 请求 wall time 与输出音频时长 Pearson `r=0.9850`，慢时长仍发生在模型生成路径内。

随后对默认派生 seed（`4004728035`）和 seed 1/5/16/23 的同输入输出做本机 ASR 内容代理核对。NFKC/字母数字规范化后，这五个输出的转写相对默认输出 CER 均为 `0.0000`；没有把 ASR 转写保存到报告，也没有重新人工听审。该组证据将离群定位到 seed 影响的模型输出时长，而不是错误音频采样率或整句重复；这与 Qwen3 TTS 通过 MLX categorical sampling 生成声学 token 的实现相符。当前 API 的默认路径已对相同 voice+normalized text 派生固定 seed：V16 派生 seed 输出 11.52 秒，既有 no-header 30/30 重复为同一 PCM SHA、0/30 超过 14 秒。该修复稳定了报告中的默认 V16 请求；显式 caller seed 仍可以可复现地选择较慢输出，未增加会截断或缓冲整段 PCM 的通用时长门。此次没有采集 vendor `GenerationResult.token_count`，也没有验证所有文本/音色的 seed 分布。

脱敏数值保存在仓库外：seed sweep artifact `issue-308-seed-sweep-20261017-719bd9d753`，SHA-256 `be112aa9d9092714282897a181022c28035dbf6d4f12ea6caa63deebe98297e4`；ASR 内容代理汇总 `issue-308-seed-content-check-20261017-e6b0636962`，SHA-256 `8d4d2914d228f079bd115854b1e88594458f92b95780f076ac01ae1c4bc08f4c`。采样前后服务保持运行、profile generation 不变，`/health`/`/readyz` 为 200，protected metrics 中 batch/realtime active 与 pending requests 均为 0，`lsof` 未见已建立客户端；没有停服、切档、安装、下载模型或更改用户记录。TTS 定向 Python 回归 73 项通过，Ruff 通过。#308 的根因和 V16 默认路径验收现已有本地证据；GitHub issue 仍 OPEN，待代码进入共享分支后再做远端交付处理。

## 2026-10-17 follow-up: #370 acoustic clustering calibration

新增并执行七档聚类/VBx screen，随后对 top-two（`threshold=0.45`、`0.75`）各跑 24 个 matcher policy。两组均完成 8/8 开发场次，best-observed matcher 均为 index 11，但各自 0/24 feasible、无 winner、未生成 `selected-candidate.json`。两组 known accuracy 均值为 89.98% / 90.15%，top-four 最低覆盖均值为 59.36% / 62.12%，其他参与者最低覆盖均值为 71.84% / 70.51%；至少一场相关覆盖为 0%。R004 未读取，生产默认值未改，#370 继续 no-go。脱敏汇总 artifact `speechrail-issue370-cluster-calibration-20261017`，SHA-256 `750ad545a0d322e4a417cf75437a9f22c90dda7805e4fabf5fdb402012c07322`。

## 2026-10-17 follow-up: #371 App role-stat performance regression

按“先查算法和工程代码”的顺序，先执行不启动 App、不接触真实音频的定向性能回归。首次执行 27 个 XCTest 中有 4 项断言失败，集中在 `testRoleStatsVisitAnnotationsAndEdgesOnceAndMatchReference`；角色计数、冲突边和遍历次数对照中，参考模型漏实现生产代码已有的自动 `.lead` 上限及短角色停止条件。对照有声书分层验收后，生产算法与规则一致，测试参考算法过期；因此更新大规模选角规范到 2.2.0，并修正参考模型，没有改生产算法。

修复后该性能子集为 27 XCTest + 41 Swift Testing tests，全部通过；`AudiobookCastTests` 73 项通过。合成回归证明遍历次数和缓存/队列限制相关的确定性行为，不提供实时 CPU/RSS、MainActor 热点、硬件音频/XPC 或长稳数据；#371 仍未达到关闭门。UI 测试发现错误仍是独立的 0-test 工具链问题，未据此判定产品性能或测试断言。

## 2026-10-17 follow-up: 接手监督复核与静态门修复

在目标工作树 `<worktree>` 对五个高 ROI issue 的实现、测试与文档开展独立核查：

- 修复 `#370` 新增探针 `examples/perf/probe_meeting_diarization_global_context.py` 与 `examples/perf/diarization_3d_speaker_runner.py` 中的 7 个 `mypy` 类型检查错误；修复后 9 个相关 Python 源文件 `mypy` 与 `ruff check` 全部通过，171 项关联 `pytest` 用例通过（1.87s）。
- 复核 `#369` 8 个 Swift 测试套件（59 项参数化/非参数化测试调用，含 `AudioCaptureDrainTests` 10 项 EOS 重采样冲刷与 `captureStop` 计量、`AudioInputTerminationTests` 14 项）、`#371` `AudiobookWorkspacePerformanceTests`（10 项）、`scripts/check_macos_test_target_coverage.py`（`OK`）及 `SpeechRailDiarizationProtocolSelfTest`（退出码 `0`），全部通过。
- 清理本计划上文重复粘贴的第二段 `#308 controlled seed duration and content probe`：V16 默认派生 seed `4004728035` 仅证明该单句默认请求稳定，不代表消除 `mlx-audio#1002` 通用慢放；五个 issue 均保持 OPEN / no-close。
