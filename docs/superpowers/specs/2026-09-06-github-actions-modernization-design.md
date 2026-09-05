# SpeechRail GitHub Actions 全面更新设计

## 状态与范围

- 状态：设计草案，待用户审阅
- 日期：2026-09-06
- 范围：`.github/workflows/`、`.github/dependabot.yml`，以及与 CI 门禁直接相关的开发者文档
- 不修改：应用代码、公共 API、模型/运行时依赖、现有发布制品、用户配置，以及当前工作区中已有的 README 未提交改动

本设计针对当前 `main` 分支的 GitHub Actions。当前工作流已经具备基础的最小权限、并发取消、Ubuntu/macOS 双矩阵、Python 3.12 和 `uv` 缓存，但最近的 wheel 发布流程、版本一致性检查、OpenAPI lint、分人契约回归和制品安全校验没有形成统一自动门禁。

## 已确认事实

当前 `.github/workflows/ci.yml`：

- 在 `main` 的 push 和 pull request 上运行；
- 使用 Ubuntu 与 `macos-14`、Python 3.12 矩阵；
- 安装 `ffmpeg`，使用 `astral-sh/setup-uv@v5` 缓存 `uv.lock`；
- 执行 `uv sync --extra dev`、wheel 构建、Ruff、Mypy 和完整 Pytest；
- 已声明 `contents: read`、并发取消和 10 分钟超时。

当前 `.github/workflows/release.yml`：

- 仅由 `v*` tag 触发；
- 工作流级别拥有 `contents: write`；
- 在 Ubuntu 上重新安装依赖并构建 wheel；
- 使用 `softprops/action-gh-release@v2` 直接创建或更新公开 Release；
- 没有在发布前强制 `uv.lock`、项目版本、tag、OpenAPI、版本一致性和 wheel 内容门禁，也没有生成 SHA-256 清单。

项目已有且应纳入自动化的事实来源与检查：

- Python 版本固定为 `>=3.12,<3.13`；
- `uv.lock` 是可复现安装的锁文件；
- `scripts/check_version_consistency.py` 检查包、配置、OpenAPI、fixture、锁文件和 CHANGELOG 版本；
- `tests/test_wheel_contents.py`、`tests/test_diarization_contracts.py`、`tests/test_diarization_extensions.py` 等测试已经覆盖 wheel 与最近的说话人分离契约；
- 正式测试门禁还包括 OpenAPI lint、`git diff --check`；
- 测试应使用 fake backend 和合成/脱敏数据，不安装 `diarization` 可选重型模型依赖，不下载模型，不访问远程音频。

## 目标

1. 让 PR、`main` push 和 tag release 使用同一套可复现质量门禁，避免 CI 与发布流程漂移。
2. 在不破坏现有 Python 3.12、Ubuntu/macOS 双平台验证和 `test` 检查语义的前提下，提高反馈速度和失败定位能力。
3. 将近期的说话人分离架构优化纳入显式 contract/regression gate，而不是只依赖完整测试偶然覆盖。
4. 让发布流程先验证版本和制品，再授予最小范围的写权限并发布。
5. 降低第三方 Action 和未固定工具版本带来的供应链风险，保留 Dependabot 的可维护更新路径。

## 非目标

- 不在 GitHub Actions 中下载或运行真实 ASR/TTS/diarization 模型。
- 不把 Apple Silicon 真实性能、音色稳定性、物理内存和本机 LaunchAgent 验收搬到 GitHub-hosted runner；这些仍由本机发布/benchmark SOP 负责。
- 不新增多版本 Python 矩阵；项目公共支持范围仍是 Python 3.12。
- 不自动合并 Dependabot PR，不改变分支保护规则，不创建新分支，不修改现有 tag。
- 不引入云端服务、持久化音频、凭据或真实用户数据。
- 本阶段不引入完整 SLSA provenance/供应链平台；先提供不可变 Action 引用、锁文件门禁和发布 SHA-256 清单，后续可单独评估签名证明。

## 方案比较

### 方案 A：只增补现有两个 workflow

在当前 `ci.yml` 和 `release.yml` 中直接增加检查、锁文件和哈希步骤。

- 优点：改动最小，现有检查名和 UI 结构变化少。
- 缺点：CI 与 Release 仍会复制安装、测试和构建逻辑，后续很容易再次漂移；发布前无法天然复用同一套 job。
- 结论：不采用。当前任务的主要问题正是门禁重复且不一致。

### 方案 B：可复用 CI + 分层发布（推荐）

将 `ci.yml` 同时设计为普通触发工作流和 `workflow_call` 可复用工作流。CI 保留现有 `test` 矩阵，增加快速的 `quality` 与依赖它们的 `package` job；Release 先做 tag/版本预检，再调用同一份 CI，最后由独立的 `publish` job 下载已验证 wheel 并发布。

- 优点：质量门禁单一来源；保留已有 `test` 检查兼容性；写权限只存在于发布 job；失败天然阻止制品发布；构建产物可追踪。
- 缺点：需要理解 reusable workflow 的 job 依赖和 artifact 生命周期，workflow 结构比当前稍复杂。
- 结论：采用。它在本项目当前规模下能消除重复，又不引入额外运行时基础设施。

### 方案 C：自定义 Composite Action + 多层 reusable workflow

把 checkout、uv、Python、依赖同步、各类检查进一步抽成多个本地 composite action，再由多个 workflow 组合。

- 优点：复用粒度最细。
- 缺点：抽象层增加，错误日志和本地复现路径变差；对当前只有两个工作流的仓库属于过度设计。
- 结论：不采用。先使用一个可复用 CI workflow；只有出现第三个消费者时再拆 composite action。

## 采用设计

### 1. CI 工作流拓扑

`.github/workflows/ci.yml` 增加 `workflow_call`，同时保留：

- `push` 到 `main`；
- 面向 `main` 的 `pull_request`；
- `workflow_dispatch`，用于维护者手动重跑非发布验证；
- `merge_group`，兼容启用 merge queue 的仓库。

工作流继续使用顶层 `permissions: contents: read`、按 ref/PR 编号分组的 `concurrency`、每个 job 的 `timeout-minutes` 和 `persist-credentials: false`。所有第三方 Action 使用不可变 commit SHA，并保留对应 release tag 注释；Dependabot 负责后续更新这些 SHA。

Job 责任如下：

#### `quality`

在 Ubuntu + Python 3.12 上执行不需要 `ffmpeg` 的快速门禁：

1. checkout；
2. 安装固定版本的 `uv`，按 `uv.lock` 缓存；
3. `uv python install 3.12`；
4. `uv sync --locked --extra dev`；
5. `uv run ruff check src tests scripts`；
6. `uv run mypy src`；
7. `uv run python scripts/check_version_consistency.py`；
8. 使用固定版本的 Redocly CLI 执行 `contracts/openapi.yaml` lint；
9. 对当前提交相对于 PR base（PR 场景）或上一个提交（push/tag/workflow_call 场景）执行 `git diff --check`，不只检查干净 checkout 的工作树；
10. 显式运行说话人分离契约/扩展测试，确保 schema、归属补丁、终态屏障和错误边界在 CI UI 中有可识别的检查结果。

不在该 job 安装 `uv sync --extra diarization`，避免把 NeMo 等重型可选依赖引入确定性 CI；相关 contract 测试使用现有 fake/fixture 路径。

#### `test`

保留现有 job id 和 Ubuntu/macOS 14、Python 3.12 矩阵，以降低已有分支保护检查失效的风险。每个矩阵单元：

1. checkout 并关闭凭据持久化；
2. 安装 runner 所需的 `ffmpeg`；
3. `uv sync --locked --extra dev`；
4. 先执行 `uv build --no-sources --wheel`，保持现有 wheel-before-test 约束；
5. 执行带覆盖率门禁的完整 Pytest；
6. 输出覆盖率摘要，不上传测试音频、日志或完整转写结果。

矩阵仍然是确定性 fake backend 测试，不启动本机 LaunchAgent，不访问模型目录，不向请求路径加入网络调用。

#### `package`

仅在 `quality` 和全部 `test` 矩阵通过后运行，在 Ubuntu 上重新使用锁定环境构建唯一发布 wheel：

1. `uv sync --locked --extra dev`；
2. `uv build --no-sources --wheel`；
3. 执行 wheel 内容安全检查和 ZIP 完整性检查；
4. 运行 `scripts/check_version_consistency.py`，防止测试后工作树版本漂移；
5. 生成 `SHA256SUMS`；
6. 使用固定版本的 `actions/upload-artifact` 上传 wheel 与清单，设置有限保留期。

`package` 的 artifact 名称保持固定且只由该次 workflow run 使用，Release 通过同一 run 下载，不从“最新成功运行”猜测制品。

### 2. Release 工作流

`.github/workflows/release.yml` 继续只接受 `v*` tag push，不新增可绕过 tag 的手动公开发布入口。

#### `verify-tag`

使用只读权限 checkout 当前 tag，读取 `pyproject.toml` 的 `[project].version`，要求：

```text
github.ref_name == "v" + project.version
```

任何不一致立即失败，不创建 Release、不修改 tag、不上传 artifact。

#### `ci`

依赖 `verify-tag`，通过 `workflow_call` 调用 `ci.yml`。Release 不复制质量命令；只有被调用的 CI 全部通过并上传 wheel 后才继续。

#### `publish`

依赖 `ci`，这是唯一拥有 `contents: write` 的 job。它：

1. 下载本次 reusable workflow 上传的固定名称 artifact；
2. 重新核对 wheel 文件名与当前版本；
3. 生成或验证 SHA-256 清单；
4. 使用 runner 内置 `gh` CLI 创建或幂等更新当前 tag 的 GitHub Release，并生成 release notes；
5. 同时上传 wheel 与 `SHA256SUMS`。

移除 `softprops/action-gh-release`，减少一个发布写权限下的第三方执行面。`GH_TOKEN` 只注入 `publish` 的单个 shell step。发布脚本所有变量均加引号，tag 由 GitHub 事件上下文提供，不接受 PR 或用户输入覆盖。

发布 job 的重跑必须是幂等的：已有同名 Release 时只更新同名资产，不创建第二个 Release，也不移动 tag。并发策略保持同一 tag 不并行发布。

### 3. Dependabot 与维护策略

更新 `.github/dependabot.yml`：

- Python/pip 依赖每周检查；
- GitHub Actions 每周检查，不再按月滞后；
- 对同一生态的更新做分组，限制 PR 数量，保留 `dependencies` 与 `ci` 标签；
- Action SHA 更新必须保留可读的上游版本注释，便于 review；
- 不自动批准或自动合并依赖升级。

### 4. 文档同步

只更新与自动门禁直接相关的文档：

- `CONTRIBUTING.md`：说明 `--locked`、版本一致性、OpenAPI lint、wheel 构建和 CI 检查；
- `docs/developers/testing-acceptance.md`：区分本地确定性门禁、GitHub Actions 双平台验证和本机真实 worker/性能验收；
- 新增的设计规格记录本次 workflow 拓扑、权限边界和回退策略。

不改 README 中的产品描述，不覆盖当前并行修改。

## 失败与安全边界

- `uv.lock` 与项目声明不一致：`uv sync --locked` 失败，后续 job 不运行。
- 版本/tag 不一致：`verify-tag` 失败，发布 job 不获得写权限执行机会。
- 任一平台测试失败：`package` 和 `publish` 被跳过。
- wheel 内容、版本 fixture 或 SHA-256 检查失败：不上传、不发布。
- pull request、fork 和普通 `main` CI 不拥有 `contents: write`，也不接触发布 token。
- workflow 不写入 `.env`、模型快照、音频、完整日志或用户路径。
- 由于 wheel 是纯 Python 发布包，不新增 macOS 专用发布构建；真实 Apple Silicon runtime 继续使用本机 SOP 验收。

## 回退方案

本次改动保持原有 tag 触发入口和 `test` 矩阵语义。若新 workflow 在 GitHub runner 上出现兼容性问题：

1. 先暂停或回退 workflow 变更 commit，恢复旧版 CI/Release 文件；
2. 已存在的 tag、Release 和本机已部署 runtime 不受影响；
3. 重新发布时必须继续使用版本/tag 一致性检查，不能为了绕过失败而移动 tag；
4. 如果只发布 job 失败，保留 CI artifact，修复发布步骤后对同一 tag 幂等重跑。

## 验收标准

### 静态与本地验证

- workflow YAML 通过 `actionlint`；
- YAML 结构、job 依赖和 `workflow_call` 输入通过 GitHub Actions 语法检查；
- 当前提交差异的 `git diff --check` 通过；
- 不触碰 README 当前未提交修改；
- 使用现有项目门禁验证：pytest、Ruff、Mypy、OpenAPI lint、版本一致性和 wheel 检查。

### GitHub 行为验证

- PR 运行 `quality`、Ubuntu `test`、macOS `test` 和 `package`；
- job 失败时不会上传可发布 artifact 或执行 Release；
- `main` push 可复用同一 CI；
- 非匹配 tag 被 `verify-tag` 拒绝；
- 匹配 tag 只由 `publish` 使用写权限创建或幂等更新 Release；
- Release 资产包含 wheel 和 `SHA256SUMS`；
- Dependabot 能识别并更新固定 SHA 的 Actions 引用。

## 后续可选项

在本次稳定运行一轮后，再单独评估：

- GitHub artifact provenance/attestation；
- workflow 安全扫描（如 zizmor）；
- branch protection required checks 的显式配置；
- 依赖漏洞扫描的阈值与误报治理。

这些项目不作为本次实现的隐式前置条件，避免把发布基础设施更新扩大为新的安全平台项目。
