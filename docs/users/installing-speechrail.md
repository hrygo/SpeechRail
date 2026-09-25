---
title: "SpeechRail 安装与首次使用"
status: active
audience: "本机最终用户、自部署用户"
version: "1.4.0"
date: 2026-09-26
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
| `speechrail-<version>-cp314-cp314-macosx_26_0_arm64.whl` | Python 服务包：`speechrail` CLI、FastAPI 应用、内置 CoreML 分人 worker，以及 `speechrail install` 安装入口 | 安装服务与版本升级 | 不含模型 snapshot、vendor runtime 和 `.env`；这些由安装入口按规格准备 |
| `SpeechRail-<version>-macOS-arm64.dmg` | unsigned 的控制面 App | 服务装好后管理模型、档位、运行状态，以及配音/音色创作 | 不加载模型、不启动服务、不监听 8201；只在「音色克隆」按下录制时使用麦克风 |
| `SHA256SUMS` | 上述两个制品的 SHA-256 | 下载后校验完整性 | — |

把两个制品和 `SHA256SUMS` 放在同一个目录，然后校验：

```bash
shasum -a 256 -c SHA256SUMS
```

两条结果都显示 `OK` 才继续安装；校验失败时重新下载，不要使用来源不明的制品。

## 2. 先决条件

- Apple Silicon Mac（`arm64`）；Intel Mac 不受支持。
- 服务与 App 的当前交付基线均为 macOS `26.0+`、Apple Silicon `arm64`。
- 已发布的 wheel 平台标签是 `macosx_26_0_arm64`；`pip` / `uv` 只会在 macOS 26 及以上接受该制品。
- 磁盘：单次全新安装预留 **≥ 25 GB**：所选规格组合待准备的模型集按 catalog 清单估算约为
  `fast/fast` 5.0 GB、`quality/quality` 8.7 GB、`reference/reference` 13.2 GB，另加隔离运行时；
  分人资产（aligner 1.28 GB / 1.84 GB）与 `reference` 的 VoiceDesign 制品（4.5 GB）另计。模型与
  vendor runtime 按清单复用，升级不会重复占用；每装一个
  **新版本** wheel 会在 `runtime/releases` 新增一个目录（重装同一份 wheel 则复用），而安装器不会
  自动清理旧版本——确认不再需要回退后，可以手动删除旧的 `runtime/releases/<旧版本>`，唯一不能删的
  是 `runtime/current` 指向的那份。
- 首次安装需要联网：先访问 PyPI 装 wheel 的依赖，再访问项目锁定的模型源取模型 snapshot。模型准备
  只在显式确认（`--yes`）后发生，请求路径不会下载模型。
- `uv`：安装命令通过 `uvx` 调用，Python 3.14.7 由它按需取用。缺少 `uv` 时 `install` 会在准备模型前
  直接给出安装地址，不会跑到一半才失败。
- 不需要预装 `ffmpeg`：安装器把锁定的 `imageio-ffmpeg` 装进隔离 runtime，并让服务指向该副本。

## 3. 安装服务

### 3.1 从 Release wheel 安装

安装入口随 wheel 发布，所以只需要下载下来的这一个文件，不需要 clone 仓库。把 wheel 和 `SHA256SUMS`
放在同一个目录（通常是 `~/Downloads`），然后在「终端」执行。通配符会展开成该目录里唯一的
wheel，因此不用手抄版本号；如果目录里还留着旧版本的 `speechrail-*.whl`，请先把旧 wheel 移到别处，
或者改用 `--wheel <路径>` 显式指定：

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS
uvx --python 3.14.7 --from ./speechrail-*.whl \
  speechrail install \
  --yes \
  --asr-spec quality \
  --tts-spec quality \
  --enable
```

这条命令做四件事：把该 wheel 装进独立的 release 目录、按所选规格准备并逐文件校验模型、执行 preflight、
原子切换 `runtime/current`；`--enable` 再注册并启动 `com.speechrail` LaunchAgent，并在结束后轮询
`/readyz` 报告服务是否真的可用（超时不算失败，只提示后续排查命令）。模型准备要下载数 GB，
通常需要几分钟，中途可以放心等待。

- `--asr-spec` 与 `--tts-spec` 各自可选 `fast`、`quality`、`reference`，可混搭；只传其中一项时另一项
  沿用已有选择或按物理内存推荐（< 10 GiB 为 `fast/fast`，< 16 GiB 为 `quality/fast`，其余 `quality/quality`）。
- 省略 `--wheel` 时会使用当前目录里唯一的 `speechrail-*.whl`；不带 `--yes` 时会先要求确认。
- 安装器每个 app home 只保留一组规格：已装过服务时，省略 `--asr-spec`/`--tts-spec` 会沿用当前组合，
  避免升级时被内存推荐改档；显式传一组不同规格会被拒绝，换规格请用已安装 runtime 的
  `speechrail profile apply --asr-spec <tier> --tts-spec <tier> --yes`。
- 安装器只接受与自身版本一致的 wheel，避免 installer 与被安装的代码脱节。
- 不加 `--enable` 时只安装不启动，命令结尾会打印该 runtime 自己的 `service start` 命令。
- 命令结尾固定打印三样东西：已安装 runtime 的 `speechrail` CLI 路径、双击即可换档位的
  `SpeechRail 设置.command`、以及服务地址（默认 `http://127.0.0.1:8201`）。
- 命令开始时就会说明要下载什么：本机已登记且校验通过的模型会打印
  `Models: local snapshots are already registered; expect no download.`，否则列出待下载的制品；
  过程中逐条打印 `Reusing verified model …` / `Downloading …`，结束时给出实际下载量。
- **升级必须先停服务**：运行中的实例占用 8201，安装器会 fail-closed 拒绝在运行中替换
  `runtime/current`。完整三步见第 6 节；失败时安装器保持或恢复原状态，上一 release、私有 `.env`、
  档位记录和模型都保留。
- 公共入口的完整流程与 `install_managed` API 见
  [运行时与部署](../operations/runtime-deployment.md#wheel-与本地安装器)。

### 3.2 源码首装

需要从源码准备本机依赖时，运行零配置首装流程；它会构建当前源码 wheel、准备模型、创建隔离 runtime
并注册 LaunchAgent：

```bash
git clone https://github.com/hrygo/SpeechRail.git
cd SpeechRail
./.agents/skills/speechrail-zero-setup/scripts/bootstrap_mac.sh \
  --yes --asr-spec quality --tts-spec quality
```

这条路径也会检查并提示缺失的 Xcode CLT、Homebrew、`ffmpeg`、`uv`。磁盘、模型校验、失败恢复和
各规格差异见 [SpeechRail 零配置首装 SOP](../../.agents/skills/speechrail-zero-setup/SKILL.md)。

## 4. 安装 App（DMG）

DMG 挂载后的卷名是 `SpeechRail <version>`，里面只有 `SpeechRail.app`。将 App 拖到当前用户的
`Applications` 目录即可：

```bash
open ~/Downloads/SpeechRail-<version>-macOS-arm64.dmg
```

习惯用终端时也可以走同一条复制路径：

```bash
mkdir -p "$HOME/Applications"
cp -R "/Volumes/SpeechRail <version>/SpeechRail.app" "$HOME/Applications/"
hdiutil detach "/Volumes/SpeechRail <version>"
open "$HOME/Applications/SpeechRail.app"
```

- 默认安装到 `~/Applications/SpeechRail.app`；同一台机器只保留一个长期可执行的 App bundle。
- 该 DMG 是 **unsigned、未公证**的制品。首次从网络下载后打开时，macOS 可能提示“无法验证开发者”或
  “无法检查恶意软件”；确认来源和 `SHA256SUMS` 后，在「系统设置 → 隐私与安全性」中点“仍要打开”。
  受企业策略管理的 Mac 可能不允许此放行。
- App 需要 macOS 26 及以上，并且需要已经安装服务。

## 5. 首次验证

第 3.1 节带 `--enable` 的安装已经检查过一次 `/readyz`；下面几条命令用于自己复核，或在没带
`--enable`、或更换规格组合之后手动确认：

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

- **升级服务**：先停旧实例，再用新 wheel 安装并启动。安装器只接受已停的服务，所以顺序不能颠倒：

```bash
APP_HOME="$HOME/Library/Application Support/SpeechRail"
SPEECHRAIL_CLI="$APP_HOME/runtime/current/.venv/bin/speechrail"
"$SPEECHRAIL_CLI" service stop --app-home "$APP_HOME"
cd ~/Downloads
uvx --python 3.14.7 --from ./speechrail-*.whl speechrail install --yes --enable
```

  省略 `--asr-spec`/`--tts-spec` 会沿用当前规格；换规格用
  `"$SPEECHRAIL_CLI" profile apply --asr-spec <fast|quality|reference> --tts-spec <fast|quality|reference> --yes`。
  不要手工替换 `runtime/current` 或直接编辑 release venv。回退方式见
  [SpeechRail 版本发布 SOP](../../.agents/skills/speechrail-release/SKILL.md)。

  **升级不会重新下载已校验的模型。** 安装器按 `prepared_id`（规格组合 + runtime lock + 每个文件的
  sha256 清单）复用本机 `models/<artifact_key>`，只重下清单变化、缺失或被改动的那些文件；分人资产
  按锁定清单、vendor runtime 按 runtime lock 同样复用。所以升级的主要耗时是本机校验（读盘）与
  preflight，不产生额外下载流量；机械硬盘或冷盘更慢。
- **升级 App**：退出旧 App，把新的 `SpeechRail.app` 复制到同一安装路径，保留上一份制品以便回滚。
- **卸载 App**：退出并删除 App bundle 即可，不影响正在运行的服务。
- **卸载服务**：

```bash
SPEECHRAIL_CLI="$HOME/Library/Application Support/SpeechRail/runtime/current/.venv/bin/speechrail"
"$SPEECHRAIL_CLI" service stop --app-home "$HOME/Library/Application Support/SpeechRail"
"$SPEECHRAIL_CLI" service uninstall --app-home "$HOME/Library/Application Support/SpeechRail"
```

  `uninstall` 只卸载并删除 `~/Library/LaunchAgents/com.speechrail.plist`，不删除模型、私有配置、
  `runtime/releases` 和日志。

当前交付不提供旧版本数据迁移流程。App 的会话记录位于
`~/Library/Application Support/SpeechRail/sessions.sqlite3`，作品位于同层的 `Works/`。在设置 → 助手 →
记录库中可以打开数据目录，并使用“备份记录库”导出会话库单文件；该入口不包含 `Works/`、custom voice
或私有配置。需要完整保留时，用户必须分别备份这些资产。`runtime/`、`state/`、模型和日志等可重建内容可以
删除后重新准备。删除前应先确认目标路径，不要把删除用户源文件当作卸载步骤。

## 7. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| App 显示「无法连接本机服务」或菜单显示「服务未连接」 | 只装了 App，或服务没启动 | 先按第 3 节安装服务；已安装未启动时执行 `"$HOME/Library/Application Support/SpeechRail/runtime/current/.venv/bin/speechrail" service start --app-home "$HOME/Library/Application Support/SpeechRail"` |
| 打开 App 提示无法验证开发者 / 无法检查恶意软件 | DMG 为 unsigned、未公证制品 | 确认来源与 `SHA256SUMS` 后走「隐私与安全性 → 仍要打开」；企业托管 Mac 可能禁止 |
| `pip install` / `uv pip install` wheel 报平台不兼容 | wheel 平台标签为 `macosx_26_0_arm64` | 在 macOS 26+ Apple Silicon 上安装当前 wheel |
| `uvx` 报 `no wheels with a matching Python version tag` | 默认用了比 3.14.7 更新的解释器 | 按第 3.1 节加上 `--python 3.14.7` |
| `install` 报 `uv is not on PATH` | 机器上没有 `uv` | 按提示访问 `https://docs.astral.sh/uv/getting-started/installation/` 安装后重试 |
| `install` 报 wheel 版本与 installer 不一致 | CLI 与待安装 wheel 不是同一个版本 | 让 `uvx --from` 指向要安装的那个 wheel |
| `install` 报 `requires the SpeechRail service to be stopped` | 旧实例还在运行，安装器拒绝热替换 | 先执行同一条报错里给出的 `service stop` 命令，再重跑安装（见第 6 节） |
| `install` 报 `a different managed selection is already configured` | 一个 app home 只保留一组规格，显式传了别的组合 | 省略 `--asr-spec`/`--tts-spec` 沿用当前规格，或用已安装 runtime 的 `profile apply --asr-spec <tier> --tts-spec <tier> --yes` 换规格 |
| `--enable` 后提示服务未就绪 | 进程起来了但模型/运行时还没就绪 | 按提示执行 `"$HOME/Library/Application Support/SpeechRail/runtime/current/.venv/bin/speechrail" service preflight --app-home "$HOME/Library/Application Support/SpeechRail"`，再 `curl -s -i http://127.0.0.1:8201/readyz \| head -1` |
| `/readyz` 返回 503 `backend_not_ready` | 服务已启动但模型或运行时未就绪 | 用 `speechrail service preflight` 与 [运维 Runbook](../operations/operations-runbook.md) 定位 |
| App 无法打开 | App 基线是 macOS 26.0 | 在支持的 macOS 26+ Apple Silicon 环境中重新安装当前 DMG |

## 8. 参考

- [用户与集成指南中心](README.md)
- [SpeechRail 零配置首装 SOP](../../.agents/skills/speechrail-zero-setup/SKILL.md)
- [运行时与部署](../operations/runtime-deployment.md)
- [运维操作实战手册](../operations/operations-runbook.md)
- [macOS App 分发与签名](../developers/macos-app-release.md)
