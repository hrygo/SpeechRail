---
title: "SpeechRail 安装与首次使用"
status: active
audience: "本机最终用户、自部署用户"
version: "1.1.0"
date: 2026-09-17
---

# 📦 SpeechRail 安装与首次使用

本页面向从 [GitHub Releases](https://github.com/hrygo/SpeechRail/releases) 下载制品、准备在本机安装
SpeechRail 的用户，说明每个发布文件是什么、该装哪一个、安装顺序，以及装完如何确认服务真的可用。
命令按 zsh 编写，在「终端」中逐条执行即可。

> [!IMPORTANT]
> 服务和 App 是两个独立发布单元：只有 `com.speechrail` 用户级 LaunchAgent 提供 8201 端口的语音服务，
> `SpeechRail.app` 只是控制面。**安装 App 不会安装服务**；服务未安装时 App 会显示「无法连接本机服务」。
> 两者同时安装时先服务、后 App。退出或卸载 App 不影响服务；卸载服务也不删除模型、私有配置和历史 release。

## 1. 发布文件分别是什么

| 文件 | 内容 | 用途 | 不包含 / 不能做什么 |
|---|---|---|---|
| `speechrail-<version>-cp312-cp312-macosx_26_0_arm64.whl` | Python 服务包：`speechrail` CLI、FastAPI 应用、内置 CoreML 分人 worker，以及 `speechrail install` 安装入口 | 安装服务与版本升级 | 不含模型 snapshot、vendor runtime 和 `.env`；这些由安装入口按档位准备 |
| `SpeechRail-<version>-macOS-arm64.dmg` | unsigned 的控制面 App（DMG 内只有 `SpeechRail.app` 和指向 `/Applications` 的链接） | 服务装好后管理模型、档位、运行状态，以及配音/音色创作 | 不加载模型、不启动服务、不监听 8201；只在「音色克隆」按下录制时使用麦克风 |
| `SHA256SUMS` | 上述两个制品的 SHA-256 | 下载后校验完整性 | — |

把两个制品和 `SHA256SUMS` 放在同一个目录，然后校验：

```bash
shasum -a 256 -c SHA256SUMS
```

两条结果都显示 `OK` 才继续安装；校验失败时重新下载，不要使用来源不明的制品。

## 2. 先决条件

- Apple Silicon Mac（`arm64`）；Intel Mac 不受支持。
- 服务运行时基线是 macOS `14.0+`；**App 控制面基线是 macOS `26.0+`**（2.6.6 的 DMG 实测
  `LSMinimumSystemVersion = 26.0`）。只需要服务、不需要图形控制面时，不受 App 的系统版本要求约束。
- 已发布的 wheel 平台标签是 `macosx_26_0_arm64`；按 PEP 425 语义，`pip` / `uv` 只在 macOS 26
  及以上接受它。需要在 macOS 14/15 上部署时，用第 3.2 节的仓库流程在目标机构建 wheel。
- 磁盘：单次全新安装预留 **≥ 25 GB**（`light` 约 2.99 GB、`balanced` 约 5.96 GB、`quality` 约
  10.73 GB 的模型，外加隔离运行时；每次安装都会在 `runtime/releases` 新增目录，installer 不自动清理旧版本）。
- 首次安装需要联网访问项目锁定的模型源；模型准备只在显式确认（`--yes`）后发生，请求路径不会下载模型。
- `uv`（命令通过 `uvx` 调用，Python 3.12 由它按需取用）与 `ffmpeg`：缺少 `ffmpeg` 时 preflight 会明确
  报错，按提示安装即可；仓库首装脚本会检查并提示缺失的依赖。

## 3. 安装服务

### 3.1 从 release wheel 安装（2.7.0 起）

安装入口随 wheel 发布，所以只需要下载下来的这一个文件，不需要 clone 仓库。把 wheel 和 `SHA256SUMS`
放在同一个目录，然后在「终端」执行（把 `<version>` 换成实际版本号，例如 `2.7.0`）：

```bash
cd ~/Downloads
uvx --python 3.12 \
  --from ./speechrail-<version>-cp312-cp312-macosx_26_0_arm64.whl \
  speechrail install \
  --yes \
  --preset balanced \
  --enable
```

这条命令做四件事：把该 wheel 装进独立的 release 目录、按档位准备并逐文件校验模型、执行 preflight、
原子切换 `runtime/current`；`--enable` 再注册并启动 `com.speechrail` LaunchAgent。模型准备要下载数 GB，
通常需要几分钟。

- `--preset` 可选 `light`、`balanced`、`quality`，省略时按物理内存推荐。
- 省略 `--wheel` 时会使用当前目录里唯一的 `speechrail-*.whl`；`--yes` 之外的非交互调用会先要求确认。
- 安装器只接受版本与自身一致的 wheel：用 2.6.6 的 CLI 装 2.7.0 的 wheel 会被拒绝，避免 installer 与
  被安装的代码脱节。
- 不加 `--enable` 时只安装不启动，随后可执行
  `"$HOME/Library/Application Support/SpeechRail/runtime/current/.venv/bin/speechrail" service start --app-home "$HOME/Library/Application Support/SpeechRail"`。
- 在已装好服务的机器上重复执行同一条命令就是升级：先停旧实例、候选 release 先 preflight、成功后原子切换；
  installer 保留上一 release、私有 `.env`、selection 和模型，失败时保持或恢复原状态。
- 公共入口的完整流程与 `install_managed` API 见
  [运行时与部署](../operations/runtime-deployment.md#wheel-与本地安装器)。

### 3.2 2.6.6 及更早版本：仓库首装流程

`speechrail install` 是 2.7.0 引入的，更早的 release 只有 wheel 本体，安装器随仓库发布，所以必须
clone 仓库（或从同一 Release 页面下载 `Source code (zip)` 并解压），再运行零配置首装流程；它会在目标机
自行构建 wheel、准备模型、创建隔离 runtime 并注册 LaunchAgent，最后执行公共 API smoke：

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh --yes --preset balanced
```

这条路径也会检查并提示缺失的 Xcode CLT、Homebrew、`ffmpeg`、`uv`。磁盘、模型校验、失败恢复和
各档位差异见 [SpeechRail 零配置首装 SOP](../../.agents/skills/speechrail-zero-setup/SKILL.md)。

仓库内还可以用 `scripts/verify_release.py --wheel <wheel> --app-home "$HOME/Library/Application Support/SpeechRail"`
按 wheel 路径核对已安装 runtime。

## 4. 安装 App（DMG）

DMG 内只有 `SpeechRail.app` 和 `/Applications` 链接，把 App 拖进去即可：

```bash
open ~/Downloads/SpeechRail-<version>-macOS-arm64.dmg
cp -R "/Volumes/SpeechRail <version>/SpeechRail.app" ~/Applications/
hdiutil detach "/Volumes/SpeechRail <version>"
open ~/Applications/SpeechRail.app
```

- 可以装到 `/Applications` 或 `~/Applications`，但同一台机器只保留一个长期可执行的 `SpeechRail.app`；
  上一版本留作 ZIP/DMG 归档，不要在系统中同时放两个 App 副本。
- 该 DMG 是 **unsigned、未公证**的制品。首次从网络下载后打开时，macOS 可能提示“无法验证开发者”或
  “无法检查恶意软件”；确认来源和 `SHA256SUMS` 后，在「系统设置 → 隐私与安全性」中点“仍要打开”。
  受企业策略管理的 Mac 可能不允许此放行。
- App 需要 macOS 26 及以上，并且需要已经安装服务；服务本身仍是 macOS 14+ 的独立组件。

## 5. 首次验证

```bash
# 进程与子系统状态
curl -s -i http://127.0.0.1:8201/health | head -1

# 推理就绪（至少一个 ASR/TTS 可接受请求）
curl -s -i http://127.0.0.1:8201/readyz | head -1

# 当前档位公开的模型与音色
curl -s http://127.0.0.1:8201/v1/models
curl -s http://127.0.0.1:8201/v1/voices
```

服务状态可以用已安装 runtime 自带的 CLI 查（不需要仓库）：

```bash
"$HOME/Library/Application Support/SpeechRail/runtime/current/.venv/bin/speechrail" \
  service status --app-home "$HOME/Library/Application Support/SpeechRail"
```

打开 App 后看「服务 → 总览」，这里会显示当前档位、可用能力和最近请求；开发者和客户端接入方式见
[用户与集成指南](README.md)。`/readyz` 返回 200 只表示推理入口就绪，不代表质量或性能验收通过。

## 6. 升级与卸载

- **升级服务**：用新版本的 wheel 再跑一次第 3.1 节的 `speechrail install`；档位切换用
  `speechrail profile apply <tier>`。不要手工替换 `runtime/current` 或直接编辑 release venv。
- **升级 App**：退出旧 App，把新的 `SpeechRail.app` 复制到同一安装路径，保留上一份制品以便回滚。
- **卸载 App**：退出并删除 App bundle 即可，不影响正在运行的服务。
- **卸载服务**：

```bash
SPEECHRAIL_CLI="$HOME/Library/Application Support/SpeechRail/runtime/current/.venv/bin/speechrail"
"$SPEECHRAIL_CLI" service stop --app-home "$HOME/Library/Application Support/SpeechRail"
"$SPEECHRAIL_CLI" service disable --app-home "$HOME/Library/Application Support/SpeechRail"
"$SPEECHRAIL_CLI" service uninstall --app-home "$HOME/Library/Application Support/SpeechRail"
```

  `uninstall` 只卸载并删除 `~/Library/LaunchAgents/com.speechrail.plist`，不删除模型、私有配置、
  `runtime/releases` 和日志；版本回退流程见
  [SpeechRail 版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md)。

## 7. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| App 显示「无法连接本机服务」或菜单显示「服务未连接」 | 只装了 App，或服务没启动 | 先按第 3 节安装服务；已安装未启动时执行 `"$HOME/Library/Application Support/SpeechRail/runtime/current/.venv/bin/speechrail" service start --app-home "$HOME/Library/Application Support/SpeechRail"` |
| 打开 App 提示无法验证开发者 / 无法检查恶意软件 | DMG 为 unsigned、未公证制品 | 确认来源与 `SHA256SUMS` 后走「隐私与安全性 → 仍要打开」；企业托管 Mac 可能禁止 |
| `pip install` / `uv pip install` wheel 报平台不兼容 | wheel 平台标签为 `macosx_26_0_arm64` | 在 macOS 26 上安装，或在目标机用第 3.2 节流程构建 wheel |
| `uvx` 报 `no wheels with a matching Python version tag` | 默认用了比 3.12 更新的解释器 | 按第 3.1 节加上 `--python 3.12` |
| `install` 报 wheel 版本与 installer 不一致 | CLI 与待安装 wheel 不是同一个版本 | 让 `uvx --from` 指向要安装的那个 wheel |
| `/readyz` 返回 503 `backend_not_ready` | 服务已启动但模型或运行时未就绪 | 用 `speechrail service preflight` 与 [运维 Runbook](../operations/operations-runbook.md) 定位 |
| App 无法在旧系统上打开 | App 基线是 macOS 26.0 | 服务仍可在 macOS 14+ 运行，此时只用 CLI、HTTP 与 WebSocket |

## 8. 参考

- [用户与集成指南中心](README.md)
- [SpeechRail 零配置首装 SOP](../../.agents/skills/speechrail-zero-setup/SKILL.md)
- [运行时与部署](../operations/runtime-deployment.md)
- [运维操作实战手册](../operations/operations-runbook.md)
- [macOS App 分发与签名](../developers/macos-app-release.md)
