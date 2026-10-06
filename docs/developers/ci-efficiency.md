---
title: "CI 效率分析与优化验收"
status: active
version: "1.0.2"
date: 2026-10-06
---

# CI 效率分析与优化验收

已实施构建复用、Swift jobs 并行与编译缓存；首次远端冷、热缓存运行均成功，但尚未达标，继续加入 pytest 进程并行。**GitHub 端到端 `<50%` 目标仍待当前改动的远端实测**，本机用时不能替代 runner 数据。所有原有测试、公共契约检查与 80% branch coverage 门槛保留；没有修改产品代码、发布流程输入或分支保护。

## 基线与计时口径

2026-10-06 查询 GitHub Actions 的成功全量 `main` push runs。端到端耗时从 run 创建到 `Gate Summary` 完成，包括调度、checkout、缓存传输、构建、测试、制品及清理；job 用时单独列示，不能将并行 job 的和当作用户等待时间。

| Run ID | HEAD | 端到端秒数 | Python job 秒数 | Swift/App job 秒数 |
|---|---|---:|---:|---:|
| 37415078886 | `7d67affc` | 525 | 390 | 504 |
| 37412148790 | `47b97bff` | 599 | 484 | 578 |
| 37409699359 | `f04cc526` | 551 | 518 | 437 |
| 37406799555 | `65df3aa6` | 577 | 434 | 555 |

最近四次中位数为 564 秒。最新、与工作区基线同 HEAD 的 run 为 525 秒（北京时间 12:43:47–12:52:32）；本次采用更严格的 **低于 262.5 秒，即 4 分 22.5 秒** 作为验收目标。其 Python 构建/测试步骤为 328 秒，uv 缓存恢复 37 秒；SwiftPM 测试为 271 秒，随后 App 构建为 220 秒。

用户于 2026-10-06 明确确认：**常规缓存命中的完整 CI 达标即可**。完全冷缓存仍单独记录，不要求其减半，也不得把热缓存收益写成冷缓存收益。

原始 job/step 时间来自 `gh run view <run-id> --json jobs`；Python 构建记录来自 `gh run view 37412148790 --job 112102766033 --log`。原始日志和 API 输出保留在仓库外，只在本文记录聚合数值。

## 瓶颈与处理

1. **重复 wheel 构建及目录竞争。** 旧 workflow 虽然后台构建 wheel，但直到 pytest 结束才写 `SPEECHRAIL_WHEEL_PATH`。`tests/test_wheel_contents.py::_wheel_for_test` 在没有此变量时自行 `uv build`，两条路径操作同一 native `.build`。修复为：唯一后台构建与非 wheel 测试并行；等待构建成功后，导出制品路径再运行 wheel 测试。构建失败不执行 wheel 测试，也不上传制品。
2. **Swift 串行关键路径。** SwiftPM 测试和 Xcode App 编译在不同 runner 上独立运行，避免把两个编译时长相加。`Gate Summary` 同时等待它们，支持全量、PR 分类和 Release 显式关闭 Swift 的路径；任一选中 job 的失败、取消或意外跳过均不能放绿。
3. **每次从头编译。** native、SwiftPM 和 Xcode 各有独立缓存，包含 OS/arch、实际 Xcode/Swift/SDK 指纹、依赖锁及构建配置；源码 hash 作为精确 key 后缀，同工具链/依赖的前缀允许增量复用。`scripts/ci_build_cache.py` 只恢复 SHA-256 相同的跟踪输入 mtime，变更、新增、删除、symlink、越界或损坏元数据不会被伪装为旧输入。
4. **缓存传输比安装昂贵。** 代表性 run 的 uv 缓存为 993,703,256 字节，恢复约 45 秒，而依赖安装为 2 秒。改用锁定版本 `setup-uv` 的 `prune-cache: true`，用新 suffix 隔离旧的大缓存，不修改 uv 版本或删除远端缓存。新缓存体积及网络节省仍须从远端日志确认。
5. **轮询过早退出。** 本地全量验证发现两个既有用例在 `queued → running` 时退出，却立即断言 `completed`。三个相关轮询点现在等待 terminal state，保留原超时与结果断言。通过 `Future` 控制 fake processor 完成，让用例必然观察 `running`，不靠增加 sleep 或重试掩盖问题。
6. **pytest 串行执行。** 远端热缓存已将 native 编译降至 4.07 秒，但非 wheel 测试仍需 273.40 秒。增加开发依赖 `pytest-xdist==3.8.0`（锁定于 `uv.lock`，唯一新增传递依赖为 `execnet==2.1.2`），非 wheel 测试用两个独立进程、`--dist loadfile` 保持同文件用例和 fixture 在同一进程。`pytest-cov` 合并两个 worker 的数据，再由 wheel 阶段追加并强制 80%。`--max-worker-restart=0` 禁止通过自动重启 worker 重试放绿。

## 本地验证

核验日期：2026-10-06。Python 3.14.7；本机 Xcode 27.0 / Swift 6.4 / arm64，与 GitHub `macos-26` 的环境不同。

- CI 脚本、缓存安全、App 清理、workflow 汇总、分类及受影响 job 测试：146 个用例通过。构建/测试各类失败均有 fake subprocess 注入；轮询的两个原失败用例在可控 `running` 下先红后绿。
- Actionlint v1.7.12、Ruff、Bash 语法与 `git diff --check` 通过。
- 初次真实 Python 两阶段编排：158.14 秒；native worker 只构建一次，43.07 秒；wheel 测试 4 个通过，合并 coverage 82.94%。该次全量测试有上述两个轮询失败，**不能作为成功耗时验收**。
- App 包装脚本真实构建：独立空 DerivedData 为 38.86 秒，复用编译输出为 1.57 秒。两次成功且退出后均不存在临时 App 包；保留的仅是编译缓存。这里的“空”指本次 DerivedData，不代表系统所有编译缓存都冷。
- 模拟新 checkout 改写输入 mtime，恢复 258 个内容未变的跟踪输入后，App 构建为 1.61 秒；成功且临时 App 包已清除。所有输入时间戳最终还原，不改写源码内容。
- 独立临时 Swift package 的真实增量构建验证：修改源码后，helper 只恢复未变输入时间戳；`swift build` 重新编译，二进制输出由 `before` 变为 `after`。临时 fixture 已清理。
- 最终真实 Python 两阶段编排：151.26 秒、退出码 0。非 wheel 测试 3278 个通过，wheel 测试 4 个通过，合计 3282 个通过；保留原有 1 个 skip，合并 coverage 82.94%。复用 native 编译输出时 worker 构建为 0.36 秒，wheel 仍由本次 `uv build` 重新生成，不缓存旧 wheel。
- 本次 wheel ZIP 完整性检查通过，并包含 16,853,384 字节的 `speechrail/_native/SpeechRailDiarizationWorker`。
- 以上本地成功数值不构成 GitHub 端到端减半证明。
- 耗时验收脚本及 CI 相关定向回归共 69 个通过。脚本以候选完整 commit SHA 和全量门禁为前提，拒绝失败、跳过、不完整或其他 workflow 的运行；不会用可变的 `updatedAt` 或并行 job 用时之和计算耗时。使用真实优化前 run 作为候选的反例已被拒绝。
- 不采用整模块编译：在独立 DerivedData 中启用 `SWIFT_COMPILATION_MODE=wholemodule`、关闭 index store 的 App 构建成功，但本机用时 95.25 秒，比默认编译方式的 38.86 秒更慢；该试验不进入 CI 配置，临时 App 包已清除。
- 两个 pytest worker 的真实完整编排：80.16 秒、退出码 0；非 wheel 3290 passed、原有 1 skipped，wheel 4 passed，合并 coverage 82.94%。与此前同机串行编排 151.26 秒相比减少约 47%；该比较包含新加的 12 个 CI 验收测试，远端收益仍须单独实测。

本地 App 验证使用隔离临时目录模拟 GitHub Actions 的 CI 环境，所有 App 构建均通过 `scripts/macos_app_build.sh --ci-derived-data`。不安装、不启动 App，不注册生产 helper，不运行 UI 自动化，不启停服务、不加载或下载模型。

## 远端验收与成本

用户已明确授权提交并推送 `codex/ci-efficiency`，顺序执行冷、热缓存完整 `workflow_dispatch` 并继续优化。首轮提交为 `a861198b99b3254627f9cdfdda4beb6bad23d4be`：

| Run ID | 编译缓存 | 端到端秒数 | 相对基线减少 | 非 wheel pytest 秒数 | 结论 |
|---|---|---:|---:|---:|---|
| 37418527900 | 冷 | 497 | 5.33% | 406.43 | 全量成功；时间未达标 |
| 37419281850 | 热 | 363 | 30.86% | 273.40 | 全量成功；时间未达标 |

两次均为非 wheel 3290 passed、wheel 4 passed、原有 1 skipped，覆盖率 82.95%，所有七个 job 成功。冷缓存 Swift 测试步骤 264 秒（编译 193.78 秒、XCTest 1199 个用例 56.82 秒），App 构建约 308 秒；热缓存对应步骤降至 72 秒、75 秒。native worker 冷编译 203.48 秒，热编译 4.07 秒；日志均只有一次 wheel 构建。热缓存 uv 恢复仅约 5 MB，native 编译缓存约 527 MB。首次缓存上传与 runner 排队均计入端到端，未删除旧缓存。

首次实测证明编译缓存有效，但单靠缓存仍不达标；后续候选需验证 pytest 并行。**冷缓存与热缓存不混为一个收益值，任何未达标运行都不能写成目标完成。**

至少检查：

- 所有选中检查、wheel 独立安装检查、native worker 内容检查及 package job 成功。
- pytest 用例全集覆盖且合并 coverage ≥80%；无额外 skip、无重试放绿。
- 端到端耗时严格小于 262.5 秒；若队列主导，另外列纯执行耗时，并保留端到端未达标结论。
- 缓存命中/传输成本、native 构建次数、Swift 两条路径及制品上传耗时均有 step 证据。
- 修改 Swift 源码仍会编译并执行测试；工具链/依赖变更进入新的缓存分区。

完整候选运行结束后，执行只读检查：

```bash
uv run --no-sync python scripts/check_ci_efficiency.py \
  --baseline-run 37415078886 \
  --candidate-run "$CI_CANDIDATE_RUN_ID" \
  --candidate-sha "$(git rev-parse HEAD)"
```

`CI_CANDIDATE_RUN_ID` 必须来自已授权运行的实际 run ID，候选提交必须是已推送并运行的优化提交。退出码 0 表示完整成功 CI 的耗时严格低于基线一半，1 表示未达到时间目标，2 表示证据不完整或不匹配。脚本只读取 GitHub，不触发或修改运行；coverage、用例数和缓存状态仍须从对应 run 日志核对。

拆分后增加一个 macOS job 的固定启动/checkout 成本，但编译及测试工作量不增加；取消重复 wheel 构建及热缓存收益预期降低 runner 总分钟数。精确计费变化依远端 job 总分钟数确认，当前不承诺节省比例。

回退时仅撤销本轮 CI workflow、辅助脚本、包装脚本 CI 选项和相关测试/文档改动；不用恢复服务、App 安装、模型或数据。远端旧缓存无须删除，新缓存前缀停止引用即可。
