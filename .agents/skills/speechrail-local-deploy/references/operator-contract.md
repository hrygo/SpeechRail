# SpeechRail 本机 operator contract

这是本机服务发布、安装、停启、切档和基准共同遵守的终态契约。具体命令可以因入口不同而变化，但安全边界和验收条件不能分叉。

## 运行边界

- 单机、单用户、单实例：一个 `com.speechrail` LaunchAgent、一个 ASGI 父进程、一个 loopback listener。
- 允许完全停服和数分钟级启动真空。效率来自减少重复检查和重复重启，不来自并行启动第二个实例。
- 所有替换、切档和回滚都先停旧实例；`launchctl bootout` 成功不等于进程和 vendor worker 已退出。
- 只使用用户级 LaunchAgent、managed `runtime/current`、私有配置和锁定的模型/runtime 制品。
- 从源码 checkout 执行带 `--app-home` 的 service 命令，以及会改变 profile/selection 的
  `profile`/`setup` 命令时，CLI 会自动转交给 `runtime/current/.venv/bin/python`；若 managed
  runtime 不存在，不得用源码依赖结果代替安装态判断。

## App 控制面边界

- `SpeechRail.app` 是按需打开的 SwiftUI 控制面，不是语音服务的启动器，也不是登录启动项。真正需要随用户登录常驻的是唯一的 `com.speechrail` user `LaunchAgent`；它直接拥有 8201 端口和服务生命周期。
- `com.speechrail.desktop.control` 是 App 随包携带、由 `SMAppService` 管理的可选 control-agent。它只接收固定 XPC 命令并委托当前 managed runtime 的 Python CLI，不加载模型、不创建第二个 ASGI worker、不替换 `com.speechrail`。
- App 退出、control-agent 注销或 App bundle 升级都不得停止、删除或覆盖服务的 `runtime/current`、selection、模型、私有配置和 `com.speechrail` plist。服务发布与 App 发布可以独立回滚；联合发布必须先验收服务，再验收 App 控制链路。
- App 发布只保留一个实际安装 bundle（默认 `~/Applications/SpeechRail.app`）。测试/归档副本放在构建或临时目录，验收后注销并清理；不要把上一版本的 `.app` 作为可执行副本长期留在 Applications 或 DerivedData 中，以免 Finder/LaunchServices 显示重复项目。

## 唯一生命周期流程

1. 记录 active profile、generation、runtime target、PID/listener 和健康状态。
2. 隔离外部 realtime 客户端：`lsof` 只把 `ESTABLISHED` 视为活动连接，metrics 确认 realtime session 和 batch/realtime active requests 为零。发现活动客户端时暂停并报告阻塞，只有用户明确授权关闭指定客户端时才按精确 PID 结束，不自动关闭 Sona、浏览器或其它客户端。
3. 通过 `LaunchAgentServiceController.stop()` 执行 `bootout`。
4. 有端口时轮询同一个 per-port singleton lock；无端口测试路径立即返回，不插入无意义 sleep。
5. 默认最多等待 2 秒；仍占用时先重新读取当前 lock owner 并核对命令行/executable，不能直接信任早期 `launchctl status` 快照；只有身份仍一致的精确 PID/进程组才允许发送 `SIGKILL`。
6. 强杀后最多再等待 10 秒确认 lock 释放；PID 身份不一致、无法验证或 lock 未释放时中止，不启动候选。`launchctl`、`ps` 和 lock waiter 都必须有界，不能因为控制面无响应而无限等待。
7. 通过 `LaunchAgentServiceController.start()` 在 bootstrap/kickstart 前再次确认 lock，启动后等待真实 ready，再做 profile/model/voice 和公共 smoke。

禁止 `pkill`、`killall`、模糊名称匹配、手工 plist 修改和连续 `restart` 重试。停止失败必须保留旧 runtime/selection 作为回退点。

## 安装与切换职责

- `tools.install_macos.install_managed(...)` 只负责 wheel/release staging、preflight、共享 runtime、模型准备和原子切换 `runtime/current`；它不复制用户 skill，也不自行实现进程强杀。
- `speechrail.service.skill_installer` 只负责可移植用户 skill 的安全、原子安装；skill 安装失败不应改变 managed runtime。
- profile apply/rollback 负责一次事务和一次回滚，候选启动、identity、ready、catalog 和真实 smoke 均失败时停止后续动作。
- wheel 替换和 profile 切换分开执行；不要在同一个事务里同时改版本和模型档位。

## 基准与证据

- 正式基准唯一入口为 `examples/perf/bench_profiles.py`，其实现分为 `benchmark_manifest.py`、`benchmark_http.py`、`benchmark_resources.py` 和 `benchmark_runner.py`。
- manifest 和 fixture 必须位于仓库外；基准工具不得生成 TTS fixture 再把它当作独立 ASR 质量证据。
- 原始 JSON、音频、日志和采样制品放在 app home 外部 benchmark 目录；Git 只保存脱敏汇总报告。
- release gate 需要真实硬件/模型身份、独立质量证据、成功公共推理和每个 tick 均完整的同 tick 资源采样；通用的 `arm`/`arm64` 只能算架构，不能算芯片身份；缺任何一项、采样线程异常或停止超时就写 `unset`/`fail`。
- manifest 的 fixture `id` 和 `language` 只能使用安全标签；原始路径、任意 token、文本和音频不得进入结果 JSON 或归档报告。
- benchmark、CLI diagnose 和本机辅助脚本统一按 `SPEECHRAIL_API_KEY` 环境变量优先、managed
  `config/.env` 回退的顺序读取 key；不得 `source` 配置、把 key 写进命令行、日志或结果。
- `PATCH` 测 active profile；`MINOR` 按 `quality → balanced → light → quality` 串行执行并恢复初始档；`MAJOR` 在此基础上加入迁移与兼容验证。

## 完成证据

最终结果至少包含：版本/commit、wheel digest、runtime target、profile/generation、唯一 listener、health/ready、models/voices、真实 ASR/TTS smoke、benchmark report、回退目标和未验证项。若范围包含 App，额外记录 App bundle version/build、bundle identifier、签名/公证状态、control-agent label、App 控制链路 smoke 和清理后的唯一安装路径。不得包含 API key、Authorization、音频、完整转写、日志全文或私人绝对路径。
