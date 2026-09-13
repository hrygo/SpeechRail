# SpeechRail 设计资料

本目录保存 SpeechRail macOS App 的原始设计资料与本项目的补充设计。

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
