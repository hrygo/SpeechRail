// Static audit of the kit sources: every colour variable, icon and text style
// the builder references must exist in its table. This is the same class of
// defect the plugin's runtime audit reports in Figma, caught before the next
// Figma run instead of after it.
//
// Usage: node audit.js
const fs = require("fs");
const path = require("path");

const dir = process.argv[2] || __dirname;
const main = fs.readFileSync(path.join(dir, "main.js"), "utf8");
const icons = fs.readFileSync(path.join(dir, "icons.js"), "utf8");

function tableNames(source, constName) {
  const start = source.indexOf("const " + constName + " = [");
  if (start < 0) return null;
  const end = source.indexOf("\n];", start);
  const body = source.slice(start, end);
  const names = [];
  const re = /\[\s*"([^"]+)"/g;
  let m;
  while ((m = re.exec(body))) names.push(m[1]);
  return new Set(names);
}

const colorTokens = tableNames(main, "COLOR_TOKENS");
const numberTokens = tableNames(main, "NUMBER_TOKENS");

// TEXT_STYLE_DEFS entries are ["Name", size, "Style", lineHeightPercent]
const styleDefs = (() => {
  const start = main.indexOf("const TEXT_STYLE_DEFS = [");
  const body = main.slice(start, main.indexOf("\n];", start));
  return new Set([...body.matchAll(/\[\s*"([^"]+)"/g)].map((m) => m[1]));
})();

const iconKeys = new Set([...icons.matchAll(/^\s*"([^"]+)":\s*"<svg/gm)].map((m) => m[1]));

function collect(re) {
  const out = new Map();
  let m;
  while ((m = re.exec(main))) {
    const key = m[1];
    const list = out.get(key) || [];
    list.push(m[0].slice(0, 70).replace(/\s+/g, " "));
    out.set(key, list);
  }
  return out;
}

function merge(into, from) {
  for (const [key, list] of from) {
    into.set(key, (into.get(key) || []).concat(list));
  }
}

const colorUses = collect(/V\["([^"]+)"\]/g);
// Status tones and similar tables name their variables in object literals
// ({ fill: "surface/infoTint", ink: "status/info" }) and bind them later with a
// dynamic lookup, so a `V["…"]`-only scan would call those two unused.
merge(colorUses, collect(/\b(?:fill|ink|stroke|color):\s*"([a-z]+\/[A-Za-z]+)"/g));
// 数值 token 在生成器里按**名字**取用（`NT["space/16"]`，见 `main.js` 的 LAYOUT 一节）。
// `N` 是 build-time 的变量注册表（装的是 Figma 变量对象），两者同名不同物，所以只扫 NT。
const numberUses = collect(/NT\["([^"]+)"\]/g);

// Icons are referenced four ways: icon(parent, "name", px, color),
// iconButton(parent, "name", side), the icon argument of
// primaryButton/secondaryButton(parent, "label", "name"), and object literals /
// table rows ({ icon: "check", … }).
const iconUses = new Map();
merge(iconUses, collect(/\bicon\([^,()]+,\s*"([^"]+)"/g));
merge(iconUses, collect(/\biconButton\([^,()]+,\s*"([^"]+)"/g));
merge(iconUses, collect(/\b(?:primary|secondary)Button\([^,()]+,\s*"[^"]*",\s*"([^"]+)"/g));
merge(iconUses, collect(/\bicon:\s*"([^"]+)"/g));

// 走变量传递的图标名（逐状态动作数组、悬停工具条的按钮列表）对上面四种调用点写法是
// 不可见的：里面写错一个名字不会报错、也画不出来，而审计仍然说 clean。所以这里再扫
// 一遍生成器里所有 kebab-case 字面量，凡是「看起来像图标名但图标表里没有」的都报出来。
// 少数确实不是图标名的字面量列在允许表里，新增时要写清原因。
const KEBAB_NON_ICONS = new Set([
  "ease-out",            // 原型连线的缓动名
  "smart-animate",       // 原型连线的转场名
  "aligner-q8",          // 制品与模型名（画板上的示例取值，不是图标）
  "aligner-bf16",
  "diarization-coreml",
  "qwen3-30b",
  "qwen3-30b-a3b",
]);
const kebabLiterals = collect(/"([a-z][a-z0-9]*(?:-[a-z0-9]+)+)"/g);

// 上面那张表之外，任何「像图标名但不是图标」的字面量都算失败：写错一个图标名不会报错、
// 也画不出来，这类缺陷只能在这里拦住。要放行就得改这张表，那是一次可评审的动作。
function reportKebab() {
  const suspicious = new Map();
  for (const [key, list] of kebabLiterals) {
    if (iconKeys.has(key) || KEBAB_NON_ICONS.has(key)) continue;
    suspicious.set(key, list);
  }
  if (!suspicious.size) {
    console.log("\n== kebab-case literals: all resolve to an icon");
    return 0;
  }
  console.log(`\n== kebab-case literals that are not icons: ${suspicious.size}`);
  for (const [key, list] of suspicious) {
    console.log(`   "${key}" referenced by: ${list.slice(0, 2).join(" | ")}`);
  }
  return suspicious.size;
}

// text(name, chars, "Style / Name", colorVar, opts): the style is the third
// positional argument, and `chars` is either a literal (sometimes concatenated)
// or a variable.
const styleUses = new Map();
merge(styleUses, collect(/text\(\s*"[^"]*",\s*"(?:[^"\\]|\\.)*"(?:\s*\+\s*"[^"]*")*\s*,\s*"([^"]+)"/g));
merge(styleUses, collect(/text\(\s*"[^"]*",\s*[A-Za-z_$][A-Za-z0-9_$.]*\s*,\s*"([^"]+)"/g));
// `captionBandFrame` 把字号档当参数传进来（调用点写的是 `style: "Caption Band / 大字"`），
// 样式名因此不在 text() 的第三个实参位置上。上面两条扫描看不见它，会把已经在用的
// 「Caption Band / 大字」报成 unused——与颜色那两处 fill/ink 的双写是同一个理由。
merge(styleUses, collect(/\bstyle:\s*"([^"]+)"/g));

function report(title, used, known, extraSkips) {
  const missing = [...used.keys()].filter(
    (k) => !known.has(k) && !(extraSkips || []).some((p) => k.startsWith(p))
  );
  console.log(`\n== ${title}: ${used.size} referenced, ${known.size} defined`);
  if (!missing.length) {
    console.log("   all references resolve");
    return 0;
  }
  for (const k of missing) {
    console.log(`   MISSING "${k}" referenced by: ${used.get(k).slice(0, 2).join(" | ")}`);
  }
  return missing.length;
}

let bad = 0;
bad += report("colour variables", colorUses, colorTokens, ["dark/"]);
bad += report("icons", iconUses, iconKeys);
bad += report("text styles", styleUses, styleDefs);
bad += reportKebab();

bad += report("number tokens", numberUses, numberTokens);
console.log(
  `   （生成器按名字引用 ${[...numberUses.values()].reduce((n, l) => n + l.length, 0)} 处；`
    + "版式数值走 LAYOUT，行内微间距仍是就地字面量）"
);

// --- 版式单点声明（LAYOUT / NT）----------------------------------------------
//
// 「一个规范」在代码里的检查点：`LAYOUT` / `NT` 已经认领的版式值，不允许再以字面量
// 出现在**宽度位置**上。它拦的是「同一语义两个数值」——2026-09-18 的核查里
// 「列表列 240 / 232 / 272 三分天下」「248 与 196 手写在四处」「字幕详情工具栏还留着 260」
// 「设置面板 240 / 260 / 300 并存」都是这一类，此前没有任何门禁看得见。
//
// 折行宽度（`{ w: N }`）**不在**这条规则里：它们由所在容器决定、随文案走，数量多且
// 大多是一次性的；列表列那一族的折行宽已经由 `LAYOUT` 推导出来（`listRowInnerW`）。
const LAYOUT_OWNED = [
  { value: 280, owner: "LAYOUT.listW（目录列）" },
  { value: 248, owner: "LAYOUT.listInnerW（列表内宽）" },
  { value: 228, owner: "LAYOUT.listRowInnerW（列表行内宽）" },
  { value: 196, owner: "LAYOUT.profileCardInnerW（档位卡内宽）" },
  { value: 220, owner: "LAYOUT.sidebarInnerW（侧栏内宽）" },
  { value: 260, owner: "LAYOUT.settingsLabelW（设置说明列）" },
  { value: 1440, owner: "LAYOUT.windowW（窗口宽）" },
  { value: 1600, owner: "LAYOUT.canvasW（文档画布）" },
  { value: 288, owner: "NT[size/menu]（菜单面板）" },
];
const WIDTH_POSITIONS = [
  /\bsize\([A-Za-z_$][A-Za-z0-9_$.]*,\s*(\d+)\s*,/g,
  /\bsearchField\([^,()]+,\s*[^,()]+,\s*(\d+)\s*\)/g,
  /\bcaptionWidth:\s*(\d+)/g,
];

function reportLayoutLiterals() {
  const hits = [];
  WIDTH_POSITIONS.forEach((re) => {
    let m;
    while ((m = re.exec(main))) {
      const value = Number(m[1]);
      const owned = LAYOUT_OWNED.find((o) => o.value === value);
      if (!owned) continue;
      const line = main.slice(0, m.index).split("\n").length;
      hits.push(`   main.js:${line} 把 ${value} 写成字面量（应走 ${owned.owner}）`);
    }
  });
  console.log(`\n== 版式单点声明: ${LAYOUT_OWNED.length} 个值受管`);
  if (!hits.length) {
    console.log("   受管值都只在声明处出现，没有第二份字面量");
    return 0;
  }
  hits.forEach((h) => console.log(h));
  return hits.length;
}

bad += reportLayoutLiterals();

// Unused definitions are informational: a token nobody binds is dead weight in
// the Figma file, not a build error.
for (const [title, uses, defined] of [
  ["colour variables", colorUses, colorTokens],
  ["icons", iconUses, iconKeys],
  ["text styles", styleUses, styleDefs],
]) {
  const unused = [...defined].filter((k) => !uses.has(k));
  if (unused.length) console.log(`\n-- unused ${title}: ${unused.join(", ")}`);
}

console.log(`\naudit: ${bad === 0 ? "clean" : bad + " missing reference(s)"}`);
process.exit(bad === 0 ? 0 : 1);
