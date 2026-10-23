# 会议四位稳定身份与未识别实施方案

> **For agentic workers:** 使用 test-driven-development；按当前用户授权直接实施，无需再次确认。主代理负责服务与协议，独立执行者负责 macOS 消费与统计，完成后独立审查。

**Goal:** 整场最多维护四位稳定匿名身份；超额、不确定和不能跨连接验证的声音保留文字并标为未识别，统计保留未识别分母。

**Architecture:** 复用已有基于 embedding 的 SessionSpeakerMatcher，将生产身份预算限制为四，不回收或轮换已确认身份。会议只请求具备拒识能力的 meeting_dynamic 后端；其制品与质量认证未就绪时保留文字，不回落到无法拒识的四槽 Sortformer。归属账本尊重拒识证据，避免概率、邻接补齐或重叠将未知重新变为已知。所有声音参考仅限本场有界内存。

**Tech Stack:** Python 3.14、Swift、既有 CoreML/FluidAudio、Swift Testing/XCTest、pytest。

**Spec:** 当前用户批准的研究方向与本方案中的行为规则。

## Global Constraints

- 最多四个被确认的自动身份；未识别不是第五个身份，不是一个共同的真实人物。
- 不改写原始会议记录、SQLite schema、现存人工标注或正文；不保存音频或 embedding。
- 不下载模型、不加载未授权的新模型、不切档、不重启、不安装、不提交或推送。
- 保留认证门槛：确定性测试不能产生真实声学质量认证；缺少原始音频不能声称完成原音频重放。
- 保留其他任务的 docs/developers/README.md 与 remote-worker-checks.md 改动。

## Review Focus

- 第五位声音可能被四槽模型高置信错认：会议不使用四槽活动分数作为身份证明。
- 未知与已知同时出现：任何不可归属的重叠不得被已知声部吞掉。
- 短插话和已知身份的短应答：独立统计，不能用主要发言人的占比掩盖错误。
- 暂停、断线与重新连接：没有跨连接声音证据时拒绝复用 A–D，不分配第五个身份。
- 统计的空值、标点、缺失或部分逐词归属：分母包括全部有效文字，未知缺口不可消失。

## Task 1: 身份预算与拒识传播（主代理）

Files: native/diarization/Sources/SpeechRailDiarizationProtocol/SessionSpeakerMatcher.swift；MeetingDiarizationWorker.swift；SpeechRailDiarizationProtocolSelfTest/main.swift；src/speechrail/backends/diarization/meeting.py；domain/diarization/attribution.py；application/services.py；compatibility/openai_realtime.py；相关 tests 与 contracts。

- [x] 先补四身份满额后第五/六人未知、原身份返回仍匹配、短插话不晋升、模糊输入不更新原型的反例并运行 RED。
- [x] 生产匹配预算固定为四；认证容量与公开能力不超过四，不改变纯实验校准的原始证据。
- [x] 拒识原因覆盖的片段不能被已知重叠、置信度投票或邻接填充覆盖；补 API/账本定向测试。
- [x] 同步能力回显与公共契约；认证不得由假数据自动产生。
- [x] 运行相应 pytest 与 native 无模型 self-test，记录实际结果。

## Task 2: 会议接入、稳定边界与占比（独立执行者）

Files: macos/SpeechRailApp 下会议生命周期、SpeakerLabeling、SpeakerScopeBinding、相关视图、ControlKit 容量契约和定向测试。

Consumes: meeting_dynamic 的 system_cap=4，max_speakers<=4；不可用时现有文本回退。
Produces: 默认会议请求可拒识后端；不再要求用户声明总人数<=4；最多四个稳定自动身份；未识别文本占比可见。

- [x] 先补超四人、短插话、重连后旧身份不能被冒用、全部未知与部分归属统计的 RED 用例。
- [x] 会议默认请求可拒识后端，认证未就绪时继续文字；移除本轮之前添加的全场人数确认要求。
- [x] 全场身份预算为四；连接切换后没有声音匹配证据时保持原记录并将新自动归属拒识，不把新连接 S1 映射成旧人物。
- [x] 从最终正文/逐词归属计算有效字符占比，明确称文本占比；未知缺口、拒识和未归属行均在分母内；不得用行数替代。
- [x] 复用视觉 Token；仅确定性/离屏验证，不接管前台窗口。

## Task 3: 有限身份验收与交付（主代理）

Files: examples/perf/meeting_quality_metrics.py 或独立有限身份评分模块；对应 tests；docs/users/meeting-minutes.md；本计划。

- [x] 为四身份模式建立独立评分：已归属精度、正确覆盖、超额者误认、所选四位逐人覆盖、未知占比与短插话保留；不把 unknown 当一个人匹配。
- [x] 保留标准 DER/JER 与原全员识别门槛，不用放宽旧门槛伪造改善。
- [x] 定向模拟五/六人、均衡与主导发言分布、短插话、陌生人后原身份返回；计算前四占比的理论上限。
- [x] 独立代码审查；按改动风险运行最小充分验证，原会议仅只读校验，记录真实音频质量未验证与运行态未启用。

## 执行记录

- 2026-10-23：已确认原始会议没有可重放音频。现有 matching 链支持拒识但生产认证未就绪，因此实施保留 fail-closed，不把软件反例通过报告为声学质量通过。

- 2026-10-23：已完成实现与只读独立审查，无 Critical / Important 发现。新增反例先观察失败，再修复通过；未改动原 DER/JER 评分与全员认证门槛。
- 服务定向回归：`uv run --extra dev pytest -n 0 --no-cov -o addopts='' -q` 配合本次相关 13 个测试文件，275 passed。覆盖五/六人、拒识混合重叠、短插话、固定身份返回与后续漂移、握手策略、统计评分。所有输入均为构造证据，不是原始音频。
- macOS 定向回归：`swift test --package-path macos/SpeechRailApp --enable-swift-testing --filter 'MeetingSpeakerCapacityTests|MeetingSessionLifecycleTests|MeetingWindowMergeRegressionTests|RealtimeContractTests'`，118 XCTest 与 17 Swift Testing 用例通过。覆盖初始握手拒识、超额及短插话、持久化旧行、重连身份隔离和全文统计；未运行 UI 自动化。
- 原生验证：`swift run --package-path native/diarization SpeechRailDiarizationProtocolSelfTest` 与 `swift build --package-path native/diarization --product SpeechRailDiarizationWorker` 通过，无模型推理。App 包装构建 `bash scripts/macos_app_build.sh --configuration Debug` 通过，构建产物按包装流程清理，未安装。
- 静态核验：相关 Python Ruff、`python3 scripts/check_macos_test_target_coverage.py`、`git diff --check` 通过。原会议仅通过只读 SQLite 连接核对，42 行正文及归属等字段摘要与修改前一致。
- 运行态及回退：未重启、切档、安装、改写会议或提交。当前修改仅在工作区；尚未启用新行为，真实拒识后端声学认证未完成。将来启用须配套通过认证的策略与 worker；回退须成套恢复运行制品和策略，不能仅放宽容量字段。
