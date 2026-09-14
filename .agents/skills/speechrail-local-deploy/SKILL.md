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
  `127.0.0.1:8201` listener；不复制服务或 worker 以提高吞吐。
- 服务只使用用户级 LaunchAgent、managed `runtime/current`、受管私有配置和锁定制品；
  不以源码 checkout 的 `.venv` 证明安装态，不在请求路径下载模型。
- 默认 loopback。非 loopback 必须同时配置 `SPEECHRAIL_API_KEY`、Bearer 鉴权和明确的
  origin 策略；key、`.env`、音频、完整转写和日志全文不进入命令输出或报告。
- `SpeechRail.app` 是按需控制面，不拥有 8201、不加载模型、不替代 `com.speechrail`；App
  或 control-agent 的退出、升级和回滚不能改动服务 runtime、selection、模型或配置。
- 不使用 `pkill`、`killall`、模糊名称匹配、手工 plist 修改或连续 restart 重试。

## 操作前快照

状态读取默认只读。执行任何 stop/start、profile 或 rollback 前，先记录当前版本、active
profile、generation、runtime target、PID/listener 和健康状态；不要输出私有配置内容。

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
[lifecycle controller](references/lifecycle.md)。所有替换、启停和回滚都必须：

共享 contract 固定生命周期上限：默认最多等待 `2 秒`；只有重新核对身份后才允许对精确进程组发送
`SIGKILL`，强杀后最多再等待 `10 秒` 确认 lock 释放。

1. 检查外部 `/v1/realtime` 客户端：只把 `ESTABLISHED` 连接视为活动，并确认 realtime session
   与 batch/realtime active requests 为零；不能自动关闭 Sona、浏览器或其他客户端。
2. 通过 controller 执行 `bootout`/stop，而不是直接把 `launchctl` 返回当作退出证明。
3. 旧进程仍持锁时，重新核对当前 owner、PID、命令行和 executable；只有精确匹配的进程组
   才能按 controller 规则强杀。PID 不安全、身份不一致或 lock 未释放时 fail closed。
4. 通过 controller start，等待真实 ready，再核对 profile/model/voice identity 和公共 smoke。

### profile apply / rollback

`profile apply <preset> --yes` 与 `profile rollback --yes` 是一次事务，不是热重启。保留初始
profile/generation；切换失败停止后续动作，只允许一次明确回滚。普通重启可用 controller-backed
`service restart`，但不能代替 profile 事务。

### 故障排查

按“单实例 → listener → lock → managed runtime/preflight → selection/model identity”的顺序
取证；不要先删除模型、配置或 release。按现象读取 [troubleshooting](references/troubleshooting.md)，
其中包含 `server_already_running`、`worker_load_error`、旧 profile、`/readyz 503`、plist 和
日志取证的最小路径。

## 完成证据

结论至少能回溯到：版本/commit、runtime target、active profile/generation、唯一 listener、
PID/executable、health/ready、models/voices、必要的真实 smoke、回退目标和未验证项。若请求
包含 App，另记录 bundle version/build、bundle identifier、control-agent 状态和唯一安装路径。

只报告状态、版本、profile、generation、错误码和脱敏 stderr 尾部；不报告 API key、Authorization、
音频、完整转写、完整 prompt、完整日志或无关私人路径。
