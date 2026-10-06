# CI 效率优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 保持全量检查及 80% branch coverage 门槛，端到端 CI 耗时降至原基线的 50% 以下。

**验收口径（用户 2026-10-06 确认）:** 常规缓存命中的完整 CI 严格低于 262.5 秒；冷缓存实测单独报告，不要求其减半。

**Architecture:** Python 的非 wheel 测试与唯一 wheel 构建并行，构建完成后 wheel 测试消费同一制品并合并 coverage。SwiftPM 测试和 Xcode App 构建使用独立 runner；编译缓存按工具链、平台、依赖及源码区分，只恢复内容未变的输入时间戳。

**Tech Stack:** GitHub Actions、uv、pytest-cov、SwiftPM、Xcode、Python 3.14、Bash。

**Spec:** 当前用户 CI 效率优化要求；约束来自 `AGENTS.md` 和 `docs/developers/testing-acceptance.md`。

## Global Constraints

- Python `>=3.14,<3.15`；产品 runner 保持 `macos-26` arm64。
- 不缩减检查、不运行 UI 自动化、不操作服务、不加载或下载模型。
- 用户已明确授权提交并推送 `codex/ci-efficiency`，顺序执行冷、热缓存完整 CI 并继续优化；不更改分支保护或合并 `main`。
- `Quality Gates`、`Gate Summary` 保持既有 required check 名称。
- Release 的 reusable CI 输入与 wheel artifact 名称保持稳定。

## Review Focus

- 任一测试或构建失败必须导致 gate 失败，后台构建必须被等待。
- wheel 测试只能消费本次构建成功产生的 wheel，不能消费旧制品。
- 两阶段 coverage 合并后仍强制 80%，不得只检查第二阶段覆盖率。
- 工具链或依赖变更不得命中不相容编译缓存；源码修改不得被时间戳恢复掩盖。
- PR 分类、Release 显式关闭 Swift、失败或意外 skip 都须正确汇总。

### Task 1: 修复 Python 制品复用

**Files:** `scripts/ci_python_gate.sh`、`tests/test_ci_python_gate.py`、`tests/test_github_workflows.py`、`.github/workflows/ci.yml`。

- [x] 用 fake uv 的 subprocess 回归证明：只 build 一次，非 wheel pytest 与 build 重叠；wheel 完成后才进入 wheel pytest。
- [x] 分别注入 build、普通测试、wheel 测试失败，证明错误未被掩盖。
- [x] 第一阶段暂缓 coverage report；第二阶段 `--cov-append` 并强制原门槛。
- [x] 使用 `uv run --no-sync pytest`，保持 editable sync 的 native-build opt-out。
- [x] 依据远端串行测试瓶颈，加入两个 pytest worker，按文件调度、关闭自动重启，并实测用例全集与 coverage；本机 3294 passed、1 skipped、82.94%，远端验收仍待完成。

### Task 2: 编译缓存及独立 Swift jobs

**Files:** `scripts/ci_build_cache.py`、`tests/test_ci_build_cache.py`、`.github/workflows/ci.yml`。

- [x] 回归证明仅相同 SHA-256 内容恢复 mtime；修改、新文件、删除、symlink 和越界路径均不被改写。
- [x] 缓存键包含 OS/arch、Xcode/SDK/Swift、锁定依赖、构建配置；源码 hash 作为精确 key 后缀。
- [x] SwiftPM 与 App build 各自恢复/保存缓存，`Gate Summary` 覆盖两条路径。
- [x] uv 使用官方 `prune-cache`，新缓存键不再恢复旧的约 1 GB 混合目录。

### Task 3: 验证及分析报告

**Files:** `docs/developers/ci-efficiency.md`、`docs/developers/testing-acceptance.md`。

- [x] 定向 pytest、Ruff、Bash 语法及 workflow shell 检查。
- [x] 记录近期成功全量 run 的端到端和 step 时长。
- [x] 区分 runner 实测、本地 fake 回归、冷缓存与热缓存估算。
- [x] 写清 `<50%` 验收条件与未执行的远端前后对比。
- [x] 修正三个 job 轮询点的过早退出，用受控 `running` 状态做回归。
- [x] 增加只读的端到端时间验收脚本，强制候选 SHA、完整门禁成功及严格 `<50%`。
- [ ] 优化分支远端全量 CI 实测低于 262.5 秒；提交、推送及触发运行已获明确授权。
- [x] 首轮冷缓存 497 秒、热缓存 363 秒均全量成功；明确记录未达标并继续优化。
- [x] 两个 pytest worker 的远端运行 331 秒，仍未达标；保持所有测试和覆盖率门槛。
- [x] 剖析并隔离五个流程测试模块的重复音高估计；真实音高算法专门用例继续执行，新增 fixture 边界回归先红后绿。
- [x] fixture 隔离后的本机完整门禁：3295 passed、1 skipped、82.93%，完整编排 42.72 秒。
- [ ] fixture 隔离后的远端缓存命中 CI 严格低于 262.5 秒。

## Execution

当前会话直接实施；用户已授权分析、优化、必要验证，以及优化分支提交、推送和冷、热缓存完整远端 CI。未授权合并、发布或运行态操作。
