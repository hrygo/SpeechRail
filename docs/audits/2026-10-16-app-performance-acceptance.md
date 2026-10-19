---
title: "SpeechRail App 性能优化实施与验收记录"
status: in-progress
date: 2026-10-16
audience: "macOS 开发者、测试与产品负责人"
---

# SpeechRail App 性能优化实施与验收记录

核验时间：2026-10-16，Asia/Shanghai；实施阶段集成于 19:35 CST 完成，提交前 Swift 定向复核于 19:54 CST 完成。性能改动的源码基线为 `bedabb6a93669144c12a4e8dba6c5305f4503128`，改后源码为 `7f32582b38e3c4c87ed9ce982246da57ed6218dd`，包含创作存储与投影、流式音频与会话两个逻辑提交；提交时的文档整理未改变该源码；PR #375 后续 CI 修复另见下节。范围与预算见[设计](../superpowers/specs/2026-10-16-app-performance-design.md)，逐项 RED/GREEN 见[实施计划](../superpowers/plans/2026-10-16-app-performance-implementation-plan.md)，当前执行边界见[开发手册](../developers/macos-app-performance.md)。

按用户要求，PR 保留当前分支全部内容，目标为 `main`，提交时远端基线为 `383e6e23`。其中已有的 `bedabb6a` 是会议归属、实时转写与服务对齐修复，包含服务代码、公共文档及历史实施记录；其范围和当时实测见[专项记录](../superpowers/plans/2026-10-16-realtime-layout-diarization-repair.md)。这些历史局部实测不覆盖本次性能改动后的制品，也不替代本记录 B/C 层验收。

本记录分三层：A 为确定性行为与编译集成，B 为实际 CPU/主线程/RSS/长时资源性能，C 为实际交互。A 已完成，独立审查的 5 项 Important 已经 RED→GREEN 修复；B、C 未验收。没有测量证明单核满载已经消除。

## 实现与回归对应

| 问题 | 实现入口 | 确定性证据 | 范围限制 |
| --- | --- | --- | --- |
| F01 音色目录重复 I/O | VoiceCatalogStore / VoiceCatalogModel | 千次读取不读盘、原子替换/损坏/新鲜度、合并刷新、停止 watcher | 实际文件事件时序、UI CPU 未测 |
| F02 有声书全量工作区 | AudiobookWorkspaceReader / Projection / ProjectStore | 统计等价、索引查询无全扫描、1 执行/1 最新等待、版本隔离/最终刷新 | 实际大书耗时与内存未测 |
| F03 主线程存储 | CreativeWorkStore / DubbingProjectStore / StoreCommitReceipt | 阻塞文件操作不阻塞 MainActor、提交时取消、恢复、真实回执/64 条历史 | 用户真实库未读写，无磁盘格式迁移 |
| F04 整段音频导出 | DubbingExportWriter / PreparedDubbingExport / SharedPlaybackOwner | 256 KiB 最大块、精确 PCM、格式/RIFF 拒绝、取消/部分保存、URL 播放与共享请求失效 | 长导出 RSS、文件播放器内部缓存未测 |
| F05 逐字节调度 | LLMProvider / LLMStreamDelivery / 助手预览 | 事件期限、挂住 transport 取消、128 事件/256 KiB、50 ms 合并与终态 | 真实网络和模型延迟未测 |
| F06 音频积压与 mixer | AudioChunkStream / CaptureDeliveryWindow / CaptureAudioRelay / StreamMixer | 137,280 B 排队 PCM 预算、独立错误、credit、最后 ACK、100 次重连、迟到 tick、四场景 draining | 原生 ring/scratch/活跃块单列；真实 XPC/硬件未测 |
| F07 tap 转换分配 | AudioCaptureDrain / AudioCaptureTimeline / 原生 source | tap 中 converter 调用 0、固定 ring/64 条时间边界、取消等待实际转换退出 | 不能证明系统 callback 总分配或实际时序 |
| F08 高频 UI 依赖 | SessionActivityIndicators / 局部 TimelineView | 隐藏/不活跃暂停、终止时间冻结、电平不修改转写投影 revision | body/diff 数、VoiceOver/Reduce Motion 实际表现未测 |
| F09 提词重复准备与扫描 | PreparedTeleprompterScript / Aligner / FollowController | 同版本 100 次预览准备一次、anchor 对数比较、旧 matcher Match 逐字段等价、代次与 final | 实际匹配 p95 未测；原窗口/DP 保留 |
| F10 长会话增长 | TranscriptPresentation / SessionStore / itemRetired | 20,000 行显示有界；两个实际场景分别合成 4 h/2,880 行完整归档、tail 500、live 索引 0；分页/锚点/完整范围复制/迟到归属 | 逻辑时间快进；实际滚动、选区及 4 h 稳定性未测 |
| F11 重复波形扫描 | WaveformEnvelopeLoader / AudioEnvelope | 扫描 1、排队 8、租约通知 256、缓存 64/256 KiB、真正退出后复用槽、版本隔离、归一化等价 | 仅持久化作品；无摘要旧作品和内存试听使用占位；实际 CPU 未测 |
| F12 服务侧候选热点 | 无服务代码改动 | 没有授权采样/基线，条件任务不执行 | 待测；不改变模型、worker 或准入策略 |

逐模块回归与最终集成会重复同一用例，不能相加为独立覆盖数量。最终定向 SwiftPM 运行显式启用 Swift Testing：464 个 XCTest 与 260 个 Swift Testing 用例/18 suites 通过，0 failures。临时将波形队列上限从 8 改成 9，容量用例按预期失败，随后恢复原条件并通过上述集成。测试仅使用 fake backend、临时合成数据和逻辑时间；未执行完整 Python/Swift 测试套件。

最终 App/helper Debug 包装构建成功；包装入口的定向 Xcode 单测 26 个 XCTest 与 93 个 Swift Testing 用例/13 suites 通过，0 failures，未启动 UI tests。SwiftPM/Xcode sources 清单检查、PBX plist 与 tracked/untracked 差异空白检查通过。构建临时 App 制品由包装脚本清理，没有安装。

## 提交前复核

2026-10-16 19:54–20:05 CST，对源码 `7f32582b38e3c4c87ed9ce982246da57ed6218dd` 重新执行以下检查。99 个 App/helper 源码、测试和注册文件的内容哈希与已审查工作树一致；分组提交没有改变源码。文档另外更新交付状态与回退说明。

| 检查范围 | 结果 |
| --- | --- |
| 性能及受影响工作流 SwiftPM 定向集成 | 464 个 XCTest + 260 个 Swift Testing 用例/18 suites，退出 0 |
| AudioSampleRingTests / TranscriptFollowStateTests / RealtimeContractTests | 72 个 XCTest + 2 个 Swift Testing 用例/1 suite，退出 0 |
| App/helper Debug 包装构建 | BUILD SUCCEEDED，退出 0 |
| 包装入口定向 Xcode 单测 | 26 个 XCTest + 93 个 Swift Testing 用例/13 suites，TEST SUCCEEDED，退出 0 |
| ASR 对齐、分人、归属、提交尾部及 Realtime 的 8 个 Python 测试文件 | 218 个成功测试标记，退出 0；全部使用隔离测试环境 |
| 9 个 Python 源文件与上述 8 个测试文件 Ruff | 通过 |
| 9 个 Python 源文件 Mypy | Success: no issues found |
| Realtime schema / fixture / 字段表 | 52 fixtures、45 tracked fields 通过 |
| sources 清单 / PBX plist / 差异空白 / 提交敏感模式 | 通过；敏感模式扫描 0 命中 |

Python 首次准备环境触发可选 native worker 打包编译，已主动中止；定向测试使用项目已有 `SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1` 开关重启并通过，没有将 native 发布制品列入验收。本次没有运行完整 Python/Swift 套件、coverage gate、真实性能或交互验收；上述定向用例也不与实施阶段重复计数。

## PR #375 CI 跟进

2026-10-16，对完整 CI 的失败项继续排查，以下证据不替代 B/C 层验收：

- 独立 LLM 编译脚本遗漏拆出的共享流与性能计量文件，本地按原入口复现类型缺失；补齐三个共享源码后独立编译通过，4 个业务依赖隔离守卫用例通过，仍不引入功能模块依赖。
- 完整 Swift 回归复现助手语音断裂后的恢复失败。保持音频不连续即终止来源的策略；故障来源收尾后，同场文字输入恢复可用；显式重建采集 epoch 后重新建立序号与回答资格水位，累计丢音证据保留。对应测试先失败，再验证恢复路径。
- 远端取消确认失败时，先取消上传/接收任务，再关闭音频与连接并等待任务退出，避免正常关闭被误报为来源丢失而再次进入 ending。取消后的上传任务不再上报采集失败。
- 波形测试的“不响应取消的物理读者”改为 continuation 挂起，保留必须显式释放才退出的条件，避免多个并行测试用 semaphore 占满 Swift 协作线程池。9 个波形用例在 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` 下通过；完整套件曾使测试调度延迟约 5 秒，超过辅助函数原有的 3 秒存活性等待；该等待放宽到 15 秒并透传失败调用位置，不改变断言。CI 是否恢复由新 head 的完整门禁确认，没有调高作业的 15 分钟超时或跳过测试。

后续 run `38902566511` 中，Python 全套、质量门禁、App 构建与 wheel 打包通过，Swift 并发测试阶段仍超时，日志无新增断言失败。本地将协作线程池限制为单线程，采样复现存储/导出测试的同步 semaphore 等待：释放者自身也依赖被占满的线程池。测试夹具改为从主队列执行既定取消或 heartbeat，再释放同步操作，原提交回执、取消与文件断言保留，并明确断言取消已发生；生产存储和导出实现未改变。三个相关 suites 的 27 个用例在严格线程池下通过。

额外的全套单线程压力运行不记为通过：它现在能在约 15 秒内退出，但 sampler 握手与 ACK 的短期限测试出现 11 个超时问题。该运行用于死锁归因，不替代 CI 的常规调度配置；常规完整回归和最终 head 的 CI 分别核验。

run `38905021569` 不再死锁，Swift 在约 10 分钟内结束，只剩 `testGracefulDrainWaitsForTheLastDequeueAcknowledgement` 的真实时钟 ACK 过期失败，其余检查通过。该用例改用既有可注入时钟冻结时间，单独验证“最后一个 ACK 到达前不能完成”；生产 1 秒期限不变，显式推进时间的过期、迟到 ACK、重复 ACK 与旧 epoch 用例保留。修复后全部 616 个 Swift Testing 用例 / 55 suites 通过，受限线程池下 8 个 credit policy 用例通过。

助手修复及后续存储/导出夹具修复后的常规完整 `swift test --package-path macos/SpeechRailApp` 退出 0：1,733 个 XCTest（1 个既有 skip）、616 个 Swift Testing 用例 / 55 suites，0 failures。远端门禁以 PR 最终 head 的检查状态为准。

#369、#371、#373 保持开放；真实性能、硬件/XPC、长时稳定性与交互验收仍未完成。源码回退还须覆盖以上 CI 修复与相应测试；仅撤销最初两个性能提交不足以完整回退本 PR。

## 独立审查与修复

新上下文审查只读检查基线至工作树的 71 个已修改路径和 39 个未跟踪路径。工作树未索引，旧 generation 图谱只作导航，相关覆盖缺口由当前源码补读；主代理复核覆盖与以下问题。审查没有运行测试、硬件或采样，测试结论来自作者的实际执行。

| 问题 | 修复与 RED→GREEN 证据 |
| --- | --- |
| 播放请求自行失效，真实错误提示被吞掉 | 内部换轨停止与公共请求失效分离；candidate/work driver 抛错均显示原有失败提示，继续保留旧回调/全局停止隔离 |
| 两份文件已提交，清理失败被误报为导出失败 | 保留成功回执与唯一清理句柄；故障注入验证返回保存成功、明确清理失败，重试不覆盖目标，关闭后清理仍可重试 |
| 同一选择在投影期间被编辑，旧快照仍返回 | book/chapter 投影后重新验证 revision，有限重读；projection gate 内提交新 candidate，发布结果必须包含新 revision |
| 共享 policy 文件包含 App-only UI，Xcode 单测编译失败 | View 移回已有 App-only 文件，policy 保留 Foundation；同一 Xcode 包装单测入口从编译失败转为通过 |
| 定时器延迟时，迟到 ACK 复活过期窗口 | 锁内先核期限，再释放 credit；假时钟精确到期限时 ACK 抛过期错误，等待者失败退出，relay 清理真实来源 |

修复后再次运行上述完整定向集成与 App/helper/Xcode 构建入口。没有第二次独立审查；修复验收由失败复现、回归和集成结果承担。

**Deferred minors：** AudioCaptureDrain 正常停止时尚未显式 EOS flush AVAudioConverter；24 kHz 同采样率的停止测试不覆盖 44.1 kHz 等非整数重采样尾部完整性。该项未在本次修复，不能据当前结果承诺硬件尾音完整性。

> **后续状态：**该项已在 2026-10-17 小节实现（正常停止排空有限 raw tail 后向同一 converter 提交 `.endOfStream`），并补入 24/44.1/48 kHz 的参考比对回归；2026-10-19 在当前 HEAD 复核通过。硬件尾音与真实设备时序仍属 #371，本条原结论仅描述 2026-10-16 的状态。

## 实际性能矩阵

下表记录初始验收时的场景状态；后续实测以本节之后的日期附记为准。方案中的预算是目标，不能填写为本次成绩。性能原始制品保留仓库外，仓库只写匿名汇总与制品引用。

| caseID | build SHA | process role | 输入规模 | sample duration | warmup | before | after | 重复次数 | 结论/未验证项 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| idle | baseline/candidate Release；二进制摘要见后文 | App | 前台/隐藏，各 5 min | 语音助手待机；pair3/pair4 使用统一预检查 | 见后文 | 见后文 | 3 组（pair1、pair3、pair4）；pair2 探索样本排除 | idle 重复数达到 3；helper、wakeups、主线程和其他场景未验收 |
| catalog | 未测 | App | 100/1,000/5,000 音色 | 未测 | 未测 | 未测 | 未测 | 0 | 解码/主线程与外部变更时序未验收 |
| audiobook | 未测 | App | 大书、多角色、快速切章 | 未测 | 未测 | 未测 | 未测 | 0 | 投影 p95、CPU、RSS 未验收 |
| export | 未测 | App | 1/30/120 min 音频 | 未测 | 未测 | 未测 | 未测 | 0 | RSS、I/O、取消到释放未验收 |
| llm | 未测 | App/service | 单字节 SSE、慢消费者/停顿 | 未测 | 未测 | 未测 | 未测 | 0 | 调度与传输资源实测未验收 |
| capture | 未测 | App/helper/service/worker | 双路音频、重连 | 未测 | 未测 | 未测 | 未测 | 0 | callback 分配、gap、XPC、队列峰值未验收 |
| capture-failure | 未测 | App/helper | 慢消费者、无/迟到 ACK、旧 epoch、100 次重连、停止与回调重叠 | 未测 | 未测 | 未测 | 未测 | 0 | 失败/回收性能未验收 |
| teleprompter | 未测 | App | 长稿/重复词/版本切换 | 未测 | 未测 | 未测 | 未测 | 0 | 实际匹配 p95 与跟随延迟未验收 |
| transcript | 未测 | App | 真实 1 h/4 h 会话与回看 | 未测 | 未测 | 未测 | 未测 | 0 | RSS、归属修订、用户位置/选区未验收 |
| waveform | 未测 | App | 多 owner、快速换音频 | 未测 | 未测 | 未测 | 未测 | 0 | 扫描 CPU、AVAudioFile 缓冲与释放时间未验收 |

AppPerformanceMetrics 已接入目录、工作区读取/投影、存储提交、LLM 事件、提词准备与波形扫描；`dubbingExport`、`captureEnqueue`、`mixerTick`、`captureStop`、`teleprompterMatch`、`transcriptPublish` 也已在各自 owner 边界记录数值样本。CaptureHelper 使用共享 sink 契约发出采集事件，不在 helper 进程内聚合内存统计。不得把通用统计中的 0 解读为未执行或无热点。实际采样应结合 Time Profiler、SwiftUI Instruments 和各 owner 的计数，不把固定容量证明当作 RSS 证明。

## 交互与运行态

截至 2026-10-16，未运行接管前台的 UI 自动化，未启动 App 进行交互验证。需要后续确认：长会话回看锚点、页间补载/新行提示、文本选择与复制、快速换页取消、叶子依赖实际 body 更新、Reduce Motion、VoiceOver 和窄窗口。

2026-10-17 经用户授权尝试运行 `testControlCenterHonorsRequestedWindowSizes`。仓库包装脚本中的 `xcodebuild test` 在测试发现阶段以 exit 70 退出；错误为 `No test bundle product for testingSpecifier`，`xcresult` 汇总为 0 tests、result `unknown`。日志同时报告本机 CoreSimulator `1171.7.0` 早于 Xcode 需要的 `1174.9.2`。源码中的 scheme、test plan 和 UI test target 均存在，但本次没有执行测试方法或产生产品交互证据；#371 的实际 UI 验收仍未完成。

本性能治理实施与提交阶段未安装、部署、启停服务、操作 profile/模型、使用真实音频或下载模型，没有运行态回退动作。性能改动保持 REST/Realtime wire 与持久化业务格式；`.itemRetired` 是 App 内部事件。PR 中已有 ASR 专项对公共文档的澄清见其原提交与专项记录。App 与 CaptureHelper 的内部 XPC 参数已经共同迁移，后续发布和回退必须使用配套制品。

## 回退准备

性能源码整理为 `80173005`（创作存储、工作区、导出与波形）和 `7f32582b`（流式交付、音频、提词与长会话），回退时按新到旧处理，并将依赖双方一起撤销；不能只撤销 async 调用者或只撤销 helper 一侧。逐任务回退仍须按 T11→T10→T09→T08→T04→T07/T06→T05→T03→T02→T01→T00 评估。`bedabb6a` 是另一个 ASR 逻辑提交，整个 PR 的回退还须覆盖它并复核对应契约。也可在另一个干净 checkout 构建基线，保留现有工作树和用户数据；本次未执行该构建或替换。

已安装版本若将来需要回退，另按发布技能和明确授权使用原配套制品。保留作品、会话库、journal 与恢复入口，不以删除库作为性能回退方式。回退后须重新检查库可读性、保存回执、音频队列/停止和 App/helper 协议；这些回退验证尚未执行。

## 后续跟踪

2026-10-16 将剩余工作登记为以下三个 issue；创建记录不表示对应实施、真实测试或交付已经执行。

| Issue | 范围 | 依赖与完成边界 |
| --- | --- | --- |
| [#369](https://github.com/hrygo/SpeechRail/issues/369) | 重采样停止 EOS 尾部冲刷、六类通用性能观测点 | 代码与确定性回归前置；关闭不代表实际性能达标 |
| [#371](https://github.com/hrygo/SpeechRail/issues/371) | Release 配对 CPU/RSS/主线程采样、硬件音频、XPC、真实长稳及 T12 条件归因 | 依赖 #369；实际输入、制品、时长与前后证据齐全后验收 B 层 |
| [#373](https://github.com/hrygo/SpeechRail/issues/373) | 性能改造的真实交互、App/helper 配套交付与回退 | UI 可与 #371 协同；正式交付汇总前置结果，C 层与运行态动作各有实际授权/证据 |

既有 #253、#258、#118 的 ASR/助手/提词器专项验收，以及 #79、#259 的 UI/会议功能范围仍由原 issue 跟踪；相同制品和条件的证据可复用，不重复建立其实施任务。三个新 issue 均包含清单、关闭条件、证据要求和授权边界，不以旧回归数量或本登记代替真实验收。

## 2026-10-17 follow-up: #369 code and deterministic evidence

本节记录 #369 的后续源码与确定性验证，不改写上文截至 2026-10-16 的历史验收状态。核验日期：2026-10-17，Asia/Shanghai。变更留在独立 worktree；未提交、推送或关闭 GitHub issue。

正常停止现在先在原 drain queue 排空已接受输入，再向同一 `AVAudioConverter` 提交 `.endOfStream`。冲刷最多进行 8 次；错误、无输出进展、格式变化、丢样或交付失败都保留错误终态，只有确实到达 converter 的无数据 `.endOfStream` 才允许完成。EOS 尾部继续使用原 epoch/source ID、递增 sequence，并用最后接收输入帧的 capture uptime；取消不会冲刷，也不会标为成功。默认 prime method / info 未改，frame count 采用 converter 返回值。

回归先以完整输入参考暴露现状：合成 44.1/48 kHz 用例分别少 9 个 24 kHz 输出采样；修复后 24/44.1/48 kHz 的 EOS 输出与同格式默认 converter 参考帧数一致，逐样本误差不超过 3。测试还检查 sequence 连续、来源时间不伪造为当前时刻、没有丢样、取消与格式错误终态，以及 drain stop 的 success/cancelled/failed 数值观测。

六类 `AppPerformanceOperation` 均在实际 owner 边界产生数值样本：dubbing 准备与 staging 复制、helper chunk 入队/交付、单次 mixer tick、AudioCaptureDrain 与 CoreAudio tap 停止、已准备 Script 的 matcher，以及历史页投影。注入 collecting metrics 的定向回归核对 bytes/count/outcome；禁用统计仍不增加 sampler、Task 或 observer。配音保存回执和 lease 清理结果仍由原状态机单独定义，metrics 不代替提交事实。字段口径详见[性能手册](../developers/macos-app-performance.md)。

验证结果：

- Issue 指定的 SwiftPM filter：5 个 XCTest 与 56 个 Swift Testing 用例（8 suites）通过，0 failures；包含音频 drain、chunk stream、capture relay、mixer、input termination、metrics、提词匹配、transcript projection 和 dubbing export。
- `python3 scripts/check_macos_test_target_coverage.py`：`macos-test-target-coverage: OK`。
- `git diff --check`：通过。
- 2026-10-17 使用 `scripts/macos_app_build.sh --configuration Release` 构建源码基线与当前候选；两者的 App 与 CaptureHelper 均编译成功，XPC packaging verification 通过，二进制为 arm64。候选 bundle 导出到仓库外，未安装或启动；当前候选编译覆盖了共享 metrics sink 的 target 集成。
- 未运行实际麦克风/CoreAudio 采集、Release 配对性能采样或 UI 自动化；CPU/RSS、硬件尾音和交互仍未验收。

## 2026-10-17 follow-up: #369 targeted rerun

08:52（Asia/Shanghai）在当前 worktree 重跑同一 SwiftPM filter，5 个 XCTest 与 56 个 Swift Testing 用例（8 suites）通过，0 failures；`python3 scripts/check_macos_test_target_coverage.py` 返回 `macos-test-target-coverage: OK`。这次复核确认定向代码门在当前工作树仍通过，不增加真实硬件、Release 配对性能或 UI 交互证据。

## 2026-10-17 follow-up: #371 foreground idle process sample

2026-10-17（Asia/Shanghai）对当时已运行的 Release App 做 300.19 秒静止前台采样。App 与
control-agent 进程身份在全程保持不变；60/60 个 5 秒 CPU tick 和 30/30 个 10 秒 footprint
tick 完整，采样前后受保护 `/metrics` 的 realtime session、batch request 和 realtime request
均为显式 0，`lsof` 未见 ESTABLISHED 客户端。没有开始会议或字幕，也没有操作当前工作区。

| 角色 | PID / start time | CPU（单核百分比，p50/p95/max） | `phys_footprint`（p50/p95/max） |
| --- | --- | ---: | ---: |
| SpeechRail App 3.11.1 (54) | 11836 / 2026-10-17 01:37:15 | 0.0 / 0.0 / 0.0% | 159.345 / 159.345 / 159.345 MiB |
| Local control-agent | 11847 / 2026-10-17 01:37:16 | 0.0 / 0.0 / 0.0% | 4.016 / 4.016 / 4.016 MiB |

CPU 使用 `ps` 累计 CPU 时间每 5 秒差分；结果为该采样分辨率下的读数。采样期间没有
CaptureHelper 进程，因而没有 CaptureHelper 音频路径数据；服务/模型 worker 也不计入上表。
这只是当前 App 的一个静止场景，不是改前/改后配对结果，不覆盖活跃音频、主线程热点、队列、
硬件尾音或长稳门。不能据此判定 #371 通过。

脱敏原始采样保存在仓库外，artifact id `speechrail-issue371-idle-20261017-k7yhoezu`，
SHA-256 `2e0268102922fbfff0c9e9d71542759dc17a24c0222d659bb4fc1a860182c3cf`；未保存音频、转写或窗口内容。

## 2026-10-17 follow-up: #371 isolated Release idle pair

2026-10-17（Asia/Shanghai）使用两个仓库外临时 Release App 副本，在默认语音助手空闲页各采样一组
前台与隐藏态数据。两者分别为源码基线 `3.10.0 (52)` 和候选 `3.11.1 (54)`，均为 arm64；
每个 300 秒样本采集 60 个 5 秒 CPU tick 与 30 个 10 秒 `phys_footprint` tick。临时副本使用
隔离的用户目录与 `SPEECHRAIL_APP_HOME`，未开始会话、未操作正式 App 工作区，也没有采集音频或写入用户记录。

| 状态 | 构建 | CPU p50/p95/max（%） | `phys_footprint` p50/p95/max（MiB） | 采样时长 |
| --- | --- | ---: | ---: | ---: |
| 前台空闲 | baseline `3.10.0 (52)` | 0.0 / 0.0 / 0.2 | 82.5 / 103.7 / 103.7 | 300.015 s |
| 前台空闲 | candidate `3.11.1 (54)` | 0.0 / 0.0 / 0.2 | 82.2 / 103.4 / 103.4 | 300.016 s |
| 隐藏空闲 | baseline `3.10.0 (52)` | 0.0 / 0.0 / 0.0 | 99.3 / 99.3 / 99.3 | 300.726 s |
| 隐藏空闲 | candidate `3.11.1 (54)` | 0.0 / 0.0 / 0.0 | 99.1 / 99.1 / 99.1 | 300.016 s |

前台两次样本都在后段由约 82 MiB 上升至约 103 MiB，p50/p95 差异分别约 0.3 MiB；隐藏态 p50
差异约 0.2 MiB。该单次配对没有显示有意义的空闲资源变化。CPU 是 `ps` 累计 CPU 时间差分读数，
此空闲场景中的 0.0% 只表示低于该采样分辨率。隐藏态 candidate 紧随其 300 秒前台样本；baseline
隐藏态前的 300 秒前台预热开始于一次先前的隐藏/显示操作后，因此两条隐藏态历史并非完全相同。

原始脱敏 JSON 留在仓库外：前台 baseline `speechrail-issue371-baseline-front-pair1-20261017`
（SHA-256 `3481d4655958db00c79214e9084fadbce9ce2ba7969d9a27fc439a44511e52ea`）、前台 candidate
`speechrail-issue371-current-front-pair1-20261017`（`bbee2142de074c009a5b7d0803538bc92db828adf68f0caee93a36aa4e8ab4cf`）、
隐藏态 baseline `speechrail-issue371-baseline-hidden-pair1-20261017`
（`e42ad310571c8b2037d7a0652eaf4b743cc178885396545b6e09d9dd647d0e0a`）与隐藏态 candidate
`speechrail-issue371-current-hidden-pair1-20261017`
（`b7b2244cad7a8abb067707baafa19746dc489c2279fe020692c156c150b572e5`）。

这只覆盖一次空闲前台与隐藏态配对，不覆盖活跃音频、CaptureHelper、会话尾音、六项 metrics 的
真实负载、主线程热点或长稳运行；不能据此关闭 #371。测量后按精确 PID 退出临时进程，并注销两份
临时 bundle 的 LaunchServices 条目；正式 App（PID 11836）与服务未停止或修改。

## 2026-10-17 follow-up: #371 isolated Release idle pair 3

在 macOS 27.0.1 / Xcode 27.1、arm64 同一设备上，用 `scripts/macos_app_build.sh --configuration Release --export-path <外部目录>` 分别构建基线 `bedabb6a93669144c12a4e8dba6c5305f4503128` 与候选 `da18da8a80ec2fbd5827148c42537024656e5f18` 加当前 App 源码树。两份 App 均为 `3.10.0 (52)` / `3.11.1 (54)`；主程序 SHA-256 分别为 `18791cc38428427c0b15d9349fd5f026fbbbb77c579f8490c3e7b3e48317ce87` / `ed05ad75403727142c334f01ea0a2254f7e35426dacd406042245f6409e726ea`。CaptureHelper SHA-256 分别为 `79f1298aacbe8d1175330112bb15da0e8f71c33c50c538db051128b228d944b9` / `693cce2f217bfd27818392783e8cd8ebdf04edf518e169413e936f1818c4372d`；control-agent SHA-256 分别为 `0ac591790a3267584ddde84ddb0d646da3380066ec25c6a75ed57a1efa2b7d33` / `4ec30b96e039447e06b3655d962074c7a85db487eb5fce651698512d9cefb743`。候选 App 源码树 SHA-256 为 `749bb22585e25bf05b79aabb10acbaedafca2a463ad9a674a1b656433598b621`。

前台 pair3 两个版本都在计时前读取相同的辅助功能树，随后保持语音助手待机 300.005 秒；隐藏 pair3 以相同方式隐藏各自的临时 App，分别采样 300.010 秒和 300.007 秒。用户 home 与 `SPEECHRAIL_APP_HOME` 均指向本轮独立临时目录，没有开启麦克风或创建会话。每份样本采集 59 个 5 秒 CPU/RSS tick 与 29 个 10 秒 `vmmap -summary` `phys_footprint` tick；CPU 是 `ps` 累计 CPU 时间差分，100% 代表一个逻辑核心。

| 状态 | 构建 | CPU p50/p95/max（%） | RSS p50/p95/max（MiB） | `phys_footprint` p50/p95/max（MiB） | 时长 |
| --- | --- | ---: | ---: | ---: | ---: |
| 前台空闲 | baseline `3.10.0 (52)` | 0.0 / 0.0 / 0.2 | 178.3 / 178.3 / 178.4 | 79.2 / 79.2 / 79.2 | 300.005 s |
| 前台空闲 | candidate `3.11.1 (54)` | 0.0 / 0.0 / 0.0 | 179.1 / 179.1 / 179.2 | 79.3 / 79.3 / 79.4 | 300.005 s |
| 隐藏空闲 | baseline `3.10.0 (52)` | 0.0 / 0.0 / 0.2 | 193.6 / 193.6 / 193.7 | 97.5 / 97.5 / 97.5 | 300.010 s |
| 隐藏空闲 | candidate `3.11.1 (54)` | 0.0 / 0.0 / 0.2 | 194.2 / 194.2 / 194.2 | 97.3 / 97.3 / 97.4 | 300.007 s |

pair3 的前台与隐藏态差异均很小；它与既有 pair1 和下文 pair4 构成三组 idle 重复，不能外推到活跃功能。另有一组探索性 pair2 因 baseline 在计时期间读取辅助功能树、candidate 未读取而排除。pair1 隐藏态的前置显示/隐藏历史不完全一致；pair3/pair4 前台读取相同辅助功能树，隐藏态条件保持匹配。采样没有 CaptureHelper 进程，没有实际硬件音频；没有 1 秒 CPU 样本、wakeups、Instruments 主线程栈、队列/取消释放时间或 1 h/4 h 会话。其他必测场景仍未运行；#371 继续未通过。

脱敏汇总制品 `speechrail-issue371-idle-pair3-20261017` 保存在仓库外，SHA-256 `cba6fde1c9f44f8628d18136adb427c34ad1e9d5ccd061e121a22e478ef617e5`。其中保留 pair3 四份原始数值 JSON 的摘要与进程时间；未保存窗口内容、转写或音频。

## 2026-10-17 follow-up: #371 isolated Release idle pair 4

沿用 pair3 的基线与候选 Release bundle、独立用户目录和 `SPEECHRAIL_APP_HOME`，每次样本均为 300 秒、59 个 5 秒 CPU/RSS tick 与 29 个 10 秒 footprint tick。前台计时前两个版本都读取相同的辅助功能树；隐藏态先隐藏对应临时进程。未启用麦克风或创建会话。

| 状态 | 构建 | CPU p50/p95/max（%） | RSS p50/p95/max（MiB） | `phys_footprint` p50/p95/max（MiB） | 时长 |
| --- | --- | ---: | ---: | ---: | ---: |
| 前台空闲 | baseline `3.10.0 (52)` | 0.0 / 0.0 / 0.2 | 178.0 / 178.0 / 181.7 | 79.1 / 79.1 / 79.2 | 300.005 s |
| 前台空闲 | candidate `3.11.1 (54)` | 0.0 / 0.0 / 0.2 | 178.9 / 178.9 / 200.1 | 79.3 / 79.3 / 79.4 | 300.004 s |
| 隐藏空闲 | baseline `3.10.0 (52)` | 0.0 / 0.0 / 0.4 | 193.4 / 193.4 / 193.4 | 97.5 / 97.5 / 97.5 | 300.001 s |
| 隐藏空闲 | candidate `3.11.1 (54)` | 0.0 / 0.0 / 0.2 | 194.2 / 194.2 / 194.3 | 97.6 / 97.6 / 97.7 | 300.000 s |

前台与隐藏态 p50 footprint 的基线/候选差为 `+0.2 MiB` / `+0.1 MiB`；前台候选 RSS 单点 max 为 200.1 MiB，但 p95 为 178.9 MiB，不能仅凭这一点认定持续增长。pair4 与 pair1、pair3 合计三组 idle 重复；这只满足 idle 重复数量，不覆盖其他矩阵行。其他 9 个场景、真实音频、CaptureHelper、主线程/wakeup、队列/释放和 1 h/4 h 长稳门仍缺，#371 继续未通过。

脱敏汇总 `speechrail-issue371-idle-pairs3-4-20261017` 保存在仓库外，SHA-256 `526be6952db5ca83aff45ec816f7766df123696f163b01c80a84752e78bbca57`；汇总包含 pair3/pair4 每个样本的原始 JSON SHA-256 和采样身份。没有保存窗口内容、转写或音频。采样后 `/health`、`/readyz` 均为 200，唯一 listener 正常，batch/realtime active requests 为 0；临时 App 进程按 PID 退出并从 LaunchServices 注销，正式 App 未隐藏或替换。

## 2026-10-17 follow-up: synthetic audiobook role-stat regression

为先检查 App 算法行为，运行现有性能与有界性定向回归。首次结果为 27 个 XCTest 中 4 项断言失败，均出现在 `AudiobookWorkspacePerformanceTests.testRoleStatsVisitAnnotationsAndEdgesOnceAndMatchReference` 的角色统计对照；同次 Swift Testing 6 个 suite 的 41 项均通过。源码核对确认生产算法遵循自动 `.lead` 数量上限和短角色停止规则，而独立参考算法只实现 75% 累计前沿；失败来自参考规则落后于角色分层验收，不是生产统计输出与当前验收冲突。

同步更新了大规模选角规范至 2.2.0，并把独立参考算法补齐同一组分层条件，没有修改生产角色统计算法。复跑性能子集：27 XCTest、0 failures；Swift Testing 6 suites、41 tests、0 failures。另运行 `AudiobookCastTests`，73 XCTest、0 failures。该证据使用合成数据，证明确定性等价、遍历次数和资源上界；不证明 Release CPU/RSS、真实 MainActor 时延、硬件音频、XPC 或长稳表现。UI 自动化尝试另见上文，其 0-test 工具链发现错误不能作为产品通过证据。#371 仍保持 no-go。

## 2026-10-19 follow-up: #369 targeted rerun at HEAD 6cce1d62

2026-10-19（Asia/Shanghai）在干净 main（`6cce1d62`，与远端一致）复核 #369 的确定性证据，未改任何源码。覆盖六类 operation 的定向 filter（`AudioCaptureDrainTests`、`CaptureAudioRelayTests`、`StreamMixerTests`、`TranscriptPresentationTests`、`DubbingExportStreamingTests`、`TeleprompterScriptPerformanceTests`）一次跑通 **40 tests / 6 suites、0 failures**；相邻的 `TeleprompterPositionTests`（提词定位）与 `AppPerformanceMetricsTests` 补跑同样通过。`python3 scripts/check_macos_test_target_coverage.py` 返回 `macos-test-target-coverage: OK`；`git diff --check` 通过。源码核对确认六类 operation 的生产记录点与 snapshot 断言、24/44.1/48 kHz EOS 参考比对回归均在当前 HEAD 存在。本次复核不增加真实硬件、Release 配对性能或 UI 交互证据；关闭 #369 仍须在 issue 内明确这些未验收项。
