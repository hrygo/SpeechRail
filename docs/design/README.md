# SpeechRail 设计资料

本目录保存 SpeechRail macOS App 的原始设计资料与本项目的补充设计。

## 唯一规范（先读这一份）

[`UX-UI-SPEC.md`](./UX-UI-SPEC.md)：**全 App 的 UX/UI 统一规范**——token 契约、组件、版式、
交互语法、导航与键盘、状态模型、跨模块脊柱、模块覆盖矩阵、门禁与证据等级。
它把「会话三屏」与「其余模块」两套口径合成一套；本目录里其余文档是它的详图、过程与历史。

## 原始设计包（归档）

完整附件已归档到 [`archive/2026-09-12-macos-app-design-package/`](./archive/2026-09-12-macos-app-design-package/)，仅供设计追溯，不作为当前实现规范，包括：

- [`PRODUCT-DESIGN.md`](./archive/2026-09-12-macos-app-design-package/PRODUCT-DESIGN.md)：产品定位、信息架构、交互原则与视觉语言。
- [`PROTOTYPE-INVENTORY.md`](./archive/2026-09-12-macos-app-design-package/PROTOTYPE-INVENTORY.md)：10 张原型图的索引与说明。
- [`DELIVERY-NOTES.md`](./archive/2026-09-12-macos-app-design-package/DELIVERY-NOTES.md)：设计包交付边界与后续建议。
- [`README.md`](./archive/2026-09-12-macos-app-design-package/README.md)：设计包总览。
- `images/`：全部 10 张原型图。

附件中的内容作为设计参考吸收；当前代码、测试和公共契约仍是实现事实来源。原始设计包明确未覆盖的设置、模型管理页面，已在本次需求的补充规格中结合现有后端能力设计。
音色创作、配音台、音色库和作品框架继续保留为产品一级区域。

## 文字原型

管理控制台、运行监控和模型下载的逐页文字原型、普通用户/开发者双层信息和交互确认见：

[`speechrail-management-prototypes.md`](./speechrail-management-prototypes.md)

## 本次补充设计

管理控制台、运行监控看板，以及独立的模型下载与校验流程见：

[`docs/superpowers/specs/2026-09-13-speechrail-app-management-observability-design.md`](../superpowers/specs/2026-09-13-speechrail-app-management-observability-design.md)

其中明确区分：模型下载/校验、profile 应用、服务运行状态、推理就绪状态和质量验证，不把原型中的概念状态直接当成后端事实。

## 会话三闭环（2026-09-17 / 09-18）

语音助手、会议助手、实时字幕三条能力的设计资料：

- [`2026-09-17-live-sessions/SESSIONS-SPEC.md`](./2026-09-17-live-sessions/SESSIONS-SPEC.md)：模块规格（边界、逐面规格、状态矩阵、SQLite 数据模型、用户旅程）。
- [`2026-09-17-session-closures/`](./2026-09-17-session-closures/)：闭环稿的设计包、离线门禁与实现就绪度核查（Figma 里 53 板；生成器已 59 板，见下一行）。
- [`2026-09-18-figma-handover/FIGMA-HANDOVER.md`](./2026-09-18-figma-handover/FIGMA-HANDOVER.md)：**Figma 稿优化的独立团队交接文档**——权威来源、生成器路线、离线门禁、实跑 SOP、导出、资产清单、未决项与回退。
- [`2026-09-18-session-layer/TECHNICAL-DESIGN.md`](./2026-09-18-session-layer/TECHNICAL-DESIGN.md)：**会话层技术方案**——哪些能力归 macOS 原生、哪些归 Python 服务、边界规矩、数据口径、验收判据与外部最佳实践依据。

macOS 26-only 的 App 设计研究、Liquid Glass 分层、统一颜色/间距/字体/可访问性 token 见：

[`macos-app-design-system.md`](../developers/macos-app-design-system.md)

## 实施计划

- [整体 App 框架实施计划](../superpowers/plans/2026-09-13-speechrail-app-framework-plan.md)
- [服务模块实施计划](../superpowers/plans/2026-09-13-speechrail-service-module-plan.md)
