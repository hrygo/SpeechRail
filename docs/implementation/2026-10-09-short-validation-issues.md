# 开放 Issue 筛选与短时回归交付记录

核验日期：2026-10-09。范围为 GitHub 当日全部 33 个开放 issue；实施位于
`codex/short-validation-issues`，工作区已有改动继续保留。以下耗时是定向确定性验证，
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
| #84 | 研究实测 | 语义断句方案需要同素材错误、延迟和资源对比 |
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
未执行真实模型、完整性能/质量基准、长稳、UI、安装或服务操作。

## 证据与回退

当前图谱工具未索引此 worktree，且只读 profile 不提供索引入口，结构结论以定向源码为准。
不操作真实库、模型、服务、安装副本或前台窗口；测试数据库与文件均使用临时目录。
回退以对应 issue 的局部 diff 为单位，保留本轮开始前已有改动和用户数据。
