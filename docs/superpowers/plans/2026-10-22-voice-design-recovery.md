# 音色保存失败恢复实施计划

**Goal:** 支持修改参考文案重新生成，区分重新校验与重新生成，并显示比对差异及试听。

**Architecture:** 保留原有确认与发布状态机、92% 确认门槛及数字一致性要求。确认拒绝响应增加有界的差异诊断；App 在内存中展示，不记录正文或转写。重新生成使用新 voice ID 和幂等键，清除旧验收与播放确认；网络重试沿用当前请求身份。

**Tech Stack:** FastAPI / Python 3.14、Swift 6 / SwiftUI、pytest 与 SwiftPM。

**Spec:** 当前会话用户明确要求的恢复流程。

## 约束与检查重点

- 保留现有未提交改动；不安装、不重启、不运行真实模型或前台 UI 自动化。
- 错误详情绑定候选版本，差异片段有界，不在日志记录文案或转写。
- 重新校验不生成音频；重新生成不复用旧验收与幂等键。
- 取消、迟到响应、请求失败均不得提升候选状态或绕过门槛；被替代候选先标记为取消，避免占用活动候选额度。取消失败可重试，用户放弃替代时不生成新音频。
- 浮层正文滚动，关键动作固定；键盘焦点与 Escape 保持可用。

## 实施

- [x] 为确认拒绝添加分数、数字一致性及有界差异的回归测试，确认先失败，再实现并更新 OpenAPI 与用户文档。
- [x] 为重新校验、编辑后重新生成、新请求身份和清除旧证据添加 Swift 回归，确认先失败，再实现模型与客户端。
- [x] 补齐失败详情、编辑和试听界面，约束浮层与操作区，更新设计系统说明。
- [x] 运行定向 pytest、SwiftPM 回归、仓库包装 App 构建及差异检查；记录未实测 UI 项。不提交或发布。

## 验证记录（2026-10-22）

- `uv run --extra dev pytest tests/test_voice_design_workflow.py tests/test_openapi_contract.py -q --no-cov`：66 项通过；诊断移除的反例按预期失败，已恢复实现。
- `swift test --package-path macos/SpeechRailApp --filter 'ServiceContractTests.testVoiceDesign|AppModelTests.test.*VoiceDesign|AppModelTests.testFailedVoiceDesign'`：13 项通过。覆盖新身份、原音频重新校验、非法文案、重新生成响应丢失、旧候选取消失败后放弃替代，以及无诊断响应的稳定错误处理。
- `scripts/macos_app_build.sh --configuration Debug`：成功，包装脚本正常退出，未导出或安装 App。
- Ruff、修改的 Python 路由 Mypy、`scripts/check_openapi_contract.py` 和 `git diff --check` 通过。
- 未执行前台 UI 自动化、真实音频生成或听评；滚动、首次 Escape、最小窗口和完整业务流程尚无实机验证。既有 92% 确认门槛、数字一致性和后续验收策略未修改。
- 保留开始任务时已有的有声书及 Realtime 未提交改动；不提交、推送、安装或重启。

回退仅需逆向本任务涉及的恢复流程、诊断字段及对应文档／测试差异；保留其他未提交改动。运行中的 App、服务、档位与用户数据未变，无需运行态回滚。

## PR 交付

用户追加授权提交 PR 后，从最新 `origin/main` 创建隔离分支 `codex/voice-design-recovery`，仅转入本修复的代码、契约、文档与测试，在隔离版本重新运行定向回归和 App 包装构建。此前“不提交、推送”的记录描述原实施阶段，本次交付按追加授权执行；安装与运行态保持不变。
