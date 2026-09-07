# SpeechRail 单机服务 Operator 效率优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans (recommended). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在允许完全停服的单机环境中，统一 SpeechRail 生命周期、managed 发布安装、profile 切换、性能基准和相关 skill，缩短无效等待并让失败证据可复现。

**Architecture:** 生命周期由单一 `ServiceLifecycle` 实现，`LaunchAgentServiceController` 只适配 LaunchAgent；managed installer 只负责 release/runtime/current，profile transaction 只负责 selection、停服、启动、smoke 和一次回滚。性能基准拆成 manifest、HTTP、资源采样和 runner 模块，旧 all-in-one wrapper 不再作为正式入口；三个 skill 通过共享 reference 维护同一套不变量。

**Tech Stack:** Python 3.12、FastAPI service layer、`launchctl`、per-port `flock`、`pytest`、`ruff`、`mypy`、Node 22 benchmark helpers、macOS `footprint`。

**Spec:** `docs/superpowers/specs/2026-09-07-service-operator-efficiency-design.md`

## Global Constraints

- SpeechRail 是单用户单机服务；只允许一个 `com.speechrail`、一个 ASGI 父进程和一个 per-port lock owner。
- 允许完全停服和数分钟启动真空；候选启动前必须确认旧 lock 已释放。
- 无响应只允许对经 owner/PID/命令行/executable 校验的精确进程或进程组发送 `SIGKILL`。
- 不使用 `pkill`、`killall`、模糊 PID、并行服务、隐式模型下载或连续 restart 重试。
- public API、worker frame protocol、模型目录和版本号保持不变。
- benchmark 原始 JSON、音频、embedding、日志和私有配置全部在仓库外；Git 只保存脱敏汇总。
- 每个行为改动遵循 TDD：先写失败测试，再写最小实现，再跑针对性门禁并提交。

---

### Task 1: 固化当前基线与生命周期失败契约

**Files:**
- Modify: `tests/test_profile_service_controller.py`
- Create: `tests/fixtures/operator_baseline.md`
- Test: `src/speechrail/service/profile_switch.py`

**Interfaces:**
- 现有 `LaunchAgentServiceController(manager, port=..., sleeper=..., clock=...)` 保持可调用。
- 新行为：`port=None` 的 stop 不人为 sleep；lock waiter 首次立即探测；超时后只允许 validated owner recovery。

- [ ] **Step 1: 写失败测试**

  在 `tests/test_profile_service_controller.py` 增加：

  ```python
  def test_controller_without_port_does_not_sleep_after_bootout() -> None:
      manager = FakeManager(loaded=True)
      delays: list[float] = []
      LaunchAgentServiceController(manager, sleeper=delays.append).stop()
      assert delays == []
  ```

  增加 lock 首次立即成功、首次失败后成功、graceful timeout 后精确 kill 三个断言，记录期望事件顺序，不断言实现私有变量。

- [ ] **Step 2: 运行针对性测试确认失败**

  Run: `env -u SPEECHRAIL_API_KEY uv run --extra dev pytest tests/test_profile_service_controller.py -q --no-cov`

  Expected: 新增 `port=None` 测试在当前实现中因 `0.25` 秒 sleep 失败。

- [ ] **Step 3: 保存基线证据**

  只读记录当前服务的 profile、PID、listener、health、ready 和 `readlink runtime/current`，写入 `tests/fixtures/operator_baseline.md` 时只保留版本、profile、generation 和脱敏状态，不写绝对私人路径、key 或日志。

- [ ] **Step 4: 提交测试与基线**

  ```bash
  git add tests/test_profile_service_controller.py tests/fixtures/operator_baseline.md
  git commit -m "test: define local operator efficiency baseline"
  ```

### Task 2: 提取单一 ServiceLifecycle 实现

**Files:**
- Create: `src/speechrail/service/lifecycle.py`
- Modify: `src/speechrail/service/profile_switch.py`
- Modify: `src/speechrail/service/__init__.py`
- Test: `tests/test_profile_service_controller.py`

**Interfaces:**
- `StopPolicy(graceful_timeout_seconds: float = 2.0, force_kill_timeout_seconds: float = 10.0, poll_interval_seconds: float = 0.25)`。
- `ServiceLifecycle.stop()`, `.start()`, `.restart()`；构造参数注入 `status_reader`, `disable`, `enable`, `port`, `clock`, `sleeper`, `process_killer`, `owner_pid_resolver`。
- `LaunchAgentServiceController` 委托 `ServiceLifecycle`，保留既有 public class 和方法签名。

- [ ] **Step 1: 写生命周期协议测试**

  将现有 controller 的 status-unavailable、graceful timeout、exact kill、force timeout 和 restart 测试改成验证事件序列；补充 `StopPolicy` 拒绝非正 timeout、lock 首次成功无 sleep、`start()` 在 lock 未释放时不调用 `enable()`。

- [ ] **Step 2: 运行测试确认提取前的失败点**

  Run: `env -u SPEECHRAIL_API_KEY uv run --extra dev pytest tests/test_profile_service_controller.py -q --no-cov`

- [ ] **Step 3: 实现 lifecycle.py**

  从 `profile_switch.py` 移出 `_service_pid`、`_kill_process_group`、`_is_live_speechrail_process`、`_owner_pid_for_port`、lock wait 和 stop/start 组合；`ServiceLifecycle` 只依赖 protocols/callables，不导入 profile store 或 HTTP。

- [ ] **Step 4: 让 profile_switch 只保留事务编排**

  删除重复生命周期私有实现，让 `LaunchAgentServiceController` 构造 `ServiceLifecycle`；`apply_prepared_profile` 继续只调用 `ServiceController` 协议。

- [ ] **Step 5: 运行针对性门禁**

  Run: `env -u SPEECHRAIL_API_KEY uv run --extra dev pytest tests/test_profile_service_controller.py tests/test_profile_switch.py tests/test_cli.py -q --no-cov`

- [ ] **Step 6: 提交生命周期重构**

  ```bash
  git add src/speechrail/service/lifecycle.py src/speechrail/service/profile_switch.py src/speechrail/service/__init__.py tests/test_profile_service_controller.py tests/test_profile_switch.py tests/test_cli.py
  git commit -m "refactor: centralize local service lifecycle"
  ```

### Task 3: 拆分 managed installer 的职责

**Files:**
- Create: `tools/skill_installer.py`
- Modify: `tools/install_macos.py`
- Modify: `.agents/skills/speechrail-zero-setup/scripts/zero_setup.py`
- Test: `tests/test_video_podcast_skill_install.py`
- Test: `tests/test_installer.py`

**Interfaces:**
- `tools/install_macos.py` 只导出 `InstallerError`, `InstallResult`, `run_preflight`, `install_managed` 及 managed 内部 helper。
- `tools/skill_installer.py` 导出 `install_video_podcast_skill(source: Path, *, user_skills_dir: Path | None = None) -> Path`。
- zero-setup 从两个模块显式导入，安装事务调用顺序不变。

- [ ] **Step 1: 写模块边界测试**

  在 `tests/test_video_podcast_skill_install.py` 改为从 `tools.skill_installer` 加载；在 `tests/test_installer.py` 增加断言 `install_macos` 不再拥有 `install_video_podcast_skill`，并保留 installer import 轻量性检查。

- [ ] **Step 2: 运行测试确认失败**

  Run: `env -u SPEECHRAIL_API_KEY uv run --extra dev pytest tests/test_installer.py tests/test_video_podcast_skill_install.py -q --no-cov`

- [ ] **Step 3: 移动 skill 安装实现**

  将 `_LOCAL_ABSOLUTE_PATH_RE`、`_ignore_skill_artifacts`、`_validate_video_podcast_skill`、`install_video_podcast_skill` 和所需 import 移到 `tools/skill_installer.py`；不改变文件权限、symlink 检查、staging 和 backup 行为。

- [ ] **Step 4: 更新 zero-setup 与测试加载路径**

  只修改 import 路径和测试模块加载路径，不改变 `install_managed(..., post_enable=...)`、API key 内存读取或 smoke rollback。

- [ ] **Step 5: 运行 installer 门禁**

  Run: `env -u SPEECHRAIL_API_KEY uv run --extra dev pytest tests/test_installer.py tests/test_video_podcast_skill_install.py tests/test_setup_launcher.py -q --no-cov`

- [ ] **Step 6: 提交 installer 分层**

  ```bash
  git add tools/install_macos.py tools/skill_installer.py .agents/skills/speechrail-zero-setup/scripts/zero_setup.py tests/test_installer.py tests/test_video_podcast_skill_install.py
  git commit -m "refactor: separate managed installer responsibilities"
  ```

### Task 4: 拆分基准核心并删除失真的正式入口

**Files:**
- Create: `examples/perf/benchmark_manifest.py`
- Create: `examples/perf/benchmark_http.py`
- Create: `examples/perf/benchmark_resources.py`
- Create: `examples/perf/benchmark_runner.py`
- Modify: `examples/perf/bench_profiles.py`
- Delete: `.agents/skills/speechrail-perf-benchmark/scripts/run_all_benchmarks.py`
- Modify: `tests/test_profile_benchmark_contract.py`
- Modify: `tests/test_resource_sampling.py`

**Interfaces:**
- `benchmark_manifest.load_manifest`, `Fixture`, `LoadedManifest` 保持现有字段语义。
- `benchmark_http.HttpResponse`, `build_auth_headers`, `validate_base_url` 和公共请求 helper 只处理 loopback HTTP。
- `benchmark_resources.ResourceMonitor`, `normalise_resources` 和 `simultaneous_peak_by_identity` 只处理资源采样。
- `benchmark_runner.run_profile_benchmark(...)` 保持当前调用签名；`bench_profiles.py` 只重导出兼容符号和解析 CLI。

- [ ] **Step 1: 写模块边界与旧入口失败测试**

  在 `tests/test_profile_benchmark_contract.py` 增加：

  ```python
  def test_release_benchmark_requires_external_manifest_and_output(tmp_path: Path) -> None:
      with pytest.raises(ValueError, match="outside"):
          load_manifest(Path("examples/fixture.json"))
      output = tmp_path / "result.json"
      output.write_text("{}", encoding="utf-8")
      with pytest.raises(ValueError, match="overwrite"):
          write_result({"release_pass": False}, output)
  ```

  增加旧 wrapper 路径不存在的 contract test，避免以后重新引入自动 TTS fixture 和吞错入口。

- [ ] **Step 2: 运行基准 contract 测试确认失败**

  Run: `env -u SPEECHRAIL_API_KEY uv run --extra dev pytest tests/test_profile_benchmark_contract.py tests/test_resource_sampling.py -q --no-cov`

- [ ] **Step 3: 按职责迁移纯函数和数据类型**

  先移动 manifest 校验，再移动 HTTP request/response，再移动 resource normalization；每次迁移保持 `bench_profiles` 的 re-export，避免测试和发布脚本同时断裂。

- [ ] **Step 4: 实现唯一 release benchmark CLI**

  `bench_profiles.py` 的 CLI 必须要求 `--base-url`、`--manifest`、`--profile`、`--phase`、`--output`；output 只能创建新文件并使用 `0600`。不生成 TTS fixture、不使用仓库内音频、不将绝对路径或完整转写写入结果。

- [ ] **Step 5: 删除旧 all-in-one wrapper 与过时 skill 引用**

  删除 `.agents/skills/speechrail-perf-benchmark/scripts/run_all_benchmarks.py`，从 skill 和 README/operations 文档移除其调用；保留 `prepare_fixtures.py` 作为明确标注的开发 fixture 工具，但不让 release benchmark 调用它。

- [ ] **Step 6: 运行基准单测与静态检查**

  Run: `env -u SPEECHRAIL_API_KEY uv run --extra dev pytest tests/test_profile_benchmark_contract.py tests/test_resource_sampling.py -q --no-cov && uv run --extra dev ruff check examples/perf tests/test_profile_benchmark_contract.py tests/test_resource_sampling.py && uv run --extra dev mypy examples/perf`

- [ ] **Step 7: 提交基准重构**

  ```bash
  git add examples/perf .agents/skills/speechrail-perf-benchmark/scripts tests/test_profile_benchmark_contract.py tests/test_resource_sampling.py
  git commit -m "refactor: unify release benchmark evidence pipeline"
  ```

### Task 5: 收敛 skill 与运行手册到共享 SOP

**Files:**
- Create: `.agents/skills/speechrail-local-deploy/references/operator-contract.md`
- Modify: `.agents/skills/speechrail-local-deploy/SKILL.md`
- Modify: `.agents/skills/speechrail-release/SKILL.md`
- Modify: `.agents/skills/speechrail-perf-benchmark/SKILL.md`
- Modify: `.agents/skills/speechrail-local-deploy/references/lifecycle.md`
- Modify: `docs/operations/operations-runbook.md`
- Modify: `docs/operations/runtime-deployment.md`
- Test: skill quick validation and text consistency checks

**Interfaces:**
- `operator-contract.md` 是 stop/start、lock、SIGKILL、rollback、外部 realtime 隔离和 evidence ledger 的唯一维护点。
- 三个入口 skill 只保留触发条件、profile/版本范围和链接，不复制 timeout 与状态机全文。

- [ ] **Step 1: 写 skill consistency 检查**

  添加一个只读 Python 检查脚本 `scripts/check_operator_docs.py`，验证三份 skill 都链接共享 reference、没有旧 wrapper、没有互相矛盾的 timeout 文本，并拒绝出现 `pkill`/`killall` 操作命令示例。

- [ ] **Step 2: 运行检查确认旧文档失败**

  Run: `uv run python scripts/check_operator_docs.py`

  Expected: 当前重复文本或旧 benchmark wrapper 引用导致失败。

- [ ] **Step 3: 编写共享 operator contract**

  只写当前终态：停止真空可持续数分钟、2 秒 graceful/锁验证、验证失败后精确强杀、最多 10 秒二次 lock 等待、候选启动前 lock free、一次回滚、not_ready 终态、外部连接隔离和证据字段。

- [ ] **Step 4: 精简三个 skill 与 operations 文档**

  删除重复 lifecycle 段落，保留每个 skill 的入口命令、SemVer 测量范围、真实 smoke、基准输出位置和失败停止条件；所有路径使用仓库相对路径和可移植命令。

- [ ] **Step 5: 验证 skill 与脚本**

  Run: `python3 /Users/hrygo/.codex/skills/.system/skill-creator/scripts/quick_validate.py .agents/skills/speechrail-local-deploy && python3 /Users/hrygo/.codex/skills/.system/skill-creator/scripts/quick_validate.py .agents/skills/speechrail-release && python3 /Users/hrygo/.codex/skills/.system/skill-creator/scripts/quick_validate.py .agents/skills/speechrail-perf-benchmark && uv run python scripts/check_operator_docs.py`

- [ ] **Step 6: 提交 SOP 收敛**

  ```bash
  git add .agents/skills/speechrail-local-deploy .agents/skills/speechrail-release .agents/skills/speechrail-perf-benchmark docs/operations scripts/check_operator_docs.py
  git commit -m "docs: make local operator SOP single-source"
  ```

### Task 6: 完整门禁与真实单机停服验收

**Files:**
- Modify: `docs/archive/performance/README.md` only if the benchmark report is generated.
- Create outside repository: `$HOME/Library/Application Support/SpeechRail/benchmarks/bench-20260907-operator-efficiency/` raw evidence.

**Interfaces:**
- 运行态只通过 `speechrail service stop/start`, `speechrail profile apply/rollback` 和唯一 benchmark CLI 操作。
- 报告必须包含 commit、profile、generation、model identity、fixture digest、hardware、resource completeness、health/ready、smoke、rollback target 和未验证项。

- [ ] **Step 1: 运行代码门禁**

  ```bash
  env -u SPEECHRAIL_API_KEY uv run --extra dev pytest
  uv run --extra dev ruff check src tests tools examples/perf
  uv run --extra dev mypy src examples/perf
  npx @redocly/cli lint contracts/openapi.yaml
  plutil -lint deploy/macos/com.speechrail.plist.example
  git diff --check
  ```

- [ ] **Step 2: 记录开始快照并隔离客户端**

  记录当前 active profile/generation、runtime target、PID、listener、health/ready 和 `/metrics` active sessions；发现外部 established realtime connection 时先关闭所属客户端。

- [ ] **Step 3: 运行生命周期效率验收**

  使用当前 managed runtime 执行 controller-backed stop；记录 `bootout`、lock 释放、强杀（若发生）、start、health/ready 的耗时。服务未完全退出时不得启动候选。

- [ ] **Step 4: 运行 MINOR 三档套件**

  逐档执行 `quality → balanced → light → quality`：每档先停服、应用 profile、等待 identity/ready、运行独立 fixture 的 ASR/TTS 基准和真实 smoke；任何失败停止后续采集并只回滚一次。

- [ ] **Step 5: 恢复并验收运行态**

  复查开始 profile、单 listener、PID executable、health、ready、models、voices、TTS→ASR 和 active requests；确认没有残留强杀目标、旧 listener 或 benchmark lock。

- [ ] **Step 6: 生成脱敏报告并做最终 review**

  只把可比摘要写入仓库归档；原始制品留在 app home benchmark 目录。执行 `git diff --staged --check`、敏感字段扫描、`git status --short`，确认未改动用户无关文件。

- [ ] **Step 7: 提交验收报告**

  ```bash
  git add docs/archive/performance/README.md docs/archive/performance/2026-09-07-v1.10.0-operator-efficiency.md
  git commit -m "docs: record local operator efficiency benchmark"
  ```

## Commit checkpoints

每个 Task 完成并通过针对性测试后单独提交；不把生命周期、基准和 SOP 文档压成一个不可回滚的大提交。最终运行态验证失败时保留服务为 `not_ready` 或恢复到开始 profile，不循环重试。
