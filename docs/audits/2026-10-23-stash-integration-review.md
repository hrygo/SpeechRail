---
title: "stash 与主干差异审查"
status: active
date: 2026-10-23
---

# stash 与主干差异审查

## 范围与结果

- 审查对象：stash `ad17eb305cdf05abc35c9bdf713f2c9ed776293f`，原基线 `06f2a4bb`；主干审查基线 `62333cae`。
- 范围：28 个已跟踪文件和 3 个新增文件。逐文件比较 Git blob，阅读剩余差异并与主干后续提交、契约及定向回归核对。
- 14 个已跟踪文件与主干完全相同；另 13 个差异由主干后续修复或共享组件取代；Realtime 文档整理纳入。新增的两个契约 README 经校正后纳入；新增计划文件的全部内容已在主干中，并有更完整的后续记录。
- 最终修改仅为文档，不改 Python/Swift 实现、测试、OpenAPI、JSON schema 或 SQL 快照。保留创建拒绝恢复、结果未明时的幂等身份、音频校验失败保护、导出 UUID 路径处理及统一浮层。
- 原 stash 与分支的 Git bundle 备份保留在仓库外；提交完成并再次核对后才清理原 stash。备份保留原始对象及新增文件，可用于恢复，不把旧改动重新覆盖到主干。

## 逐文件处置

| 文件 | 审查结论与处置 |
|---|---|
| `contracts/openapi.yaml` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `contracts/realtime-openai.md` | 纳入中文整理；把窗口与匿名分人章节归入正文，保留窗口旧锚点；协议规则、预算与机器 schema 不变。 |
| `docs/developers/macos-app-audiobook.md` | 保留主干：导出失败已迁移到所属 Sheet 的操作浮层，不恢复旧内联说明。 |
| `docs/developers/macos-app-design-system.md` | 保留主干：统一 OperationFeedback 已覆盖有声书专用浮层；正文高度约束已包含在统一规则中。 |
| `docs/users/api-contract.md` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `docs/users/audiobook-workshop.md` | 保留主干：导出错误在当前导出面板浮层中展示，比 stash 的内联说明准确。 |
| `macos/SpeechRailApp/SpeechRailApp/AppModel.swift` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `macos/SpeechRailApp/SpeechRailApp/AppWorkflowTypes.swift` | 保留 7efb6fe3 的 creationWasRejected 状态，避免撤销明确创建拒绝后的恢复。 |
| `macos/SpeechRailApp/SpeechRailApp/AudiobookBookWorkspaceView.swift` | 保留 fe55ca79 的 Sheet/Popover 浮层；制作错误由工坊浮层展示，不重复放回进度栏。 |
| `macos/SpeechRailApp/SpeechRailApp/AudiobookProductionController.swift` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkflowModel.swift` | 保留错误 occurrence ID，重复同文错误仍能作为新反馈出现。 |
| `macos/SpeechRailApp/SpeechRailApp/AudiobookWorkshopView.swift` | 保留统一浮层、制作错误独立展示与关闭确认；不恢复专用组件、计时器和内联导入导出错误。 |
| `macos/SpeechRailApp/SpeechRailApp/CreatorServiceClient.swift` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `macos/SpeechRailApp/SpeechRailApp/CreatorSurfaceViews.swift` | 保留 deff3a31/fe55ca79：生成、取消、试听、音色详情、查询、重命名、导出等恢复入口已移至所属宿主浮层；读取失败仍显示可重试不可用状态。 |
| `macos/SpeechRailApp/SpeechRailApp/CreatorWorkflowErrors.swift` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `macos/SpeechRailApp/SpeechRailApp/ServiceAPIClient.swift` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `macos/SpeechRailApp/SpeechRailApp/SpeechRailDesignTokens.swift` | 仅注释不同；主干的共享浮层正文上限覆盖 stash 的简短提示说明，保留主干。 |
| `macos/SpeechRailApp/SpeechRailApp/VoiceWorkflowModel.swift` | 保留明确拒绝时允许编辑/本地取消、结果未明时恢复原幂等身份、重试前清除拒绝结论的后续修复。 |
| `macos/SpeechRailApp/SpeechRailMacControlTests/AppModelTests.swift` | 保留主干新增的 5 个创建恢复回归及 fake/等待支持；stash 不含这些后续用例。 |
| `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookProductionTests.swift` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `macos/SpeechRailApp/SpeechRailMacControlTests/AudiobookWorkflowTests.swift` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `macos/SpeechRailApp/SpeechRailMacControlTests/ServiceContractTests.swift` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `src/speechrail/cli.py` | 保留 aa58fc14 的 dict[str, object] 类型标注；media.export 失败的 event=result 行为已包含。 |
| `src/speechrail/http/routes/voice_designs.py` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `src/speechrail/media/manifest.py` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `tests/test_cli_machine_output.py` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `tests/test_media_manifest.py` | 与审查基线主干逐字节一致，已有实现、契约或回归完整保留。 |
| `tests/test_voice_design_workflow.py` | 保留主干新增的归一化拒绝不创建候选的参数化回归。 |
| `contracts/README.md` | 补入导航与边界说明；按 OpenAPI 校正错误的 /v1/speechrail/jobs 为 /v1/jobs，并移除音色扩展统一路径前缀的错误断言。 |
| `contracts/audiobook-schema/README.md` | 补入快照导航与校验规则；v7 实际新增 sources 加工文本字段及 characters.source_id，修正文档中的版本含义和重复字。 |
| `docs/superpowers/plans/2026-10-22-voice-design-recovery.md` | 保留主干 51 行记录：已包含 stash 的全部 35 行，并追加 PR 交付、创建拒绝恢复与后续验证记录。 |

## 文档校正

`contracts/README.md` 的接口导航以 `openapi.yaml` 的实际路径为准：音色操作并非全部采用 `/v1/speechrail/*` 前缀，durable job 的路径为 `/v1/jobs`。数据库快照说明以 v6/v7 DDL 差异与 `AudiobookStoreSchema.currentUserVersion` 为准，不沿用 stash 中错误的功能版本描述。

Realtime 的英文窗口说明翻译为中文并放入第 6 节，匿名分人说明归入第 5.2 节；保留 `revision-window-transcription` 锚点。既有规则、预算、失败边界和机器 schema 未改变，协议版本和生效日期保持不变。

## 验证（2026-10-23）

- Python 定向回归：`uv run --no-sync --extra dev pytest --no-cov tests/test_voice_design_workflow.py tests/test_cli_machine_output.py tests/test_media_manifest.py tests/test_openapi_contract.py tests/test_realtime_current_schema.py tests/test_audiobook_schema_contract.py`，118 项通过。
- Swift 定向回归：`swift test --package-path macos/SpeechRailApp --disable-automatic-resolution --enable-swift-testing --filter 'AudiobookProductionTests|AudiobookWorkflowTests|AppModelTests.testVoiceDesign|AppModelTests.testFailedVoiceDesign|ServiceContractTests.testVoiceDesign'`，实际执行 154 项 XCTest，0 失败。编译有既有警告，未在本次文档恢复中扩展修改范围。
- REST 路由契约：39 个路径、47 个操作通过；Realtime：61 个 fixture、65 个字段通过；SQLite 当前结构与历史快照基线校验通过；用户 API 文档：39 个路径、21 个错误码、9 个模型 alias 通过。
- 新增契约 README 的本地链接与所列精确 REST 路径逐项核对；提交前检查暂存差异、空白与敏感字段，并确认实现和测试的 Git blob 与审查基线一致。
- 无 App 安装、服务启停、档位变更、模型加载下载、真实音频生成或前台 UI 自动化；未将这些定向回归报告为全量测试、真实窗口交互或模型质量验收。

## 回退

本提交只涉及文档，可使用 `git revert <本次提交>` 撤回。原 stash 的完整内容另有仓库外 Git bundle 备份；需要追溯原始差异时，从备份读取 stash 对象，按本表区分被后续修复取代的旧内容，避免整份恢复而回退主干行为。
