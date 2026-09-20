---
name: speechrail-local-deploy
description: >-
  SpeechRail macOS 本机日常服务运维：已安装 managed runtime 的 status/start/stop/restart、
  profile apply/rollback 和运行故障排查。仅用于本机单实例；不用于全新首装、wheel/App 发布、
  性能基准、远程或多实例部署。
---

# SpeechRail 本机日常服务运维

本 skill 只处理已经安装的 SpeechRail 单实例服务。它负责 service 生命周期、profile 事务和
故障定位；不会把普通查询升级成发布、模型下载或 App 安装。

## 入口边界

- 全新 Apple Silicon Mac 首装、下载模型和注册首个 LaunchAgent：读
  [speechrail-zero-setup](../speechrail-zero-setup/SKILL.md)。
- wheel/App 版本发布、安装、签名、App bundle 整理或回滚：读
  [speechrail-release](../speechrail-release/SKILL.md)。
- ASR/TTS/Realtime 性能、质量或内存基准：读
  [speechrail-perf-benchmark](../speechrail-perf-benchmark/SKILL.md)。
- 已有服务的状态、启停、切档、回滚和运行故障：继续使用本 skill。

## 不变量

- 单机单用户只保留一个 `com.speechrail` user `LaunchAgent`、一个 ASGI 父进程和一个
  配置端口的 listener（默认 `127.0.0.1:8201`）；不复制服务或 worker 以提高吞吐。
- 服务只使用用户级 LaunchAgent、managed `runtime/current`、受管私有配置和锁定制品；
  不以源码 checkout 的 `.venv` 证明安装态，不在请求路径下载模型。
- 默认 loopback。非 loopback 必须同时配置 `SPEECHRAIL_API_KEY`、Bearer 鉴权和明确的
  origin 策略；key、`.env`、音频、完整转写和日志全文不进入命令输出或报告。
- `SpeechRail.app` 是按需控制面，不拥有 8201、不加载模型、不替代 `com.speechrail`；App
  或 control-agent 的退出、升级和回滚不能改动服务 runtime、selection、模型或配置。
- 不使用 `pkill`、`killall`、模糊名称匹配、手工 plist 修改或连续 restart 重试。
- `runtime/releases` 只增不减：每次安装/替换新增一个 release 目录，installer 没有自动保留策略。保留
  基线是 `runtime/current` 指向的 release、回退目标和最近 1–2 个版本；清理更旧的 release 属运行态动作，
  必须有当前用户明确授权。

## 操作前快照

状态读取默认只读。执行任何 stop/start、profile 或 rollback 前，先记录当前版本、active
profile、generation、runtime target、PID/listener 和健康状态；不要输出私有配置内容。
以下命令以默认端口为例；先从状态结果核对实际端口。纯查询只取回答所需字段，不自动执行整套验收。

```bash
APP_HOME="${SPEECHRAIL_APP_HOME:-$HOME/Library/Application Support/SpeechRail}"
speechrail service status --app-home "$APP_HOME"
speechrail profile status --app-home "$APP_HOME"
readlink "$APP_HOME/runtime/current"
lsof -nP -iTCP:8201 -sTCP:LISTEN
curl --fail http://127.0.0.1:8201/health
```

发布前或怀疑安装态不一致时，再执行：

```bash
speechrail service preflight --app-home "$APP_HOME"
```

CLI 从源码 checkout 执行带 `--app-home` 的 service/profile/setup 状态变更时，会转交给
`runtime/current/.venv/bin/python`；managed runtime 不存在就停止，不用源码环境替代判断。

## 生命周期路由

### 普通 service 操作

先阅读 [operator contract](references/operator-contract.md)；需要实际 stop/start 时再阅读
[lifecycle controller](references/lifecycle.md)。按动作选择路径：

| 请求 | 执行与完成条件 |
|---|---|
| start / 确保启动 | 目标已 ready 且身份一致时直接报告；已停止时确认 lock/端口无冲突后启动并验证 ready。正在启动则有界等待；身份不符或不健康时报告诊断，不自动 stop/restart。 |
| stop | 按共享 contract 排除活动请求，通过 controller 停止并确认目标退出、lock 释放和 listener 消失；已停止且无残留时直接报告。 |
| restart | 排除活动请求，完成 controller stop，再 start 并核对 ready 与身份。 |
| profile apply / rollback | 交给下述 profile 事务管理停启与恢复，不在事务外额外执行一轮 stop/start。 |

停止等待、精确进程身份复核与强杀上限统一见 operator contract。profile 事务内置 smoke 按已授权事务执行，
额外真实推理需用户明确要求。

生命周期硬上限是：`bootout` 后最多等待 `2 秒`；仅在重新核对 PID、命令行和 owner 后，才可对精确进程组发送
`SIGKILL`，强杀后最多再等待 `10 秒` 确认 lock 与 listener 释放；身份无法核实时必须 fail closed。

### profile apply / rollback

`profile apply <preset> --yes` 与 `profile rollback --yes` 是一次事务，不是热重启。保留初始
profile/generation；切换失败停止后续动作，只允许一次明确回滚。普通重启可用 controller-backed
`service restart`，但不能代替 profile 事务。

### 故障排查

按“单实例 → listener → lock → managed runtime/preflight → selection/model identity”的顺序
取证；不要先删除模型、配置或 release。按现象读取 [troubleshooting](references/troubleshooting.md)，
其中包含 `server_already_running`、`worker_load_error`、旧 profile、`/readyz 503`、plist 和
日志取证的最小路径。

## 旧 release 与陈旧进程

- `runtime/releases` 不自动清理；累积到几十上百 GB 属于已知现象，不是故障。每次安装或替换都会新增一个
  release 目录，磁盘随发布次数单调增长。
- 清理前必须核对没有活进程从待删目录执行：用 `ps -axo pid,command` 和 `ps -axo pid,comm` 匹配 release
  的绝对路径，并确认待删目录不是 `runtime/current` 或其指向的目录。被引用的目录必须保留，否则会打断
  运行中的服务或 `speechrail-mcp`。
- 旧版本残留进程很常见：例如长期运行的 `speechrail-mcp` 仍在使用旧 release 的 `.venv`，同一个 release
  目录可能同时被服务父进程、worker 和 MCP 进程引用。发现这类进程时先按 PID、owner、command 和
  executable 取证，不要假设它已经退出。
- 终止陈旧进程与删除 release 目录都属运行态动作，需要当前用户明确授权，并按 operator contract 只对重新
  核对过身份的精确进程组处理，不使用模糊名称匹配。

## 完成证据

按请求选择证据：查询报告实际读到的状态；stop 报告退出和 lock/listener 释放；启动或切换再核对 ready 与身份。
适用时记录版本/commit、runtime target、active profile/generation、唯一 listener、
PID/executable、health/ready、models/voices、必要的真实 smoke（仅在当前用户明确授权时执行，否则列为
未执行项）、回退目标和未验证项。若请求包含 App，另记录 bundle version/build、bundle identifier、
control-agent 状态和唯一安装路径。

只报告状态、版本、profile、generation、错误码和脱敏 stderr 尾部；不报告 API key、Authorization、
音频、完整转写、完整 prompt、完整日志或无关私人路径。
