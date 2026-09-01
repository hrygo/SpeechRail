# Wheel + Local Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 SpeechRail 交付为可在 macOS 单人本机安装的 wheel + 本地安装器，安装器负责创建隔离运行环境、配置校验、LaunchAgent 注册、ASR/TTS 验收和可回退升级。

**Architecture:** wheel 只包含 SpeechRail 服务代码和普通 Python 依赖；ASR/TTS vendor runtime、模型 snapshot 和 `ffmpeg` 保持外置。独立的 macOS 本地安装器接收 wheel，创建应用数据目录和专用 venv，复制用户明确提供的 `.env`，再调用已安装 CLI 生成用户级 `LaunchAgent`。服务 plist 只保存绝对解释器、工作目录和日志路径，不保存凭据或完整环境变量。

**Tech Stack:** Python `>=3.12,<3.13`、PEP 621、Hatchling、`uv`、wheel/sdist、`plistlib`、macOS `launchctl`、FastAPI/Uvicorn、pytest。

**Spec:** `docs/operations/runtime-deployment.md`、`docs/operations/operations-runbook.md`、`pyproject.toml` 和本计划中的分发决策。

## Global Constraints

- Python 版本必须满足 `>=3.12,<3.13`；使用 `uv` 和 PEP 621 元数据。
- wheel 不包含 ASR/TTS 模型权重、vendor Python runtime、音频、`.env`、API key、日志或缓存。
- ASR 与 TTS 使用外部绝对路径；两者各自的 model/runtime 配置必须成对存在，不能静默下载模型。
- 本机服务只使用当前用户的 `~/Library/LaunchAgents`，不使用 root `LaunchDaemon`，不要求管理员权限。
- 一个安装实例只有一个 SpeechRail ASGI 进程；每个已启用 profile 只有一个隔离 worker。
- plist 使用绝对 `ProgramArguments`，直接执行 Python module，不使用 shell、`uv run` 或相对路径。
- plist 不写入 secret；配置文件权限为 `0600`，日志目录权限为 `0700`。
- README 和面向用户的正式文档不写死发布版本；包 metadata、wheel 文件名和发布索引仍必须保留标准版本字段。
- 任何升级先在新 runtime 中安装和验收，再切换当前运行目录；失败时恢复上一 runtime，不删除模型、配置或用户数据。
- 每个实现任务遵循 TDD：先写失败测试，再实现最小改动，再运行针对性测试和项目级 gate。

## File Map

- Modify: `pyproject.toml` — 完善可发布 metadata、项目 URL、license 表达和构建边界；保留 `[project.scripts] speechrail`。
- Create: `tools/install_macos.py` — 接收 wheel 和用户配置，创建本机应用目录、隔离 venv、安装 wheel、运行 preflight 并注册服务；不属于 wheel 内容。
- Create: `src/speechrail/service/paths.py` — 统一计算应用目录、runtime、配置、日志和 LaunchAgent 路径，避免安装器和服务 CLI 各自拼路径。
- Create: `src/speechrail/service/preflight.py` — 检查 Python、`ffmpeg`、配置、ASR/TTS runtime 和 snapshot 的可用性；只读、可测试、无模型下载。
- Modify: `src/speechrail/service/launchd.py` — 支持显式 app home/working directory，继续生成安全的用户级 plist。
- Modify: `src/speechrail/cli.py` — 为 service 子命令增加显式路径和 preflight 入口，保持当前命令兼容。
- Modify: `src/speechrail/config/__init__.py` — 使服务配置目录可由安装布局稳定提供，不再把源码仓库作为发布安装的隐含前提。
- Create: `tests/test_service_paths.py` — 路径布局、权限和跨平台纯逻辑测试。
- Create: `tests/test_service_preflight.py` — runtime/model/ffmpeg/config 检查测试。
- Modify: `tests/test_launchd_service.py` — 显式 app home、plist 参数和无 secret 验收。
- Modify: `tests/test_cli.py` — service 参数和 preflight 输出测试。
- Create: `tests/test_installer.py` — 安装器的 fake runner、原子切换、失败回滚和敏感信息隔离测试。
- Create: `tests/test_wheel_contents.py` — wheel 内容白名单/黑名单测试。
- Create: `tests/test_release_verification.py` — 发布验收脚本的 fake HTTP/CLI/音频失败条件测试。
- Modify: `docs/operations/runtime-deployment.md` — 发布安装目录、runtime 外置和升级模型。
- Modify: `docs/operations/operations-runbook.md` — 本地安装器、preflight、服务验收和回滚步骤。
- Modify: `docs/developers/development-guide.md` — 开发安装与发布 wheel 安装的区别。
- Modify: `README.md` — 只描述稳定能力和安装入口，不加入具体发布版本。
- Create: `docs/archive/process/2026-09-01-wheel-local-installer-design.md` — 记录本方案的取舍、非目标和后续决策依据。

## Task 1: 固化分发契约与 wheel 边界

**Files:**
- Modify: `pyproject.toml`
- Create: `tests/test_wheel_contents.py`
- Create: `docs/archive/process/2026-09-01-wheel-local-installer-design.md`

**Interfaces:**
- Produces: wheel 中只含 `speechrail` 包及其 metadata；不含 `tests/`、`.env`、模型、日志、音频、`dist/` 和本机路径。

- [ ] **Step 1: Write the failing artifact tests**

  在 `tests/test_wheel_contents.py` 中实现 `test_wheel_contains_runtime_only`：读取测试传入的 wheel zip，断言至少存在 `speechrail/__main__.py`、`speechrail/cli.py` 和 `.dist-info/METADATA`，并断言不存在 `.env`、`tests/`、`*.safetensors`、`*.wav`、`*.log` 及 `/Users/` 绝对路径。

- [ ] **Step 2: Run the artifact tests to verify the boundary is not yet enforced**

  Run: `uv run --extra dev pytest tests/test_wheel_contents.py -q --no-cov`

  Expected: FAIL because the test fixture/build invocation and artifact assertion helper do not yet exist。

- [ ] **Step 3: Update package metadata and build configuration**

  在 `pyproject.toml` 中保持 `src/speechrail` wheel 包选择和 `speechrail = "speechrail.__main__:main"` entry point；补齐适合分发的 `project.urls` 和标准 license metadata；明确不把 `tools/`、`tests/`、模型和本机配置加入 Hatchling wheel。

- [ ] **Step 4: Implement the artifact inspection helper**

  在测试中增加 `assert_wheel_contents(wheel_path: Path) -> None`，通过 `zipfile.ZipFile` 检查白名单/黑名单；测试只检查构建产物，不修改源码树，不读取真实 `.env`。

- [ ] **Step 5: Run the focused packaging checks**

  Run: `uv build --no-sources --wheel`

  Then run: `uv run --extra dev pytest tests/test_wheel_contents.py -q --no-cov`

  Expected: wheel 构建成功，内容检查通过。

- [ ] **Step 6: Record the distribution decision**

  在 `docs/archive/process/2026-09-01-wheel-local-installer-design.md` 记录：wheel/sdist 是服务代码分发物；ASR/TTS runtime、snapshot、`ffmpeg` 是外部前置；README 不写死版本但 package metadata 必须版本化；不建设 Docker、Kubernetes 或单文件二进制。

- [ ] **Step 7: Commit the packaging contract**

  ```bash
  git add pyproject.toml tests/test_wheel_contents.py docs/archive/process/2026-09-01-wheel-local-installer-design.md
  git commit -m "build: define wheel distribution boundary"
  ```

## Task 2: 建立稳定的本机应用目录和路径接口

**Files:**
- Create: `src/speechrail/service/paths.py`
- Modify: `src/speechrail/config/__init__.py`
- Create: `tests/test_service_paths.py`

**Interfaces:**
- Produces: `ServiceLayout.for_app_home(app_home: Path) -> ServiceLayout`；属性包括 `app_home`、`runtime_root`、`current_runtime`、`config_file`、`log_directory` 和 `plist_path`。
- Produces: `ServiceLayout.ensure_directories() -> None`，创建目录并设置 `config_file` 所在目录为用户私有。
- Consumes: 当前 `Settings` 的 `.env` 环境配置语义；不改变现有配置键名。

- [ ] **Step 1: Write failing path tests**

  覆盖固定布局：`app_home/config/.env`、`app_home/runtime/current/bin/python`、`app_home/logs`、`~/Library/LaunchAgents/com.speechrail.plist`；断言相对 app home 被拒绝，路径计算不调用 `resolve()` 破坏 runtime/current symlink。

- [ ] **Step 2: Run focused tests**

  Run: `uv run --extra dev pytest tests/test_service_paths.py -q --no-cov`

  Expected: FAIL because `ServiceLayout` 尚未定义。

- [ ] **Step 3: Implement the minimal immutable layout type**

  使用 frozen dataclass 保存绝对路径；`for_app_home` 只规范化 app home 本身，保留 `current_runtime` 的 symlink；`ensure_directories` 只创建安装器所需目录，不创建模型目录、不下载文件。

- [ ] **Step 4: Align settings loading with the installed working directory**

  保持服务进程从 `WorkingDirectory` 读取 `.env`，但将该目录从隐含的源码仓库改为 `ServiceLayout.app_home`；开发模式继续支持当前目录 `.env`，避免破坏现有 `uv run speechrail` 用法。

- [ ] **Step 5: Run tests and permission checks**

  Run: `uv run --extra dev pytest tests/test_service_paths.py tests/test_config.py -q --no-cov`

  Expected: 路径布局、现有环境键和配置读取测试通过；不输出 `.env` 内容。

- [ ] **Step 6: Commit the path contract**

  ```bash
  git add src/speechrail/service/paths.py src/speechrail/config/__init__.py tests/test_service_paths.py
  git commit -m "feat: define stable local service layout"
  ```

## Task 3: 让 LaunchAgent 支持发布安装布局

**Files:**
- Modify: `src/speechrail/service/launchd.py`
- Modify: `src/speechrail/cli.py`
- Modify: `tests/test_launchd_service.py`
- Modify: `tests/test_cli.py`

**Interfaces:**
- Produces: `create_launch_agent_manager(*, working_directory: Path | None = None) -> LaunchAgentManager`，显式传入安装 app home 时，plist 的 `WorkingDirectory` 与其一致。
- Produces: `speechrail service install --app-home PATH`、`enable`、`disable`、`restart`、`status`、`uninstall` 支持同一 `--app-home`。
- Produces: plist 的 `ProgramArguments` 为 `<app-home>/runtime/current/bin/python`, `-m`, `speechrail`, `serve`；不包含 `EnvironmentVariables`、API key 或模型路径。

- [ ] **Step 1: Add failing LaunchAgent tests**

  增加测试：给定带空格的 app home，生成的 plist 仍使用数组参数；`WorkingDirectory` 指向 app home；plist 中没有 `.env` 内容、`EnvironmentVariables` 和 shell 命令；service CLI 将 `--app-home` 传入 manager。

- [ ] **Step 2: Run focused tests**

  Run: `uv run --extra dev pytest tests/test_launchd_service.py tests/test_cli.py -q --no-cov`

  Expected: FAIL because parser 尚未接受 `--app-home`，且默认 manager 没有使用稳定 runtime 路径。

- [ ] **Step 3: Implement explicit app-home plumbing**

  在 `argparse` service parser 增加 `--app-home`；`_run_service(command, app_home)` 通过 `ServiceLayout` 构造 manager；保留没有参数时的当前目录兼容行为。继续使用 `launchctl bootstrap gui/<uid>`、`kickstart`、`bootout`，不增加 root 权限路径。

- [ ] **Step 4: Preserve symlink-safe Python executable handling**

  保留当前不调用 `.resolve()` 展开 venv launcher 的行为；对不存在、非绝对或不可执行的 Python 路径返回脱敏错误。

- [ ] **Step 5: Run focused and plist validation tests**

  Run: `uv run --extra dev pytest tests/test_launchd_service.py tests/test_cli.py -q --no-cov`

  Run: `plutil -lint deploy/macos/com.speechrail.plist.example`

  Expected: 所有测试通过，plist 模板和动态 plist 均为合法 XML。

- [ ] **Step 6: Commit the LaunchAgent integration**

  ```bash
  git add src/speechrail/service/launchd.py src/speechrail/cli.py tests/test_launchd_service.py tests/test_cli.py
  git commit -m "feat: install launchagent from stable app home"
  ```

## Task 4: 实现只读 preflight，阻止半安装服务

**Files:**
- Create: `src/speechrail/service/preflight.py`
- Modify: `src/speechrail/cli.py`
- Create: `tests/test_service_preflight.py`

**Interfaces:**
- Produces: `PreflightResult(ok: bool, checks: tuple[PreflightCheck, ...])`。
- Produces: `run_preflight(layout: ServiceLayout, *, require_tts: bool, runner: Runner) -> PreflightResult`。
- Defines: `CommandRunner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]`，所有外部命令检查均通过该接口注入。
- Checks: Python 版本范围、`ffmpeg` 可执行性、`.env` 存在和权限、ASR 两条路径成对且存在、TTS 两条路径成对且存在、snapshot 必要文件、vendor Python 可执行性。
- Constraint: preflight 不导入模型、不启动 worker、不访问网络、不打印 secret、model path 只显示 basename 或状态。

- [ ] **Step 1: Write failing preflight tests**

  覆盖以下结果：ASR/TTS 均完整时通过；缺少 TTS 任一配置且 `require_tts=True` 时失败；只设置一条 ASR/TTS 路径时失败；snapshot 缺少 `config.json` 时失败；`.env` 权限不是 `0600` 时给出修复建议；`ffmpeg` 不在 PATH 但 `/opt/homebrew/bin/ffmpeg` 存在时通过。

- [ ] **Step 2: Run focused tests**

  Run: `uv run --extra dev pytest tests/test_service_preflight.py -q --no-cov`

  Expected: FAIL because preflight result types and checks are not implemented。

- [ ] **Step 3: Implement pure checks and redacted rendering**

  每个检查返回 `name`、`ok`、`message`；`message` 只能包含状态、文件 basename 和修复动作，不包含 API key、完整 `.env`、完整模型绝对路径、音频或转写正文。使用现有 `Settings` 校验规则，不复制一套配置键名。

- [ ] **Step 4: Add a CLI entry point**

  增加 `speechrail service preflight --app-home PATH [--asr-only]`；默认安装目标要求 ASR+TTS，只有显式 `--asr-only` 才允许 TTS 缺失。preflight 失败时返回非零退出码，不能自动 enable。

- [ ] **Step 5: Run focused tests**

  Run: `uv run --extra dev pytest tests/test_service_preflight.py tests/test_cli.py -q --no-cov`

  Expected: 检查结果和 CLI 退出码通过；测试输出不出现真实配置值。

- [ ] **Step 6: Commit the preflight gate**

  ```bash
  git add src/speechrail/service/preflight.py src/speechrail/cli.py tests/test_service_preflight.py tests/test_cli.py
  git commit -m "feat: add redacted runtime preflight"
  ```

## Task 5: 实现 wheel + macOS 本地安装器

**Files:**
- Create: `tools/install_macos.py`
- Create: `tests/test_installer.py`
- Modify: `src/speechrail/service/__init__.py`

**Interfaces:**
- Produces: `install_wheel(wheel: Path, *, app_home: Path, env_file: Path, uv_executable: str = "uv", require_tts: bool = True, runner: Runner) -> InstallResult`。
- Produces: `InstallResult(app_home: Path, runtime_python: Path, plist_path: Path, enabled: bool)`。
- Defines: `CommandRunner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]`；runner 必须使用 `subprocess.run(..., shell=False)`，测试中使用 fake runner。
- Installer input: 必须显式提供 wheel 和 `.env`；不从当前 Git 工作树自动复制 `.env`，不下载模型，不覆盖已有 `.env`。
- Installer flow: 创建 `runtime/releases/<build-id>` → `uv venv` → `uv pip install` wheel → 写入配置副本并设置 `0600` → 运行 preflight → 用临时 symlink 原子切换 `runtime/current` → 调用 `speechrail service install --app-home` → 仅在 `--enable` 且 preflight 通过时 enable。

- [ ] **Step 1: Write failing installer tests**

  使用 fake runner 测试：正确调用 `uv venv` 和 `uv pip install`；wheel 安装失败不会改变 `runtime/current`；未提供 `.env` 时不创建半成品服务；既有 `.env` 不被覆盖；preflight 失败时不调用 `launchctl bootstrap`；enable 后 plist 指向新 runtime；所有 subprocess 使用参数数组且不经过 shell。

- [ ] **Step 2: Run focused tests**

  Run: `uv run --extra dev pytest tests/test_installer.py -q --no-cov`

  Expected: FAIL because installer entry points and `InstallResult` do not exist。

- [ ] **Step 3: Implement the installer with explicit safety gates**

  `tools/install_macos.py` 使用 `argparse`，参数包括 `--wheel PATH`、`--env-file PATH`、`--app-home PATH`、`--uv PATH`、`--asr-only` 和 `--enable`；默认只安装不启动。文件复制使用临时文件 + `os.replace`，创建失败只清理本次临时 release，不触碰旧 runtime、旧配置和外部模型。

- [ ] **Step 4: Add the clean-environment wheel installation check**

  安装器完成后，用新 runtime 的 Python 执行 `python -m speechrail --help` 和 `speechrail service status`；不从源码目录导入 `speechrail`，确保验证的是 wheel。

- [ ] **Step 5: Run installer tests and a temporary isolated install**

  Run: `uv run --extra dev pytest tests/test_installer.py tests/test_service_paths.py tests/test_service_preflight.py -q --no-cov`

  Then create a temporary app home outside the repository, install a freshly built wheel with a fake backend configuration, and assert that no `.env` or model file enters `dist/` or the wheel。

- [ ] **Step 6: Commit the local installer**

  ```bash
  git add tools/install_macos.py src/speechrail/service/__init__.py tests/test_installer.py
  git commit -m "feat: add macos wheel installer"
  ```

## Task 6: 加入发布、升级和回滚验收

**Files:**
- Create: `scripts/verify_release.py`
- Modify: `docs/operations/runtime-deployment.md`
- Modify: `docs/operations/operations-runbook.md`
- Modify: `docs/developers/development-guide.md`
- Modify: `README.md`

**Interfaces:**
- Produces: `python3 scripts/verify_release.py --wheel PATH --app-home PATH`，检查 wheel 安装、CLI、plist、健康端点和配置脱敏；失败返回非零退出码。
- Produces: 发布验收顺序：构建 wheel → 干净 venv 安装 → preflight → LaunchAgent install/enable → `/health`、`/readyz`、`/v1/models`、`/v1/voices` → 真实短音频 ASR smoke →真实 TTS PCM smoke → TTS 输出回送 ASR。

- [ ] **Step 1: Write failing release verification tests**

  覆盖 wheel 不可安装、plist 含 secret、健康端点非 200、`/v1/voices` 非 200、TTS 音频为空/奇数字节、ASR 文本为空和服务进程不属于当前 runtime 等失败条件。

- [ ] **Step 2: Run the focused release tests**

  Run: `uv run --extra dev pytest tests/test_release_verification.py -q --no-cov`

  Expected: FAIL until the verification script and test fixtures are added。

- [ ] **Step 3: Implement release verification without retaining user audio**

  使用临时目录和操作者有权使用的短音频；验证结束后删除临时音频；日志只输出状态码、request ID、字节数和耗时，不输出正文、API key、完整路径或 Base64。

- [ ] **Step 4: Document install and rollback**

  README 只保留稳定安装入口；运维文档说明 wheel、installer、app home、外置 model/runtime、LaunchAgent 和回滚命令。明确升级顺序为：构建新 wheel → 新 runtime 安装 → preflight/smoke → 原子切换 current → restart；失败时恢复旧 current 并 restart。

- [ ] **Step 5: Run the complete release gate**

  ```bash
  uv build --no-sources --wheel
  uv run --extra dev pytest
  uv run --extra dev ruff check src tests tools scripts
  uv run --extra dev mypy src
  npx @redocly/cli lint contracts/openapi.yaml
  git diff --check
  ```

  再在干净临时 app home 完成一次 ASR/TTS 真实验收；不能只以命令退出码作为通过证据。

- [ ] **Step 6: Commit the release workflow documentation**

  ```bash
  git add scripts/verify_release.py README.md docs/operations/runtime-deployment.md docs/operations/operations-runbook.md docs/developers/development-guide.md
  git commit -m "docs: define wheel release and rollback gates"
  ```

## Release Artifact and Distribution Decision

首个可分发制品建议为一个 macOS/ Python 兼容的 wheel，加上同一 release archive 中的本地安装器和校验文件：

```text
speechrail-<release>.whl
install_macos.py
configs/speechrail.example.env
deploy/macos/com.speechrail.plist.example
SHA256SUMS
```

分发渠道按复杂度递增：

1. 本地或可信机器：直接提供 wheel + `install_macos.py`。
2. 多台本机：上传到私有 package index 或 release archive，安装器仍在本机执行。
3. 面向非技术用户：确认 wheel 安装和升级稳定后，再考虑签名/公证的 `.pkg` 或 `.dmg`。

暂不做 `.app` 单文件、PyInstaller 合并模型、Docker、系统级服务和自建 package server。这些方案会把外部 MPS/TTS runtime、模型生命周期和服务权限问题混在一起，超出单人本机项目的必要复杂度。

## Self-Review Checklist

- [ ] wheel 边界、app home、LaunchAgent、preflight、安装、升级、回滚和文档均有对应任务。
- [ ] README 不固化具体发布版本；package metadata 仍满足 Python packaging 规范。
- [ ] ASR/TTS 模型与 vendor runtime 没有被误纳入 wheel 或 plist。
- [ ] 失败安装不会覆盖旧 runtime、`.env`、模型或当前服务。
- [ ] 所有 subprocess 使用参数数组；没有 shell interpolation、root 安装或 secret 输出。
- [ ] 发布验收同时包含静态检查、干净 wheel 安装、LaunchAgent 状态和真实 ASR/TTS smoke。
