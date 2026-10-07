---
title: "Loader 身份声明的纯归一化边界"
status: under_review
audience: "Worker / backend 开发者"
version: "0.1.0"
date: 2026-10-07
---

# Loader 身份声明的纯归一化边界

对应 #234 / #238 R09。`backends/loader_metadata.py` 只处理调用者明确选择的有限来源，
不读取模型目录、不导入 MLX/vendor、不加载模型、不拥有进程或 registry。
共享 bits/group 规则来自 `model_identity.validate_quantization_pair`，
snapshot 声明、loaded 观测和 ready identity 都复用它。

## 来源与取值

`LoaderSource` 包含固定来源标签和 Mapping / attribute 对象。collector 留在对应 worker：

| 后端 | 来源优先级 |
| --- | --- |
| ASR | session.model_info → session.config → session.model → session.model.config |
| TTS | model.model_info → model.config → model |

`loader_value` 按来源顺序、再按显式字段名顺序取首个非 missing / 非 None 值；
保留 False、空字符串及 unknown 字符串，让对应 adapter 决定是否合法，不推断成缺失。
family / variant、ASR compute dtype 与 tensor 分组、TTS tts_model_type / sample_rate
仍由各 adapter 验证。增加 collector 形状不需要修改基础合并规则。

## 两种声明合同

| 输入 | snapshot 完整声明 | loaded 部分观测 |
| --- | --- | --- |
| 没有量化字段 | 既有 unquantized 默认 | 未观察，返回 None |
| 量化字段为 None | 明确 unquantized | 未观察，继续其他来源 |
| 非空对象声明 bits=None / group=None | 明确 unquantized | 明确 unquantized，与有量化声明冲突 |
| 多份合法声明 | bits/group/format/dtype 完整相等 | 只比较 bits/group；保留首份合法规格 |

loaded 收集所有来源的 quantization / quantization_config，以及扁平
quantization_bits / quantization_group_size；不能用取值优先级掩盖矛盾量化声明。
缺失的扁平配对字段按 None 校验；bits/group 不配对时拒绝。

共同约束只接受整数位宽 4 或 8、正整数 group size；拒绝 bool、浮点数、
非法位宽、零/负 group size、不配对、空对象及未知声明键。
嵌套 QuantizationSpec 实例也重新经过完整 parser，不能凭实例类型绕过位宽/配对规则。
loaded 无效声明与冲突使用 `backend_identity_mismatch`，诊断仅带固定来源标签，
不包含声明值、模型路径或 vendor 内容；snapshot / ready pair 继续使用 ValueError。

解析能表示 4-bit 不意味着 catalog、档位或产品增加 Q4；本包不改模型支持集合、
dtype 选择、mixed precision、采样率、解码或生命周期。

## 验证与回退

纯向量覆盖 Mapping/object、字段优先级、missing/None/unknown、严格配对、
多声明冲突、snapshot 与 loaded 的差异和不触碰模型文件的独立 import。
两 worker 的 fake loader 构造测试分别验证 collector 接线、专属策略与错误分类；
现有 model identity、worker ready、limit/isolation 回归保留。

实际命令、审查修订和 CI 见 [loop r2 账本](../implementation/2026-10-07-issue-238-solid-loop-plan-r2.md)。
没有运行真实模型、音频、GPU 性能或服务操作。回退只撤销本包 source 接线与共享模块，
不改 catalog 格式、不迁移或删除用户模型。
