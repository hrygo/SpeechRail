---
title: "CI 效率分析与优化验收"
status: active
version: "1.1.0"
date: 2026-10-10
---

# CI 效率分析与优化验收

**按用户确认的常规缓存命中口径，远端完整 CI 已从 525 秒降至 229 秒，减少 56.38%，严格低于 262.5 秒。** 达标 run 为 `37422635179`，实现候选 SHA 为 `64899395ab2a9e06a30befe32b26b866d3f4ca19`，七个 job 全部成功。优化包含构建复用、Swift jobs 并行、编译缓存、pytest 进程并行与流程测试的声学 fixture 隔离。所有原有测试、公共契约检查与 80% branch coverage 门槛保留；没有修改产品业务实现、发布流程输入或分支保护。

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
7. **流程测试重复执行声学计算。** `cProfile` 对 4 个音色并发用例记录了 204,456,960 次自相关生成器调用；这一小组的自相关累计约 16.51 秒，占总 19.47 秒的大部分。音高只用于预筛展示，不参与质量门禁。五个 fake-backend 流程测试模块共享 `tests/voice_test_fixtures.py` 中的确定性音高 fixture，仅在显式导入它的模块中生效，每个用例后恢复原函数；取消、幂等、并发、输入质量、声学报告与持久化断言保留。专门的 `test_voice_quality_gates.py` 继续使用真实算法验证参考频率及无声输入。新增回归令真实自相关函数调用直接失败，证明创建流程确实使用 fixture，并验证该测量值被写入候选记录；生产实现未改动。

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
- 最终五个模块的音高 fixture 隔离版本：真实完整编排 42.72 秒、退出码 0；非 wheel 3291 passed、原有 1 skipped（40.48 秒），wheel 4 passed（1.88 秒），合并 coverage 82.93%。native 热编译为 0.49 秒。与此前同机串行完整编排 151.26 秒相比减少约 71.8%；新增 fixture 边界回归包含在 3295 个通过用例中，真实音高算法专门用例未跳过。远端端到端仍需单独验收。

本地 App 验证使用隔离临时目录模拟 GitHub Actions 的 CI 环境，所有 App 构建均通过 `scripts/macos_app_build.sh --ci-derived-data`。不安装、不启动 App，不注册生产 helper，不运行 UI 自动化，不启停服务、不加载或下载模型。

## 远端验收与成本

用户已明确授权提交并推送 `codex/ci-efficiency`，顺序执行冷、热缓存完整 `workflow_dispatch` 并继续优化。首轮提交为 `a861198b99b3254627f9cdfdda4beb6bad23d4be`：

| Run ID | 编译缓存 | 端到端秒数 | 相对基线减少 | 非 wheel pytest 秒数 | 结论 |
|---|---|---:|---:|---:|---|
| 37418527900 | 冷 | 497 | 5.33% | 406.43 | 全量成功；时间未达标 |
| 37419281850 | 热 | 363 | 30.86% | 273.40 | 全量成功；时间未达标 |
| 37420187146 | 热，pytest 两个进程 | 331 | 36.95% | 230.75 | 全量成功；时间未达标 |
| 37422635179 | 热，两个进程及声学 fixture 隔离 | 229 | 56.38% | 127.81 | 全量成功；严格 `<50%` 达标 |

两次均为非 wheel 3290 passed、wheel 4 passed、原有 1 skipped，覆盖率 82.95%，所有七个 job 成功。冷缓存 Swift 测试步骤 264 秒（编译 193.78 秒、XCTest 1199 个用例 56.82 秒），App 构建约 308 秒；热缓存对应步骤降至 72 秒、75 秒。native worker 冷编译 203.48 秒，热编译 4.07 秒；日志均只有一次 wheel 构建。热缓存 uv 恢复仅约 5 MB，native 编译缓存约 527 MB。首次缓存上传与 runner 排队均计入端到端，未删除旧缓存。

两个进程的候选 SHA 为 `d0a3a7da2f93ff398b45ca79ab24e9efb4101ea7`；该候选仍为 3294 passed、1 skipped、82.95%，没有新增 skip 或 worker 重试。App job 曾排队约 100 秒，最终端到端仍计入这段等待。该提交已由另一流程于北京时间 13:53:23 通过 PR #274 合并，merge commit 为 `568485deb2b47fee3d22f153df075076932bca8a`；后续改动基于此提交继续。

最终达标运行核验时间为北京时间 2026-10-06 14:18：

- 非 wheel 3291 passed、wheel 4 passed，共 3295 passed；保留原有 1 skipped，合并 coverage 82.94%。两个 pytest worker 未自动重启，真实音高算法专门用例仍在全量套件中。
- SwiftPM 编译 4.90 秒，1199 个 XCTest 用例全部通过（53.59 秒），419 个 Swift Testing 用例、17 个 suite 也全部通过（3.41 秒）；Swift job 96 秒，App job 77 秒，Python job 189 秒，Package job 7 秒。质量、范围分类及最终汇总也全部成功。
- uv、native、SwiftPM、Xcode 缓存分别约 5、527、277、154 MB，三个编译缓存均命中精确 key。native 编译 7.48 秒，只有一次 wheel 构建；wheel 独立安装帮助检查、ZIP 校验、16,855,704 字节 native worker 内容检查及制品上传均成功。
- 端到端包括 runner 排队、缓存恢复、制品上传和 post-actions；从 run 创建到最后 job 完成为 229 秒。只读验收脚本验证候选完整 SHA、全量门禁和严格时限后退出 0。
- GitHub API 的所有 job 时长之和由 956 秒降至 423 秒，减少 55.8%；该和用于观察总工作量，不作为并行端到端时间或实际计费额。

**冷缓存与热缓存分别报告。** 冷缓存全量复测见下节；用户已明确无需冷缓存减半，冷缓存数据不并入热缓存收益。首轮 CI 优化与 fixture 调整均已合并保留。

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

## 冷缓存全量复测

冷缓存结果与常规缓存命中口径分别记录。基线仍为 run `37415078886` 的 525 秒；热缓存达标值 229 秒不变，冷缓存数据不并入该收益。

| Run ID | 事件 | 候选 SHA | 端到端秒数 | 相对基线减少 | 非 wheel pytest 秒数 | 结论 |
|---|---|---|---:|---:|---:|---|
| 38000384151 | pull_request #353 | `71b3a7ed8d793a52e377b939317fe7671bf0f248` | 408 | 22.29% | 184.01 | 七个 job 全成功；冷缓存不要求减半 |

核验时间：北京时间 2026-10-10 06:39:25–06:46:14（UTC 2026-10-09 22:39:25–22:46:14），端到端按 run 创建至 `Gate Summary` 完成计算。三个编译缓存均为首次创建：`native-v2`、`swift-test-v2`、`xcode-debug-v2` 的 restore 步骤分别只有 2、1、2 秒，日志明确 `Cache not found`；run 结束时三个缓存分别保存。setup-uv 缓存命中，约 5 MB（5,653,562 字节），恢复约 2 秒。

job 用时：`Change Scope` 9 秒、`Quality Gates` 34 秒、`Test (macos-26 / Python 3.14.7)` 288 秒、`Swift Package Tests` 383 秒、`macOS App Build` 340 秒、`Package wheel artifact` 8 秒、`Gate Summary` 3 秒，全部 success；job 时长之和 1065 秒。

冷缓存阶段拆分：

- Python：锁定依赖安装 6 秒；非 wheel pytest 3825 passed、1 skipped、184.01 秒（两个 worker，未自动重启）；wheel 阶段 4 passed、5.34 秒；合并 coverage 83.98%，通过 80% 门槛。只有一次 wheel 构建，wheel 独立安装检查、ZIP 校验与制品上传均成功。
- SwiftPM：冷编译从零开始，测试于该 step 开始约 4 分 36 秒后启动；XCTest 1391 个用例、0 failures（68.0 秒），Swift Testing 519 个用例、41 个 suite（3.53 秒）；独立 LLM 支持编译检查 14 秒。
- Xcode App：冷编译 303 秒；缓存 miss 后 `ci_build_cache.py` 无有效输入清单，改用 checkout timestamps，不伪造命中。
- 用例与门槛口径：保留既有 1 skipped，无新增 skip；80% branch coverage 门槛保持；`Quality Gates` 与 `Gate Summary` 为 required 检查且通过；无 worker 重试放绿。

冷缓存 408 秒高于热缓存 229 秒，差距来自三个编译缓存从零编译；相对优化前冷缓存 run `37418527900`（497 秒）减少 17.9%。用户已确认冷缓存不要求减半，本节补齐的阶段拆分与缓存证据满足 #286 的验收项。

回退：撤销本次缓存键与文档改动即可恢复原缓存口径；远端旧缓存不删除，新缓存前缀停止引用即可。

回退时仅撤销本轮 CI workflow、辅助脚本、包装脚本 CI 选项和相关测试/文档改动；不用恢复服务、App 安装、模型或数据。远端旧缓存无须删除，新缓存前缀停止引用即可。
