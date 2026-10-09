# 开放 Issue 筛选与短时回归交付记录

核验日期：2026-10-09。首次筛选覆盖 GitHub 当时全部 33 个开放 issue；首批实施位于
`codex/short-validation-issues`，后续批次与远端回读见各节。以下耗时是定向确定性验证，
不代表真实模型、性能、设备或 UI 验收。远端 issue 状态不随本地实施自动变化。

## 筛选规则与实施顺序

优先处理有明确失败条件、可以临时文件或 fake 重现、无需真实声音或长时观察的缺陷。
其次处理能由类型检查、组合测试和源文件清单证明的结构调整。
需要声音质量、设备时序、窗口体验或长期驻留的 issue 保留独立验收门。

| Issue | 分类 | 判断与安排 |
| --- | --- | --- |
| #222 | 短时缺陷 | REST/job 共用时间戳前提，缺 aligner 时在解码、准入和 ASR 前拒绝 |
| #261 | 短时缺陷 | 归档/删除会议禁止新纪要排队；恢复后允许排队 |
| #152 | 短时缺陷 | 两个 store 共用已发布音频校验，失败保留 journal |
| #262 | 短时缺陷 | 备份导出返回成功前快检，恢复预演继续完整核对 |
| #187 | 短时缺陷 | 控制通道与作业队列区分未知/成功/失败，取消保留已观察事实 |
| #194 | 短时工程 | 补齐两套展示测试登记，清除清单豁免，保留 CI 漂移检查 |
| #225 | 短时结构 | 提取纯类型化验证策略，发现展示与严格执行分别投影 |
| #224 | 短时结构 | 增量 factory/prepare/lane 需完整调用合同与取消回归 |
| #223 | 短时结构 | registry 注入需贯穿组合根、backend、HTTP、Realtime/job 与文件租约 |
| #226 | 较大结构 | render 用例拆分需保护首块预取、断连和 owned cleanup |
| #228 | 较大结构 | 会话 owner 拆分需覆盖 ASR/TTS/辅助任务整个生命周期 |
| #229 | 较大结构 | Creator 窄协议须迁完生产消费者与 fake，不能只加协议名称 |
| #230 | 较大结构 | AppModel 拆分须明确任务代次与唯一共享播放 owner |
| #263 | 混合范围 | SessionStore 域拆分可短测；MeetingView 另需授权真机走查 |
| #148 | 产品与数据 | 恢复区可见性、回收确认与保留政策须一起定义，不能自动清理真实数据 |
| #150 | 产品与数据 | 条件漂移需明确重建项目操作与旧采用关系处理，不能仅改提示或放宽摘要 |
| #151 | 产品与数据 | 候选/项目删除需要事务、采用保护和完整用户出口 |
| #196 | 产品与数据 | 服务执行身份与回执快照落盘涉及持久化含义和消费路径 |
| #260 | 条件任务 | 等转录正文编辑入口出现，同次实现证据重验证；不先造编辑入口 |
| #336 | 真实验收 | ASR 四场景质量回退、标点、噪声与长稳 |
| #308 | 真实验收 | 偶发慢放需要重复真实合成和人工听审 |
| #286 | 远端与长期 | 冷缓存完整 CI、阶段计时与耗时长稳 |
| #268 | 真实验收 | 完整/增量同文质量对照及取消、积压 |
| #259 | 真实验收 | 会议 UI、输入法、语义召回与模型校准 |
| #258 | 真实验收 | 助手设备恢复、质量、取消与长稳 |
| #257 | 混合范围 | adapter 实施与 #268 的真实分组对照一起决定完成 |
| #256 | 真实验收 | 长停顿、关键语义和澄清需要真机对照 |
| #253 | 真实验收 | 四场景质量、延迟、资源与生命周期 |
| #118 | 真实验收 | 真实设备拔插、蓝牙重连与连续长时内存 |
| #95 | 综合验收 | P0–P5 实施与真实质量/资源/播放认证，不能整体以单测结案 |
| #89 | UI 验收 | 窗口、AX、快捷键与实际手工走查 |
| #84 | 短期研究 | 同口径人工轨迹可评估最小候选；证据不足时允许记录不实施，真实语料另授权 |
| #79 | 混合范围 | UI/UX 系统计划包含大量窗口及辅助功能实测 |

## 可独立评审的任务

- [x] #222：`domain/transcription_requirements.py` 定义共同前提；REST/job 映射各自错误。
  `uv run --no-sync pytest --no-cov tests/test_transcription_api.py tests/test_local_file_processor.py`
  实测 102 passed，1.73 秒。
- [x] #261：事务内拒绝不可用会议排队；不生成 queued 行，不改变提交侧保护。
- [x] #152：正常提交和已提交恢复均验证音频；缺失、摘要变化、符号链接明确报错。
- [x] #262：`exportBackup(to:)` 快检文件完整性与清单纪要计数，设置页成功文案说明快检范围。
  上述三个 Swift issue 的相关四套测试共 91 项，0 failures，0.35 秒。
- [x] #187：`AppModel.swift` 保存已完成探测事实；控制通道成功或失败才更新结果，
  取消或过期返回保留旧结果，列表和档位一起落地。作业队列区分未读取、未就绪和可用；
  health 失败时不以旧快照冒充新事实。新增回归先复现取消抹掉旧错误，再确认修复。
- [x] #194：展示类型已在 `WorkspaceComponents.swift`；两套展示测试加入 Xcode Sources，
  清除过期豁免。新增清单回归先确认缺项，修复后清单守卫通过，Xcode 实际运行
  ModelName 9 项、ModelReadiness 11 项、WindowLayout 7 项。
- [x] #225：`domain/voice_validation_policy.py` 提供不可变 `VoiceValidationVerdict`，
  `application/voice_validation_presentation.py` 单独生成公开 JSON。strict gate 使用类型字段；
  discovery 和 HTTP voice projection 共用 evaluator，删除跨模块私有函数依赖和旧内部入口。
  逐维 stale、output scope、reference/output/identity 分离、cold recorded/warm observed、
  runtime unknown、revision pin、严格合成与取消回归通过。独立导入策略不初始化默认音色 registry。

## 最终定向验证

日期：2026-10-09。全部使用确定性 fake、合成字节与临时数据；下列数量各自对应一条验证命令，
Xcode 的测试是 Swift 套件的另一条编译/执行路径，不能把两者相加当作独立覆盖。

```bash
uv run --no-sync pytest --no-cov \
  tests/test_transcription_api.py tests/test_local_file_processor.py \
  tests/test_speech_api.py tests/test_tts_voice_clone.py \
  tests/test_voice_quality_routes.py tests/test_voice_design_workflow.py \
  tests/test_voice_validation_policy.py tests/test_capability_snapshot.py \
  tests/test_voice_validation_residency.py tests/test_interface_parity.py \
  tests/test_macos_test_target_coverage.py tests/test_server_workflow_integration.py

swift test --package-path macos/SpeechRailApp \
  --filter 'CreativeWorkStoreTests|DubbingProjectStoreTests|MeetingBackupRestoreTests|MeetingLibraryDeletionTests|AppModelTests|ModelNamePresentationTests|ModelReadinessPresentationTests|WindowLayoutPolicyTests'

scripts/macos_app_build.sh --test-unit --timeout 600 -- \
  -only-testing:SpeechRailAppTests/ModelNamePresentationTests \
  -only-testing:SpeechRailAppTests/ModelReadinessPresentationTests \
  -only-testing:SpeechRailAppTests/WindowLayoutPolicyTests \
  -only-testing:SpeechRailAppTests/AppModelTests \
  -only-testing:SpeechRailAppTests/MeetingBackupRestoreTests
```

- Python：交付前复跑 362 passed，13.95 秒。
- SwiftPM：交付前复跑 200 tests，0 failures，1.78 秒。
- Xcode：117 tests，0 failures，`TEST SUCCEEDED`；包含完整 App 源码编译与两套新增登记。
  此次 Xcode 运行早于最后补入的一个作业队列测试，该测试随后由 SwiftPM 实际执行。
- 受影响 Python 文件 Ruff 通过；6 个策略/准入/投影源文件定向 Mypy 通过。
- 将 HEAD 的原验证函数与新 evaluator/presenter 做 3,840 组逐字段对照，覆盖音色模式、
  reference/output 状态、运行时身份、scope 与逐维失配；公开投影完全一致。
- 源码与接线复查覆盖错误优先级、旧状态保留、journal 失败保留、严格执行与只读展示的身份语义；
  公开 JSON 与原因码保持原合同，持久化格式未变。
- 未执行真实模型、设备、质量/性能基准、UI 自动化、完整测试套件或安装发布。
- 本地实施对应 #222/#261/#152/#262/#187/#194/#225，按 issue 分成七个独立提交。
远端关闭以 main 合入与 GitHub 状态回读为准。

## 执行身份快照与作品回执查询（#196）

作品和段落候选保存可选 request/receipt ID、渲染返回时的回执状态与终态时间。
原文件无需迁移，缺失身份保持未知；响应头与回执身份失配时保留音频并拒绝采用错误回执。
作品详情通过独立只读 port 查询回执，结果与保存时快照分开展示，不回写用户资产。
相关说明见 `docs/developers/macos-app-development.md`。

2026-10-09 定向 SwiftPM：240 tests，0 failures，2.09 秒；覆盖真实 HTTP 接线、
作品和候选重新读取、旧记录、身份失配、未知状态与查询不改写快照。
新增断言先证明结果类型缺少身份字段，再完成接线。
`scripts/macos_app_build.sh --configuration Debug --timeout 600` 返回 `BUILD SUCCEEDED`，
验证详情区与生产组合根编译；未运行 UI 自动化、真实服务或安装 App。

第一批 PR #345 的七个 CI job 全成功，已按 rebase 合入；GitHub 回读七个 issue 全部关闭，
开放数量为 26。#196 的远端完成状态仍以其独立 PR 合入后回读为准。

## 制作条件漂移与显式新项目（#150）

采用拒绝区分缺配方、正文变化、模型/运行版本漂移和其他条件变化。摘要比较继续严格；
返修页提前显示可由能力快照确认的版本漂移，失配候选提供确认后按其条件建立新项目的入口。
新项目重新分段、不继承采用历史；旧项目、候选音频和原作品保留。查询与重建不自动合成全文。

2026-10-09：定向 SwiftPM 115 tests，0 failures，1.57 秒；
包装脚本 Debug App `BUILD SUCCEEDED`。回归覆盖运行时与制品版本漂移、正文变化、
不完整配方拒绝、新项目完成下一次生成与采用、旧记录与音频不变。
新测试先确认缺少漂移专属原因与重建入口；持久化保留的比较以实际落盘基线为准。
未执行真实模型、UI 自动化、安装或运行态变更。PR #346 已合入，#196 关闭。

## 后续可短测但需要独立实施的范围

#224 需让 factory、prepare、lane 与 runtime identity 的实际合同贯穿组合根和所有消费者；
#223 需贯穿音色解析、租约、HTTP/Realtime/job 与 backend，迁移测试中的全局 patch。
两者均可先用确定性回归，但不能仅调整签名或改为 lazy singleton 就算完成。
#226/#228/#229/#230 同样可分步短测，需按各自所有权边界独立交付，保护已有取消与清理保证。
#263 的 store 部分可以独立推进；当前状态和 SQLite 帮助方法具有文件级私有访问，
拆文件需要明确共享访问边界，不能直接搬走 extension。MeetingView 的真机走查门仍独立。

## 配音资产清理与开放清单复核

2026-10-09 再次读取 GitHub 全部开放 issue，共 25 项。当前批次分支为
`codex/dubbing-project-cleanup`，延续原有未提交修改；以下为本地交付状态，不改变远端 issue。

| 范围 | Issue | 当前判断 |
| --- | --- | --- |
| 明确缺陷，定向短测 | #148 / #150 / #151 | 制作条件漂移已有独立提交；作品恢复区出口与配音项目清理已完成本地实施 |
| 可确定性验证，较大结构迁移 | #223 / #224 / #226 / #228 / #229 / #230 | 需各自完成依赖或生命周期迁移，当前批次未实施；不能用声明协议或搬文件代替完成 |
| 可拆出的 store 工作 | #263 | SessionStore 可定向回归；MeetingView 仍有真机走查条件，整条不能按 store 单测结案 |
| 等待功能前提 | #260 | 转录正文编辑尚不可达，不提前新增该入口 |
| 真实、长期或远端验收 | #336 / #308 / #286 / #268 / #259 / #258 / #257 / #256 / #253 / #118 / #95 / #89 / #84 / #79 | 继续保留各自真实证据门，短测不能替代关闭条件 |

### #151：配音项目与候选删除

Store 提供候选删除、未采用候选批量清理、项目删除。当前采用和撤销历史引用的候选受保护，
项目删除要求撤销全部采用，原作品保留。索引提交后按固定摘要回收候选音频；
提交前失败保留原索引与音频，提交后失败保留 journal，重试恢复后确认已经删除。
改变的字节和符号链接拒绝删除，索引事务恢复不再要求存在新发布音频。

返修页提供确认、项目重开、未导出结果提示及清理后关闭。
作品页头部也提供保存项目入口，原作品已删除或作品列表为空时仍能重开项目。
两份导出文件都成功写入才确认本次选择已导出，重新打开时不推断外部文件仍存在。

### #148：作品恢复区出口

应用删除作品后将该事务的音频与记录移入系统废纸篓，永久移除由用户清空系统废纸篓决定。
旧恢复区显示件数和总占用，提供确认后批量转移；读取列表不自动清理旧数据。
单件删除只转移本次事务。索引已提交但转移失败时，分别报告列表删除成功和转移待重试。
转移前验证删除 journal、文件名、音频摘要与目录归属，拒绝链接、额外文件与发生变化的音频。
恢复目标已被占用时保留两份内容，原路径音频在索引提交后发生变化时原地保留。

### 实测证据与边界

2026-10-09 15:17（Asia/Shanghai），定向 SwiftPM 170 tests，0 failures，1.75 秒。
覆盖 AppModel、CreativeWorkStore、DubbingProjectStore，包括漂移重建、原作品为空后的重开、
采用/撤销保护、删除中断恢复、清理失败重试、废纸篓失败、变更字节与链接拒绝。
新增重试测试先复现 `candidateNotFound`，音频完整性测试先复现错误转移，再确认修复。
恢复区 API 的测试先确认入口缺失；所有转移测试注入临时文件操作，不访问系统废纸篓或真实作品库。
重新读取项目与保存时比较采用实际落盘基线，避免 JSON 数值形状变化被误判为内容变化。

包装脚本 Debug App 返回 `BUILD SUCCEEDED`，验证 SwiftUI 菜单、确认和项目弹层接线。
临时 App 由包装脚本注销并清理；未执行 UI 自动化、真实模型、长稳、安装或服务操作。
#150 通过 PR #347 按 rebase 合入，2026-10-09 15:22（Asia/Shanghai）
回读为 CLOSED；随后复核开放数量为 24。#148/#151 的本地修复通过上述验证，
远端完成状态以本批次 PR 合入与回读为准。

## 创作客户端按功能注入（#229）

PR #348 门禁通过后按 rebase 合入，#148/#151 关闭；2026-10-09 15:32
（Asia/Shanghai）回读开放数量为 22。

移除 `SpeechRailCreatorClient` 与默认 unsupported 实现，以目录、渲染、设计、
克隆、音色编辑、版本管理、发音表、质量运行八项窄接口表达实际依赖。
AppModel 持有所用的六项可选接口，缺失能力在操作边界拒绝；未使用的版本管理与发音表
不注入。生产组合根共享一个 ServiceAPIClient，没有新增全能 facade 或 HTTP 实现。
质量、设计、克隆、渲染 fake 按实际调用迁移；质量 fake 不实现任何生成方法。

2026-10-09 15:32：定向 SwiftPM 178 tests，0 failures，1.45 秒。
新增缺失能力测试先确认文案误归类为服务失败，再修正为明确客户端能力提示。
音频专用 render fake 仅实现 createSpeech，证明字节保留、身份未知与取消传播；
原有 ServiceContract、CAS、幂等、取消、配音与质量状态回归继续通过。
SwiftPM/Xcode 沿用原文件及工程登记，不新增编译成员；
仓库包装脚本 Debug App 返回 `BUILD SUCCEEDED`，验证正式与 DEBUG 组合根。
未运行 UI 自动化、真实模型、服务或安装操作。

## TTS 执行能力的显式端口（#224）

PR #349 门禁通过后按 rebase 合入，#229 关闭；回读开放数量为 21。

增量服务注入既有 `IncrementalSpeechSynthesizer.open_stream`，生产 adapter 委托
worker/router 的租约 factory，不绕过音色/槽位 owner。prepare、lane、runtime identity、
采样读取通过独立 typed port 接线，批量 synthesize 接口保持窄合同。
组合根绑定同一快照供 REST、Realtime、作业与验证使用；动态发现仅在后端 adapter。
无提示继续保守 wildcard，非法 lane 拒绝；协商与 ready 动态判定。
错误 factory 签名在装配时拒绝，无效会话返回隔离 lane，避免误报物理资源已回收。
原 StreamController、owned cleanup、ACK、receipt 与 quarantine 保持原 owner。

2026-10-09：13 个相关测试文件 368 passed，10.30 秒；
19 个源文件定向 Mypy 通过，改动 Python 文件 Ruff 与 diff check 通过。
新增 domain factory fake 不需要批量或 vendor 方法；覆盖错误签名/返回值、实时协商、
缺失 lane、非法 lane。原取消、清理失败、唯一终态、背压、strict prepare、运行身份、
HTTP、Realtime、文件作业、同次验证与组合根回归通过。
直接构造验证用例的测试显式注入同一生产身份读取器，不再期待隐式后端附加方法。
PR #350 首轮 CI 发现真实 pipe 回归仍使用旧构造参数；改为直接注入
`Qwen3TtsIncrementalSynthesizer` 的 domain factory，保留管道、序列化与背压链路。
该回归定向实测 1 passed，1.08 秒；合入以修正后的远端门禁为准。
未执行真实模型、完整性能/质量基准、长稳、UI、安装或服务操作。

## 语义辅助端点研究（#84）

PR #350 修正后门禁全部通过并按 rebase 合入；2026-10-09 16:18
（Asia/Shanghai）回读 #224 CLOSED，开放数量为 20。

完整正文允许证据不足时记录不实施结论；此前把它整体归为真实验收过于宽泛。
[研究报告](../research/2026-10-09-semantic-endpointing.md) 与离线脚本对当前
SpeechAdmission 和有界词尾等待策略做同口径人工回放。
12 条轨迹中修正 3 条过度切段、新增 1 条插话误合并；独立“嗯”增加 320 ms 等待。
两条观察事实完全相同、期望分段相反的轨迹构成反例；脚本显式核对。
当前不实施服务端语义辅助端点，继续声学基线与调用方轮次决策。
资源数字为 PCM/文本设计预算，首个 partial/final、RSS 和真实语料收益未测；
未运行模型、采集、性能基准、UI 或运行态操作。Ruff 与离线回放通过。

## 证据与回退

当前图谱工具未索引此 worktree，且只读 profile 不提供索引入口，结构结论以定向源码为准。
不操作真实库、模型、服务、安装副本或前台窗口；测试数据库与文件均使用临时目录。
回退以对应 issue 的局部 diff 为单位，保留本轮开始前已有改动和用户数据。

## 音色存储与租约显式注入（#223）

2026-10-09 复核 GitHub 开放清单为 19 项。#223 的本地实现将文件 registry
移入 infrastructure；领域导入仅提供纯音色值与规则。组合根打开唯一 owner，
目录、修订、验证、HTTP/Realtime/job 与 backend 租约使用显式依赖。

默认 `custom_voices.json` 的辅助制品位置保持；其他文件名使用 owner 命名空间，
同目录中的两个 store 不共享验证证据、候选或幂等日志。旧未命名制品归属不明
时拒绝装配，不自动迁移或删除。测试默认路径在 collection 前就进入临时目录，
覆盖测试模块导入默认 ASGI app 的场景。

审查发现并修复 batch abort/reap 失败提前退出读租约：worker 保留引用至后续
明确回收成功。新回归先证明该路径允许错误删除，再确认清理前持续拒绝删除。
双 owner 测试使用真实临时 clone 文件，验证实际音频读保护。

定向实测：34 个相关测试文件 791 passed，27.79 秒；随后补齐默认布局与五类
旧制品保护，组合测试 13 passed，0.68 秒。Ruff 与 21 个源文件 Mypy 通过；
只读独立复核未发现阻塞问题。所有文件制品均为临时合成数据；没有模型、
服务、UI、安装或真实用户目录操作。此阶段远端 #223 保持开放，关闭以合入后回读为准。

## 渲染准备、执行与交付用例（#226）

纯准备构造固定请求、配方和时间轴坐标；单次 `RenderOperation` 负责 deadline、
准入、严格准备、validated PCM、身份/采样计量与交付收尾。HTTP 保留鉴权、
错误优先级、结果登记、格式编码、headers 及 ASGI send/disconnect。
PCM 和编码流共用交付 owner，首块预取后 body 未开始也能回收。
严格准备自身使用同一 deadline，不依赖 HTTP 包装器才得到时限。

2026-10-09 定向实测：8 个测试文件 146 passed，4.62 秒；覆盖纯用例、
原 HTTP/receipt/timing/发音接线、重复执行拒绝、严格准备 deadline、
PCM 与 fake 编码流的 send 失败/取消/清理失败隔离及反复取消。
3 个源文件定向 Mypy 与 Ruff 通过。未执行模型、UI 或完整套件；
代码与接口事实见[渲染应用用例](../architecture/render-usecase.md)。

只读独立复核未发现阻塞问题；补充 timing sidecar 的 body 未开始取消、
重复关闭、deadline 失败与回收未确认 pending 断言，相关 36 项实测通过（1.25 秒）。

## Realtime 状态与资源所有权（#228）

根 session 负责协议配置、派发和组合关闭；ASR ingress/frozen final、
TTS utterance、alignment/diarization 分属独立 owner。子 owner 接收窄端口，
不持有 AppServices 或 root 任意写接口。配置读取使用独立的只读快照；
辅助输入使用 `FrozenTranscript` 与 `AsrIdentity`。

TTS 每次请求聚合 ready/task/controller/window/receipt/terminal 与计量，
旧 ACK/finally/terminal 使用捕获的 context。连接 owner 保留退休但仍在发送的
task，关闭时同样等待。未确认模型回收保留 context、pending receipt 和 lane
隔离；组合关闭不因一个 owner 失败而跳过其他 owner，并传播汇总错误。

2026-10-09：20 个相关测试文件 416 passed，6.35 秒；5 个源文件 Mypy 通过。
覆盖独立 owner 构造、admission 前取消、旧 context 收尾、关闭重复取消、
失败清理、采样轴/冻结 final/commit、辅助 epoch 与原 transport 组合回归。
现有私有测试引用迁至实际 owner；ASR debug tap 仅使用临时测试 WAV。
公开 wire、模型进程、用户存储与运行态保持。
架构见[Realtime 状态与资源所有权](../architecture/realtime-ownership.md)。

独立只读复核未发现阻塞回归；补充关闭期间及关闭后拒绝新事件的回归后，
owner 定向集合为 9 项通过。5 个源文件重新运行 Mypy、Ruff，`git diff --check`
通过。未确认资源回收时仍保留隔离与可见错误，不把清理失败当作成功。

## macOS 引擎、音色与配音所有权（#230）

引擎、音色和配音的可变状态、task、generation 与依赖分别进入
`EngineModel`、`VoiceWorkflowModel`、`DubbingWorkflowModel`。AppModel
保留装配、命令转发和直接读取子 owner 的投影；功能不反持组合根。
能力快照由引擎唯一持有，配音只读取音色目录；克隆与设计幂等回读、
配音固定保存身份和返修代际保持。

共享播放 owner 捕获 token、target 与功能回调；旧完成、进度和电平
不影响新播放。设计听审捕获 candidate/revision/validation，不按当前选择推断。
试听与正式生成通过唯一准入 owner 互斥，原创作反馈文案保持唯一。
实测发现并修复试听等待能力绑定时准入被配音取得后的检查遗漏：
恢复时核对取消、请求代际与共享准入，不越过当前生成归属。

2026-10-09 18:52（Asia/Shanghai）：95 项定向 Swift 测试通过，运行 1.533 秒。
包含原 AppModel 回归及独立引擎/配音、组合层 Observation、播放旧回调、
停止/失败撤销身份、准入归属和绑定后再检查。引擎相关测试直接构造引擎；
部分音色用例直接构造音色 workflow，不构造作品、设计或克隆无关依赖。
新增候选创建响应丢失回归验证完整请求与幂等键保持相同，服务端 fake
仅提交一份候选；原注册、发布与保存失败重试继续通过。

包装脚本 Debug 编译出现 `BUILD SUCCEEDED`，临时 App 由脚本清理；
SwiftPM 清单和六个新增 Swift 文件在 App/单测 target 的唯一成员登记均已核对。
当前实测工具链为 Swift 6.4 / arm64，部署目标保持 macOS 26。
独立只读复核未发现阻塞问题。没有 UI 自动化、真实模型、用户内容、安装
或服务操作；编译不构成视觉、音质或长稳验收。

所有权与依赖矩阵见[macOS 引擎与创作状态所有权](../architecture/macos-feature-ownership.md)
及[实施计划](../superpowers/plans/2026-10-09-app-feature-ownership.md)。
图谱对本 worktree 的十个相关路径报告 `outside_project`，判断依据为当前源码、
旧源码比较、定向测试与成员解析，不依据主 checkout 的图谱宣称覆盖。
四项改造在 `codex/voice-store-ownership` 按 Issue 分成四个独立提交。
#223、#226、#228 的暂存源码分别导出到临时目录，通过各自组合与生命周期定向回归；
#230 复用上述未发生语义变化的测试、编译与成员登记证据。
交付通过同一 PR 执行必需 CI，以当前提交的门禁结果和合入后 GitHub 回读判定关闭。
回退按四个逻辑提交逆序恢复 owner 与组合接线源码；不改变 JSON/SQLite、
作品目录或用户数据。没有运行态部署。

## 本批剩余边界

提交阶段的 19 项开放 Issue 中，本批完成 #223、#226、#228、#230 的实施与短时验证。
提交前回读 GitHub，开放清单仍为相同 19 项，没有新增或消失的条目；
四项合入后的目标数量为 15，实际数量须重新读取，不能以本地完成推断。
#263 的 SessionStore 部分可单独短测，但完整 Issue 包括 MeetingView
专项 UI 走查，不能按局部存储单测宣称整条完成；#260 的转录编辑入口前提
尚未满足。其余 #336、#308、#286、#268、#259、#258、#257、#256、
#253、#118、#95、#89、#79 仍需各自真实、长稳或专项验收。
