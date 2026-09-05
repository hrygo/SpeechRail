---
title: "SpeechRail × Sona 讲话人分离端到端验收与发布就绪报告 (SPK-E2E-1)"
status: accepted
type: acceptance_report
category: diarization
version: "1.0.0"
date: 2026-09-06
owners: [speechrail-core, sona-core]
tags: [speechrail, diarization, e2e, acceptance, spk-e2e-1]
---

# SpeechRail × Sona 讲话人分离端到端验收与发布就绪报告 (SPK-E2E-1)

> 验收日期：2026-09-06<br>
> 责任团队：SpeechRail Core Team, Sona Core Team<br>
> 设计规格：[SpeechRail 端到端设计](../architecture/speaker-diarization-e2e-design.md) 与 [Sona 端到端设计](../../../sona/docs/architecture/speaker-diarization-e2e-design.md)<br>
> 实施计划：[SpeechRail R0–R5 实施计划](../superpowers/plans/2026-09-05-speaker-diarization-e2e.md) 与 [Sona S0–S4 实施计划](../../../sona/docs/superpowers/plans/2026-09-05-speaker-diarization-e2e.md)<br>
> 关联报告：Sona 侧 [2026-09-06 联合验收报告](../../../sona/docs/operations/speaker-diarization-e2e-acceptance-2026-09-06.md)

---

## 1. 验收概述与发布就绪状态

本报告汇总 SpeechRail 与消费端 Sona 针对 **SPK-E2E-1**（会议多讲话人分离与流式归属持续流）的端到端实现、协议协商、评测套件及联合联调证据。

经过双方系统化重构与严格质量门禁验证：
1. **SpeechRail 侧**：R0–R4（全局采样时标、状态机、扩展契约、归属账本、结束屏障）全量闭环交付；修复了对齐不可用/晚到单元的生命周期漏洞；R5 离线评测套件（`tools/evaluate_diarization_e2e.py` 与 `tests/test_diarization_metrics.py`）全功能就绪并通过 8 项数学与契约验证。
2. **Sona 侧**：S0–S4 协议协商、不可变正文持久化、PostgreSQL 加法事务、UI 原位渲染与联合集成测试已在 commit `e8817fc` 闭环交付。
3. **两端兼容性**：新旧 Rail × 新旧 Sona 四组合兼容矩阵全部跑通，支持安全单向平滑灰度与零停机协议回退。

**综合判定：SpeechRail 侧功能实施与测试全部通过（ACCEPTED），具备受控灰度发布条件。**

---

## 2. 代码基准与门禁结果

### 2.1 版本与提交基准

| 维度 | SpeechRail | Sona |
|---|---|---|
| **代码仓库 / 分支** | `SpeechRail` @ `master` (`29faed0`) | `sona` @ `main` (`e8817fc`) |
| **Python / 运行时** | Python `>=3.12,<3.13` (3.12.14), uv, FastAPI | Python 3.12.14, uv, React 19, Vite, PostgreSQL |
| **协议扩展版本** | `speechrail.diarization.v1` | `speechrail.diarization.v1` (opt-in) |
| **测试框架** | pytest, ruff, mypy, redocly | pytest, ruff, mypy, vitest |

### 2.2 SpeechRail 门禁与测试覆盖

```bash
# 1. Diarization 扩展与评测套件
uv run --extra dev pytest tests/test_diarization*.py --no-cov -q
# 结果：67 passed in 1.45s

# 2. Python 代码风格与类型安全
uv run --extra dev ruff check src tests tools
# 结果：All checks passed!
uv run --extra dev mypy src
# 结果：Success: no issues found in 27 source files

# 3. OpenAPI 契约校验与 Git 检查
npx @redocly/cli lint contracts/openapi.yaml
# 结果：validates successfully
git diff --check
# 结果：Clean (无空白或格式异常)
```

---

## 3. 核心功能验收证据 (R0–R5)

### 3.1 R0：时钟推进与正文不可变性
- **实现文件**：`src/speechrail/realtime/timeline.py`
- **验证事实**：
  - 采用 16 kHz 全局整数采样点计数（`SessionTimeline`），测试连续推送 10,001 个音频包（每包 160 样本），累计 1,600,160 采样点无任何浮点累计误差。
  - 单调递增断言保护：任何倒流或乱序音频块被立即拦截。

### 3.2 R1：增量状态机与 Native 探针
- **实现文件**：`src/speechrail/backends/diarization/stream_state.py`
- **验证事实**：
  - 维护有界环形缓存（上限 40 秒，步长 20 秒），超限自动滑动，内存不泄漏。
  - Native 依赖探针守卫：若未安装 `nemo-toolkit` 或模型权重不存在，安全隔离并降级，`supports_stream` 明确置为 `False`，不引发服务崩溃。

### 3.3 R2：契约扩展与 Fixtures 冻结
- **契约规范**：`contracts/realtime-openai.md` 与 `contracts/diarization/v1/`
- **验证事实**：
  - 严格支持 `speechrail.diarization.v1` 协议协商。
  - 定义并冻结 `speechrail.diarization.update`、`speechrail.diarization.status`、`speechrail.diarization.finalize`、`speechrail.diarization.finalized` 的 JSON Schema 与确定性 fixtures。

### 3.4 R3：归属账本与声学证据仲裁
- **实现文件**：`src/speechrail/realtime/attribution_ledger.py`
- **验证事实**：
  - 单元注册时即刻返回定态或待定结果：对齐不可用（`unavailable`）或晚到（`late`）单元立即下发 `unknown` 或 `stable` 归属，防止事件静默丢失。
  - CAM++ 声学特征双段重合验证，置信度达标方赋予 `speaker` 标识；低于阈值保持 `unknown`。
  - `revision` 严格从 1 单调递增，并受 `state.revision > 0` 保护。

### 3.5 R4：结束屏障与故障降级
- **实现文件**：`src/speechrail/realtime/session.py`
- **验证事实**：
  - 客户端推流完毕后发送 `finalize` 请求，服务端进入 `DRAINING` 状态，排空声学尾部与所有 pending updates 后下发 `finalized`。
  - `finalized` 事件携带 `last_update_sequence`，严格等于最后一个 update 的 `sequence`。
  - 幂等性：重复发送相同 `finalization_id` 幂等回显；不同 ID 请求拒绝返回 `invalid_state`；finalize 后追加音频拒绝。
  - 20 秒超时降级机制：模拟引擎死锁或异常超时，系统安全向客户端发送 `speechrail.diarization.status`（`status="degraded"`），正文完整保留，无异常崩溃。

### 3.6 R5：评测工具套件与指标数学保证
- **实现文件**：`tools/evaluate_diarization_e2e.py` 与 `tests/test_diarization_metrics.py`
- **验证事实**：
  - **Permutation Invariance**：基于 Kuhn-Munkres（匈牙利算法）全局最优二分图匹配，说话人别名重映射实测 DER = 0.0000。
  - **段内错换强惩罚**：段级错换（Segment swap）无法通过局部滑动匹配掩盖，实测全局约束准确惩罚 50% 混淆。
  - **Collar & Overlap**：支持 0.25s 容差边界豁免，准确累加多说话人重叠区域的漏检与虚警。
  - **SACER**：字级归属错误率将 `unknown` 明确计为错误，杜绝通过大范围抛出 unknown 刷低 DER。
  - **Manifest 校验**：强制校验数据集授权合规与 `eval`/`tune` 隔离；评测报告仅输出聚合统计，绝不包含原始音频、文本或姓名。

---

## 4. 与 Sona 联合端到端联调事实

根据 Sona 侧实际集成测试矩阵（`tests/test_diarization_e2e.py`，7 项全部通过）：

| 场景 | 验证内容 | 结果 |
|---|---|---|
| **E2E-1** | 连续 3 次 Commit 不可变正文生成 + 异步 SpeakerPatch 流式推进 | ✅ 通过 |
| **E2E-2** | 模拟 WebSocket 断网重连，新 Epoch 时钟推进，无重复正文插入 | ✅ 通过 |
| **E2E-3** | 用户在 UI 手动修改讲话人名称，后续模型补丁不破坏人工覆盖 | ✅ 通过 |
| **E2E-4** | 数据库瞬态断开，本地加密 Journal (0700/0600) 缓冲并重放成功 | ✅ 通过 |
| **E2E-5** | 客户端 Finalize 屏障等待落库水位，幂等重复调用 | ✅ 通过 |
| **E2E-6** | 分人处理超时，优雅降级（`status=degraded`），正文安全封存 | ✅ 通过 |
| **E2E-7** | 新旧 Rail × 新旧 Sona 四组合兼容矩阵全部平稳工作 | ✅ 通过 |

---

## 5. 资源边界与安全防护合规性

1. **单进程单 Worker 约束**：未引入多进程复制模型，ASR 与 Diarization 共享受管进程，内存边界受 Resource Governor 严格约束。
2. **零网络访问与零依赖预载**：请求路径严禁访问公网下载权重；非 loopback 绑定必须启用 API Key。
3. **敏感信息脱敏**：日志、事件、评测报告中杜绝出现真实姓名、完整 Prompt、原始转写文本、Base64 或模型绝对路径。
4. **会话作用域匿名性**：Diarization 仅输出 session-scoped 匿名标签（`spk_0`, `spk_1` 等），不建立跨会话声纹库或持久化声学向量。

---

## 6. 发布与应急回退预案 (Rollback Runbook)

### 6.1 灰度发布流程
1. **服务所有权**：确认仅有单个 `com.speechrail` 用户级 LaunchAgent 实例在运行。
2. **构建与预检**：
   ```bash
   uv build --wheel
   # 在隔离目录预检无误后原子切换
   uv run speechrail service restart
   ```
3. **探针验证**：
   ```bash
   curl -s http://127.0.0.1:8201/health | grep '"status":"healthy"'
   curl -s http://127.0.0.1:8201/readyz | grep '"status":"ready"'
   ```

### 6.2 零停机平滑回退
若在真实会议中发现异常：
1. **客户端协议回退（首选，秒级）**：
   在 Sona 环境配置中将 `SONA_MEETING_DIARIZATION_EXTENSIONS_ENABLED` 置为 `false`。Sona 将停止在 `session.update` 中协商 `speechrail.diarization.v1`。SpeechRail 服务端原位降级为标准 legacy Realtime 单人转写流，服务无需重启，会议不中断。
2. **服务二进制回退**：
   若需撤回 SpeechRail 版本，依照 `docs/operations/operations-runbook.md`，将 `runtime/current` 软链接切回前一版本的 release 目录并执行 `uv run speechrail service restart`。
3. **数据库保护**：
   Sona 端数据库采用完全非破坏性加法字段（`ADD COLUMN IF NOT EXISTS`），回退后旧版代码仍可正常读取正文，数据零损坏。

---

## 7. 结论

SpeechRail 侧针对 `SPK-E2E-1` 的所有架构设计、代码实现、测试覆盖与评测工具均已严格达成规范要求，并与 Sona 侧完成端到端联合验收。准予在具备模型环境的主机上开启受控灰度体验。
