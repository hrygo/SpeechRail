---
title: "远端开发检查与差异交付"
status: active
version: "1.0.0"
date: 2026-10-23
---

# 远端开发检查与差异交付

远端开发节点使用独立 Git checkout 和项目虚拟环境，按任务固定源码提交、检查范围和交付路径。无模型检查适合后台执行；检查通过只证明所选范围，不代表完整 CI、真实语音质量或 macOS App 验收通过。

## 1. 环境与任务边界

- 使用项目要求的 Python `>=3.14,<3.15`，依赖按 `uv.lock` 同步。记录 `uv --version`；旧版 uv 无法接受锁文件时，先对齐任务工具版本，不重新生成锁文件。登录 shell 的索引覆盖也可能与锁文件登记的源冲突；仅对当前任务撤除已确认的覆盖，不改用户全局镜像配置或在报告中输出可能含凭据的索引值。
- 每个节点保留独立 checkout；同节点并行任务使用独立 worktree。默认一个主要执行任务，是否增加并发以实际内存和任务行为为依据。
- 同步 Git 跟踪的源码、契约和测试。模型、私有环境文件、登录凭据、真实音频、日志、音色数据和生产运行目录均不随项目迁移。
- 任务开始记录基线提交、目标文件、明确的检查命令和预期结果。任务分支使用 `codex/` 前缀；不要在主分支直接实施试运行。
- Python 无模型检查不需要完整 Xcode；App 构建、Swift 测试、真实 worker 和前台 UI 操作按各自开发与授权要求另行执行。

## 2. 固定源码与依赖

在已建立的远端 checkout 中先确认 `git status --short` 没有未知修改，再选择任务基线：

```bash
git status --short
git fetch --no-tags origin
# BASE_COMMIT 使用任务指定的完整提交 SHA。
git switch -c codex/remote-checks "$BASE_COMMIT"
git rev-parse HEAD
uv --version

# 选择该节点已有的 Python 3.14，避免跟随全局默认 Python。
SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1 \
  uv sync --locked --python 3.14 --extra dev --extra mcp
```

`SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1` 与质量门禁保持一致，只跳过当前检查不消费的 native worker 编译。它不产生可发布或可安装的完整 native 制品。后续使用 `--no-sync`，避免每条检查重新触发依赖同步。

若 macOS CLT 在构建 `meeteval` 时报告 C++ 标准头文件 `ios` 不存在，先用最小编译探针确认。只有 SDK 中头文件存在且显式搜索可通过时，才对当前同步进程设置 `CXXFLAGS`：

```bash
SDK_PATH=$(xcrun --show-sdk-path)
printf '#include <ios>\n' | clang++ -x c++ -std=c++11 \
  -isystem "$SDK_PATH/usr/include/c++/v1" -fsyntax-only -
CXXFLAGS="-isystem $SDK_PATH/usr/include/c++/v1 ${CXXFLAGS:-}" \
  SPEECHRAIL_SKIP_NATIVE_WORKER_BUILD=1 \
  uv sync --locked --python 3.14 --extra dev --extra mcp
```

这只是当前依赖构建的搜索路径处理，不证明系统工具链完整；探针仍失败时保留错误证据，单独处理工具链，不改锁文件规避。

## 3. 限定的无模型检查

以下是一组适合验证远端执行链的契约检查示例；业务任务应按实际改动重新确定范围：

```bash
uv run --no-sync ruff check \
  src/speechrail/domain/contracts.py \
  tests/test_domain_contracts.py \
  tests/test_openapi_contract.py \
  tests/test_current_boundaries_contract.py

uv run --no-sync pytest --no-cov \
  tests/test_domain_contracts.py \
  tests/test_openapi_contract.py \
  tests/test_current_boundaries_contract.py

git diff --check
```

这里的 `--no-cov` 用于限定用例检查，不更改完整 Python 门禁的 80% coverage 要求。保留 pytest 实际发现、通过、失败和跳过数量；仅有退出码或脚本打印成功不能证明用例执行。不要把无模型测试扩展为服务启停、模型下载或 UI 接管。

## 4. 差异交付与本机整合

任务结束报告基线 SHA、分支、完整检查命令、实际结果、未验证项和变更路径。日志只保留必要摘要，不包含音频、转写正文或凭据。

对于尚未提交且范围明确的文档或代码差异，可用路径限定 patch 交付。在远端先用 `git status --short` 核对目标；新文件需以 `git add -N` 纳入 diff，不能靠普通 `git diff` 发现未跟踪文件。下例以本文档作为交接范围：

```bash
git add -N -- docs/developers/remote-worker-checks.md
git diff --check
git diff --binary --full-index "$BASE_COMMIT" -- \
  docs/developers/remote-worker-checks.md > "$PATCH_PATH"
```

`PATCH_PATH` 指向仓库外、任务专属的非敏感制品目录。传回本机后，先核对基线、patch 路径与差异内容，再检查目标文件是否被其他任务修改：

```bash
git status --short
git apply --stat "$PATCH_PATH"
git apply --check "$PATCH_PATH"
git apply "$PATCH_PATH"
git diff --check
```

`git apply --check` 只检查能否应用；审查仍需确认含义、范围和验证证据。发现基线漂移或同文件并行修改时先协调，不用强制覆盖或自动三方应用掩盖冲突。提交、推送、合并和发布按项目授权分别处理。

## 5. 相关入口

- [测试与验收](testing-acceptance.md)：完整门禁及不同证据的适用范围。
- [开发者上手指南](development-guide.md)：项目环境和开发入口。
- [macOS App 开发与测试](macos-app-development.md)：App 与 Swift 相关验证。
