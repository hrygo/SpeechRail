---
title: "macOS App 性能观测与回归"
status: active
version: "1.0.0"
date: 2026-10-16
---

# macOS App 性能观测与回归

AppPerformanceMetrics 提供按操作记录的 OSSignposter 区间和固定桶统计。它不启动任务、timer 或进程采样；默认关闭内存统计，只有 Instruments 启用 signpost 后才发送操作事件。测试或受控诊断可注入 collecting 为 true 的实例，按 AppPerformanceOperation 查询聚合结果。每种操作固定 13 个耗时桶，计数与总耗时溢出时饱和，不保留原始 sample 数组。

记录仅包含枚举操作/结果、耗时（ns）、字节数与数量。禁止扩展为任意标签、路径、prompt、转写、音频或 Base64。measure 的同步闭包在调用者执行域运行；它用于观测，不能用来把 MainActor 工作移到后台。后续存储、投影与流式任务各自承担执行域和生命周期。

## 定向正确性验证

```bash
swift test --package-path macos/SpeechRailApp --filter AppPerformanceMetricsTests
python3 scripts/check_macos_test_target_coverage.py
git diff --check
```

SwiftPM 定向运行仍会编译测试目标；新测试必须同时登记到 Xcode 单测 target，生产文件也必须登记到 App 与相关单测 sources。需要构建 App 时使用仓库 macos_app_build.sh 包装入口，不裸跑产出 App 的 xcodebuild。

当前已验证固定容量、数字字段、禁用采集和饱和计数；这不是实际 CPU、UI 流畅度或长时稳定性的验收。模块级观测点与对应回归随实施任务接入，不能把尚未接入的操作计数 0 当作没有工作。

## 音色目录执行边界

VoiceCatalogStore 是存储 actor，初始化仅保存配置；refresh 显式读盘，snapshot 只返回已加载的不可变值。每份 VoiceCatalogSnapshot 构造时计算一次 revision。VoiceCatalogModel 在 MainActor 发布该快照，行、筛选器与菜单读取缓存，不执行文件读取或 JSON 解码。文件目录缺失、文件不可读、schema 不支持和首次加载分别保留独立状态。

目录的父目录事件覆盖外部原子替换，变更通知以 50 ms 合并。刷新保持一个在途任务和 dirty 标记；观察器停止时等待已拥有的任务，并用代次隔离迟到收尾。配声计划、试听和制作在动作边界重新刷新；损坏的目录即使保留旧内容供显示，也不能授予生产权限。写入仍先读取现有文件，保留未知字段与归属规则，只有原子提交成功才发布新快照。

```bash
swift test --package-path macos/SpeechRailApp --filter 'VoiceCatalogPerformanceTests|AudiobookCastTests|AudiobookProductionTests|AudiobookStoreTests|AudiobookWorkflowTests|ServiceContractTests'
```

## 有声书工作区执行边界

AudiobookProjectStore 在一个无 await 的 SQLite 读事务中产生冻结输入。章节候选按本章 fragment IDs 分批查询，每批至多 500 IDs，复用已有 book/fragment 索引；不读取其他章节候选再过滤。角色统计按角色聚合标注并建立冲突边邻接表，区间计数复用 source index 的标量边界。

AudiobookWorkspaceReader 管理读任务与缓存，文本规范化、统计与未知说话人投影通过显式 @concurrent 入口执行。每个书籍/章节选择域至多一个执行任务和一个最新待处理请求；覆盖的等待者立即退出，执行槽在旧任务真正结束后释放。MainActor 通过既有选择代次发布整份快照。

工作区在读取与后台投影后核对内容 revision，同一选择内的编辑也会使旧结果失效；内容变化最多重读一次，持续变化则返回 staleInput，由功能 owner 合并安排一次后续刷新，再失败则返回错误。离开功能取消并等待自有读取和延迟刷新。250 ms 制作轮询使用 SQLite 变更水位唤醒，只有本章内容 revision 改变才重建文本投影；制作完成、失败和暂停单独刷新工作区。

界面保留当前书工作区与两个章节投影；存储 actor 的正文索引、角色与标注缓存各至多两本书，兼顾前台阅读和后台制作。缓存淘汰只释放内存。回归检查有限访问计数、SQLite 虚拟机步骤/全扫描步骤、结果等价、快速选择、取消、最终刷新和缓存容量；实际主线程耗时与 CPU 收益仍需采样。

```bash
swift test --package-path macos/SpeechRailApp --enable-swift-testing --filter 'AudiobookWorkspacePerformanceTests|AudiobookWorkflowTests|AudiobookCastTests|AudiobookStoreTests|AudiobookProductionTests|SelectionLoadTests'
```

## 性能采样口径

[设计说明](../superpowers/specs/2026-10-16-app-performance-design.md)定义场景与拟定预算；[实施计划](../superpowers/plans/2026-10-16-app-performance-implementation-plan.md)记录任务依赖。真实性能基准需明确授权后按 speechrail-perf-benchmark 技能执行，UI 自动化另需逐次明确授权。性能原始制品放在仓库外，仓库只保留匿名汇总。

同一设备、Release 构建、输入规模与预热条件下，至少 3 次配对比较改前/改后。macOS 进程 CPU 100% 表示占用一个逻辑核心；分别记录 App、CaptureHelper、service 与实际 worker，不能将推理开销算作 App 热点。报告采样时长、中位数、p95、RSS 峰值、队列峰值、在途任务和取消到释放时间。

| 场景 | 改前 CPU / main-thread / RSS | 改后 | 条件与证据 |
| --- | --- | --- | --- |
| 前台与隐藏窗口空闲 5 min | 未测 | 未测 | 构建 SHA、功能、前后台分别填写 |
| 音色库 100/1,000/5,000 条 | 未测 | 未测 | 目录读取/解码次数与文件变更 |
| 有声书多角色与快速切章 | 未测 | 未测 | 角色/annotation/candidate 数量、过期结果 |
| 配音保存与长音频导出 | 未测 | 未测 | 1/30/120 min、PCM 工作块、取消与文件回执 |
| SSE 单字节与慢消费者 | 未测 | 未测 | 事件数、timer/task 数、传输释放 |
| 双路音频与来源重连 | 未测 | 未测 | queue bytes、gap、epoch、XPC 在途数 |
| 提词器长稿与版本切换 | 未测 | 未测 | tokens、prepare 次数、anchor 比较数 |
| 1 h/4 h 合成会话与回看 | 未测 | 未测 | 完整档案行数、有限投影与滚动锚点 |
| 多 owner 波形与快速换音频 | 未测 | 未测 | 实际 scan 数、取消、LRU 峰值 |

固定桶计数用于复杂度和容量回归；Instruments 用于主线程栈、SwiftUI 依赖和实际调度。CI 不能用 CPU 百分比或墙钟速度证明功能正确。缺少改前/改后实测时保留“未测”，不从函数名、代码长度或一次测试耗时估算收益。

## 作品存储执行域

`CreativeWorkStore` 与 `DubbingProjectStore` 的恢复、锁、读写、JSON 和 fsync 由各自 actor 串行执行；初始化仅配置位置，MainActor 通过异步库快照展示元数据与已验证 URL。写入进入 actor 时检查取消，接受后同步完成事务，不在文件锁内 await。返回的 `StoreWriteResult` 包含领域值与 `StoreCommitReceipt`；最近 64 条回执仅用于本进程核对，重启仍以既有 journal/index 恢复。音频完整性核验或提交后清理失败可以同时存在 `committed == true` 与错误，界面保留数据并报告核验/恢复问题，不把回执解释为音频验收通过。页面代次只控制发布，不推断磁盘是否提交。

## LLM 流执行与交付

Responses SSE 的 UTF-8/逐行解析仍为单 reader；只有完整事件更新截止时间。`StreamDeadlineState` 使用事件接收时的单调时间，reasoning 不解除首正文期限；一条可重新调度的原生计时器在期限到达时关闭实际 transport。每次 run 只有 reader 与 deadline waiter 两个子任务，返回前等待两者退出；没有逐字节 actor 查询或逐 delta Task。

`LLMStreamDelivery` 使用原生 `bufferingOldest(128)`，并将累计正文 UTF-8 限制为 256 KiB；任何 dropped/terminated 都显式结束交付。SSE 单行与单事件保留各 256 KiB 上限，非 2xx 错误正文按字节截断到 8 KiB。助手的领域正文逐事件累加，界面只保留一份最新预览，每轮一个 50 ms 定时任务发布，终态立即 flush 并等待计时任务退出；过期代次不能发布到新轮。

## 音频交付与采集边界

`AudioChunkStream` 的 PCM、chunk 数和年龄均有限制；overflow、过期和丢样通过独立错误终态交付，失败立即清除 pending PCM。gate/watch 是拉取式包装，不添加队列。每块保留 epoch、来源序号、采集 uptime 与累计丢样；静音和混音不将新编号冒充原始连续性。终态跨 XPC 使用最多 1,024 B 的固定枚举、UUID 与数值 JSON，不含音频或业务文字。

转换后排队 PCM 的双路保守上限为 137,280 B：三个 source channel 各 24,000 B、XPC 4 × 1,920 B、两个 mixer input 各 19,200 B、output 19,200 B。这不是总 RSS：麦克风 raw ring 的默认实际分配为 262,144 × 4 + 1,024 B（含 64 条时间边界）；每个 drain 的 scratch 为 `max(1024, ceil(rate/10)) × 4 + (ceil(frames × 24000/rate) + 64) × 2` B。系统采集另有按 native rate/channels 固定的 power-of-two raw ring、最多 100 ms 转换 scratch 及最多 24,000 B 的转换拼块工作区。正在处理的块、AVAudioConverter 内部存储和 ASR 合法窗口另计。750 ms 年龄限制按实际采集时间检查，不因 drain 推迟而刷新。

helper 最多四块在途，App 真正 dequeue 才 ACK；无有效 ACK 达 1 s 终止。ACK 在同一临界区先检查已有期限，定时器执行延迟不能让过期 ACK 恢复 credit；过期终止以 staleInput 触发实际采集清理。正常停止等最后 ACK，再回复停止 RPC；App RPC 超时会显式记录清理未确认。mixer 最多两个来源 slot，旧 ingest 退休后才复用；延迟 tick 只处理一个当前周期。正常停止保留已转换的完整及部分尾块，失败停止清空无效输入。AVAudioConverter 重采样的 EOS 尾部冲刷尚未单独验证。场景 owner 等待采集、上传及既有受限 draining，已保存文字保留；残缺语音不得触发完整意图回复。

`AudioCaptureDrain` 的 tap 只做格式检查、原子水位与预分配 raw ring 搬运；converter、PCM Data 和电平计算在独占 drain queue。元数据 ring 固定 64 条，满载报告丢样，不能覆盖来源时间。格式变化退休旧 epoch。确定性测试证明转换不在自有 callback 中执行、stop 等待正在转换的工作；实际设备时序、callback 总分配与耗时需要另行 Instruments 验证。

## 导出与文件播放

配音项目在存储 actor 的同一锁内冻结候选顺序与 revision，预检所有 WAV 格式及 RIFF 大小，再以最多 256 KiB 的块写入专属临时目录；同一 store 最多一个导出租约。格式错误、缺失候选或大小溢出明确失败，不补静音。PreparedDubbingExport 只返回 URL、字节数和版本身份。作品与候选播放走已验证 URL；共享播放请求在停止或另一个 owner 播放时失效，迟到的加载不得重新开始旧音频。

DubbingExportWriter actor 将每个文件复制到目标同目录 staging，fsync 后检查取消，再逐文件 rename；音频和正文各有真实提交回执。取消前未提交的目标保持原状；一份已经提交时照实报告部分保存并保留可重试 lease。两份已经保存后，临时文件清理失败仍报告保存成功，并保留唯一清理句柄；该次导出的重试只清理临时文件，不再次覆盖目标。关闭页面取消 copy、等待实际结束后才释放临时文件；清理失败也保留后续可重试的 lease。没有跨两份文件的原子性承诺。文件播放的内部换轨不使当前请求失效，真实播放器错误仍能显示；用户停止或新的播放请求仍使旧加载失效。测试只用临时合成音频，最大块与句柄有界；实际长文件 RSS 和文件播放器内部缓存另行测量。

## 高频展示与提词匹配

会议状态栏由局部子 View 订阅电平与经过时间；父级转写列表不提前读取这些值。有声书分析的经过时间由局部 TimelineView 计算，workflow 仅维护开始/停止时间，不运行周期 Task。分析与制作的局部时间线在功能不活跃、不可见或 scene 非活跃时暂停。电平状态的可访问描述独立于动画；Assistant 既有 Reduce Motion 和暂停策略保持一致。模型回归检查电平变化不增加 transcript projection revision，实际 body/diff 次数、VoiceOver 与视觉仍需独立核验。

PreparedTeleprompterScript 缓存当前版本的冻结 Script，正式跟随与试读共用；同版本事件不重新 tokenize、hash 或比较整稿。anchor 使用 lower_bound 找第一个满足原 token.end 比较关系的位置，别名共享位置时仍取第一个匹配 token。其后的 72 token 输入上限、窗口与 DP 不变。确定性语料与冻结的旧 matcher 逐字段比较结果，并检查 anchor 比较次数随稿长对数增长；这不代表实际匹配延迟已经达到预算。

## 长会话显示与完整档案

TranscriptPresentation 的 live tail 最多 500 行，ID 索引用于追加和归属更新；正常追加不排序历史，乱序插入只重建这份有界 tail。只有正式保存回执后才进入显示。回看使用每页 200 行、最多三页的缓存，保留用户锚点页；非连续缓存之间提供显式补页入口。新行继续进入 tail，用户回看时不替换当前历史窗口。复制完整会议文字直接请求 SessionStore 完整范围，不能从显示窗口推导完整档案。

SessionStore 复用既有 session/ordinal 索引执行 keyset 分页，不用 OFFSET，不新增 schema。live item 索引和 speaker 单元在 Realtime 客户端既有的 128 项/30 s 生命周期退休后清理，接受中的保存与归属写入先完成既有屏障；不缩短修订窗口。退休 tombstone 固定 512 条，不把迟到保存重新登记为 live。4 小时规模的合成事件验证两个场景均完整保存 2,880 行、显示上限 500，以及 live 索引清零；这是逻辑时间快进，不能替代实际 4 小时稳定性采样。滚动锚点模型和复制范围已有回归，真实滚动、选择和复制交互未验收。

```bash
swift test --package-path macos/SpeechRailApp --enable-swift-testing --filter 'SessionActivityPolicyTests|TeleprompterScriptPerformanceTests|TeleprompterPositionTests|TeleprompterFollowControllerTests|TeleprompterSessionLifecycleTests'
swift test --package-path macos/SpeechRailApp --enable-swift-testing --filter 'TranscriptPresentationTests|TranscriptPagingTests|AudioInputTerminationTests|MeetingSessionLifecycleTests|CaptionSessionLifecycleTests'
```

## 波形读取与缓存

WaveformEnvelopeLoader actor 合并相同 assetID/revision/fileIdentity/bucketCount 请求，最多一个实际扫描和八个不同 key 等待。@concurrent worker 分块读取 AVAudioFile，每块检查取消；管理 actor 在扫描阻塞时仍能处理 release。最后一个 owner 离开后取消 worker 并等待实际退出，期间保留执行槽，不能提前启动下一份扫描。同一操作的其他 owner 不受单个 release 影响。

LRU 最多 64 条，Double 数组 payload 总计最多 256 KiB；最多 256 份租约通知，仅传固定终态，不持有缓存外的数组。每个 active 操作拥有一个 worker 和一个完成观察 Task；退出后两个句柄均回收。排队溢出返回 deferred，打开/解码失败明确失败，超大或无效 bucket 数拒绝。结果若在 owner 读取前已被 LRU 淘汰，返回 expired，不保留无界的已完成结果副本。界面额外只保留当前一份小型投影，页面 .task 取消会等待 release，过期 revision 不发布。

作品 key 使用保存时的文件 SHA-256 和 renderRevision，不在 MainActor hash 音频。没有文件摘要的旧作品保留播放能力，波形使用占位。内存 TTS 试听不为波形写临时文件；PreparedDubbingExport 临时文件只用于导出保存。参考录音的质量分析在已有解码循环内同时计算包络，不启动另一份文件扫描。这些边界不保证检测库外程序绕过存储接口、在保留旧摘要的同时篡改文件；实际播放仍走已有验证。

```bash
swift test --package-path macos/SpeechRailApp --enable-swift-testing --filter WaveformEnvelopeLoaderTests
```

## 服务热点归因

服务侧重采样和 event-loop lag 尚无分进程采样证据，状态为“待测，无服务代码改动”。App 的确定性回归不能推导 service/worker 的 CPU 收益。达到采样授权后分别归因 App、helper、service、worker，再决定是否修改逐样本处理；不预先改变模型、线程数、ASGI worker 或 Resource Governor。
