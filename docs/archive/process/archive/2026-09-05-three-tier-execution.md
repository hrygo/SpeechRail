# 三档统一运行时实施记录

状态：本机三档实现与可行性验收完成；目标设备发布门仍在实施中。

## 工作边界

- 原始基线：`001e744`；实现已 rebase 并快进合并到 `main` 的 SpeechRail 1.6.9 发布线，
  临时 worktree 与已合并分支已清理。
- 私有配置、旧 release 和外部模型保留；当前安装已迁移到受管共享 runtime，结束时 active
  profile 为 `quality`（generation 9）。
- 三档切换采用单机停服事务；不识别 Mac 营销型号，不实现服务内热切换、drain 或控制 socket。
- M1 Air 8GB 仍是 light 的发布验收条件；设备证据只在 B02/V01 基准阶段记录，不进入运行架构。

## 已验证的制品元数据

2026-09-05 从 ModelScope 文件 API 获取五个候选快照的文件清单，选定完整提交 ID 后
重新查询该不可变版本。配置内容 SHA-256 与清单一致；主权重和 codec 的 SHA-256
与 Hugging Face 转换维护者仓库的 LFS 元数据一致。四个正式 q8 snapshot 已下载或从既有
内容一致快照导入，并在发布前逐文件实算大小与 SHA-256；q4 候选未下载。

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
当前锁定为 ASR 26 个包、TTS 46 个包，联合去重后为 47 个包。
两者均使用 Python 3.12.14、MLX 0.32.2；ASR 使用 mlx-qwen3-asr 0.3.5，
TTS 使用 mlx-audio 0.4.8。25 个跨 role 依赖由 `common.constraints` 统一版本；
ASR 的 `huggingface-hub` 随 TTS 要求从 0.36.2 对齐到 1.29.0。各档共享相同依赖文件。

解析目标为 Apple Silicon macOS 14.0 及以上；macOS 13 默认目标无法匹配当前
MLX wheel，安装器需明确检查最低系统。ASR/TTS 联合临时 venv 的
`uv pip sync --require-hashes --only-binary :all:` 成功；离线导入 SpeechRail ASR/TTS
worker 与两个模型 SDK 的入口成功，未加载权重。联合 Apple Silicon/macOS 14 dry-run
得到 47 个包且无冲突。
受管共享 runtime 已在本机真实创建，47 个锁定包、worker import、内置 ffmpeg 与三档真实
推理均通过。

```bash
MACOSX_DEPLOYMENT_TARGET=14.0 uv pip compile \
  src/speechrail/assets/runtime/asr.in \
  -c src/speechrail/assets/runtime/asr.constraints \
  --python-version 3.12 --python-platform aarch64-apple-darwin \
  --generate-hashes --no-annotate --no-header --only-binary :all: \
  --output-file src/speechrail/assets/runtime/asr.txt
```

TTS 使用对应的 `tts.in`、`tts.constraints` 和 `tts.txt`。
ffmpeg 为 `imageio-ffmpeg==0.6.0` 的 arm64 wheel，下载 URL、大小与 SHA-256 来自 PyPI
发布元数据并记录于 `bootstrap-artifacts.json`；已在受管 runtime 中安装，并用于真实 WAV
解码和公共 API smoke。

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
  超时、慢消费者和生命周期去重回归；本轮 `3b104d7` / `d9046cb` 进一步补齐接收侧
  EOF/半帧安全重试与发送前取消语义。
- A01–A04 已实现有界上传解码、30 秒滚动窗、增量拼接和 REST 流式 batch 端口；
  A04 的转写、解码、分窗和 diarization 组合共 59 项测试通过。
- M04 已接入 sidecar 选择解析；本轮 `8472391` 已修正初版缺口：保留公共 model ID，
  精确校验 preset/artifact family 与 runtime lock；20 项针对性测试通过。
- R06 初版预算没有生产调用方。本轮 `44933a7` 已在组合根接入共同硬件预算：未知
  footprint 或内存检测失败时 ASR/TTS 保守串行，只有显式 worker 内存上限在整机预算内
  才允许重叠，并把决策原因保存在 Governor snapshot；59 项相关回归通过。
- T03 已用同一有界分句和 token budget 驱动两种 TTS variant，长文本不再依赖单次
  生成上限静默截断；`de0041c` 的 TTS 针对性测试 28 项、全套测试 778 项通过。
- main v1.6.9 对比复核发现 CustomVoice worker 的 ready identity 门仍只接受
  VoiceDesign；`607b5e7` 已补齐双 variant 启动门及空首块/单 final chunk fade 回归。
- T04 已把 mp3/opus/aac/flac 改为输入/输出各 4 块的流式 ffmpeg 管线，PCM 保持真流式，
  WAV 保留 128MiB 有界缓冲；`2be3c71` 通过真实四格式 ffmpeg 往返与取消/早退回收测试。
- P01 已实现清单锁定的离线制品准备、逐文件校验、缓存、原子登记和回退保留；`9247784`
  与一致性修复 `4eb9efa` 的 36 项 fake 测试通过。registry rename 后的目录 fsync 失败不会
  回滚已登记模型，下载流在成功、失败和取消时关闭，制品 identity 包含 `model_id` 与量化元数据。
  尚未接入真实 ModelScope downloader，也未下载模型。
- P02 已实现共同 vendor release、锁文件原始字节校验、带 hash/仅 wheel 安装、独立 ffmpeg、
  离线 preflight、inactive release 复用和 current/registry 回滚；实现 commit `71fa2bb`，
  共享依赖锁修复 `8e8c9d1`。联合解析为 47 个包、25 个交集且零冲突；73 项相关测试与
  Apple Silicon/macOS 14 dry-run 通过。临时共同 venv 只做 SDK 导入，未加载模型或切换服务。
- S02/S03 曾实现服务内 `ManagedRuntime`、generation 租约与 drain。用户明确单机允许停服后，
  这两层只增加请求路径和状态机复杂度，已分别由 `6694640`、`94ca67e` 完整撤销；
  共享物理 ASR owner、模式互斥和既有有界推理实现不受影响。
- B02 已交付公共 API runner 与 fail-closed 证据门 `d6daaa5`、资源监控生命周期
  `57fc5e2`；本机已按 `quality→balanced→light→quality` 完成真实模型准备、切换、公共
  ASR/TTS、独立系统语音准确率代理、热态 RTF 与完整 `phys_footprint` 采样。三档最大峰值
  分别为 7000.3/5877.4/4484.2 MB，详见三档可行性报告。M1 Air 8GB、12GB、完整真人
  质量集、cold/soak/streaming 仍未执行，因此 G2 发布门保持未完成。
- rebase 已保留 main v1.6.9 的 `POST/DELETE /v1/voices`、`VoiceRegistry`、契约和版本信息；
  `e86f451` 将 VoiceDesign 的 profile seed/temperature 与 CustomVoice 显式 speaker 绑定重新接入
  三档 worker，同时保留制品 family/variant/量化身份门。任意 custom ID 可由 VoiceDesign
  instruction 合成；CustomVoice 没有可信 vendor speaker 映射时稳定拒绝。
- P03 已在 `44938e9` 接入 managed wheel/vendor release、私有配置、preflight 和原子 current
  指针回退；本机已完成真实升级安装、共享 runtime 构建和 service enable。受管 ffmpeg 接线提交为
  `7748964`；撤销热切换后的组合回归发现包循环导入，`bb9d826` 将可执行文件校验移到
  `runtime` 边界后，139 项 API/组合回归与 ruff/mypy 通过。
- S04 前置解析器 `a37e26c` 已把 prepared ID 严格绑定到 catalog/runtime lock、完整
  ASR/TTS pair、目录、文件大小和 SHA-256；44 项测试通过。解析只在准备/启动/切档调用，
  不进入请求热路径；全量哈希在停服前完成。
- S04 核心事务已由 `9d577ed`、`620395e`、`8c7478f` 完成：一次性候选启动许可、停服切换、
  公共 ASR/TTS smoke 与一次有界回退均已接线。三次真实成功切换已验证；本机还复现并修复
  `launchctl bootout` 后立即 `bootstrap` 的 exit-5 竞态（`5b081b3`）。
- U01 核心命令由 `5011c36`、`9aa8bfd` 完成：`setup` 与
  `profile list|status|apply|rollback` 复用同一停服切换路径，自动化必须显式 `--yes`；
  8/12/16GiB 推荐只读取物理内存，不识别机器营销型号。更细的缺失下载量与能力影响展示仍待收口。
- U02 的已安装双击入口由 `10af956` 完成，安装器生成 0700 的“SpeechRail 设置.command”，
  路径含空格/中文与 symlink 拒绝测试通过。干净机器 bootstrap、签名/公证和实机双击仍未验收。
- `a9ad380` 接入官方 ModelScope 不可变 revision 的直接流式下载，避免 SDK cache 与模型仓库
  同时保留整份快照；下载仍由 model store 执行大小、SHA-256、取消和原子发布门。
- 本机真实安装额外暴露并修复标准 uv 解释器 symlink、MLX wheel 平台解析、`uv pip sync`
  参数、受管共享 Python/ffmpeg 激活和 installed-host preflight 问题（`c3fb306`、`97dc91e`、
  `30af091`、`5e29b72`、`4f30605`）。C01 合入后的最终代码门为 983 项通过、覆盖率 83.09%；
  `ruff src tests`、`mypy src`、OpenAPI lint、LaunchAgent plist lint、wheel 构建与真实安装通过。
- C02 已由 `8c94fb2` 完成：REST 的 `AsrModeBusy` 映射为带 request ID 与
  `Retry-After` 的 `429 backend_busy`，Realtime 既有同码行为保持。C01 的动态模型/音色
  能力目录由 `339fdb2` 完成：`/health`、canonical `/v1/models` 和
  `/v1/voices` 从启动时同一受管 selection 发布实际 profile、artifact、variant、量化与
  voice capabilities；OpenAI alias 与必需 Model 字段保持稳定。完整真实质量、12GB 与
  M1 Air 8GB 内存/热稳态、V01 发行验收仍在待办范围。
- 用户确认将系统音色收敛为九个一一对应角色：`serena`、`vivian`、`uncle_fu`、
  `dylan`、`eric`、`ryan`、`aiden`、`ono_anna`、`sohee`。`quality` 以 VoiceDesign
  指令复现角色，`balanced/light` 绑定同名 CustomVoice speaker；旧四 ID 与 13 个 OpenAI
  voice 名称保留为 alias。API 从当前权重声明能力，自定义 VoiceDesign 音色在低档返回
  `available=false`，合成前稳定返回 `voice_not_available`。
- 最终 wheel 已安装；`quality` 的九个 VoiceDesign 角色和 `balanced` 的九个 CustomVoice
  speaker 均逐项通过真实公共 PCM 合成，`light` 复用同一 TTS artifact 并完成真实合成。
  自定义音色在 `light` 为不可用，切回 `quality` 后同一条目恢复并合成成功。切档 smoke
  同步改为 canonical `serena` 的中文原生短句，消除目录旧 ID 与跨语言随机质量对可用性门的干扰；
  最终已安装 CLI 的 `quality→balanced→quality` 往返 smoke 通过。最终代码门为 1005 项
  通过、覆盖率 83.17%，Ruff、Mypy、OpenAPI、plist lint 与 wheel 构建均通过。
  S05 私有控制 socket 已退役。

## 回退

旧 app release、私有配置、外部模型和受管模型均保留。应用层回退时先停用服务，将
`runtime/current` 恢复到上一 release，再重新安装并启用对应 LaunchAgent；档位回退使用
`speechrail profile rollback --yes`。不得删除外部模型、配置或日志。真实失败回退已验证
selection 保持 last-known-good；目标设备上的回退与长时间运行仍随 V01 验收。
