# SpeechRail Design Kit（Figma 开发插件）

把这套重设计规格生成到 Figma 的**本机开发插件**。它只写 Figma 文档，不接触仓库代码、服务或运行态。

## 文件

| 文件 | 作用 |
|---|---|
| `manifest.json` | 插件清单（`editorType: ["figma"]`，`networkAccess` 仅 `none`） |
| `icons.js` | 30 个 lucide 图标的真实几何（由 lucide 源生成后固化） |
| `main.js` | 生成器：Variables、Text styles、Foundations、Components、8 个屏幕画板 + 深色克隆、流程页、菜单栏与设置页、归档对照页、原型连线、自检 audit |
| `build.js` | 把 `icons.js` + `main.js` 合成 `code.js`，并连同 `manifest.json` 落到 Figma 文件选择器可访问的目录 |

`code.js` 是构建产物，只写在落地目录（仓库外），不写回本目录，也不纳入版本控制。

## 使用

```bash
node build.js          # 合成 code.js，并写 code.js + manifest.json 到 ~/Downloads/SpeechRail-figma-kit/
```

生成器只有这一份：源码在仓库里，运行产物在仓库外。不要在工作目录之外再留一份源码副本。

然后在 Figma 桌面版：

**Plugins → Development → SpeechRail Design Kit**

首次使用需要先 `Plugins → Development → Import plugin from manifest…`，指向与 `code.js` 同目录的
`manifest.json`（即 `~/Downloads/SpeechRail-figma-kit/manifest.json`）。

## 行为

- **幂等**：重跑时清空并重建全部 7 个页面（`00 Cover` / `01 Foundations` / `02 Components` / `03 Flows` /
  `04 Screens` / `05 Menu & Settings` / `06 Archive`），不新增页面。
  Figma 不允许插件删除已被引用的页面或变量集合，因此实现上是「复用页面 + 清空子节点 + 复用同名变量」；
  页面重命名（`03 Screens` → `04 Screens`）在清空之前执行，避免旧页名留成一张带内容的游离页。
- **自检**：运行结束会弹出报告面板，结论排在前面（`AUDIT VERDICT` → 连线数 → 绑定错误数 → 分步结果 → 逐帧明细）。
  审计覆盖全部 7 页；每帧列出尺寸、绑定归属（dark/light 计数）、字面量与变量解析值、占位灰计数、
  根帧越界与父子级内部越界，另有 stray 顶层节点检查，防止漏 `add()` 的节点掉在画布上无声通过。
  文档页（Cover / Foundations / Components）同样是单帧页面，所以一并纳入，不要只审带屏幕的那几页。
- **连线**：`04 Screens` 内 16 帧之间的侧边栏导航与状态行入口自动写入原型反应（126/126）。
  插件 API 只允许连**同一页内的顶层 frame**，所以流程页与设置窗口内部的跳转要手动补。
- **导出就绪**：每个画板写入 `exportSettings = PNG @1x`，在 Figma 里全选屏幕帧后即可一次性导出。
- **可选 PNG 导出**：`main.js` 顶部的 `EXPORT_PNGS` / `EXPORT_PAGES` 决定构建时是否把指定页的顶层 frame 按 0.5x
  导出成 PNG。默认 `false`（构建不该写文件）；需要评审图时再打开，并让 `EXPORT_PAGES` 一次只放一页 ——
  每个文件都会弹一次保存确认，前一个没确认完时后续下载会被丢掉。

## 生成器里几个容易踩的点

改 `main.js` 前值得先知道（都是实测踩出来的，不是 Figma 文档里的说法）：

- **绑定 paint 必须用 `figma.variables.setBoundVariableForPaint`**；`node.setBoundVariable("fills", …)` 对 paint 字段无效，
  异常还会被 `try/catch` 吞掉，表现为所有填充停在占位灰 `#808080`。
- **`resize()` 在 auto-layout 的 AUTO 轴上不生效**（下一次布局会覆盖回去）。所以 `size(node, w, h)` 会顺带把对应轴切成 `FIXED`。
- **`layoutGrow` / `layoutAlign` 必须在节点已有 auto-layout 父级时设置**。`add(d, node)` 之后再 `grow(node)` 不会报错，
  但也不生效；`applyLayout()` 会在挂载后重放这些意图。
- **`text()` 先套 `textStyleId`，再写 `characters`**。反过来的话节点仍按旧字体测量，按钮和表格单元格会按偏小的宽度裁掉自己的标签。
- **`spacer()` 不能放进“按内容撑高”的卡片**：它用 `layoutAlign:STRETCH` + `layoutGrow`，会在卡片内部制造溢出。
- 越界审计分两层：根帧级 `auditOverflow()` 与父子级 `auditInnerOverflow()`；只做前者时卡片内部的溢出是看不见的。
- **面板与窗口的高度按内容取高**：固定高度在内容刚好合适时看不出问题，长一页就在卡片内部溢出，而根帧级审计看不见。
  同级多个外观（三个菜单面板、三个设置窗口）取最高值对齐，图上并排比较才不会有参差的底边。
- **每个 builder 都要把节点 `add()` 进父级**：漏一次就是画布上一个游离 frame。stray 顶层节点检查就是为这类遗漏加的。

键帽、键值行与 Inspector 取值对齐统一走 `kbd()` / `kbdInRow()` / `kvRow()`，不要在页面里手写这几个形状。

## 约束

- Figma **免费版每个变量集合只允许 1 个 mode**。因此深色外观不是 mode，而是克隆浅色画板后逐节点改绑到
  `SpeechRail (Dark reference)` 集合。生产实现应使用真正的 Light/Dark 双 mode（见 `../REDESIGN-SPEC.md` §11.6）。
- 插件环境取不到 SF Pro，画板使用 `Inter`；生产 UI 使用系统字体。
- 给 paint 绑定变量必须用 `figma.variables.setBoundVariableForPaint`；`node.setBoundVariable("fills", …)`
  对 paint 字段无效且异常会被静默吞掉，表现为所有填充停在占位灰 `#808080`。
