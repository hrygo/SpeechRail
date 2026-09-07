# SpeechRail 单机服务 Operator 效率优化设计

> 状态：已获用户批准，2026-09-07

## 目标

在单机、单用户、允许完全停服的前提下，收敛 SpeechRail 的服务安装、wheel 发布、启停、profile 切换、回滚和性能基准流程，消除重复的生命周期实现与失真的基准入口，缩短停服窗口，并让 skill 与代码共享同一套终态规则。

## 当前事实

- 服务只允许一个 `com.speechrail` LaunchAgent、一个 ASGI 父进程和一个 per-port lock owner。
- `LaunchAgentServiceController` 已具备 `bootout → lock 等待 → 精确 SIGKILL → lock 再确认`，但生命周期细节仍集中在 `profile_switch.py`，发布、切档和 skill 文档分别重复描述。
- `tools/install_macos.py` 已只有 `install_managed(...)`，但仍把 release staging、配置、runtime、LaunchAgent 初始化和视频 skill 安装放在一个工具模块中。
- `examples/perf/bench_profiles.py` 有较完整的证据门，但仍是大型单体；`.agents/skills/speechrail-perf-benchmark/scripts/run_all_benchmarks.py` 是另一条旧入口，会自动用 TTS 生成 ASR fixture、写死 `/tmp`、吞掉 Realtime 失败，也不生成统一报告。
- release、local-deploy、perf 三个 skill 对停服和回滚规则有重复文本，规则变化时容易漂移。
- 当前本机基线：服务版本 `1.10.0`、`quality` profile、单 listener、`/health` 和 `/readyz` 均通过；优化前不得把这些运行态事实写入代码或报告作为永久常量。

## 设计原则

1. **单一生命周期边界**：只有一个 controller 负责 LaunchAgent、精确 PID/进程组、lock 释放和启动前校验。
2. **事务职责分层**：release installer 只准备 wheel/runtime/current；profile transaction 只管理 selection、服务生命周期和 smoke；两者通过明确接口组合，不互相调用 CLI 或复制回滚代码。
3. **停服优先于复杂热切换**：允许数分钟真空，候选服务只有在旧 lock 完全释放后才能启动；不做并行服务、不做连续 restart、不做隐式重试。
4. **证据优先**：基准必须使用仓库外、独立 fixture manifest；每个失败、缺失采样或非真实依赖都关闭 release gate，不用旧数据补齐。
5. **DRY 但不隐藏副作用**：纯校验、路径、生命周期等待和证据聚合可复用；下载、写盘、启动、切换等副作用必须保留显式边界。
6. **向后兼容只保留真实入口**：不恢复已删除的 explicit-env installer；旧基准 wrapper 不再作为正式入口，必要时只保留明确失败提示。

## 目标架构

### 1. Lifecycle 层

新增小型生命周期模块，定义以下职责：

- `StopPolicy`：graceful timeout、force-kill timeout、poll interval，所有时间参数集中定义并可注入测试。
- `ServiceLifecycle`：实现 `stop()`、`start()`、`restart()`，内部复用一个 lock waiter 和一个 validated-owner killer。
- `LaunchAgentServiceController`：保留现有类名作为 LaunchAgent adapter，委托 `ServiceLifecycle`，不让 profile transaction 直接操作 `launchctl`。

停止流程固定为：读取状态和候选 PID → `bootout` → 立即尝试 lock → 短轮询 → owner/PID/命令行/executable 校验 → 精确 `SIGKILL` → 再轮询 lock。无 port 校验需求时不再人为 sleep。启动流程固定为：lock free → `bootstrap`/`kickstart` → 由调用方执行 identity/ready/smoke。

### 2. Release 与 profile 层

- `install_managed(...)` 保持 wheel staging、release identity、配置和 `runtime/current` 原子切换；它不得启动第二个服务，也不复制生命周期 kill 逻辑。
- `apply_prepared_profile(...)` 继续承担 selection journal、停止旧服务、候选启动、公共 smoke、一次回滚；它只依赖 `ServiceController` 和 `PublicSmokeProbe` 协议。
- CLI、zero-setup 和 release 文档只组合这两个边界，不再各自实现 stop/start 顺序。
- `install_video_podcast_skill` 从 wheel installer 模块拆为独立工具模块，减少 installer 的职责和导入面；zero-setup 显式组合两个 installer。

### 3. Benchmark 层

将基准拆成四个可测试模块：

- `benchmark_manifest`：校验仓库外 fixture、文本、voice、模型身份和 phase evidence。
- `benchmark_http`：统一 loopback HTTP、鉴权、health/catalog、ASR/TTS 请求和响应解析。
- `benchmark_resources`：统一 process identity、`phys_footprint` 同 tick 聚合和完整性判断。
- `benchmark_runner`：按 profile/phase 执行 warm/cold/soak/switch，生成脱敏 JSON；CLI 只解析参数和写文件。

现有 `bench_profiles.py` 变成兼容薄入口；旧的 all-in-one wrapper 不再生成 TTS ASR fixture、不吞掉 Realtime 错误，也不作为 release gate 入口。正式基准命令必须显式提供外部 manifest、profile、phase 和仓库外 output。

### 4. Skill 层

新增一个共享 reference，维护生命周期不变量、stop/start 时序、错误码和证据要求。`speechrail-local-deploy`、`speechrail-release`、`speechrail-perf-benchmark` 只保留各自触发条件、参数和验收清单，并链接到共享 reference；任何固定 timeout、lock 规则和回滚规则只保留一份。

## 错误与回滚

- lock 未释放、PID 不可验证、候选 preflight/identity/ready/smoke 失败：保持停服或执行一次回滚，不启动第二实例。
- 回滚失败：selection journal 标记 `NOT_READY`，不循环重试，报告 operation、PID、stderr 尾部和 lock 状态。
- benchmark fixture、硬件、模型身份、资源采样或独立质量证据不完整：结果可保存为 `release_pass=false`，但不能写入 README 的通过结论。
- 任何新公共错误仍使用现有 envelope/request ID；本设计不改 API 版本或 worker 协议。

## 验收与效率指标

代码验收：

- lifecycle、installer、profile switch 和 benchmark 单测覆盖新的边界；完整 pytest、ruff、mypy、OpenAPI、plist 和 diff gate 通过。
- old wrapper 不再自动生成质量 fixture；无凭据、音频、绝对私人路径进入仓库报告。
- skill 中的 stop/start、回滚和基准 gate 规则不再重复或互相矛盾。

运行态验收：

- 在当前 profile 上完成一次安全 stop/start，记录停服、lock 释放、ready 和 smoke 时间。
- 对 MINOR 影响范围执行 `quality → balanced → light → quality`，每档完全停服并核对 `/health.profile`、models、voices 和真实 TTS→ASR。
- 资源采样使用真实 `footprint`，同一 tick 计算同时峰值；采样不完整时 gate 为 `unset/fail`。
- 最终恢复开始前的 profile、单 listener、健康和 ready 状态。

## 非目标

- 不引入远程控制面、容器、HA、并发 ASGI worker 或第二服务实例。
- 不改变模型目录、公共 API、voice cloning 能力、版本号或发布渠道。
- 不删除历史 archive/plan 文档；历史材料只用于追溯，不作为当前操作入口。
