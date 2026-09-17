# SpeechRail Design Kit（Figma 开发插件）

把这套重设计规格生成到 Figma 的**本机开发插件**。它只写 Figma 文档，不接触仓库代码、服务或运行态。

## 文件

| 文件 | 作用 |
|---|---|
| `manifest.json` | 插件清单（`editorType: ["figma"]`，`networkAccess` 仅 `none`） |
| `icons.js` | 34 个 lucide 图标的真实几何（由 lucide 源生成后固化） |
| `main.js` | 生成器：Variables、Text styles、Foundations、Components、10 个屏幕画板 + 深色克隆、流程页、菜单栏与设置页、归档对照页、原型连线、自检 audit。七组内容排在**两个真实页面**上（见「页面与排布」） |
| `build.js` | 把 `icons.js` + `main.js` 合成 `code.js`，并连同 `manifest.json` 落到 Figma 文件选择器可访问的目录 |
| `audit.js` | 静态自检（不需要 Figma）：`main.js` 引用的颜色变量、图标、文本样式是否都能在自己的表里解析到 |

`code.js` 是构建产物，只写在落地目录（仓库外），不写回本目录，也不纳入版本控制。

## 使用

```bash
node build.js          # 合成 code.js，并写 code.js + manifest.json 到 ~/Downloads/SpeechRail-figma-kit/
node audit.js          # 静态自检引用的变量 / 图标 / 文本样式，退出码非 0 即有悬空引用
```

生成器只有这一份：源码在仓库里，运行产物在仓库外。不要在工作目录之外再留一份源码副本。

然后在 Figma 桌面版：

**Plugins → Development → SpeechRail Design Kit**

首次使用需要先 `Plugins → Development → Import plugin from manifest…`，指向与 `code.js` 同目录的
`manifest.json`（即 `~/Downloads/SpeechRail-figma-kit/manifest.json`）。

## 行为

- **幂等**：重跑时清空并重建全部 26 个顶层画板，页面本身尽量复用。
  逻辑上有七组内容（`00 Cover` / `01 Foundations` / `02 Components` / `03 Flows` / `04 Screens` /
  `05 Menu & Settings` / `06 Archive`），但**只落在两个真实页面**上（见下）。
  早于本方案的页名（例如上一版的 `00 Cover` 独立页）会被改名接管，接管不到的会被清空后删除，
  避免旧页把免费版的三页额度占满。
- **画板必须自己拥有内容**：文档画板（Cover / Foundations / Components）的导出取的是**该画板的子树**，
  页面层的兄弟节点再摆在画板矩形里也不会进图。`componentSet()` 因此把 16 个组件集建成画板的
  `layoutPositioning = "ABSOLUTE"` 子节点（坐标仍按声明值，不用改成内边距坐标系）；
  否则导出 Components 只会得到标题和一段说明——历史上真发生过一次，且画板被解散后内容会散在页面上。
- **自检**：运行结束会弹出报告面板，结论排在前面（`AUDIT VERDICT` → 连线数 → 绑定错误数 → 分步结果 → 逐帧明细）。
  审计按真实页面去重后覆盖全部画板；每帧列出尺寸、绑定归属（dark/light 计数）、字面量与变量解析值、占位灰计数、
  根帧越界与父子级内部越界，另有 stray 顶层节点检查，防止漏 `add()` 的节点掉在画布上无声通过。
  文档画板（Cover / Foundations / Components）同样是单帧，所以一并纳入，不要只审带屏幕的那几页。
- **连线**：屏幕那一组内 20 帧之间的侧边栏导航与状态行入口自动写入原型反应。
  预期 198 条（每帧 9 条导航 + 状态行；两帧「服务状态」自己就是状态行的目标，跳过），
  重跑报告里的实际连线数应与这个预期一致。

## 页面与排布

Figma **Starter（免费）版每个文件只允许 3 个页面**，而本套内容有七组。所以生成器把它们平铺在
两个真实页面上（留一页额度给使用者），每组画板之间留 400px 间距、顶端对齐：

| 真实页面 | 承载的逻辑组 |
|---|---|
| `01 Kit` | `00 Cover`、`01 Foundations`、`02 Components` |
| `02 Screens` | `04 Screens`（20 帧）、`03 Flows`、`05 Menu & Settings`、`06 Archive` |

页面由 `main.js` 顶部的 `PAGE_LAYOUT` 声明，想换小组、加第三页或改间距都改这一处。
生成器**不会**在额度已满时硬造页面：它先复用同名页，再接管其他遗留页（改名），最后才 `createPage()`。
  插件 API 只允许连**同一页内的顶层 frame**，所以流程页与设置窗口内部的跳转要手动补。
- **描边与投影**：静态容器（卡片 / 列表 / 分组 / 流程步 / 归档面板）不描边、不投影，分离只靠填充层级与
  `hairline()` 分隔线（REDESIGN-SPEC §5.2）。保留描边的只有三类：承载状态的元素（选中档位卡、播放中候选卡、
  焦点字段、结论面板）、系统控件（输入框 / 按钮 / 分段控件 / 键帽）和窗口级浮层（菜单面板）。
- **导出就绪**：每个画板写入 `exportSettings = PNG @4x`（`main.js` 顶部 `SCREEN_EXPORT_SCALE`，Figma 的倍率
  上限）：1440×900 的画板导出为 5760×3600（288 dpi）。嫌文件大可改回 `2`（2880×1800）。在 Figma 里全选屏幕帧后
  （⌘A）用 `⇧⌘E` 或 Main menu ▸ File ▸ Export 一次性导出。
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
- **`combineAsVariants()` 只重新挂载，不摆位**：变体停在创建时的同一个角上，集合看上去只有最上面那一个状态。
  `componentSet()` 因此自己按 `SET_W = 704` 换行摆放变体，并用 `gridCursor` 把每个集合沿列推下去，避免长高的集合压到下一个。
- **`comp()` 的 `w` / `h` 要按轴落到 `primaryAxis` / `counterAxisSizingMode`**：竖向框的主轴是高，
  把 `w` 当主轴会让变体停在 40px 高，第二行起被裁掉。两个轴每次都写，未指定的轴留 `AUTO` 才能 hug 内容。
- **auto-layout 子行要显式 `stretch()`**：`Candidate Tile/head`、`Code Block/codeHead` 自己 hug 时，
  里面 `spacer()` 推不动右对齐的 `seed` 和复制按钮。
- **CJK 要在生成器里显式套字体**：Inter 不承载中文，Figma 的缺字回退在刚重建的文档里未热时会把中文导出成空白
  （拉丁文照常）。`loadCjkFont()` 从可用字体里挑一个 CJK 家族，`applyCjkFont()` 只给 CJK 区段套上；
  运行报告里的 `CJK runs:` 就是这次选中的家族。
- **导出面板按“上次用过的目录”落盘**：`⌘⇧G` 输入目标目录再 `Return` 只是把面板切到该目录，
  必须等「位置：」显示目标文件夹后再点 `Save`，否则文件会写进上一个目录（曾因此落到 `~/Downloads` 根目录）。
- **多选可以一次导出**：选中若干帧后右侧按钮会变成 `Export N layers`，各帧按自己的 export 设置（4x PNG + SVG）一次落盘，
  比逐帧点省事；目标目录里若已有同名文件，macOS 会弹覆盖确认，先清走旧文件更省事。

键帽、键值行与 Inspector 取值对齐统一走 `kbd()` / `kbdInRow()` / `kvRow()`，不要在页面里手写这几个形状。

## 约束

- Figma **免费版每个变量集合只允许 1 个 mode**。因此深色外观不是 mode，而是克隆浅色画板后逐节点改绑到
  `SpeechRail (Dark reference)` 集合。生产实现应使用真正的 Light/Dark 双 mode（见 `../REDESIGN-SPEC.md` §11.6）。
- 插件环境取不到 SF Pro，画板使用 `Inter`；生产 UI 使用系统字体。
- 给 paint 绑定变量必须用 `figma.variables.setBoundVariableForPaint`；`node.setBoundVariable("fills", …)`
  对 paint 字段无效且异常会被静默吞掉，表现为所有填充停在占位灰 `#808080`。
