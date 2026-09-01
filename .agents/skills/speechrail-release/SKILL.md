---
name: speechrail-release
description: SpeechRail 版本发布流程。Use when cutting a SpeechRail release: bumping version across all files, updating CHANGELOG and docs metadata, building the wheel, installing/upgrading the launchd service, and running full verification gates. Covers the exact file list with line-level version references, the 4-step gate, wheel build/install commands, health/model/voice verification, and rollback. Triggers: 发布, release, 版本号, bump version, 构建 wheel, 安装新版本, tag, git tag, speechrail 发布.
---

# SpeechRail 版本发布

SpeechRail 是单人本机 ASR/TTS 服务，默认部署目标为本机一个 wheel release +
`launchd` LaunchAgent。本 skill 指导完整发布流程：版本号精准更新 → 门禁 → 构建 →
安装 → 验证 → 提交与 tag。

## 核心原则

- 版本号是**配置事实来源**；`/health` 返回的 `version` 来自
  `src/speechrail/config/__init__.py` 的 `Settings.version`，不是包版本。
- 一次 commit 只表达一个逻辑主题：`refactor:`/`fix:` 代码、`chore:` 版本号、
  `docs:` 文档分开提交。
- 破坏性变更必须伴随 ADR 或归档记录；不 force-push、不覆盖他人分支。
- 服务安装/升级/回滚必须使用 `speechrail service` CLI 与 `tools/install_macos.py`，
  不得手动编辑 plist 或 kill 进程。
- 模型 snapshot、vendor Python、`ffmpeg`、`.env` 均在仓库外，由本机单独准备；
  发布流程不下载模型、不覆盖 `.env`。

## 版本号精准更新清单（文件 + 行号索引）

发布新版本 `<X.Y.Z>` 时，以下文件必须同步更新。行号以 **v1.0.0**（2026-09-02）为基准，
随代码改动会漂移；发布前必须用 `rtk grep -rn "<旧版本>" <路径>` 重新定位，勿凭记忆或
仅依赖行号。

| # | 文件 | 行号（v1.0.0 基准） | 更新为 | 说明 |
|---|---|---|---|---|
| 1 | `pyproject.toml` | L3 `version = "..."` | `version = "X.Y.Z"` | PEP 621 包版本 |
| 2 | `src/speechrail/__init__.py` | L3 `__version__ = "..."` | `__version__ = "X.Y.Z"` | 包 `__version__` 属性 |
| 3 | `src/speechrail/config/__init__.py` | L28 `version: str = "..."` | `version: str = "X.Y.Z"` | `Settings.version` 默认值，**决定 `/health` 输出**，最容易遗漏 |
| 4 | `contracts/openapi.yaml` | L4 `info.version`；L47 `/health` example | 两处 `X.Y.Z` | `info.version` + example 双位置 |
| 5 | `configs/speechrail.example.env` | L5 `SPEECHRAIL_VERSION=` | `X.Y.Z` | 环境模板 |
| 6 | `configs/speechrail.example.yaml` | L5 `version:` | `X.Y.Z` | YAML 模板 |
| 7 | `tests/test_app_contract.py` | L24、L124 `"version": "..."` | 两处 `"X.Y.Z"` | `/health` 断言（asr_ready False/True 各一） |
| 8 | `tests/test_installer.py` | L34 wheel 文件名 | `speechrail-X.Y.Z-py3-none-any.whl` | 测试夹具 |
| 9 | `tests/test_release_verification.py` | L23 dist-info 名 | `speechrail-X.Y.Z.dist-info/METADATA` | 测试夹具 |
| 10 | `CHANGELOG.md` | L3 `[Unreleased]`（L5 `[1.0.0]` 参考格式） | 新 `[X.Y.Z]` 条目 + 新 `[Unreleased]` | 按 Keep a Changelog |
| 11 | docs front-matter | `docs/architecture/architecture.md` L4、`docs/architecture/product-scope.md` L4 | `version: "X.Y.Z"` + `date` | **仅正文实质变更时更新**（AGENTS.md metadata 规则）；`date` 为更新日期，不是日历日期 |
| 12 | `uv.lock` | L2163-2164 包版本 | `X.Y.Z` | `uv sync` 自动同步，勿手改 |

**注意**：
- `tests/test_worker_protocol.py`、`tests/test_qwen3_tts.py` 中的 `"version": 1` 是
  **worker 帧协议版本**（int），不是发布版本，不要改。
- `contracts/openapi.yaml` L316 `version: {type: string}` 是 schema 字段定义，不是值。
- `tools/install_macos.py`、`scripts/verify_release.py` 从 wheel 文件名动态解析版本，
  无硬编码，不需要改。
- `docs/archive/` 与 `docs/superpowers/` 为历史材料，不随发布更新。
- 已发布历史版本号引用（如 docs 中 "v1.0.0 已移除"）保留原样。

## 发布流程

### Step 1 — 前置检查

```bash
cd <path-to-SpeechRail>
git status --short        # 工作树干净或明确属于本发布
git log --oneline -5      # 确认分支与最近提交
```

### Step 2 — 版本号更新

按上表逐文件更新。全部完成后：

```bash
rtk grep -rn "0\.1\.0" pyproject.toml src/ contracts/ configs/ tests/  # 应无旧版本残留
uv run --extra dev python -c "from speechrail.config import Settings; print(Settings().version)"
# 必须输出新版本
```

### Step 3 — 门禁（完整代码 gate）

```bash
uv run --extra dev pytest                      # 全部通过
uv run --extra dev ruff check src tests        # clean
uv run --extra dev mypy src                    # Success
npx @redocly/cli lint contracts/openapi.yaml   # valid
git diff --check                               # clean
```

mypy 报错时先确认是否为**干净基线**（`git stash` 后重跑对比），不要在工作树半删除状态
下判断"预先存在错误"。

### Step 4 — 按主题提交

```bash
git add <代码文件> && git commit -m "refactor: ..."   # 代码主题
git add pyproject.toml src/__init__.py ... && git commit -m "chore: bump version to X.Y.Z"
git add README.md AGENTS.md docs/ && git commit -m "docs: ..."
```

版本号 commit 必须包含 `config/__init__.py` 的 `Settings.version` 行——它独立于
代码 refactor，不要混入移除类 commit。

### Step 5 — 构建 wheel

```bash
uv build --no-sources --wheel
# 输出 dist/speechrail-<X.Y.Z>-py3-none-any.whl
```

### Step 6 — 安装/升级服务

```bash
USER_APP_HOME="$HOME/Library/Application Support/SpeechRail"
uv run speechrail service disable --app-home "$USER_APP_HOME"   # 先停旧实例，避免争用 8201
python3 tools/install_macos.py \
  --wheel dist/speechrail-<X.Y.Z>-py3-none-any.whl \
  --env-file "$USER_APP_HOME/config/.env" \
  --app-home "$USER_APP_HOME" \
  --enable
```

`--env-file` 指向**已存在的** `<app-home>/config/.env`（安装器不覆盖已有配置）。

### Step 7 — 验证

等待模型 worker 加载（ASR+TTS 双配置约 30-40s）：

```bash
sleep 30
curl -s http://127.0.0.1:8201/health    # version 必须为新版本；asr_ready/tts_ready=true
curl -s http://127.0.0.1:8201/readyz    # ready:true
curl -s http://127.0.0.1:8201/v1/models  # canonical + alias（resolves_to）
curl -s http://127.0.0.1:8201/v1/voices  # preset 目录，available 状态
readlink "$USER_APP_HOME/runtime/current"  # 指向新 release 目录
ps -p <pid> -o command=                  # 确认进程用 runtime/current/.venv
```

**关键检查**：`/health` 的 `version` 若仍显示旧版本，说明 `Settings.version` 未更新或
`config/.env` 有 `SPEECHRAIL_VERSION` 覆盖——先查 `config/.env` 是否有该键，再查
`config/__init__.py`。

真实推理 smoke（有外部 snapshot/runtime 时）：

```bash
./examples/curl-transcribe.sh <path-to-short-audio>   # HTTP 200 + 非空文本
```

### Step 8 — git tag

```bash
git tag v<X.Y.Z>
git push origin v<X.Y.Z>   # 仅推送自己的 tag，不 force-push
```

## 回滚

```text
1. uv run speechrail service disable --app-home <app-home>
2. 保留旧 runtime/releases/、config/.env 与模型（不删除外部资源）
3. 将 runtime/current 恢复到上一份 release（或备份 plist）
4. uv run speechrail service install --app-home <app-home>，再显式 enable
5. 重新核对 service status、/health、/readyz、/v1/models、/v1/voices
```

`disable` 只停止服务；`uninstall` 删除 plist；都不是 release 回退。

## 常见陷阱

| 陷阱 | 处理 |
|---|---|
| `/health` 版本不变 | `Settings.version` 默认值未改，或 `config/.env` 有 `SPEECHRAIL_VERSION` |
| 旧实例仍占 8201 | 安装前必须 `service disable`；单实例原则 |
| mypy 报错误判"预先存在" | `git stash` 后跑干净基线对比，半删除状态会误报 |
| `git checkout -- <file>` 误恢复 | 发布期间勿用 destructive checkout/stash 操作整理提交；用 `git restore --staged` 拆分 |
| 测试夹具版本号漏改 | `test_installer.py` wheel 名、`test_release_verification.py` dist-info、`test_app_contract.py` 断言 |
| 版本 commit 缺 `Settings.version` | `/health` 与包版本脱节；版本 commit 必须含 `config/__init__.py` |
| docs front-matter 随日历更新 | 仅正文实质变更才更新 `version`/`date`（AGENTS.md metadata 规则） |

## 验证清单（发布完成判定）

- [ ] 版本号所有位置一致（含 `Settings.version`）
- [ ] pytest / ruff / mypy / redocly / git diff check 全绿
- [ ] wheel 构建成功且版本正确
- [ ] 服务运行新 release，`/health` 返回新版本
- [ ] `/readyz` true、`/v1/models` 与 `/v1/voices` 正常
- [ ] 真实音频 smoke 通过（有模型时）
- [ ] commit 按主题拆分、`git tag v<X.Y.Z>` 已打