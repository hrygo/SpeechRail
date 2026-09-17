---
title: "SpeechRail 安装与首次使用"
status: active
audience: "本机最终用户、自部署用户"
version: "1.0.0"
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
| `speechrail-<version>-cp312-cp312-macosx_26_0_arm64.whl` | Python 服务包：`speechrail` CLI、FastAPI 应用、内置 CoreML 分人 worker | 服务交付与版本升级 | 不含模型 snapshot、vendor runtime、`.env` 和 managed 安装器；单独安装它不会得到可用服务 |
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
- 2.6.6 release 的 wheel 平台标签是 `macosx_26_0_arm64`；按 PEP 425 语义，`pip` / `uv` 只在
  macOS 26 及以上接受该 wheel。需要在 macOS 14/15 上部署时，改用第 3.1 节的首装流程在目标机构建 wheel。
- 磁盘：单次全新安装预留 **≥ 25 GB**（`light` 约 2.99 GB、`balanced` 约 5.96 GB、`quality` 约
  10.73 GB 的模型，外加隔离运行时；每次安装都会在 `runtime/releases` 新增目录，installer 不自动清理旧版本）。
- 首次安装需要联网访问项目锁定的模型源；模型准备只在显式确认（`--yes`）后发生，请求路径不会下载模型。
- `uv`、`ffmpeg` 以及 Python `>=3.12,<3.13`：首装脚本会检查并提示缺失项，缺失时按提示安装即可。

## 3. 安装服务

### 3.1 首装（当前唯一完整支持的首装路径）

全新机器上用仓库内的零配置首装流程。它会在独立输出目录构建本次唯一 wheel、按档位准备并逐文件校验模型、
创建隔离 runtime 并注册 `com.speechrail` LaunchAgent，最后执行公共 API smoke：

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh \
  --yes \
  --preset balanced
```

`--preset` 可选 `light`、`balanced`、`quality`，省略时按物理内存推荐。磁盘、模型校验、失败恢复和
各档位差异见 [SpeechRail 零配置首装 SOP](../../.agents/skills/speechrail-zero-setup/SKILL.md)。

> [!NOTE]
> 首装流程是在目标机自行构建 wheel，**不下载 Release 里的 wheel**。因此 Release 资产是给审计、
> 手工交付和升级用的制品，不是首装的下载入口。

### 3.2 Release wheel 的用途与限制

managed 安装器（准备 release 目录、preflight、更新 LaunchAgent、原子切换 `runtime/current`）和示例配置
都在仓库里，不随 wheel 或 Release 资产发布。因此：

- **只下载了 wheel**：仍需 clone 仓库，再按
  [运行时与部署](../operations/runtime-deployment.md#wheel-与本地安装器) 里的 managed installer 安装该 wheel；
  installer 负责注入 catalog 选定档位、执行 preflight 并原子切换。
- **已经装好服务、只想升到本次 release**：同样走 managed installer（先停旧实例、候选 release 先 preflight、
  成功后切换）；不要手工覆盖 `runtime/current` 或直接编辑 release venv。
- **安装后的校验**：用仓库内脚本按 wheel 路径核对已安装 runtime，而不是源码工作树：

```bash
python3 scripts/verify_release.py \
  --wheel <下载的 wheel 路径> \
  --app-home "$HOME/Library/Application Support/SpeechRail"
```

安装器会保留上一 release、私有 `.env`、selection 和模型，失败时保持或恢复原状态；不要为了“装干净”而
删除它们。

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

在 clone 目录里还可以查服务状态：

```bash
uv run speechrail service status --app-home "$HOME/Library/Application Support/SpeechRail"
```

打开 App 后看「服务 → 总览」，这里会显示当前档位、可用能力和最近请求；开发者和客户端接入方式见
[用户与集成指南](README.md)。`/readyz` 返回 200 只表示推理入口就绪，不代表质量或性能验收通过。

## 6. 升级与卸载

- **升级服务**：走 managed installer 与 `speechrail profile apply <tier>`，不要绕过它手工替换 runtime。
- **升级 App**：退出旧 App，把新的 `SpeechRail.app` 复制到同一安装路径，保留上一份制品以便回滚。
- **卸载 App**：退出并删除 App bundle 即可，不影响正在运行的服务。
- **卸载服务**：

```bash
uv run speechrail service stop --app-home "$HOME/Library/Application Support/SpeechRail"
uv run speechrail service disable --app-home "$HOME/Library/Application Support/SpeechRail"
uv run speechrail service uninstall --app-home "$HOME/Library/Application Support/SpeechRail"
```

  `uninstall` 只卸载并删除 `~/Library/LaunchAgents/com.speechrail.plist`，不删除模型、私有配置、
  `runtime/releases` 和日志；版本回退流程见
  [SpeechRail 版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md)。

## 7. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| App 显示「无法连接本机服务」或菜单显示「服务未连接」 | 只装了 App，或服务没启动 | 先按第 3 节安装服务，再在 clone 目录执行 `uv run speechrail service start --app-home "$HOME/Library/Application Support/SpeechRail"` |
| 打开 App 提示无法验证开发者 / 无法检查恶意软件 | DMG 为 unsigned、未公证制品 | 确认来源与 `SHA256SUMS` 后走「隐私与安全性 → 仍要打开」；企业托管 Mac 可能禁止 |
| `pip install` / `uv pip install` wheel 报平台不兼容 | wheel 平台标签为 `macosx_26_0_arm64` | 在 macOS 26 上安装，或在目标机用第 3.1 节流程构建 wheel |
| `/readyz` 返回 503 `backend_not_ready` | 服务已启动但模型或运行时未就绪 | 用 `speechrail service preflight` 与 [运维 Runbook](../operations/operations-runbook.md) 定位 |
| App 无法在旧系统上打开 | App 基线是 macOS 26.0 | 服务仍可在 macOS 14+ 运行，此时只用 CLI、HTTP 与 WebSocket |

## 8. 参考

- [用户与集成指南中心](README.md)
- [SpeechRail 零配置首装 SOP](../../.agents/skills/speechrail-zero-setup/SKILL.md)
- [运行时与部署](../operations/runtime-deployment.md)
- [运维操作实战手册](../operations/operations-runbook.md)
- [macOS App 分发与签名](../developers/macos-app-release.md)
