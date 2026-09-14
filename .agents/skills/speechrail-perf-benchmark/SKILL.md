---
name: speechrail-perf-benchmark
description: >-
  SpeechRail 性能、质量和资源基准：按 SemVer 选择 active profile 或三档，测量 ASR/TTS/Realtime
  延迟、RTF、吞吐、phys_footprint 与音色稳定性。仅在用户明确要求基准或质量验收时触发；
  README 同步另需明确授权。
---

# SpeechRail 性能与质量基准

目标是生成可复现、可比较、不会夸大证据的发布基准。推理走公共 API；原始 JSON、音频、embedding
和日志放在仓库外，Git 只保存脱敏汇总报告。

## 触发与边界

- 用户明确要求性能、延迟、RTF、吞吐、内存、质量、音色稳定性或 benchmark 时使用本 skill。
- 普通服务诊断、启停、切档和回滚读
  [speechrail-local-deploy](../speechrail-local-deploy/SKILL.md)；发布范围与版本材料读
  [speechrail-release](../speechrail-release/SKILL.md)。
- 不因生成 benchmark 报告自动修改 README；只有用户明确要求时才读取
  [报告与 README 规则](references/reporting.md)。

## 共享安全契约

开始任何会停服、切档或产生真实推理的工作前，先读
[operator contract](../speechrail-local-deploy/references/operator-contract.md)。关键不变量：

- 使用已安装 wheel、锁定 snapshot 和无下载运行态；不把源码 checkout 当作 managed runtime。
- 单机只运行一个 `com.speechrail` 服务和一个 ASGI worker；batch ASR 与 streaming ASR 分开测量。
- 基准开始、切档前和最终恢复后，用 `lsof` 排除外部 `ESTABLISHED` realtime 客户端，并用鉴权
  `/metrics` 确认 realtime session 与 batch/realtime active requests 为零。发现活动客户端就暂停，
  不自动关闭 Sona、浏览器或其他客户端。
- API key 按 shared resolver 读取：显式 `SPEECHRAIL_API_KEY` 优先，其次是 managed
  `config/.env`；不得 `source` 配置，也不得把 key 写入命令、结果或日志。
- 内存以 Apple Silicon 的 `phys_footprint` 计量：每个完整采样 tick 汇总目标 PID+start-time；
  缺样、PID 重用、sampler 异常或停止超时会关闭对应 gate。懒加载 worker 必须在预热后重新发现。
- `SPEECHRAIL_ALLOW_HEAVY_OVERLAP=auto` 是默认测量口径，不再执行 overlap OFF 对照；重叠轴是
  ASR∥TTS，不是 ASR∥ASR。多路 ASR 被单 worker 拒绝时记录为 `429 backend_busy`，不当作并发收益。

## 1. 选择基准范围

| 发布类型 | 必测范围 | 切换规则 |
|---|---|---|
| PATCH | 当前部署 profile | 不为基准切档；与同机同口径版本纵向比较 |
| MINOR | `quality`、`balanced`、`light` | active → 其余档 → active，逐档恢复 |
| MAJOR | 三档完整套件 | 另加迁移、兼容客户端和回退验证 |

若改动影响未覆盖的 profile、模型、共同 runtime 或 benchmark 工具，扩大到三档；纯文档改动不制造
新的性能结论。三档当前能力以 `/v1/models` 和 `/v1/voices` 实测声明为准，不能根据计划或目录名推断。

## 2. 测量口径

- 记录 commit、版本、profile、artifact、variant、quantization、macOS、实际芯片、物理内存、
  Python、MLX 和 benchmark schema；`arm`/`arm64` 只能作为架构，不能替代芯片身份。
- 每项先预热至少 1 次；基础套件 warm N=5，报告 p50、p95、min/max 和样本数。cold 只能来自
  已确认未加载或已重置状态的首次推理；任何前置推理都标为 warm 或 `cold_unavailable`。
- RTF 使用 `ffprobe` 实测输出时长：`latency / actual_audio_seconds`；不能使用 fixture 文件名标签。
- 同轮比较固定 fixture 字节、文本、请求参数、环境和静默背景负载；变化标为不可直接比较。
- 对短生命周期分人 worker 按 PID+start-time incarnation 建立 active window；不能合并不同 incarnation
  的峰值，也不能把窗口内缺样包装成全局 `sampling_complete`。

## 3. 官方入口

正式 benchmark 只接受仓库外 manifest 和 fixture。`prepare_fixtures.py` 仅供开发调试，不得生成独立
ASR 质量集或作为发布入口。正式入口：

```bash
uv run python examples/perf/bench_profiles.py \
  --base-url http://127.0.0.1:8201 \
  --app-home "${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}" \
  --manifest <repo-external-manifest.json> \
  --profile <quality|balanced|light> \
  --phase warm \
  --output <repo-external-result.json>
```

`bench_profiles.py` 默认覆盖 A–E；只重测受影响场景时显式传 `--scenarios C D E` 并记录
`scenario_ids`。工具会先探测受保护路由鉴权；收到 `401` 时在任何推理前停止并修正 app home/key。

Realtime 正式证据使用：

```bash
uv run python examples/perf/bench_realtime_json.py <external-16khz-pcm> \
  --profile <quality|balanced|light> \
  --output <repo-external-realtime.json> \
  --app-home "${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
```

默认 warm-up 后测 3 个 session；`--no-warmup` 仅在已确认模型未加载/已重置且确需严格 cold 时使用。
`bench_realtime.py` 只用于 stdout 快速预览，不是发布证据。fixture `id`/`language` 使用安全标签，
不能把原始路径、文本、音频或 token 写入结果。

## 4. 基础与质量套件

每个适用 profile 的基础套件包含：

- 身份：`/health`、`/readyz`、`/v1/models`、`/v1/voices`、公共 ASR/TTS smoke；身份读取不影响 cold。
- Batch ASR：独立中英文 3/10/30/60 秒样本，cold 1 次、warm N=5，记录 latency、RTF、CER/WER，
  可选吞吐；不得使用 SpeechRail TTS 生成主质量集。
- TTS：固定短长句、canonical `serena`，cold 1 次、warm N=5，记录输出实测时长、RTF、首音频时间；
  独立 ASR 回读只能作为可懂度代理，不替代人工听感。
- Realtime：完整套件或相关改动时，记录 setup、首 delta、commit、TTFA、terminal event 和成功率，
  16 kHz mono PCM16，连续 3 个 session。

PATCH 若影响推理、分句、采样、量化、音色或模型 runtime，仍执行质量套件。质量报告至少覆盖：

- ASR 总体及语言/时长分组 CER/WER、样本数和失败数，并报告 p50/p95；
- 九个角色的中英文、短长句、数字和标点，生成失败率及独立 ASR 回读；没有人工 MOS/偏好测试就写
  “未验证”；
- 每角色 3 类文本 × 3 次生成、服务重启后重复、同文本 PCM hash、跨文本 speaker embedding、
  跨重启变化和 ABX 盲听。建议门值需先在首个可信数据集上冻结。

## 5. 切档与恢复

MINOR/MAJOR 切档通过 `speechrail profile apply <profile> --yes`，不能用热重启代替；每档后先核对
`/health.profile`，再核对 catalog、做该档套件，结束恢复初始 profile。停止、lock、精确 PID、回滚
和失败出口统一按 local-deploy 的 controller 与 operator contract 执行；不循环 restart，不在同一时间
运行多个 benchmark。

切换或 smoke 失败时停止后续采集，记录失败档、operation 状态、PID、stderr 尾部和错误码。事务已自动
回滚且恢复时不得再次回滚；仅在确认未恢复且回退目标明确时执行一次 rollback。

## 6. 报告与完成条件

生成归档报告或比较版本时，读取 [报告与 README 规则](references/reporting.md)；它包含变化口径、模板、
README 授权边界和核对命令。主流程完成时应满足：

- 原始制品保存到仓库外受限目录，Git 中只有脱敏汇总；
- 报告记录 identity、warm/cold/N、资源采样完整性、外部客户端隔离、gate、限制和未验证项；
- 性能/质量不足时写 `unset`/`fail`，不以一次 smoke、健康端点或目录名代替证据；
- 最终 active profile 与开始一致，服务 listener、health/ready 和必要 smoke 复核通过；
- 性能归档索引已更新。README 只有在用户明确要求同步时才修改。
