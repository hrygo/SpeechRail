# 三档统一运行时实施记录

状态：实施中。本文记录代码证据，不代表三档真实模型验收通过。

## 工作边界

- 基线：`001e744`；实现位于 `feature/three-tier-runtime` 独立工作树。
- 保留既有部署、私有配置和外部 runtime；当前服务尚未切换。
- 用户提供 Parallels Desktop 虚拟机。2026-09-05 只读清单显示现有 guest 是 Ubuntu
  与 Windows 11，没有 macOS guest；可验证不支持平台的提示，不能替代本机 macOS
  安装测试、MLX/Metal 推理或 M1 Air 8GB 实机验收。未改变虚拟机运行态。

## 已验证的制品元数据

2026-09-05 从 ModelScope 文件 API 获取五个候选快照的文件清单，选定完整提交 ID 后
重新查询该不可变版本。配置内容 SHA-256 与清单一致；主权重和 codec 的 SHA-256
与 Hugging Face 转换维护者仓库的 LFS 元数据一致。没有下载完整权重；下载后的
逐文件实算哈希、真实 loader 与质量验证仍是后续门槛。

| artifact | ModelScope revision | 文件数 | 总字节 |
|---|---|---:|---:|
| asr-1.7b-q8 | `579e237ce6ec925252973afe835d2f98a138602f` | 10 | 2467857511 |
| asr-0.6b-q8 | `54e4c7130621e78fd227cf3a49893c670d9057f1` | 10 | 1010772242 |
| tts-1.7b-design-q8 | `319768077bff672bfbea587c72982016052e8d43` | 13 | 3080139348 |
| tts-0.6b-custom-q8 | `a04a567b78dae1d0bb08bb63eb90a13976e09fd0` | 13 | 1973573869 |
| tts-0.6b-custom-q4 | `b3e1b295821bacbca1461f68b69676cb9015e4f1` | 13 | 1693603219 |

发布清单位于 `src/speechrail/assets/model-catalog.json`。ModelScope 已有完整匹配制品，
目前未加入未核对完整文件集的备用镜像。README 被纳入文件校验；`.gitattributes`
及仓库根目录的平台专用 `configuration.json` 未作为推理必需文件。

## 共同依赖锁

从当前 runtime 读取包版本作为约束，解析最小依赖闭包。首次仅计算 vendor SDK 时为
ASR 18 个包、TTS 40 个包；补齐 SpeechRail worker 入口所需的 Pydantic 配置依赖后，
当前锁定为 ASR 24 个包、TTS 46 个包。
两者均使用 Python 3.12.14、MLX 0.32.2；ASR 使用 mlx-qwen3-asr 0.3.5，
TTS 使用 mlx-audio 0.4.8。各档共享相同依赖文件。

解析目标为 Apple Silicon macOS 14.0 及以上；macOS 13 默认目标无法匹配当前
MLX wheel，安装器需明确检查最低系统。两个临时 venv 的 `uv pip sync --require-hashes`
均成功；离线导入 SpeechRail ASR/TTS worker 与两个模型 SDK 的入口成功，未加载权重。
该导入结果尚不等于新环境真实推理通过。

```bash
MACOSX_DEPLOYMENT_TARGET=14.0 uv pip compile \
  src/speechrail/assets/runtime/asr.in \
  -c src/speechrail/assets/runtime/asr.constraints \
  --python-version 3.12 --python-platform aarch64-apple-darwin \
  --generate-hashes --no-annotate --no-header --only-binary :all: \
  --output-file src/speechrail/assets/runtime/asr.txt
```

TTS 使用对应的 `tts.in`、`tts.constraints` 和 `tts.txt`。
ffmpeg 候选为 `imageio-ffmpeg==0.6.0` 的 arm64 wheel，下载 URL、大小与 SHA-256
来自 PyPI 发布元数据，记录于 `bootstrap-artifacts.json`；尚未执行下载或安装验证。

## 验证进度

- 原始完整 fake 测试套件通过，未加载真实模型。
- R01 模式门实现与 7 项测试通过；父 Agent 完成代码审查和针对性复测。
- M01a 离线目录构建器 18 项测试通过；生产目录通过同一校验函数。
- B01a 指标与 TTS 读取测试 15 项通过，首包读取使用 `read1`，拒绝截断 PCM16。
- B01b 资源采样 12 项测试通过，缺样/RSS 不冒充物理内存，PID 生命周期在读前读后核对。
- M03 目录和运行时清单 28 项测试通过，下载镜像允许独立不可变版本，实际文件哈希已校验。
- T01 音色绑定与原有 TTS policy/splitter 共 34 项回归通过。
- 共享传输 20 项测试通过，空闲等待与半帧超时分开处理。
- wheel 构建成功，并确认包含全部 9 份当前 assets 文件。
- M02/T02 已校验实际量化身份并由同一 TTS engine 支持 VoiceDesign 与 CustomVoice；
  worker 相关 75 项 fake 回归通过，未加载真实模型。
- R02–R05 已将 Batch/Streaming 接入一个物理 ASR owner，并补 generation、取消、
  超时、慢消费者和生命周期去重回归；本轮 `243fe5e` / `dec1de7` 进一步补齐接收侧
  EOF/半帧安全重试与发送前取消语义。
- A01–A04 已实现有界上传解码、30 秒滚动窗、增量拼接和 REST 流式 batch 端口；
  A04 的转写、解码、分窗和 diarization 组合共 59 项测试通过。
- M04 已接入 sidecar 选择解析；本轮 `cd969ec` 已修正初版缺口：保留公共 model ID，
  精确校验 preset/artifact family 与 runtime lock；20 项针对性测试通过。
- R06 初版预算没有生产调用方。本轮 `29e089d` 已在组合根接入共同硬件预算：未知
  footprint 或内存检测失败时 ASR/TTS 保守串行，只有显式 worker 内存上限在整机预算内
  才允许重叠，并把决策原因保存在 Governor snapshot；59 项相关回归通过。
- T03 已用同一有界分句和 token budget 驱动两种 TTS variant，长文本不再依赖单次
  生成上限静默截断；`e2ec63b` 的 TTS 针对性测试 28 项、全套测试 778 项通过。
- main v1.6.9 对比复核发现 CustomVoice worker 的 ready identity 门仍只接受
  VoiceDesign；`169358b` 已补齐双 variant 启动门及空首块/单 final chunk fade 回归。
- T04 已把 mp3/opus/aac/flac 改为输入/输出各 4 块的流式 ffmpeg 管线，PCM 保持真流式，
  WAV 保留 128MiB 有界缓冲；`90d8308` 通过真实四格式 ffmpeg 往返与取消/早退回收测试。
- P01 已实现清单锁定的离线制品准备、逐文件校验、缓存、原子登记和回退保留；`dc0f70c`
  的 29 项 fake 测试通过，尚未接入真实 ModelScope downloader，也未下载模型。
- B02 真实质量、P02 之后的 runtime/安装切换、ManagedRuntime、公开契约及
  M1 Air 8GB 内存/热稳态仍在待办范围。

## 回退

本次代码与现有部署隔离。可继续使用原部署与基线版本；不删除模型、配置、日志或
外部 runtime。实际服务切换前，仍须完成计划规定的 drain、旧进程退出、新组合验证和
last-known-good 恢复测试。
