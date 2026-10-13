# Realtime 会话所有权拆分（#228）

日期：2026-10-09

范围为本地实施与 fake 定向测试，不改公开 wire、模型配置、服务运行态或用户存储。

1. 将 TTS 的连接级 request ledger 与每次 utterance 的 task、controller、ready、window、receipt、wire terminal 分开。异步路径捕获本次 context，旧 finally 只能释放本次 context。
2. 将 ASR 的输入时钟、admission、冻结 item、reader、commit barrier 与 governor reservation 归入独立 owner。
3. 将 alignment task、diarization actor/ledger、epoch 与归属投影归入辅助 owner。辅助结果只读取冻结文本和输入身份快照。
4. 根 session 仅负责协议配置、事件派发和组合关闭。子 owner 接收窄端口和只读配置快照，不接收 AppServices 或 root 任意写接口。
5. 保留 controller 的唯一领域终态、owned cleanup、lane 隔离、canonical final、现有采样轴及错误顺序。

验证使用定向 ASR/TTS/alignment/diarization 回归与独立 owner fake；增加旧 context 收尾、admission 前取消和组合关闭的确定性断言。结构迁移不以文件长度或编译通过单独验收。

回退通过恢复对应 owner 接线完成，不触碰模型或用户内容。Git 提交与远端操作仍待用户明确要求。
