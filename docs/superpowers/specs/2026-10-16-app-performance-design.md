---
title: "SpeechRail App 性能与资源治理设计"
status: active
date: 2026-10-16
audience: "产品负责人、macOS 与服务开发者、验收人员"
---

# SpeechRail App 性能与资源治理设计

目标是让 App 的计算量、队列、任务和界面更新随实际工作量增长，避免空闲耗电、主线程卡顿、长会话退化，以及积压任务持续占用一个 CPU 核。实施步骤见[实施计划](../plans/2026-10-16-app-performance-implementation-plan.md)。

**状态：代码与确定性回归已完成，实际性能与交互待验收。** 核验日期为 2026-10-16（Asia/Shanghai），审查基线为 bedabb6a93669144c12a4e8dba6c5305f4503128。问题清单描述该基线，逐项实现与确定性验证记录见实施计划及[验收记录](../../audits/2026-10-16-app-performance-acceptance.md)。尚未运行 CPU 采样、真实性能基准、真实音频、UI 自动化或服务操作；实际收益与资源预算仍待对应验收。

## 1. 推荐决策与边界

采用“读模型与存储分离、流水线逐层有界、任务由功能所有者管理、界面订阅收窄”的整体方案，按 P0、P1 分批交付。先解决反复触发的同步 I/O、计算复杂度和逐字节调度，再处理音频完整性、长期运行与资源回收。不要统一降低功能刷新率来掩盖根因。

本方案覆盖创作、会话、播放、采集、共享 LLM adapter、App 与 CaptureHelper 的内部 XPC。服务侧只增加有证据支持的排查入口；没有采样证据时不修改模型、推理线程、档位、Resource Governor、ASR 切段或识别策略。保持唯一 ASGI worker 与唯一共享 ASR worker，不通过复制模型进程提高吞吐。

不改变持久化文档、作品库与 SQLite 的业务语义；不删除历史记录。内部 Swift 接口可以迁移为 async；CaptureHelper 与 App 必须成套构建。REST / Realtime 公共 wire 不在本方案的默认修改范围。

### 1.1 历史约束与已完成工作

> 🧠 **From Hindsight memory (SpeechRail 开发约定与验证方法)** — 回归以确定性 fake backend 为基础；异步结果需要核对所属记录与运行代次；超时不能被当作底层任务已经停止。本文将这些约定落实到缓存发布、取消、保存确认和资源释放测试，并以当前源码复核适用性。

> 🧠 **From Hindsight memory (四场景共享 ASR：策略与契约落地)** — 四场景共用识别内核，预览与正式终态分别处理，会话采集 PCM 有界且不落盘。这里只复用这些边界；历史页面的完成状态和参数不能证明当前实现或当前性能。

当前代码已有的重要优化继续保留：有声书 source index 与部分集合索引、SQLite 批量写入、独立制作进度时钟；正式提词跟随的脚本缓存与有界匹配；语音助手的有限上下文；监控的低频采样与有限历史。当前未发现这些机制需要整体重写的依据。

同日的[有声书工作流计划](../plans/2026-10-16-audiobook-workflow-further-optimization.md)主要覆盖业务体验，不替代本文的性能任务。[会议与字幕识别设计](2026-10-16-meeting-caption-asr-design.md)涉及识别质量与可修订文本窗口；本文仅治理采集、投影与显示成本，不提前实现其协议或分人变化。二者若同时实施，MeetingSession、CaptionSession、RealtimeASRClient 和相关存储只能由一个执行者串行修改；mutable preview、final、receipt 与 barrier 语义以届时已接受的契约为准。

## 2. 当前证据与优先级

所有定位行号对应上述基线，实施前按符号重新定位。结构检索复用了同 SHA 的已索引 checkout，并核对了相关工作树文件一致性；Swift 部分范围无法完整解析，已用当前源码补读。图谱没有返回结果不等于不存在问题。

| ID / 优先级 | 静态确认的路径 | 风险及限定 | 任务 |
| --- | --- | --- | --- |
| F01 / P0 | [AudiobookDomain.swift](../../../macos/SpeechRailApp/SpeechRailApp/AudiobookDomain.swift#L2091) 的 snapshot 每次 reload、读文件、两次 JSON 转换；metadata 查询再次进入 snapshot；snapshot.revision 每次遍历并 hash | 音色行与过滤逻辑反复调用，会将 I/O 与全库处理带入 UI 求值 | T01 |
| F02 / P0 | [AudiobookWorkflowModel.swift](../../../macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift#L2756) 在 MainActor 拼装工作区；[角色统计](../../../macos/SpeechRailApp/SpeechRailApp/AudiobookCastRegistry.swift#L434)逐角色过滤全部 annotation 与 edge；章节详情读取全书 candidate 后过滤 | 复杂度与全书规模相关。制作轮询是 250 ms，但仅完成数或总数变化时重载，不能描述为每秒四次无条件全量读取 | T02 |
| F03 / P0 | [CreativeWorkStore.swift](../../../macos/SpeechRailApp/SpeechRailApp/CreativeWorkStore.swift#L278)、[DubbingProjectStore.swift](../../../macos/SpeechRailApp/SpeechRailApp/DubbingProjectStore.swift#L313)显式隔离到 MainActor，执行锁、恢复、JSON、音频读取、fsync | 仅在调用方加 Task 不会移动存储隔离；阻塞影响整个 App | T03 |
| F04 / P1 | [DubbingProjectStore.export](../../../macos/SpeechRailApp/SpeechRailApp/DubbingProjectStore.swift#L609)汇总所有音频；makeWAV 再拼数组；工作流读整段 Data 试听和导出 | 峰值内存随导出总时长增长；导出与 UI 共用执行域 | T04 |
| F05 / P0 | [LLMProvider.StreamRace.run](../../../macos/SpeechRailApp/SpeechRailApp/LLMProvider.swift#L1031)对每个字节 await timer.expired，delta 后另起 Task 通知计时器；公共 stream 默认无界 | 存在调度放大与慢消费者积压风险。当前总文本已有长度限制，并非无限输出 | T05 |
| F06 / P0 | [AudioSourceCoordinator.swift](../../../macos/SpeechRailApp/SpeechRailApp/AudioSourceCoordinator.swift#L234) gate/watch/mixer 输出及 [CaptureHelperClient.swift](../../../macos/SpeechRailApp/SpeechRailApp/CaptureHelperClient.swift#L62)无界；gate/mix 重建 chunk 时丢来源证据 | 输入 ring 有界不能证明全链路有界；不能靠静默丢块换取低 CPU | T06 |
| F07 / P1 | [MicrophoneCapture.swift](../../../macos/SpeechRailApp/SpeechRailApp/MicrophoneCapture.swift#L272)实时 tap 内调用 converter 并分配 AVAudioPCMBuffer / Data | 高负载时增加回调抖动；AssistantAudioSession 已有预分配 ring + drain，可复用基础设施 | T07 |
| F08 / P1 | [MeetingView.swift](../../../macos/SpeechRailApp/SpeechRailApp/MeetingView.swift#L93)父级 body 读取高频 level；[AudiobookBookWorkspaceView.swift](../../../macos/SpeechRailApp/SpeechRailApp/AudiobookBookWorkspaceView.swift#L1762)父级依赖分析时钟 | 父级依赖扩大后可能重复 diff 长列表；尚无 Instruments 证据证明所有行都重新绘制 | T08 |
| F09 / P1 | [TeleprompterSession.swift](../../../macos/SpeechRailApp/SpeechRailApp/TeleprompterSession.swift#L2308)试读按 ASR 更新构造 Script；[TeleprompterAligner.swift](../../../macos/SpeechRailApp/SpeechRailApp/TeleprompterAligner.swift#L167)定位 anchor 扫全 script | 正式跟随已有缓存和有限 DP 窗口；这次补齐试读和 anchor 索引，不重写匹配算法 | T09 |
| F10 / P1 | [MeetingSession.swift](../../../macos/SpeechRailApp/SpeechRailApp/MeetingSession.swift#L1243)、[CaptionSession.swift](../../../macos/SpeechRailApp/SpeechRailApp/CaptionSession.swift#L1126)按行 contains/sort、归属更新 map 全数组；[CaptionBandWindow.swift](../../../macos/SpeechRailApp/SpeechRailApp/CaptionBandWindow.swift#L189)where 条件不终止反向遍历 | 长会话投影与显示仍随全量历史增长；LazyVStack 不能消除模型全量扫描 | T10 |
| F11 / P1 | [SharedPlaybackOwner.swift](../../../macos/SpeechRailApp/SpeechRailApp/SharedPlaybackOwner.swift#L204)只有完成后的波形缓存，无 pending 合并和任务上限；[AudioEnvelope.swift](../../../macos/SpeechRailApp/SpeechRailApp/AudioEnvelope.swift#L40)无扫描取消检查 | 当前音频扫描已经分块读取；问题在并发、重复扫描与退出后的存活任务 | T11 |
| F12 / P2 条件项 | [audio_timeline.py](../../../src/speechrail/domain/audio_timeline.py)、[realtime_asr.py](../../../src/speechrail/application/realtime_asr.py)的逐样本重采样与同步音频处理 | 可能占用服务 event loop，尚未证明构成当前热点；需要先分进程采样 | T12 |

StreamMixer 还存在可证实的生命周期问题：来源 attach 后退休只清空 slot，slot 数量仍增长；固定 next += 40 ms 在迟到时会追赶旧 tick。它目前在没有足够输入时不输出虚构静音，改造必须保留这一行为。

### 2.1 全 App 覆盖范围

| 功能范围 | 本方案对应项 | 已有机制与处理判断 |
| --- | --- | --- |
| 配音台、作品库、音色设计与克隆、音色库 | F01/F03/F04/F05/F11 | 共用目录、LLM、存储与播放是治理入口，不逐页复制缓存或后台任务 |
| 有声书工坊 | F01/F02/F04/F08/F11 | 保留已有批量写入、source index 和制作进度局部时间线；分析/制作终态仍可靠刷新 |
| 语音助手 | F05/F06/F07/F11 | 保留有限上下文、draining 和 voice processing；不把语音助手专用采集行为套用到所有会话 |
| 会议助手与实时字幕 | F06/F07/F08/F10 | 整体检查输入、保存、归属、显示与退出；不把 LazyVStack 当作模型复杂度上限 |
| AI 提词器 | F06/F07/F09 | 正式跟随缓存与窗口 DP 已存在；试读共用准备结果，stage 排版只在布局输入变化时发生 |
| 服务状态与运行监控 | T00/T12，暂无直接修复项 | 当前监控约 5 s 刷新并限制历史，EngineModel 有刷新防重入；没有依据改成另一套采样循环 |
| 模型组合、诊断与控制 XPC | T00/T12，暂无直接修复项 | 命令 runner 已用 utility 执行域并并发排空管道；不将其后台 waitUntilExit 误报为主线程忙等 |
| 导入、公共播放与进度组件 | T02/T04/T08/T11 | 复核调用边界；TXT 导入已有异步准备入口，波形已有分块读取，分别针对残余计算和任务所有权改进 |

“暂无直接修复项”表示当前静态分析未确认需要修改，不表示实际 CPU 或长期稳定性已经通过。采样若在这些路径发现热点，先补充操作证据和具体任务，再扩大实现范围。

## 3. 执行域与所有权

| 执行域 | 允许承担 | 产出与生命周期 |
| --- | --- | --- |
| MainActor | 用户选择、有限 UI 状态、轻量状态跃迁、AV/AppKit 必需操作 | 接收不可变快照；每项操作有 selection generation / operation ID；过期结果不能覆盖当前状态 |
| 存储 actor | 文件锁、SQLite/JSON、事务恢复、校验、原子写、有限导出任务 | 一次拥有一个存储目录的串行写者；跨 actor 仅传 Sendable 值或 URL；文件句柄不外泄 |
| 计算 worker | 统计索引、正文投影、波形、导出 PCM 拷贝 | 输入冻结，检查取消；单个功能只有规定数量的在途任务，不为每个事件创建独立 Task |
| 实时回调 | 有限复制到预分配 ring、计数与唤醒 | 不转换、不创建 Task、不做文件 I/O；满载产生可观察的丢样证据 |
| 音频 drain / mixer | 重用 converter、有限 PCM 队列、按时产出 | 显式 epoch、来源序号与终止原因；stop 可等待资源确实释放 |

Task 继承 MainActor 时仍可能在主线程执行；Task.yield 只让出执行权。迁移使用真正的存储 actor 隔离或明确的并发计算入口。禁止用新增 @unchecked Sendable、nonisolated(unsafe) 或独立 detached Task 掩盖所有权问题；现有低层 ring 的锁与线程契约需单独验证，不据此全局重写。

### 3.1 取消与发布

读任务允许取消；UI 切换同时递增 generation。后台结果发布必须同时匹配 record ID、selection generation、源 revision。取消前的旧结果不得通过 defer 或 catch 发布“成功”。

存储事务进入 durable commit 后按既有恢复协议完成或回滚到可恢复状态；不能因为 UI task 被取消而留下半份 journal，或者向用户报告已取消但随后发生未经解释的保存。结果回执带 operation ID，显示是否已保存；取消 UI 等待不能取消已经接受的提交。存储写锁作用域内不 await 任意外部回调。

stop 的定义是停止接收、终结输出、取消并收束子任务、卸载 tap / converter / XPC；排队的终止动作不等于已经释放。紧急错误与正常 stopping/draining 区分：已提交的 Realtime item 继续按既有契约处理 final / failed / receipt / barrier；断裂的输入不能被标为完整成功。

## 4. 模块设计

### 4.1 音色目录：内存读模型 + 单一持久化所有者

将 VoiceCatalogStore 改为存储 actor，沿用已有变更方法的参数和返回语义，调用改为 await。init 只建立路径和内存状态，不读盘。新增 MainActor 的 VoiceCatalogModel：持有一个不可变 VoiceCatalogSnapshot，body、metadata 查询与过滤只读这一份值。

VoiceCatalogLoadState 增加 loading，初始状态不冒充 ready/missing。snapshot.revision 在 snapshot 构造时计算一次，后续读取 O(1)；不引入另一套内容摘要算法。目录读取、JSON 解码和 revision 构造在存储 actor 内完成。每次视图投影先抓取一个 snapshot，再用 metadata 字典执行过滤，禁止每个 voice 再访问 store。

刷新由进入功能、前台恢复、存储提交成功及父目录文件事件触发；父目录监听才能覆盖原子替换。外部事件合并 50 ms，只有一个刷新在途，期间变化设 dirty，结束后最多再读一次；不创建常驻轮询。文件内容与既有 revision 判定变更，不仅比较 mtime/size。已加载快照可以继续显示，但加载失败必须附带错误状态，动作不能把旧缓存当权威许可。

每次写入仍从磁盘重读、验证 schema/ownership，沿用未知字段保留、原子写、迁移备份和成功后通知。制作、锁定配声、归档等关键动作先 await refresh，再核对既有 source/cast/voice revision；冲突返回可操作错误。保持单进程写入边界，不声称新 actor 提供跨进程 CAS。失败不发布新快照，不用空目录覆盖损坏文件。

### 4.2 有声书：一致输入与线性投影

新增 AudiobookWorkspaceReader actor。AudiobookProjectStore 提供一次事务读出的 Sendable 输入，包含 book/chapter/source revision、角色、annotation、edge、所选章节 fragment 与 candidate；查询 candidate 时使用章节/fragment 限定，不把全书 candidate 交给 UI 再过滤。

角色统计先按 roleID 聚合 annotation，并建立 edge adjacency；原文区间只合并和扫描实际命中的区间。统计聚合复杂度目标是 O(A + E + R + K log K + K log M)，K 为需合并的命中区间数，M 为 source index 的标量数；区间计数复用二分边界，禁止 R 次扫描 A/E。沿用已有 source index，规范化正文只在输入 revision 变化时计算。

Reader 产出 AudiobookBookWorkspaceSnapshot / AudiobookChapterDetailsSnapshot，MainActor 仅核对 selection 与 revision 后整体发布。每个选择域最多一个 read task，连发进度只保留最新 reload 请求；正在读取时置 dirty，结束后重读最新一次。250 ms 的进度读取先保留，确认生产状态是否变化与加载大章节分开；只有所选章节的相关 revision 改变时重建章节投影。最终完成、失败与停止回执触发一次可靠的最终刷新，不把终态并入可丢弃的进度通知。

缓存 key 至少包含 bookID、chapterID、sourceSHA、涉及的角色/注释/制作 revision；不要用 completedFragments 单独判断内容是否改变。界面读模型至多保留当前书工作区和当前/上一章两个详情投影；换书释放旧投影。存储层 source index、角色与全书标注缓存各至多保留两本书，支持前台阅读与另一部作品的后台制作；LRU 淘汰不删除持久化记录。后台大循环按批次检查取消。

### 4.3 作品库：存储 actor 与文件导出

CreativeWorkStore、DubbingProjectStore 改为各自独立 actor；保持现有目录锁、恢复、journal、校验和 fsync 协议。现有文件操作对象和文件句柄由 actor 独占；测试注入闭包改成 @Sendable，并使用锁保护计数器，不能只取消 @MainActor 声明后保留不安全共享对象。

工作流从初始化同步 list 改为显式 load；save/rename/delete/adopt 返回回执后再发布新列表。所有写入、恢复与备份测试保留。删除与覆盖的用户交互语义不变。

导出不再返回完整音频 Data。DubbingProjectStore.prepareExport(projectID:) 先冻结已采纳 candidate 的顺序、格式、revision，在同一存储 actor 的不可重入文件操作段内解析 WAV 头并把 PCM 分块写入专属临时目录。内存 PCM 块上限 256 KiB，一次只打开一个输入文件；一次最多一个实际导出，临时 lease 未释放时第二个请求返回 exportBusy。格式不一致、缺失 candidate、非法长度与 RIFF 4 GiB 上限必须明确失败，不能截断、补静音或静默转换。

输出 PreparedDubbingExport，包含 lease ID、audioURL、scriptURL、sourceRevision、字节数。临时文件不进入作品索引；lease 持有到保存完成、取消或失败，调用方明确 release，另有退出时清理已释放文件。每个 store 至多一个 lease。另由 DubbingExportWriter actor 承担复制，workflow 只持有一个可取消 copy task，并 await writer.copyPrepared；其文件复制与替换不在 MainActor 执行。将文件复制到用户目标同目录的 staging 后逐文件原子替换；只有用户既有保存流程确认目标时才写目标。音频与脚本是两份文件，不承诺跨文件原子性。替换前取消移除本次 staging，已有目标保持原状；某份文件替换后必须给出真实回执，另一份失败明确报告部分保存并允许重试，不能把已经成功的文件当作未保存。作品播放使用已校验的 URL，避免 MainActor Data(contentsOf:)。

### 4.4 LLM：事件级计时与有界交付

保留当前 MacPaw/OpenAI 0.5.1 固定依赖与 provider adapter 边界，不借性能改造升级 SDK 或重写 SDK 已覆盖的 transport。当前自有 SSE decoder 负责兼容能力，UTF-8、跨块与多行事件解析规则不变。

网络读取和截止时间各只有一个受拥有的任务。读 byte 时不 await timer，也不为 delta 另开 Task；一条完整合法 SSE 事件解码后按现有语义更新 first-progress / stall deadline。reasoning / heartbeat 是否算进度保持当前测试定义，不能通过优化改变超时合同。独立 deadline task 能取消正在等待网络的读取任务与底层请求，不能只在下一字节到来时检查。使用可注入单调时钟验证截止点竞态。

公共 stream 保持 AsyncThrowingStream<String, Error>，使用 bufferingOldest(128)，检查每次 yield 的 dropped/terminated 结果；dropped 立即标为 overflow、取消 transport 并以错误终结，不能伪装成正常完成。所有累计 text delta 的 UTF-8 bytes 另设 256 KiB 上限，现有总文本限制继续生效，因此排队 payload 同样不可能超过该上限。非文本事件、SSE 行与 parser buffer 各有限制，避免空 delta 或无换行输入绕过约束；finish(throwing:) 的终态独立于 payload 缓冲，不占第 129 个槽。使用原生有限 stream 即可满足这里的约束，不再创建另一套通用事件通道。

只有 UI 预览可以按 50 ms 合并：持有“当前全文的最新快照”，终态立即刷新；推理输出、工具/协议事件、正式文本与错误不能按预览规则丢弃。取消或 EOF 缺失合法终态均不产生伪完成。

### 4.5 音频：逐层上限、可靠断裂、无追赶 tick

内部 AudioChunkSource.start() 迁移为返回 AudioChunkStream（可抛错 AsyncSequence）。通道提供同步 offer 与异步 next；锁只保护有限队列，不在实时回调里等待下游。普通 gate/watch 变成拉取式包装，不建立第二份缓冲队列。音频满载、来源丢失与正常结束分别处理。

每个生产 chunk 保留原有 capturedAt、sequenceNumber、droppedSamplesBefore；新增跨进程 AudioCaptureStamp，包含 captureEpoch UUID、sourceID UUID、sourceSequence UInt64、capturedUptimeNanoseconds UInt64。helper 与 App 使用同一台 Mac 的 monotonic uptime 做年龄判断；不得传无法 XPC 编码的 ContinuousClock.Instant。合流输出同时保留各来源最近 sequence/drop 水位，以及 mixer 自己的 output sequence，不能把重新编号冒充来源连续。

**初始容量配置，统一按 24 kHz / mono / PCM16，即 48,000 B/s 计：**

| 阶段 | PCM 上限 | 额外数量上限 | 满载行为 |
| --- | ---: | ---: | --- |
| 麦克风转换后 source channel | 24,000 B / 500 ms | 16 chunks | 显式 overflow，停止本次采集 |
| helper 转换后 source channel | 24,000 B / 500 ms | 16 chunks | 显式 overflow，停止本次采集 |
| XPC 在途窗口 | 7,680 B / 160 ms | 4 × 40 ms chunks | 无 credit 不发送，由 ack 唤醒，不轮询 |
| App 内 system source channel | 24,000 B / 500 ms | 16 chunks | 显式 overflow，停止本次采集 |
| mixer 每个输入 ring | 19,200 B / 400 ms | 最多 2 个活动 source | 显式 overflow，不静默 removeFirst 丢块 |
| mixer 输出 channel | 19,200 B / 400 ms | 10 chunks | 显式 overflow，停止本次采集 |

双来源情况下以上排队 PCM 的保守总上限为 137,280 B，不含固定 raw Float capture ring、正在处理的一块、converter scratch 与 ASR 自身合法的窗口。它是各阶段容量之和，不是允许的音频延迟。**单个 chunk 年龄超过 750 ms 即报告 staleInput 并停止该 epoch**，不允许排满所有阶段后仍持续识别陈旧音频。raw ring 额外内存按实际采样率 × channels × Float32 bytes × 容量秒数报告；容量在 start 时固定，不能随积压增长。

XPC deliver 增加 epoch、sequence、uptime 和 dropped-sample 水位，增加 acknowledge(epoch:throughSequence:)；App 真正 dequeue 后回 credit。旧 epoch 的 deliver/ack 不影响新一轮，ack 单调且不大于已发送序号。helper 不用无界 Task/DispatchQueue 积攒未获 credit 的 payload。在有在途数据时，1 s 无有效 ack 则终止并回报错误。App 与 helper 的协议签名、NSXPCInterface 允许类型和相关注释成套更新，不保留旧 bundled helper 的兼容分支。

AudioChunkStream 的 overflow / stale / droppedSamples 增量通过独立终态传递：立即拒绝新 PCM，清除未消费的失败缓冲并记录丢样范围，不能因满队列而丢掉错误。会话层显示输入中断、停止新输入并执行受限 draining；保留已经保存的文字，不能把残缺输入发送给 LLM 当成完整意图。四场景与试读路径、fake source 一并迁移。sourceLost 沿用现有中断与恢复语义，不等同于系统整体失败。

StreamMixer 提取到可测试文件，用有限 SourceID slot 表取代永远增长的数组。退休时取消并回收对应 ingest task / ring。手动时钟推进超过一个周期时跳过旧 deadline，一次只处理当前一个 tick；不追赶历史 tick。停止后 ticker、观察任务、所有 ingest task 都有句柄并等待退出。无输入不输出虚构静音；静音门控只改 PCM 与 level，保留来源证据。PCM16 输出一次申请整块空间并批量填充，保留现有求和、饱和裁剪与电平算法，不先引入 SIMD 依赖。

### 4.6 麦克风：实时回调只搬运

抽取 AudioEngineSession 已验证的 ring/drain 机制为有限共用核心，继续保留语音助手特有的 voice processing / 播放参考行为。tap 仅按实际输入格式向预分配 Float ring 写入，记录 host time、累计 dropped samples 并发出 drain 唤醒；converter、重采样、PCM16 Data 和 level 均放在串行 drain 上。

ring 和 scratch 在 start 或格式变更期间配置；设备变化先停止旧 epoch，再创建新资源，不能在回调中扩容或换 converter。stop 必须移除 tap、停止 engine、收束 drain 后才释放 buffer。测试验证停机竞态和样本时间轴；分配次数与回调耗时另用 Instruments 实测。

### 4.7 SwiftUI：高频依赖只到叶子

MeetingLevelIndicator 直接读取所需的轻量 level 状态，父级 MeetingView 不读取 level。AudiobookAnalysisElapsedLabel 自持计时，父级不依赖 analysisClockTick。转录、角色与候选行读取有限投影及稳定 ID；避免 computed property 仍在父 body 读取高频字段、只是把布局挪到 extension 的形式分离。

复用现有 ProductionProgressRail 的局部时间线。Assistant waveform 已有 40 ms TimelineView 和可见性/Reduce Motion 暂停条件，不重复替换。新增时间线离开页面、停止工作或隐藏窗口时停用。保持现有文案、布局、Token、键盘和无障碍语义；实际刷新次数与视觉正确性须在获准后分别采样和检查。

### 4.8 提词器：试读脚本缓存与索引

正式跟随与试读共用不可变 PreparedTeleprompterScript，由 versionID + segment digest 唯一标识；一次版本只构建一次 token/segment 索引。anchor 用有序 token start offsets 二分定位，随后仍运行现有有限窗口 DP；不改变文本归一化、得分或回退政策。

第一步只消除重建与全脚本 anchor 扫描。若实测匹配主线程 p95 仍超 5 ms，再将匹配移入独占 matcher actor；该条件变化需要补充任务说明与收益证据。已有 final/failed、revision、generation 与停止屏障不被 latest-preview 合并吞掉。切换版本立即使旧 script/match 结果失效。

### 4.9 长会话：完整档案与有限显示投影

先用 itemID/lineID 索引、ordinal 顺序插入与定点归属更新消除 contains/sort/map 全表操作；浮层反向遍历在拿够可见行后立即 break。正式存储继续完整追加并等待 receipt。

MainActor 的 transcript presentation 保留最近 500 行，每次回看从 SQLite 取 200 行，最多缓存 3 页；并保留当前活动 item、正在等待保存/归属的有限单元。全量历史留在数据库，不能因为移出显示窗口删除、提前退休或伪造保存确认。当前 client 已有的在途数量与生命周期限制继续生效；overflow 明确失败，不能借显示上限扩大协议队列。

用户回看时固定 scroll anchor，新增转录不跳到底部；回到底部再恢复 tail-follow。迟到归属按 ID 更新数据库和命中的可见页，不扫描全部内存历史。跨页选择、复制与搜索从数据库获取完整请求范围，不能悄悄只复制当前 500 行。这部分涉及交互，应与同日原生滚动修复及可修订文本设计逐项合并；如无法在一个变更中保留交互，先交付索引与 break，分页作为独立后续提交。

### 4.10 波形：单飞、取消、有限缓存

WaveformEnvelopeLoader actor 维护请求与缓存；同 key 并发请求共享一次扫描。key 包含作品/candidate ID、revision、采样桶数与文件身份，不能仅以可复用 URL 命中旧波形。全局同时 1 个实际扫描，等待队列最多 8 个不同 key，完成缓存最多 64 个条目且总 payload 不超过 256 KiB，按 LRU 淘汰。

WaveformEnvelopeLoader 只管理 lease、队列和缓存，不在其 actor executor 同步扫描。它保留唯一 active scan Task 的句柄；该任务调用显式 @concurrent nonisolated async 扫描入口，把分块扫描移到 generic executor，保证管理 actor 可同时接收 release/cancel。[Swift 并发隔离说明](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)明确 @concurrent 的这一执行语义（核验于 2026-10-16）。最后一个 owner release 后 cancel 并 await worker 退出，在真正结束前仍占用 active slot，不能提前启动第二个扫描。

播放和界面 owner 获取 lease；最后一个 owner 释放时取消扫描/排队。超出等待队列时返回 deferred，显示占位，下一次明确请求再排队，不循环重试。沿用 AVAudioFile 分块算法，每块检查取消；旧 revision 完成不能覆盖新 revision。结果数组与任务句柄在 stop/release 后可归零，不能把 Task.detached 当作生命周期管理。

### 4.11 服务侧：以进程与栈证据决定改动

性能记录分别标识 App、CaptureHelper、service 和实际 worker PID，并记录构建、输入规模、场景和时间段。CPU 的 100% 表示占用一个逻辑核心；不能把整机百分比、单核占用和 GPU 推理混为一谈。

当前服务已有准入、有限队列与等待机制，未静态确认普遍 busy loop。若服务 event-loop lag、重采样或 VAD 在采样中占显著时间，再为具体函数制定方案：优先减少 Python 逐样本循环，验证流式相位与时钟不变；必要时移动到受拥有的单一串行执行域。先计算输入、输出与复制成本，不直接增加线程/进程或修改 Governor。没有证据时 T12 以“无需服务代码改动，保留观察记录”结束。

## 5. 观测与验收

### 5.1 最小观测面

新增按操作启停的 OSSignposter 区间，覆盖 catalog refresh、workspace input/project、store commit/export、LLM event decode/timeout、capture enqueue/mix/stop、teleprompter prepare/match、transcript publish、waveform scan。以粗粒度操作为单位，不逐字节/逐样本记录。计数器只保留固定容量直方图、总数和峰值；禁止无限采样数组或额外常驻高频定时器。

记录耗时、字节、数量、队列峰值、在途任务数、丢样、generation discard 与 cancellation-to-release 时间；不记录 prompt、转写、角色真名、原始音频、Base64、API key、绝对模型路径。性能原始制品放仓库外，仓库仅保留匿名汇总。

### 5.2 两层验收

**确定性回归**验证零主线程 I/O、操作次数、复杂度、队列/任务上限、输出一致性和恢复语义；使用 fake backend、人工事件、合成 PCM、临时目录与手动时钟。CI 不用 CPU 百分比或墙钟耗时作为正确性断言，不创建脆弱的“机器必须足够快”测试。

**实际性能验收**在用户明确授权基准后使用对应 skill，必要时再单独取得 UI 自动化授权。先采改前 Release 基线再用同设备、同输入、同场景比较改后，预热条件一致；至少重复 3 次，报告中位数、p95、峰值与测量时长。先固定预算，再观察候选结果；预算调整要记录原因，不能为获得通过而事后放宽。

| 指标 | 初始验收目标 | 解释 |
| --- | --- | --- |
| App 无任务空闲 5 min | 进程平均 CPU ≤1%，1 s 样本 p95 ≤3% | 前后台分别记录；系统动画/后台服务单独标注；不是当前测得的数值 |
| 功能退出 | 2 s 内任务/队列回到对应空闲计数 | 不包含已接受的 durable commit；后者必须有回执且不继续驱动 UI 轮询 |
| 自有主线程工作 | 持续更新 p95 ≤5 ms，p99 ≤16 ms；无 >100 ms 同步 I/O/投影阻塞 | 单次超限保留栈分析，区分系统布局与自身工作 |
| 音色目录渲染 | 同 revision 的 1,000 次 metadata 查询，文件读取与解码增加数为 0 | refresh 与真正写入另计，不能缓存失败状态为成功 |
| 统计与长会话 | 10 倍输入时操作计数近线性；1 h/4 h 档案不扩大可见窗口与后台任务上限 | 不要求 4 h 全量转录常驻内存 |
| 音频 | 稳态无队列增长；硬上限与 750 ms 年龄保护生效；无静默丢样 | 包括 helper/XPC；错误路径不得标成完整识别 |
| LLM | timer actor 消息与 Task 数随事件增长，不随 byte 增长；取消后传输可结束 | 回归保留 UTF-8、多行、无终态 EOF 与超时行为 |
| 导出 | PCM 工作块 ≤256 KiB；常驻内存不随总 PCM 字节线性增长 | 不把输出文件大小算作内存；文本 manifest 单独计量 |
| 波形 | 最多 1 扫描、8 等待、64 缓存；同 key 只读一遍 | 取消后无无主扫描，缓存还受字节上限约束 |

任一非必要 App 线程持续 >80% 单核占用超过 10 s，必须触发栈采样和归因；这不是禁止合法导出、解码等后台计算使用 CPU。GPU/模型推理单独报告。Apple 的[响应性指导](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)和[SwiftUI 性能指导](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)是主线程预算与依赖隔离的参考，不是 SpeechRail 已达到指标的证据。

### 5.3 场景矩阵

| 场景 | 输入与操作 | 核验重点 |
| --- | --- | --- |
| 空闲与导航 | 引擎页、创作页、会话页无任务，前台/隐藏/再次进入 | idle CPU、残留时钟、重复 observer |
| 音色库 | 100 / 1,000 / 5,000 条匿名音色，筛选、归档、外部原子替换、损坏文件 | 读次数、revision、状态错误与动作 freshness |
| 有声书 | 10/100/1,000 角色，1万/10万 annotation，多章节候选，快速切章 | 统计复杂度、所选章读取、过期结果、最后一次刷新 |
| 配音/作品库 | 1/30/120 min 合成 PCM，保存、导出、取消、空间不足与恢复 | 主线程占用、RSS 峰值、PCM 哈希、原子性 |
| LLM | 同一 SSE 内容分成 1 byte / 多字节块、reasoning、长时间无网络、慢消费者 | 调度数、超时、文本完全一致、传输释放 |
| 双路采集 | 合成 24 kHz PCM，慢消费者、helper 无 ack、100 次来源重连、时钟跳跃 | 有界、可靠失败、slot 回收、无追赶 burst |
| 麦克风 | 原生采样率/声道变化、停止与回调重叠 | 分配、丢样计数、时间轴、资源回收 |
| 提词器 | 1千/1万/10万 tokens，试读与正式跟随，版本切换 | 单次准备、anchor 二分、匹配输出一致 |
| 长会议/字幕 | 1 h / 4 h 合成事件、迟到归属、回看、复制与搜索 | 有界投影、保存终态、滚动锚点、完整档案 |
| 播放/波形 | 30 min / 120 min 文件，多 owner 同 key、快速换音频与离页 | single-flight、取消、缓存 key 与内存上限 |

## 6. 分阶段投入与回退

| 阶段 | 包含任务 | 估算人日 | 退出条件 |
| --- | --- | ---: | --- |
| A：先消除公共放大点 | T00、T01、T02、T03、T05 | 9–12 | 读模型无 I/O，存储离开 MainActor，LLM 事件调度，定向回归通过 |
| B：音频完整性与退出 | T06、T07 | 5–7 | 全链路容量可计算，压力不静默丢样，stop 真正释放 |
| C：长任务与长会话 | T04、T08、T09、T10、T11 | 6–9 | 导出/波形有界，叶子订阅，试读缓存，长会话不持续放大 |
| D：采样闭环与验收 | T12、T13 | 2–3，另计实测发现的服务修复 | 场景前后对照、无未解释热点、资料与回退可复核 |

总计约 22–31 人日，另预留约 20% 集成与审查余量；这是按现有架构的工程估算，不是工期承诺。若只做 T01/T02/T05 的首批高收益改动，约 5–7 人日，但 MainActor 作品库、音频积压与长会话风险仍存在，不能称为全面治理完成。

每个任务作为独立逻辑变更，只有用户授权时提交。保持磁盘格式与公共协议，优先通过回退对应源码恢复；不得删除用户库或重建历史数据。T06 的 App/helper 必须同一变更回退；T03/T04 保留原事务恢复测试和临时产物清理。发布、安装、签名、模型/服务操作与完整基准另按授权范围执行。

完成定义是：已确认项有对应回归与所有权边界，条件项有实测归因或明确未触发记录；实际性能达标必须附前后对照。仅写完代码、定向测试通过或某次 readyz 成功，不能宣布单核满载问题已经解决。
