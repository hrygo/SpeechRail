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

## 后续可短测但需要独立实施的范围

#224 需让 factory、prepare、lane 与 runtime identity 的实际合同贯穿组合根和所有消费者；
#223 需贯穿音色解析、租约、HTTP/Realtime/job 与 backend，迁移测试中的全局 patch。
两者均可先用确定性回归，但不能仅调整签名或改为 lazy singleton 就算完成。
#226/#228/#229/#230 同样可分步短测，需按各自所有权边界独立交付，保护已有取消与清理保证。
#263 的 store 部分可以独立推进；当前状态和 SQLite 帮助方法具有文件级私有访问，
拆文件需要明确共享访问边界，不能直接搬走 extension。MeetingView 的真机走查门仍独立。

## 证据与回退

当前图谱工具未索引此 worktree，且只读 profile 不提供索引入口，结构结论以定向源码为准。
不操作真实库、模型、服务、安装副本或前台窗口；测试数据库与文件均使用临时目录。
回退以对应 issue 的局部 diff 为单位，保留本轮开始前已有改动和用户数据。
