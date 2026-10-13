# 音色存储显式所有权 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task in the current session. 用户要求逐项处理短时可验证 Issue；实施和必要验证按该范围推进。本计划不构成提交、推送或合入的额外授权。

**Goal:** 完成 #223：纯领域导入不初始化存储；每个应用显式拥有一个文件存储，目录、验证、修订与租约共同使用它。

**Architecture:** domain 定义值、规则与目录/修订/租约端口；现有文件实现移入 infrastructure，保持锁、CAS 与清理语义。App composition root 通过明确路径打开 owner，并注入 HTTP、Realtime、job、gate、backend；worker 只消费请求快照或纯系统音色。

**Tech Stack:** Python >=3.14,<3.15，现有 uv / pytest / Ruff / Mypy，FastAPI 与现有 framed worker。

**Spec:** GitHub #223 的全部验收矩阵；关联现有 `domain/tts.py`、`application/services.py` 与 `backends/qwen3_tts.py`。

## Global Constraints

- 不改音色 JSON schema、公开协议、用户数据、模型与运行态。
- 一个应用只有一个生产存储/租约 owner；不建立 lazy singleton 或请求期默认存储。
- 文件锁、原子替换、CAS、撤销、读租约与实际后端清理顺序保持。
- 文件模型与测试 fixture 均使用临时目录；不访问真实用户音色目录。
- 当前 worktree 无匹配图谱，coverage 为 outside_project；以定向源码和回归验证范围。

## Review Focus

- 两应用在同一进程使用相同 voice ID 时，修订、验证、缓存与租约不能交叉。
- 损坏/链接/权限异常继续 fail closed，不把系统音色成功误当存储正常。
- 更新与取消期间读租约保留至实际 cleanup；不能在 admission 或响应结束时提前释放。
- candidate 临时 profile 和 worker warmup 不隐式重新读取用户 registry。
- 设计幂等日志与 validation store 随 owner 的路径隔离，不能继续从全局定位。

### Task 1: 冻结依赖与隔离要求

**Files:** Create `tests/test_voice_store_composition.py`; inspect existing clone/revision/safe-listing/design tests.

**Interfaces:** `create_app(..., voice_store=...)`；`AppOverrides.voice_store`；`services.voice_store`。

- [ ] 添加受控子进程导入测试，拦截 home 路径文件访问，导入 `speechrail.domain.tts` 必须无事件。
- [ ] 添加两个临时文件 owner 的应用测试，相同 voice ID 的创建、更新、验证与租约彼此隔离。
- [ ] 先运行新测试，确认旧全局入口无法满足隔离和注入要求。

```python
first = create_app(settings, voice_store=store_a)
second = create_app(settings, voice_store=store_b)
assert first.state.services.voice_store is store_a
assert second.state.services.voice_store is store_b
```

### Task 2: 移出文件实现并定义端口

**Files:** Create `domain/voice_ports.py`, `infrastructure/voice_registry.py`; modify `domain/tts.py` and file-store test imports.

**Interfaces:**

```python
class VoiceDirectory(Protocol):
    def get_profile(self, voice: str) -> VoiceProfile: ...
    def snapshot_profiles(self) -> tuple[VoiceProfile, ...]: ...

class VoiceLeases(VoiceDirectory, Protocol):
    def lease_profile(
        self, voice: str, *, expected_revision: str | None = None
    ) -> AbstractContextManager[VoiceProfile]: ...
```

- [ ] 按现有方法签名补充修订/CAS与存储位置、验证属性合同；不复制持久化实现。
- [ ] 将 VoiceRegistry 原类体及文件原子写入 helper 移到 infrastructure；新增显式 `open`/`load`。
- [ ] 删除模块级实例和 getter；系统音色解析仅访问不可变内存常量。
- [ ] 更新真实文件回归为显式打开临时存储，跑 schema、CAS、链接、损坏、租约回归。

### Task 3: 迁移生产调用链

**Files:** `app.py`, `config/__init__.py`, `application/services.py`, `application/voice_validation_gate.py`, `application/voice_quality_run.py`, `application/realtime_openai.py`, `backends/qwen3_tts.py`, `backends/qwen3_tts_worker.py`, `backends/qwen3_voice_binding.py`, `runtime/local_file_processor.py`, `http/voice_projection.py`, `http/routes/{audio,capabilities,system,voice_designs}.py`。

**Interfaces:** composition 显式打开 FileVoiceRegistry；backend 必需注入 `VoiceLeases`/`VoiceDirectory`；gate 必需注入验证目录；job TTS 必需注入存储。

- [ ] 组合根根据 Settings 路径打开唯一 owner，并向所有路由与 worker/router 注入相同对象。
- [ ] 将 profile/binding、验证与 journal 读取改为显式参数；worker 不导入存储实现。
- [ ] 保留 `lease_profile` 的现有 `with`/ExitStack 和后端 cleanup owner，不移动退出点。
- [ ] 测试应用和 backend helper 改为显式依赖，删除全局 monkeypatch，不为通过保留 fallback。
- [ ] 跑两应用隔离、HTTP/Realtime/job 接线与严格验证定向回归。

### Task 4: 完整验收与交付

**Files:** update architecture ownership documentation and `docs/implementation/2026-10-09-short-validation-issues.md`。

- [ ] 复核所有生产入口无全局 getter，无 Request 中默认创建存储。
- [ ] 运行受影响文件回归、Ruff、Mypy、diff check；记录本地交付状态，远端动作须有用户明确授权。
- [ ] 若获得远端交付授权，全部 selected/required CI 通过后 rebase 合入，回读 #223 为 CLOSED 与开放数量；不以本地测试代替远端完成。
- [ ] 记录无运行态/模型/UI 操作；回退只撤销接线与搬移，不删除或迁移用户制品。
