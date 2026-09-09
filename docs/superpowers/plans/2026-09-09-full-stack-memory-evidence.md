# 全链路内存证据与保护：ROI 审查及执行方案

日期：2026-09-09。状态：方案已审查，实施待启动。

跟踪 issue：https://github.com/hrygo/SpeechRail/issues/35 。GitHub issue 正文保存本方案的可远程审阅副本；阶段进度以 issue 检查项和关联证据为准。

目标：使三档内存报告覆盖实际使用的 VAD、ASR、ForcedAligner、CoreML 分人和 TTS，先修正测量可信度，再根据证据决定运行时保护投入。

范围：采样器、公共 API 基准、确定性回归测试、基准 SOP 与脱敏报告。运行时准入变更属于有条件后续阶段。本方案不代表新的性能实测或发布验收。

## 1. 审查结论与 ROI

| 工作 | 收益 | 相对成本/风险 | 决策 |
|---|---|---|---|
| 修复丢失样本却判 complete | 消除错误通过，是所有后续数字的基础 | 低；仅工具和测试 | P0 必做 |
| 精确发现 CoreML 子进程，保存角色 | 覆盖真实服务占用，可追溯 | 低至中 | P0 必做 |
| 公共 VAD/分人组合场景与加载证据 | 得到用户实际场景峰值 | 中；需要真实模型执行时间 | P1 必做 |
| 长会话、重复关闭与低内存设备验收 | 发现增长和释放问题，限定设备承诺 | 中；设备依赖 | P1 分层执行 |
| 动态字节 reservation、所有模型统一生命周期 | 可能改善低内存拒绝与调度 | 高；死锁、重复计费、兼容性风险 | P2 由证据触发 |
| 全硬件/OS 精确匹配的 footprint 数据库 | 理论可细分预算 | 高维护成本，容易因版本变化拒绝正常请求 | 首轮不做 |

推荐用两个可独立交付的变更完成 P0/P1。P0 完成即有收益，无需等待低内存设备；P1 后才决定是否开展 P2。成本为相对判断，未作工时承诺。

## 2. 事实与上一方案需要修正的地方

- `examples/perf/sample_resources.py::worker_pids` 通过命令字符串识别 host/ASR/TTS，缺少 CoreML 分人；还需要绑定具体服务身份，避免采到无关测试进程。
- `examples/perf/benchmark_resources.py::ProcessResourceMonitor._collect_tick` 遇到 reader 返回 None 直接 continue，整个空 tick 也不保留。下游 `_normalise_resources` 只能看见剩余样本，可能错误判 complete。这是源码确认的缺陷，不证明历史每个 tick 都曾缺样；历史 complete 标记不能单独证明覆盖完整。
- 归一化会删除 role，因此已保存的 JSON 无法恢复角色归属；不得根据旧 PID 猜测历史模型加载状态。
- `bench_realtime.py` 请求 manual turn detection，没有主动验证 Silero 推理。VAD 在 host 中共享 ONNX session，加载后会保留；因此应表述为“未验证 VAD 覆盖”，不能仅凭 manual 就断言历史 host 内完全没有 VAD 内存。
- ForcedAligner 在 `qwen3_worker.py::_align_fixed_text` 懒加载并缓存于 ASR worker。已有带时间戳请求可能触发它；必须验证实际加载状态，不能笼统声称历史基准完全排除 aligner。
- `model_budget.py` 的半物理内存预算仅影响 ASR/TTS overlap；`services.py::_heavy_overlap_policy` 对启用模型使用未知 footprint。串行计算不等于权重互斥常驻，也不构成整个服务物理内存硬上限。
- REST 分人后处理在 ASR governor 调用结束后进行；Realtime 分人有独立单会话 admission。把分人简单放进与 ASR 互斥的计算槽，会破坏其合法协作，并有嵌套获取风险。
- 实测进程总量应只相加去重后的进程 footprint。VAD/aligner 的增量用于解释，不能再加到包含它们的 host/ASR 总量上。

取证基线为提交 `494f953` 及 2026-09-09 检查到的工作树。运行相关文件存在并行改动；实施时复核基线和差异，不能覆盖未知改动。关联 #11 的 VAD 声学质量工作继续独立跟踪；本方案的资源测试不替代 FAR/FRR、DER 或人工质量验收。

## 3. P0：修复采样契约

目标文件：`examples/perf/sample_resources.py`、`examples/perf/benchmark_resources.py`、`tests/test_resource_sampling.py`、`tests/test_profile_benchmark_contract.py`。

- [ ] 先增加失败回归：发现 host+CoreML，CoreML reader 返回 None，归一化结果必须 complete=false；全空 tick、发现异常、PID 生命周期变化、RSS fallback 分别覆盖。
- [ ] 每轮记录 discovered identities、observed identities、missing identities 与错误原因；读取失败保留空值，空 tick 保留。整体 gate 不能以删除坏样本恢复通过。
- [ ] 进程发现以目标服务 PID/生命周期为根，核对父子归属和可执行文件；识别 CoreML worker，包含服务实际存活的辅助子进程。命令参数只在内存内核对，输出只保留白名单角色与身份。
- [ ] 动态扫描覆盖懒加载；发现期间集合变化单列 transition/incomplete。期望角色按场景 active 窗口定义，不能要求分人子进程在启动前或关闭后存在。
- [ ] 保留安全 role、相对采样时间、tick 开始/结束、实际间隔、最长间隔、缺样数和覆盖状态。基准 schema 升版；旧结果可读，但覆盖未知不能通过新 gate。
- [ ] 统一 standalone sampler 与 benchmark monitor 的完整性计算，避免两套逻辑再漂移。
- [ ] 修订 v2.0.3 报告限制说明：保留原始数值，注明历史缺少全链路覆盖证据，不能作为绝对上限；不伪造补测。

验收：模拟遗漏、异常、空 tick、进程重用均无法通过；CoreML 被纳入同 tick 总量；无关同名进程排除；角色保留且不泄露命令、路径或密钥。跨进程逐个采样存在时间偏差，应称“同轮采样最大观测值”，不是数学瞬时极值。

## 4. P1：最小充分真实场景

复用 `bench_realtime.py`、`benchmark_runner.py`、共享鉴权 resolver 和资源 monitor。只在必要时拆出 `examples/perf/benchmark_scenarios.py`，不再建独立私有 runner。CLI 新参数在实现后才进入复现说明。

| 场景 | 必须实际执行的行为 | 证明什么 |
|---|---|---|
| A 基线 | 同一 fixture 的 manual ASR，随后固定 TTS | 与原测试流程对照 |
| B VAD | server_vad 输入含静音和真实语音，收到 speech started/stopped 与非空 ASR 终态 | Silero 实际推理及 host 占用 |
| C REST 分人 | gpt-4o-transcribe-diarize + diarized_json，带有效文本和匿名分人结果 | CoreML、对齐与 ASR 组合 |
| D Realtime 全链路 | server_vad + session.speechrail.diarization.enabled=true；完成对齐、分人事件，分人会话仍存活期间请求 TTS | 产品允许的共存峰值 |
| E 生命周期 | 重复连接/取消/关闭，持续会话及慢消费者 | 缓冲增长、退出和残留 |

先 quality 冒烟确认场景真的激活，再逐档 quality/balanced/light 正式采集：至少一次预热、五次完整循环；E 每档先执行 10 次关闭循环及 10 分钟持续会话。只有增长趋势、积压或取消异常才扩大到 30–60 分钟。shadow VAD 仅在实际启用或改动相关时增补，不作为每次发布默认工作。

内存窗口覆盖首次加载、推理、对齐、尾部 drain、TTS 及关闭后状态。真 cold 必须确认模型未加载；切档自带 smoke 已加载时记 cold_unavailable，可单列“首次 VAD/首次分人”而不冒称全服务 cold。

加载证据优先使用已有公共事件和经过身份核对的子进程。若无法证明 aligner 实际执行，补最小内部诊断计数（loaded/requests），不扩大公开 API。VAD/aligner 同进程的差值标为归因估计，正式总量仍来自唯一 PID 集合。

持续采样记录覆盖间隔和开销；若短生命周期 worker 无完整 active tick，结果为未覆盖，延长合法 fixture 后重测。比较一组有/无采样运行判断扰动；无需首轮重写原生采样器。

报告分开给出 sample completeness、scenario coverage、resource budget verdict 三项。五次循环报告 max/median/range 和样本数；N=5 的 p95 仅描述性展示，不用于宣称统计可靠上界。记录 pressure/swap 变化作为系统辅助证据，不直接归因于服务，也不与进程 footprint 相加。

- [ ] 场景 runner 及 fake WebSocket/HTTP 回归完成；错误/超时/取消必须非成功退出并保留安全原因。
- [ ] 三档 A–E 实测与加载证据齐全；外部客户端隔离、共享 key 自动发现、恢复原 profile。
- [ ] 脱敏报告逐场景列身份、预期/观测角色、峰值、采样间隔与完整性、结束状态。
- [ ] 8 GiB light 能力在真实目标设备验收前保持 unset；大内存机器限额测试只证明拒绝逻辑，不能替代设备运行验收。

## 5. P2：仅在证据触发后实施

触发条件：目标设备预算被合法场景超过；稳定复现 pressure/OOM；持续内存增长；或既有互斥导致用户可见延迟且实测支持放宽。任一项需要附 run、场景、身份和重复证据，再开关联实施 issue。

优先级依次为：修复具体泄漏/无界缓存 → 减少重复 PCM 拷贝和限定缓冲 → 复用既有闲置 worker 回收 → 有必要才加入预算 reservation。VAD 共享权重缓存是合法常驻，不能把 session 关闭后不降至初始 host 内存直接判泄漏。

若需要 reservation：以实际物理 owner 和生命周期计费；驻留与请求增量分开；共享 ASR 和 aligner 不重复计费。获取组合资源采用一次原子检查，禁止持有 ASR 后等待与其互斥的分人资源。释放与真实卸载一致，不能在请求结束但权重仍驻留时归零。未知 footprint 首先关闭证据 gate 并保留当前保守调度，不因 OS 小版本变化自动拒绝所有正常推理。

安全余量和限制值应在观测噪声、加载峰值及目标设备证据后冻结；本方案不先写任意百分比。保护定位为应用级准入；轮询存在延迟，不能承诺阻止所有瞬时 OOM。超限失败复用已审查契约，新增错误码或拒绝行为必须更新契约与测试。不得自动降级模型或退出其它客户端。

## 6. 验证、发布与跟踪

P0/P1 的确定性测试在 GitHub Ubuntu/macOS CI 执行，真实权重只在授权本机运行。先执行针对性测试：

```bash
uv run --extra dev pytest tests/test_resource_sampling.py tests/test_profile_benchmark_contract.py
```

代码交付前执行项目完整 gate：

```bash
uv run --extra dev pytest
uv run --extra dev ruff check src tests
uv run --extra dev mypy src
npx @redocly/cli lint contracts/openapi.yaml
git diff --check
```

同步 `.agents/skills/speechrail-perf-benchmark/SKILL.md`：声明模型启用与实际执行的区别、预期角色、schema、覆盖 gate 和失败处理。脚本负责强制校验，skill 负责范围与证据解释。README 未获本任务修改授权，保持不变。

跟踪方式：一个 GitHub 主 issue 使用以下检查项，每项完成附 PR/commit、CI run 与报告链接。P2 作为条件评估关闭，无证据时不因未实施而无限延期。

- [x] ROI 审查与方案落盘
- [ ] P0 采样可信度和旧报告说明完成
- [ ] P1 公共场景 runner 和回归完成
- [ ] 三档真实资源报告完成，原 profile 恢复
- [ ] 对应提交 GitHub CI 全绿
- [ ] P2 决策有证据：无需实施或已创建关联 issue
- [ ] 目标设备限制明确，交付审查后关闭主 issue

自动跟踪每日检查一次 issue/关联 PR/CI；状态有变化或新增阻塞时报告，关闭且证据齐全后暂停。跟踪不自动实施、合并、发布或重跑真实模型。方案本轮为文档交付；已有源码并行改动保持原样。
