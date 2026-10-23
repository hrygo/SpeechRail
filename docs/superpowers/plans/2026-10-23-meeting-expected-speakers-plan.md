# 会前预计发言人数实施方案

> **For agentic workers:** 使用 executing-plans 与 test-driven-development；用户已明确批准方向与实施，按任务顺序执行，最后独立审查。未经要求不提交、安装或改变运行态。

**Goal:** 会前提供不确定、2 人、3 人、4 人、超过 4 人；默认不确定，将选择真正接入本场稳定身份预算，超额或不确定保留未识别和正文。

**Architecture:** 会前值仅作用于本场，2/3/4 对应身份上限，不确定和超过 4 对应预算 4；不强制凑数、不改变声学匹配阈值、不轮换身份。App 通过 meeting_dynamic 的 max_speakers 请求，服务校验并冻结到本连接匹配器，native preflight 回显有效预算；握手不符拒绝分人，文字回退。人数限制不是实际参与人数认证。

**Tech Stack:** SwiftUI、Swift、Python 3.14、Realtime JSON Schema、pytest、XCTest/Swift Testing。

**Spec:** 本会话用户当前请求及上方已批准的预计人数方向。

## Global Constraints

- 身份预算最多四，不改写原会议、持久化 schema、人工标注或正文；未识别保留统计分母。
- 不加载/下载模型，不安装/重启/切档，不执行 UI 自动化，不自动提交或推送。
- 保留前一任务修改与其他任务的 docs/developers 改动。
- 确定性证据测试不等于声学准确率；原始会议无音频，不能宣称同音频重放。

## Review Focus

- 填少：已确认身份不轮换，新增声音拒识，不能挤进既有身份。
- 填多：证据不足不晋升、不凑人数，短插话继续未识别。
- 中途新增及重连：预算沿用本场选择，跨连接无身份证明仍拒识；下一场默认不确定。
- 请求、回显及 worker 预算一致；非法、错误后端、音频开始后修改不得静默忽略。
- 认证容量小于请求不扩大认证范围；保留原记录和未知占比。

## Task 1: 预算协议及匹配器

Files: compatibility/openai_realtime.py、application/realtime_openai.py、application/realtime_auxiliary.py、backends/diarization/meeting.py、runtime/diarization_worker.py、native/diarization 的 matcher/worker/self-test、相关 tests 与 contracts。

- [x] RED：协议接收 1..4 max_speakers 并拒非法/错误后端；native 小预算下第三人未知、原人返回、填多不凑数、短插话未知。
- [x] 服务将请求冻结到本场 owner/engine/worker；匹配器用 min(请求预算, 认证容量)，不改全局策略文件；IPC 回显核对防旧二进制忽略参数。
- [x] GREEN：协议/服务端到端 fake 和 native self-test，覆盖音频后更改拒绝和预算会话隔离。

## Task 2: 会前 UI 与客户端链路

Files: MeetingView/MeetingViewSourceSetup、MeetingSession/Dependencies/ProductionWiring、RealtimeASRClient、RealtimeContractTypes、相关 macOS tests。

- [x] RED：默认/所有选项预算映射、会话配置与重连、wire 序列化及不符回显。
- [x] 增加原生 Picker 与简明帮助文案；选择仅本场，不写全局偏好或旧记录；实际传参且验证回显。
- [x] GREEN：定向 Swift 测试，检查测试 target 注册；不接管 UI。

## Task 3: 文档、审查与交付

- [x] 同步协议 Schema 和正式用户文档，记录选错的拒识代价与未识别统计口径。
- [x] 相关定向回归、必要构建、静态检查；独立审查本次增量，修复重要问题。
- [x] 原会议只读核对摘要；记录测试结果、运行态未变、无原音频验证限制及回退方式。

## 执行证据（2026-10-23）

- 协议、匹配器、会前枚举/配置与握手回退均先观察 RED，再实现 GREEN。原生用构造的不同声音向量验证：预算 2 时中途第三人拒识且第一人返回仍保持身份；预算 4 但实际仅一人时不凑数，短插话拒识，后来具备充分独占证据的新声音可建立第二身份。输入不是原始音频。
- 服务定向回归（本次新文件与既有 13 个相关文件）：`uv run --extra dev pytest -n 0 --no-cov -o addopts='' -q tests/test_meeting_expected_speakers.py tests/test_stable_four_attribution.py tests/test_stable_speaker_metrics.py tests/test_meeting_diarization_contract.py tests/test_meeting_diarization_session.py tests/test_diarization_attribution.py tests/test_diarization_owner.py tests/test_diarization_sdk.py tests/test_diarization_extensions.py tests/test_diarization_session.py tests/test_diarization_alignment.py tests/test_diarization_worker.py tests/test_realtime_current_schema.py tests/test_capability_snapshot.py`，299 passed。
- Swift 定向回归：`swift test --package-path macos/SpeechRailApp --enable-swift-testing --filter 'MeetingSpeakerCapacityTests|MeetingSessionLifecycleTests|MeetingWindowMergeRegressionTests|RealtimeContractTests'`，120 XCTest、18 Swift Testing 用例通过。包括本场 2 人传参、重连仍为 2、下一场默认不确定及预算不符时文字回退。
- 原生协议 self-test 与 worker 构建通过：`swift run --package-path native/diarization SpeechRailDiarizationProtocolSelfTest`、`swift build --package-path native/diarization --product SpeechRailDiarizationWorker`；无模型加载或推理。
- App 包装构建 `bash scripts/macos_app_build.sh --configuration Debug` 通过，临时 App 按包装流程清理，未安装；未执行真实窗口或 UI 自动化。
- 相关 Python Ruff、`python3 scripts/check_macos_test_target_coverage.py`、`git diff --check` 通过。容量条件 4→3 的变异被测试捕获，源码已恢复；恢复后使字节码缓存失效，以上 299 项为恢复后完整定向回归结果。
- 独立审查发现一项 Important：native 启动参数列表覆盖了 max_speakers；已修复，并加 2/3/4 三种真实 start()→进程参数边界回归，修复前三项均失败。审查未发现其他 Critical/Important。
- 原会议只读核对：42 行正文、归属、顺序及人工标注字段摘要与前次基线相同；未更新数据库或旧记录。
- 运行态未改动：未安装、重启、切档、改认证策略或提交。真实声学拒识质量未认证，原始会议没有音频，未完成同音频重放。回退需恢复本次配套 App/服务/native 制品；没有持久化格式迁移或历史记录回写。
