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

## 实际性能矩阵

下表 build 均为“未生成配对 Release 构建”；before/after 没有可比数据。方案中的预算是目标，不能填写为本次成绩。原始性能制品未产生；未来获准采样后放在仓库外，仓库只写匿名汇总与制品引用。

| caseID | build SHA | process role | 输入规模 | sample duration | warmup | before | after | 重复次数 | 结论/未验证项 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| idle | 未测 | App/helper | 前台/隐藏，各 5 min | 未测 | 未测 | 未测 | 未测 | 0 | 空闲 CPU/唤醒/任务退出未验收 |
| catalog | 未测 | App | 100/1,000/5,000 音色 | 未测 | 未测 | 未测 | 未测 | 0 | 解码/主线程与外部变更时序未验收 |
| audiobook | 未测 | App | 大书、多角色、快速切章 | 未测 | 未测 | 未测 | 未测 | 0 | 投影 p95、CPU、RSS 未验收 |
| export | 未测 | App | 1/30/120 min 音频 | 未测 | 未测 | 未测 | 未测 | 0 | RSS、I/O、取消到释放未验收 |
| llm | 未测 | App/service | 单字节 SSE、慢消费者/停顿 | 未测 | 未测 | 未测 | 未测 | 0 | 调度与传输资源实测未验收 |
| capture | 未测 | App/helper/service/worker | 双路音频、重连 | 未测 | 未测 | 未测 | 未测 | 0 | callback 分配、gap、XPC、队列峰值未验收 |
| teleprompter | 未测 | App | 长稿/重复词/版本切换 | 未测 | 未测 | 未测 | 未测 | 0 | 实际匹配 p95 与跟随延迟未验收 |
| transcript | 未测 | App | 真实 1 h/4 h 会话与回看 | 未测 | 未测 | 未测 | 未测 | 0 | RSS、归属修订、用户位置/选区未验收 |
| waveform | 未测 | App | 多 owner、快速换音频 | 未测 | 未测 | 未测 | 未测 | 0 | 扫描 CPU、AVAudioFile 缓冲与释放时间未验收 |

AppPerformanceMetrics 已接入目录、工作区读取/投影、存储提交、LLM 事件、提词准备与波形扫描。`dubbingExport`、`captureEnqueue`、`mixerTick`、`captureStop`、`teleprompterMatch`、`transcriptPublish` 枚举暂未接入通用 signpost；这些领域的容量/次数由 owner 快照和定向测试检查。不得把这些通用统计中的 0 解读为未执行或无热点。实际采样应结合 Time Profiler、SwiftUI Instruments 和各 owner 的计数，不把固定容量证明当作 RSS 证明。

## 交互与运行态

未运行接管前台的 UI 自动化，未启动 App 进行交互验证。需要后续确认：长会话回看锚点、页间补载/新行提示、文本选择与复制、快速换页取消、叶子依赖实际 body 更新、Reduce Motion、VoiceOver 和窄窗口。

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
