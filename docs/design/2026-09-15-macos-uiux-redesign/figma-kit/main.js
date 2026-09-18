// =============================================================================
// SpeechRail macOS 26 · UI/UX Redesign — Figma design kit builder
// Generates variables, text styles, foundations, components and all 8 screens.
// Idempotent: pages it owns are removed and rebuilt on each run.
// =============================================================================

// 这套生成器交付两份稿：全量稿（48 板，macOS 重设计的全貌）与会话闭环稿（只画三个
// 能力的完整闭环）。范围由 SPEECHRAIL_SCOPE 决定，默认 "full"——所以 build.js 的行为
// 一字未改；闭环稿由 build-closures.js 在拼接时先声明 SPEECHRAIL_SCOPE = "closures"。
const SCOPE = (typeof SPEECHRAIL_SCOPE === "string" && SPEECHRAIL_SCOPE)
  ? SPEECHRAIL_SCOPE
  : "full";
const CLOSURE_SCOPE = SCOPE === "closures";

const PAGE_NAMES = CLOSURE_SCOPE
  ? ["10 闭环总览", "11 会话闭环", "12 会话浮层"]
  : [
    "00 Cover", "01 Foundations", "02 Components", "03 Flows",
    "04 Screens", "05 Menu & Settings", "06 Archive",
    // 07 / 08 是 "02 Screens" 上的分组，不是独立页；列在这里是为了让审计名单与
    // PAGE_LAYOUT.groups 一一对应，而不是漏掉一半分组。
    "07 会话", "08 会话浮层"
  ];

// Page names retired in an earlier revision. Applied before the build loop so a
// re-run adopts the existing page — and every frame already on it — instead of
// creating an empty page under the new name and leaving the old one behind.
const PAGE_RENAMES = { "03 Screens": "04 Screens" };

// A Starter (free) file holds at most three pages, and this kit used to create
// seven. The logical pages are therefore laid out as two real pages: the
// documentation group on the first, the screens plus the flows / menu /
// archive on the second. Reusing two of the three leaves the file with
// headroom, and nothing in the kit needs a page of its own.
const PAGE_LAYOUT = CLOSURE_SCOPE
  // 闭环稿只用一张页：三条闭环是同一台机器的三个用法，拆到两页会让连线跨页失效
  // （插件只能写「同页 + 顶层 frame」的连线）。免费版每文件 3 页，这里占 1 页。
  ? [{ page: "01 闭环", groups: ["10 闭环总览", "11 会话闭环", "12 会话浮层"] }]
  : [
    { page: "01 Kit", groups: ["00 Cover", "01 Foundations", "02 Components"] },
    { page: "02 Screens", groups: [
      "04 Screens", "07 会话", "08 会话浮层", "03 Flows", "05 Menu & Settings", "06 Archive"
    ] }
  ];
const REAL_PAGES = PAGE_LAYOUT.map(function (spec) { return spec.page; });
// Groups whose top-level frames are product screens: they share the "▸ " naming
// rule and they are the only frames the prototype wiring can link across.
const SCREEN_GROUPS = CLOSURE_SCOPE ? ["11 会话闭环"] : ["04 Screens", "07 会话"];
// Gap between the tiled groups on a shared page, in canvas pixels.
const GROUP_GAP = 400;

const FONT_FAMILY = "Inter";
const FONT_STYLES = ["Regular", "Medium", "Semi Bold", "Bold"];

// Inter carries no CJK glyphs. Figma draws the missing runs with a system
// fallback, but that fallback is resolved per session, and a document that was
// just rebuilt exports those runs blank until something re-renders them at a
// readable zoom. The CJK family is therefore loaded up front and written onto the
// runs Inter cannot draw, which is also what macOS does on screen when SF Pro
// meets a Chinese string. Order = preference; the first family Figma has wins.
const CJK_FAMILIES = [
  "PingFang SC", "Hiragino Sans GB", "Noto Sans SC", "Source Han Sans SC", "Heiti SC", "Songti SC"
];
const CJK_STYLE_ORDER = ["Regular", "W3", "Medium", "W6", "Semibold", "Bold"];
let CJK_FONT = null;

// Screen hand-off exports. Figma re-renders vectors at the requested scale and
// caps the scale at 4x, so 4 is the highest-fidelity PNG the canvas can hand
// off: 1440 x 900 frames come out at 5760 x 3600 (288 dpi) instead of the soft
// 1440 x 900 files. Drop to 2 (2880 x 1800, Retina-exact) if the file size
// matters more than close-up detail: 16 screens are ~20 MB at 4x, ~4 MB at 2x.
const SCREEN_EXPORT_SCALE = 4;

// 会话三页的右栏（「本次会话 / 记录信息 / 字幕文件 / 分人的两个出口」）只有这一个宽度。
//
// 用户 2026-09-18 裁决（SESSIONS-SPEC §13 D7）：稿上原来同时在用 320（会议来源、内心 OS 的
// 邻居板）与 420（内心 OS、音色列表），而应用那边详情列的宽度只有一处声明——
// `Layout.inspectorColumnWidth = 360`（SpeechRailDesignTokens.swift，2026-09-16 定死）。
// 三个值不能同时成立，所以**取 360**：稿与实现各少一个可以漂移的数字。
// 要改宽度只改这一行，下面所有 `size(..., SESSION_SIDE_W, null)` 跟着走。
const SESSION_SIDE_W = 360;
// 目录列宽度（D10 / 未决项 1 归一化：会议 / 记录库 / 助手 / 文档全部收敛到 280）
const SESSION_LIST_W = 280;

// --- Colour tokens (Light / Dark) -------------------------------------------
const COLOR_TOKENS = [
  ["accent/rail", "#2A4E57", "#4FA4BA"],
  ["accent/voice", "#D97706", "#F59E0B"],
  ["status/ready", "#0D8A4F", "#34D17E"],
  ["status/attention", "#A86500", "#F5B544"],
  ["status/critical", "#CF2B2B", "#FF6F6F"],
  ["status/info", "#1A63D8", "#62A8FF"],
  ["surface/window", "#E8E8EA", "#201E21"],
  ["surface/sidebar", "#F2F2F4", "#28262A"],
  ["surface/content", "#FFFFFF", "#2B292C"],
  ["surface/panel", "#F5F5F7", "#232124"],
  ["surface/field", "#FFFFFF", "#1A191C"],
  ["surface/railTint", "#DCE9EE", "#36424A"],
  ["surface/voiceTint", "#FBEFD9", "#41331C"],
  ["surface/readyTint", "#E1F2E8", "#1B3A2A"],
  ["surface/attentionTint", "#FBEEDA", "#3D2F16"],
  ["surface/criticalTint", "#FBE4E4", "#40211F"],
  ["surface/infoTint", "#E1EBFB", "#1C2A40"],
  ["border/separator", "#DCDCE0", "#3A383C"],
  ["border/strong", "#C6C6CB", "#4A484C"],
  ["text/primary", "#1C1C1E", "#F1F0F3"],
  ["text/secondary", "#6E6E73", "#A8A6AD"],
  ["text/tertiary", "#A1A1A6", "#75737A"],
  ["text/onAccent", "#FFFFFF", "#07151A"]
];

const NUMBER_TOKENS = [
  ["space/2", 2], ["space/4", 4], ["space/8", 8], ["space/12", 12],
  ["space/16", 16], ["space/20", 20], ["space/24", 24], ["space/32", 32],
  ["space/48", 48],
  ["radius/container", 12], ["radius/tile", 10], ["radius/control", 8],
  ["radius/field", 8],
  ["size/controlComp", 28], ["size/control", 34], ["size/controlProm", 40],
  ["size/hitMin", 44], ["size/sidebar", 240],
  // 详情/侧栏列的唯一宽度。稿与实现各只有一处声明：这里是稿的那一处，
  // 实现那边是 `Layout.inspectorColumnWidth`（用户 2026-09-18 裁决 D7，= 360）。
  ["size/inspector", 360],
  ["size/windowMinW", 1120], ["size/windowMinH", 720]
];

const TEXT_STYLE_DEFS = [
  ["Title / Large", 22, "Semi Bold", 130],
  ["Title / Page", 20, "Semi Bold", 132],
  ["Heading / Section", 13, "Semi Bold", 140],
  ["Body", 13, "Regular", 150],
  ["Body / Medium", 13, "Medium", 150],
  ["Callout", 12, "Regular", 145],
  ["Subheadline", 11, "Regular", 140],
  ["Caption", 10, "Regular", 135],
  ["Caption / Medium", 10, "Medium", 135],
  // 字幕正文是「用户可调字号的内容」，不是界面层级：它的字号由「字幕字号」设置驱动，
  // 所以它有自己的两档样式（稿 20 / 26 → 实现 .title / .largeTitle）。
  ["Caption Band / 标准", 20, "Regular", 145],
  ["Caption Band / 大字", 26, "Medium", 130]
];

// --- Registries populated at build time --------------------------------------
let V = {};            // colour variables by token name
let N = {};            // number variables by token name
let TS = {};           // text styles by definition name
let P = {};            // pages by name
let VALUE_HEX = {};    // literal fallback colour per variable id
const BIND_ERRORS = []; // paint-binding failures, surfaced in the run report
const EXPORT_ERRORS = []; // export-setting failures, surfaced in the run report
let DARK_COLLECTION_ID = null; // set when dark is delivered as a second collection

// --- Small utilities ---------------------------------------------------------
function hexToRgb(hex) {
  const h = hex.replace("#", "");
  return {
    r: parseInt(h.slice(0, 2), 16) / 255,
    g: parseInt(h.slice(2, 4), 16) / 255,
    b: parseInt(h.slice(4, 6), 16) / 255
  };
}

function rgbToHex(c) {
  function part(x) {
    return ("0" + Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16)).slice(-2);
  }
  return "#" + part(c.r) + part(c.g) + part(c.b);
}

// Node.setBoundVariable() covers scalar fields (cornerRadius, width, …) but not
// paint fields. Binding a fill/stroke colour goes through
// figma.variables.setBoundVariableForPaint(), which returns a new paint that
// must be written back to the node. Using the wrong call silently left every
// paint at its literal placeholder colour.
function bindPaint(node, field, variable) {
  if (!variable) return node;
  const existing = node[field];
  const first = existing && existing.length ? existing[0] : null;
  const literal = VALUE_HEX[variable.id] ||
    (first && first.color ? rgbToHex(first.color) : "#808080");
  const paint = {
    type: "SOLID",
    color: hexToRgb(literal),
    opacity: first && first.opacity != null ? first.opacity : 1
  };
  try {
    if (typeof figma.variables.setBoundVariableForPaint === "function") {
      node[field] = [figma.variables.setBoundVariableForPaint(paint, "color", variable)];
    } else {
      node[field] = [paint];
      BIND_ERRORS.push("setBoundVariableForPaint unavailable; " + field + " left literal");
    }
  } catch (e) {
    node[field] = [paint];
    BIND_ERRORS.push(field + " -> " + (e && e.message ? e.message : String(e)));
  }
  return node;
}

function paintVarId(node, field) {
  const paints = node[field];
  if (paints && paints.length === 1 && paints[0].boundVariables && paints[0].boundVariables.color) {
    return paints[0].boundVariables.color.id;
  }
  const bound = node.boundVariables && node.boundVariables[field];
  if (bound && bound.length === 1) return bound[0].id;
  return null;
}

function bindFill(node, variable) {
  return bindPaint(node, "fills", variable);
}

function bindStroke(node, variable, weight) {
  node.strokeWeight = weight == null ? 1 : weight;
  node.strokeAlign = "INSIDE";
  return bindPaint(node, "strokes", variable);
}

function bindNum(node, field, variable) {
  try { node.setBoundVariable(field, variable); } catch (e) {}
  return node;
}

function frame(name, o) {
  o = o || {};
  const f = figma.createFrame();
  f.name = name;
  f.fills = [];
  f.clipsContent = o.clip === true;
  if (o.layout) {
    f.layoutMode = o.layout;
    f.itemSpacing = o.gap == null ? 0 : o.gap;
    const pad = o.pad == null ? 0 : o.pad;
    f.paddingLeft = o.padX == null ? pad : o.padX;
    f.paddingRight = o.padX == null ? pad : o.padX;
    f.paddingTop = o.padY == null ? pad : o.padY;
    f.paddingBottom = o.padY == null ? pad : o.padY;
    f.primaryAxisAlignItems = o.justify || "MIN";
    f.counterAxisAlignItems = o.align || "MIN";
    if (o.wrap) f.layoutWrap = "WRAP";
  }
  if (o.fill) bindFill(f, o.fill);
  if (o.stroke) bindStroke(f, o.stroke, o.strokeWeight);
  if (o.radius != null) {
    f.cornerRadius = o.radius;
    if (o.radiusVar) bindNum(f, "cornerRadius", o.radiusVar);
  }
  if (o.w != null) f.resize(o.w, o.h == null ? 40 : o.h);
  if (o.layout) {
    f.primaryAxisSizingMode = o.w == null ? "AUTO" : "FIXED";
    f.counterAxisSizingMode = o.h == null ? "AUTO" : "FIXED";
  }
  return f;
}

// Figma rejects layoutGrow / layoutAlign on a node whose parent is not an
// auto-layout frame, so layout intent is recorded first and applied right
// after the node is appended.
const PENDING_LAYOUT = new WeakMap();

// resize() alone does not stick on an auto-layout frame: as long as the axis
// stays AUTO (hug contents) the next layout pass overwrites the value. Anything
// that is meant to be an explicit size has to switch that axis to FIXED first.
function size(node, w, h) {
  node.resize(w == null ? node.width : w, h == null ? node.height : h);
  if (node.type === "FRAME" && node.layoutMode && node.layoutMode !== "NONE") {
    if (w != null) {
      if (node.layoutMode === "HORIZONTAL") node.primaryAxisSizingMode = "FIXED";
      else node.counterAxisSizingMode = "FIXED";
    }
    if (h != null) {
      if (node.layoutMode === "HORIZONTAL") node.counterAxisSizingMode = "FIXED";
      else node.primaryAxisSizingMode = "FIXED";
    }
  }
  return node;
}

function add(parent, node) {
  parent.appendChild(node);
  // Every canvas frame carries its own hand-off settings, so Figma's Export
  // panel writes the whole set without a dialog trip per file: 4x PNG for the
  // pixel checks and SVG as the vector ceiling (rasterise it at any DPI later).
  if (parent.type === "PAGE" && node.type === "FRAME") setCanvasExportSettings(node);
  return applyLayout(node);
}

function setCanvasExportSettings(node) {
  try {
    // SVG carries no `constraint`: it is vector, Figma rejects a scale on it and
    // a rejected entry fails the whole array — which leaves the frame with no
    // export settings at all and "0 of 0 selected" in the export dialog.
    node.exportSettings = [
      { format: "PNG", constraint: { type: "SCALE", value: SCREEN_EXPORT_SCALE } },
      // svgOutlineText defaults to true, and Figma then converts every run to
      // paths: the PNG looks right, the SVG looks right, and the copy is gone —
      // an SVG that no tool can search. Keep the text as text (实测 2026-09-17：
      // 上一批 26 块画板导出后 0 个 SVG 含 <text>)。
      { format: "SVG", svgOutlineText: false }
    ];
  } catch (e) {
    EXPORT_ERRORS.push(node.name + ": " + (e && e.message ? e.message : String(e)));
  }
}

// Figma rejects layoutGrow / layoutAlign while the node has no auto-layout
// parent, so the intent is recorded first and applied here. Callers that set the
// intent *after* appending (add(d, editor) followed by grow(editor)) go through
// the same path instead of silently keeping the node at its hugged size.
function applyLayout(node) {
  const parent = node.parent;
  const pending = PENDING_LAYOUT.get(node);
  if (!pending || !parent || !parent.layoutMode || parent.layoutMode === "NONE") return node;
  try {
    const ownMode = node.type === "FRAME" && node.layoutMode && node.layoutMode !== "NONE"
      ? node.layoutMode
      : null;
    if (pending.layoutGrow != null) {
      node.layoutGrow = pending.layoutGrow;
      // Filling the parent's main axis only works if the child is FIXED on the
      // matching axis. For a child whose layout axis differs from the parent's,
      // that axis is the child's counter axis.
      if (ownMode) {
        if (ownMode === parent.layoutMode) node.primaryAxisSizingMode = "FIXED";
        else node.counterAxisSizingMode = "FIXED";
      }
    }
    if (pending.layoutAlign) {
      node.layoutAlign = pending.layoutAlign;
      if (ownMode && pending.layoutAlign === "STRETCH") {
        if (ownMode === parent.layoutMode) node.counterAxisSizingMode = "FIXED";
        else node.primaryAxisSizingMode = "FIXED";
      }
    }
  } catch (e) {}
  return node;
}

function stretch(node) {
  const p = PENDING_LAYOUT.get(node) || {};
  p.layoutAlign = "STRETCH";
  PENDING_LAYOUT.set(node, p);
  return node.parent ? applyLayout(node) : node;
}

function grow(node, value) {
  const p = PENDING_LAYOUT.get(node) || {};
  p.layoutGrow = value == null ? 1 : value;
  PENDING_LAYOUT.set(node, p);
  return node.parent ? applyLayout(node) : node;
}

function text(name, chars, styleName, colorVar, o) {
  o = o || {};
  const t = figma.createText();
  t.name = name;
  const st = TS[styleName];
  const def = TEXT_STYLE_DEFS.find(function (d) { return d[0] === styleName; });
  // Apply the style before the characters. Assigning characters first and the
  // style afterwards leaves the node measured against the previous font, and
  // every caller that reads .width straight after building a row (buttons,
  // table cells, pills) inherits that stale, too-small number and clips its own
  // label.
  if (st) {
    t.textStyleId = st.id;
  } else {
    t.fontName = { family: FONT_FAMILY, style: def ? def[2] : "Regular" };
    t.fontSize = def ? def[1] : 13;
    t.lineHeight = { unit: "PERCENT", value: def ? def[3] : 150 };
  }
  t.characters = chars;
  if (colorVar) bindFill(t, colorVar);
  applyCjkFont(t, def ? def[2] : "Regular");
  if (o.w != null) {
    t.textAutoResize = "HEIGHT";
    size(t, o.w, t.height);
  }
  if (o.align) t.textAlignHorizontal = o.align;
  return t;
}

function icon(parent, name, px, colorVar) {
  const svg = ICONS[name];
  if (!svg) return null;
  const sized = svg
    .replace('width="24"', 'width="' + px + '"')
    .replace('height="24"', 'height="' + px + '"');
  const node = figma.createNodeFromSvg(sized);
  node.name = "icon/" + name;
  recolor(node, colorVar);
  return add(parent, node);
}

function recolor(node, colorVar) {
  if (node.type === "VECTOR" || node.type === "ELLIPSE" || node.type === "RECTANGLE" ||
      node.type === "LINE" || node.type === "POLYGON" || node.type === "STAR") {
    if (node.strokes && node.strokes.length) bindStroke(node, colorVar, node.strokeWeight);
    if (node.fills && node.fills.length) bindFill(node, colorVar);
  }
  if ("children" in node) {
    node.children.forEach(function (c) { recolor(c, colorVar); });
  }
}

function dot(parent, diameter, colorVar) {
  const e = figma.createEllipse();
  e.name = "dot";
  e.resize(diameter, diameter);
  bindFill(e, colorVar);
  return add(parent, e);
}

function rect(parent, name, w, h, colorVar, radius) {
  const r = figma.createRectangle();
  r.name = name;
  size(r, w, h);
  bindFill(r, colorVar);
  if (radius != null) r.cornerRadius = radius;
  return add(parent, r);
}

function spacer(parent, grow) {
  const s = figma.createFrame();
  s.name = "spacer";
  s.fills = [];
  size(s, 1, 1);
  return add(parent, stretch(setGrow(s, grow)));
}

function setGrow(node, value) {
  return grow(node, value);
}

function waveform(parent, bars, colorVar, gap, maxHeight) {
  const g = gap == null ? 2 : gap;
  const box = frame("waveform", { layout: "HORIZONTAL", gap: g, align: "CENTER" });
  bars.forEach(function (h) {
    const b = figma.createRectangle();
    b.name = "bar";
    size(b, 2, h);
    b.cornerRadius = 1;
    b.fills = [];
    bindFill(b, colorVar);
    box.appendChild(b);
  });
  return add(parent, box);
}

// =============================================================================
// Build steps
// =============================================================================

async function loadFonts() {
  for (const style of FONT_STYLES) {
    await figma.loadFontAsync({ family: FONT_FAMILY, style: style });
  }
}

async function loadCjkFont() {
  let available = [];
  try {
    available = await figma.listAvailableFontsAsync();
  } catch (e) {
    return;
  }
  for (const family of CJK_FAMILIES) {
    const styles = available
      .filter(function (f) { return f.fontName.family === family; })
      .map(function (f) { return f.fontName.style; });
    const wanted = CJK_STYLE_ORDER.filter(function (s) { return styles.indexOf(s) >= 0; });
    if (!wanted.length) continue;
    for (const style of wanted) {
      await figma.loadFontAsync({ family: family, style: style });
    }
    CJK_FONT = { family: family, styles: wanted };
    return;
  }
}

// Full-width forms, CJK ideographs and the CJK punctuation blocks: the ranges
// Inter cannot draw, and the only places a second family is written.
function isWideGlyph(code) {
  return (code >= 0x2e80 && code <= 0x9fff) || (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0xfe30 && code <= 0xfe4f) || (code >= 0xff00 && code <= 0xffef) ||
    (code >= 0x3000 && code <= 0x303f);
}

function cjkStyleFor(weight) {
  const order = {
    "Bold": ["Bold", "Semibold", "Medium", "Regular"],
    "Semi Bold": ["Semibold", "Medium", "Bold", "Regular"],
    "Medium": ["Medium", "Semibold", "Regular"],
    "Regular": ["Regular", "W3", "Medium"]
  }[weight] || ["Regular"];
  for (const style of order) {
    if (CJK_FONT.styles.indexOf(style) >= 0) return style;
  }
  return CJK_FONT.styles[0];
}

function applyCjkFont(node, weight) {
  if (!CJK_FONT) return;
  const style = cjkStyleFor(weight);
  const chars = node.characters;
  let start = -1;
  for (let i = 0; i <= chars.length; i++) {
    const wide = i < chars.length && isWideGlyph(chars.charCodeAt(i));
    if (wide && start < 0) start = i;
    if (!wide && start >= 0) {
      try {
        node.setRangeFontName(start, i, { family: CJK_FONT.family, style: style });
      } catch (e) {}
      start = -1;
    }
  }
}

function ensureCollection(name) {
  const found = figma.variables.getLocalVariableCollections().find(function (c) {
    return c.name === name;
  });
  return found || figma.variables.createVariableCollection(name);
}

function ensureVariable(collection, name, type) {
  const found = figma.variables.getLocalVariables(type).find(function (v) {
    return v.name === name && v.variableCollectionId === collection.id;
  });
  return found || figma.variables.createVariable(name, collection, type);
}

async function buildPages() {
  Object.keys(PAGE_RENAMES).forEach(function (from) {
    const to = PAGE_RENAMES[from];
    const stale = figma.root.children.find(function (p) { return p.name === from; });
    const taken = figma.root.children.find(function (p) { return p.name === to; });
    if (stale && !taken) stale.name = to;
  });
  // Re-runs reuse pages in place, and a page left over from an earlier revision
  // is adopted by renaming rather than asked for as a new one: on Starter the
  // file is capped at three pages, so `createPage()` is the last resort, never
  // the first move.
  const owned = [];
  REAL_PAGES.forEach(function (name) {
    let page = figma.root.children.find(function (p) {
      return p.name === name && owned.indexOf(p) === -1;
    });
    if (!page) {
      const spare = figma.root.children.filter(function (p) {
        return owned.indexOf(p) === -1 && REAL_PAGES.indexOf(p.name) === -1;
      }).sort(function (a, b) { return a.children.length - b.children.length; })[0];
      if (spare) {
        page = spare;
        page.name = name;
      } else {
        page = figma.createPage();
        page.name = name;
      }
    }
    owned.push(page);
  });
  // The current page cannot be removed, so step off the leftovers first.
  await gotoPage(owned[0]);
  figma.root.children.slice().forEach(function (p) {
    if (owned.indexOf(p) === -1) {
      // A page that cannot be removed (still referenced, or the file's last
      // page) is emptied instead, so it can never leak stale frames into the
      // audit or eat a page slot on the next run.
      try { p.remove(); } catch (e) {
        try { p.children.slice().forEach(function (child) { child.remove(); }); } catch (e2) {}
      }
    }
  });
  owned.forEach(function (page) {
    page.name = REAL_PAGES[owned.indexOf(page)];
    page.children.slice().forEach(function (child) { child.remove(); });
  });
  PAGE_LAYOUT.forEach(function (spec) {
    spec.groups.forEach(function (logical) {
      P[logical] = owned[REAL_PAGES.indexOf(spec.page)];
    });
  });
  owned.forEach(function (page, i) {
    try { figma.root.insertChild(i, page); } catch (e) {}
  });
}

// Tiles the groups that share a real page side by side, top-aligned, so two
// real pages can carry the seven logical ones without overlapping.
function tileGroups(groupNodes) {
  PAGE_LAYOUT.forEach(function (spec) {
    let cursorX = 0;
    spec.groups.forEach(function (logical) {
      const nodes = (groupNodes[logical] || []).filter(function (n) {
        return !n.removed && n.parent;
      });
      if (!nodes.length) return;
      let minX = Infinity;
      let maxX = -Infinity;
      let minY = Infinity;
      nodes.forEach(function (n) {
        minX = Math.min(minX, n.x);
        maxX = Math.max(maxX, n.x + n.width);
        minY = Math.min(minY, n.y);
      });
      const dx = cursorX - minX;
      const dy = -minY;
      if (dx !== 0 || dy !== 0) {
        nodes.forEach(function (n) { n.x += dx; n.y += dy; });
      }
      cursorX += (maxX - minX) + GROUP_GAP;
    });
  });
}

// What a top-level frame may be called on a given real page. The stray check
// needs this because several logical groups now share a page.
function allowedFrameName(realPageName) {
  const spec = PAGE_LAYOUT.find(function (s) { return s.page === realPageName; });
  const exact = [];
  let screens = false;
  (spec ? spec.groups : []).forEach(function (logical) {
    if (SCREEN_GROUPS.indexOf(logical) >= 0) screens = true;
    const declared = CANVAS_NAMES[logical];
    if (!declared) return;
    // A logical group may own more than one board (the overlay group does), so the
    // entry is either a name or a list of names.
    if (Array.isArray(declared)) exact.push.apply(exact, declared);
    else exact.push(declared);
  });
  return function (name) {
    // Dark clones carry a " · Dark" suffix; the suffix is not part of the name the
    // kit declares, so it is stripped before the check rather than added to every
    // entry of every group.
    const bare = name.replace(/ · Dark$/, "");
    return (screens && bare.indexOf("▸ ") === 0) || exact.indexOf(bare) >= 0;
  };
}

function buildVariables() {
  let modeError = null;
  const collection = ensureCollection("SpeechRail");
  const lightMode = collection.modes[0].modeId;
  try { if (collection.modes[0].name !== "Light") collection.renameMode(lightMode, "Light"); } catch (e) {}
  let darkMode = null;
  const namedDark = collection.modes.find(function (m) { return m.name === "Dark"; });
  if (namedDark) {
    darkMode = namedDark.modeId;
  } else if (collection.modes.length > 1) {
    darkMode = collection.modes[1].modeId;
    try { collection.renameMode(darkMode, "Dark"); } catch (e) {}
  } else {
    try {
      darkMode = collection.addMode("Dark");
    } catch (e) {
      darkMode = null;
      modeError = e && e.message ? e.message : String(e);
    }
  }
  COLOR_TOKENS.forEach(function (t) {
    const v = ensureVariable(collection, t[0], "COLOR");
    v.setValueForMode(lightMode, hexToRgb(t[1]));
    if (darkMode) v.setValueForMode(darkMode, hexToRgb(t[2]));
    V[t[0]] = v;
    VALUE_HEX[v.id] = t[1];
  });
  if (!darkMode) {
    const darkCol = ensureCollection("SpeechRail (Dark reference)");
    const darkModeId = darkCol.modes[0].modeId;
    try { darkCol.renameMode(darkModeId, "Dark"); } catch (e) {}
    DARK_COLLECTION_ID = darkCol.id;
    COLOR_TOKENS.forEach(function (t) {
      const v = ensureVariable(darkCol, t[0], "COLOR");
      v.setValueForMode(darkModeId, hexToRgb(t[2]));
      V["dark/" + t[0]] = v;
      VALUE_HEX[v.id] = t[2];
    });
  }

  NUMBER_TOKENS.forEach(function (t) {
    const v = ensureVariable(collection, t[0], "FLOAT");
    v.setValueForMode(lightMode, t[1]);
    if (darkMode) v.setValueForMode(darkMode, t[1]);
    N[t[0]] = v;
  });
  return {
    collection: collection,
    darkModeId: darkMode,
    modeError: modeError,
    modes: collection.modes.map(function (m) { return m.name; })
  };
}

function buildTextStyles() {
  TEXT_STYLE_DEFS.forEach(function (d) {
    const s = figma.getLocalTextStyles().find(function (x) { return x.name === d[0]; }) ||
      figma.createTextStyle();
    s.name = d[0];
    s.fontName = { family: FONT_FAMILY, style: d[2] };
    s.fontSize = d[1];
    s.lineHeight = { unit: "PERCENT", value: d[3] };
    TS[d[0]] = s;
  });
}

function note(x, y, w, lines) {
  const wrap = frame("note", { layout: "VERTICAL", gap: 4 });
  lines.forEach(function (l) {
    add(wrap, text("line", l, "Body", V["text/secondary"], { w: w }));
  });
  size(wrap, w, wrap.height);
  wrap.x = x;
  wrap.y = y;
  return wrap;
}

function buildFoundations() {
  const page = P["01 Foundations"];
  const canvas = frame("Foundations", { layout: "VERTICAL", gap: 48, pad: 64, fill: V["surface/content"] });
  add(page, canvas);
  size(canvas, 1600, 2000);
  canvas.x = 0;
  canvas.y = 0;

  add(canvas, text("h1", "SpeechRail · Foundations", "Title / Large", V["text/primary"]));
  add(canvas, text("lead",
    "macOS 26 原生重构：品牌只负责强调色、字体节奏与一处关键动效；材质、玻璃、层级与圆角交还给系统。" +
    "颜色与数值以 Variable 形式发布，Light / Dark 两个模式并存。",
    "Body", V["text/secondary"], { w: 900 }));

  // --- Colour ---------------------------------------------------------------
  const colourBlock = frame("block/colour", { layout: "VERTICAL", gap: 16 });
  add(colourBlock, text("t", "Colour", "Title / Page", V["text/primary"]));
  add(colourBlock, text("d",
    "两个品牌色（钢轨青强调、真空管琥珀语义）+ 系统语义色。状态永远由「颜色 + 图标 + 文字」共同表达。",
    "Callout", V["text/secondary"], { w: 900 }));

  const swatchRows = frame("swatches", { layout: "VERTICAL", gap: 8 });
  COLOR_TOKENS.forEach(function (t) {
    const row = frame("row", { layout: "HORIZONTAL", gap: 16, align: "CENTER" });
    const chip = rect(row, "chip", 56, 36, V[t[0]], 8);
    const meta = frame("meta", { layout: "VERTICAL", gap: 2 });
    add(meta, text("name", t[0], "Body / Medium", V["text/primary"]));
    add(meta, text("value", t[1] + "  ·  " + t[2], "Caption", V["text/tertiary"]));
    add(row, meta);
    size(row, 420, 40);
    add(swatchRows, row);
  });
  add(colourBlock, swatchRows);
  add(canvas, colourBlock);

  // --- Type -----------------------------------------------------------------
  const typeBlock = frame("block/type", { layout: "VERTICAL", gap: 16 });
  add(typeBlock, text("t", "Typography", "Title / Page", V["text/primary"]));
  add(typeBlock, text("d",
    "只用系统文本样式层级。数字统一 tabular figures，避免刷新时跳动。生产环境使用 SF Pro；本文件用 Inter 表达同一层级关系。",
    "Callout", V["text/secondary"], { w: 900 }));
  TEXT_STYLE_DEFS.forEach(function (d) {
    const row = frame("row", { layout: "HORIZONTAL", gap: 16, align: "CENTER" });
    add(row, text("sample", "声音在这条钢轨上流过", d[0], V["text/primary"]));
    spacer(row);
    add(row, text("spec", d[0] + "  ·  " + d[1] + "pt  ·  " + d[2], "Caption", V["text/tertiary"]));
    size(row, 900, row.height);
    add(typeBlock, row);
  });
  add(canvas, typeBlock);

  // --- Spacing & radius -----------------------------------------------------
  const spaceBlock = frame("block/spacing", { layout: "VERTICAL", gap: 16 });
  add(spaceBlock, text("t", "Spacing, radius & control sizes", "Title / Page", V["text/primary"]));
  add(spaceBlock, text("d",
    "4pt 基准节奏。半径以同心几何为准：容器 12、卡片 10、控件与字段 8；命中区不小于 44pt。",
    "Callout", V["text/secondary"], { w: 900 }));

  const spaceRow = frame("spaceScale", { layout: "HORIZONTAL", gap: 16, align: "MAX" });
  NUMBER_TOKENS.filter(function (t) { return t[0].indexOf("space/") === 0; }).forEach(function (t) {
    const cell = frame("cell", { layout: "VERTICAL", gap: 6, align: "CENTER" });
    const bar = rect(cell, "bar", Math.max(2, t[1]), Math.min(48, Math.max(2, t[1])), V["accent/rail"], 1);
    add(cell, text("label", String(t[1]), "Caption / Medium", V["text/tertiary"]));
    add(spaceRow, cell);
  });
  add(spaceBlock, spaceRow);

  const radiusRow = frame("radiusScale", { layout: "HORIZONTAL", gap: 20, align: "CENTER" });
  [[12, "container"], [10, "tile"], [8, "control / field"]].forEach(function (r) {
    const cell = frame("cell", { layout: "VERTICAL", gap: 8, align: "CENTER" });
    const box = rect(cell, "box", 84, 60, V["surface/panel"], r[0]);
    bindStroke(box, V["border/separator"], 1);
    add(cell, text("label", r[0] + " · " + r[1], "Caption", V["text/tertiary"]));
    add(radiusRow, cell);
  });
  add(spaceBlock, radiusRow);
  add(canvas, spaceBlock);

  // --- Icons ----------------------------------------------------------------
  const iconBlock = frame("block/icons", { layout: "VERTICAL", gap: 16 });
  add(iconBlock, text("t", "Iconography", "Title / Page", V["text/primary"]));
  add(iconBlock, text("d", "SF Symbols 语义映射；导航与工具栏使用 16pt 单色。", "Callout", V["text/secondary"], { w: 900 }));
  const iconRow = frame("icons", { layout: "HORIZONTAL", gap: 18, align: "CENTER", wrap: true });
  ["audio-lines", "sparkles", "library", "folder-open", "server", "activity", "package",
   "stethoscope", "search", "plus", "check", "triangle-alert", "play", "pause",
   "download", "refresh-cw", "trash-2", "pencil", "info", "ellipsis", "audio-waveform"
  ].forEach(function (n) {
    const cell = frame("iconCell", { layout: "VERTICAL", gap: 6, align: "CENTER" });
    icon(cell, n, 18, V["text/secondary"]);
    add(cell, text("k", n, "Caption", V["text/tertiary"]));
    add(iconRow, cell);
  });
  size(iconRow, 1100, iconRow.height);
  add(iconBlock, iconRow);
  add(canvas, iconBlock);

  size(canvas, 1600, canvas.height);
  canvas.primaryAxisSizingMode = "AUTO";
  return canvas;
}

// =============================================================================
// Component library
// =============================================================================

const PILL_TONES = {
  Ready: { icon: "check", fill: "surface/readyTint", ink: "status/ready" },
  Attention: { icon: "triangle-alert", fill: "surface/attentionTint", ink: "status/attention" },
  Critical: { icon: "triangle-alert", fill: "surface/criticalTint", ink: "status/critical" },
  Info: { icon: "info", fill: "surface/infoTint", ink: "status/info" },
  Off: { icon: null, fill: null, ink: "text/secondary" }
};

function comp(name, o) {
  o = o || {};
  const c = figma.createComponent();
  c.name = name;
  c.fills = [];
  c.clipsContent = false;
  if (o.layout) {
    c.layoutMode = o.layout;
    c.itemSpacing = o.gap == null ? 0 : o.gap;
    const pad = o.pad == null ? 0 : o.pad;
    c.paddingLeft = o.padX == null ? pad : o.padX;
    c.paddingRight = o.padX == null ? pad : o.padX;
    c.paddingTop = o.padY == null ? pad : o.padY;
    c.paddingBottom = o.padY == null ? pad : o.padY;
    c.primaryAxisAlignItems = o.justify || "MIN";
    c.counterAxisAlignItems = o.align || "MIN";
    // A literal size belongs to the axis it names, and a vertical frame's width is
    // its counter axis. Reading `w` as the primary axis left every vertical variant
    // on a fixed 40px height: the states below the first row spilled out of the
    // component and were clipped away from the export. Both axes are written every
    // time, because an untouched axis keeps the 100x100 a fresh component starts
    // with and the variant stops hugging its own content.
    const vertical = c.layoutMode === "VERTICAL";
    c.primaryAxisSizingMode = (vertical ? o.h : o.w) == null ? "AUTO" : "FIXED";
    c.counterAxisSizingMode = (vertical ? o.w : o.h) == null ? "AUTO" : "FIXED";
  }
  if (o.fill) bindFill(c, o.fill);
  if (o.stroke) bindStroke(c, o.stroke, o.strokeWeight);
  if (o.radius != null) c.cornerRadius = o.radius;
  if (o.w != null || o.h != null) {
    c.resize(o.w == null ? c.width : o.w, o.h == null ? c.height : o.h);
  }
  return c;
}

// The board frame owns its component sets. A variant set left on the page renders
// in the same place but sits outside the board's subtree, so exporting the board
// hands off only its title and lead paragraph — the component grid never reaches
// the PNG or SVG. Absolute positioning keeps the hand-placed grid while making the
// set a child of the board.
// `combineAsVariants` only reparents the components: every variant keeps the
// (0, 0) corner it was created at, so all states of a set land on the same pixel
// and a multi-state set renders its labels on top of each other. The variants are
// therefore laid out here, wrapping inside SET_W, and `gridCursor` walks each
// artboard column downwards so a set that outgrew its declared slot pushes the
// next one down instead of covering it.
const SET_W = 704;
const SET_GAP = 24;
const SET_ROW_GAP = 48;
const gridCursor = {};

function componentSet(board, setName, defs, x, y) {
  const nodes = defs.map(function (d) {
    const c = comp(setName + "/" + d.prop, d.o || {});
    d.build(c);
    return c;
  });
  const set = figma.combineAsVariants(nodes, board);
  set.name = setName;
  if (set.layoutMode !== "NONE") {
    try { set.layoutMode = "NONE"; } catch (e) {}
  }
  if (set.layoutMode === "NONE") {
    let cx = 0, cy = 0, rowH = 0, rowW = 0, maxW = 0;
    nodes.forEach(function (n) {
      if (cx > 0 && cx + n.width > SET_W) {
        cy += rowH + SET_GAP;
        cx = 0;
        rowH = 0;
        rowW = 0;
      }
      n.x = cx;
      n.y = cy;
      cx += n.width + SET_GAP;
      rowW = cx - SET_GAP;
      rowH = Math.max(rowH, n.height);
      maxW = Math.max(maxW, rowW);
    });
    set.resize(Math.max(maxW, 1), Math.max(cy + rowH, 1));
  } else {
    // A release that refuses to drop a component set's auto-layout still gets the
    // same width contract, and Figma's engine places the variants in that box.
    set.itemSpacing = SET_GAP;
    set.counterAxisSpacing = SET_GAP;
    set.layoutWrap = "WRAP";
    set.counterAxisSizingMode = "AUTO";
    set.primaryAxisSizingMode = "FIXED";
    set.resize(SET_W, set.height);
  }
  const top = Math.max(y, gridCursor[x] == null ? 0 : gridCursor[x]);
  set.layoutPositioning = "ABSOLUTE";
  set.x = x;
  set.y = top;
  // Absolute children are measured from the frame's corner. A release that
  // measures from the padded content box instead would push the whole grid one
  // padding-step right and down; the read-back absorbs that without a second run,
  // and ignores anything else so a stale rectangle can never move the grid.
  const box = set.absoluteBoundingBox;
  const origin = board.absoluteBoundingBox;
  if (box && origin) {
    const offX = Math.round(box.x - origin.x - x);
    const offY = Math.round(box.y - origin.y - top);
    if (offX === board.paddingLeft && offY === board.paddingTop) {
      set.x = x - offX;
      set.y = top - offY;
    }
  }
  gridCursor[x] = top + set.height + SET_ROW_GAP;
  return set;
}

// `side` must not be called `size`: it would shadow the size() helper below.
function iconButton(parent, name, side) {
  const b = frame("iconButton", { layout: "HORIZONTAL", align: "CENTER", justify: "CENTER", radius: 7 });
  b.resize(side, side);
  icon(b, name, 15, V["text/secondary"]);
  return add(parent, b);
}

function pill(parent, tone, label) {
  const t = PILL_TONES[tone];
  const p = frame("Status Pill", { layout: "HORIZONTAL", gap: 5, align: "CENTER", padX: 8, padY: 2, radius: 999 });
  if (t.fill) bindFill(p, V[t.fill]);
  if (t.icon) icon(p, t.icon, 12, V[t.ink]);
  add(p, text("label", label, "Caption / Medium", V[t.ink]));
  return add(parent, p);
}

function voiceBadge(parent, label) {
  const b = frame("badge", { layout: "HORIZONTAL", align: "CENTER", padX: 7, padY: 1, radius: 999 });
  bindFill(b, V["surface/voiceTint"]);
  add(b, text("label", label, "Caption", V["accent/voice"]));
  return add(parent, b);
}

function primaryButton(parent, label, iconName, width) {
  const b = frame("Button / Primary", {
    layout: "HORIZONTAL", gap: 7, align: "CENTER", justify: "CENTER", padX: 14, radius: 8, fill: V["accent/rail"]
  });
  if (iconName) icon(b, iconName, 15, V["text/onAccent"]);
  add(b, text("label", label, "Body / Medium", V["text/onAccent"]));
  // Size after the content exists: the hugged width is the real minimum, so a
  // requested width acts as a floor instead of clipping the label.
  size(b, Math.max(width == null ? 0 : width, Math.ceil(b.width)), 34);
  return add(parent, b);
}

function secondaryButton(parent, label, iconName) {
  const b = frame("Button / Secondary", {
    layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 11, radius: 8,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
  });
  if (iconName) icon(b, iconName, 15, V["text/primary"]);
  add(b, text("label", label, "Callout", V["text/primary"]));
  size(b, Math.ceil(b.width), 30);
  return add(parent, b);
}

function textField(parent, label, value, width, wrap) {
  const box = frame("Text Field", {
    layout: "VERTICAL", gap: 2, padX: 12, padY: 9,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1, radius: 8
  });
  if (label) {
    const lbl = text("fieldLabel", label, "Caption / Medium", V["text/secondary"]);
    add(parent, lbl);
  }
  const inner = width != null && wrap ? Math.max(40, width - 26) : null;
  add(box, text("value", value, "Body", V["text/tertiary"], inner ? { w: inner } : {}));
  size(box, width == null ? null : Math.max(width, Math.ceil(box.width)), null);
  return add(parent, box);
}

function buildComponents() {
  const page = P["02 Components"];
  Object.keys(gridCursor).forEach(function (k) { delete gridCursor[k]; });
  const canvas = frame("Components", { layout: "VERTICAL", gap: 40, pad: 64, fill: V["surface/content"] });
  add(page, canvas);
  size(canvas, 1600, 2400);
  canvas.x = 0;
  canvas.y = 0;

  add(canvas, text("h1", "SpeechRail · Components", "Title / Large", V["text/primary"]));
  add(canvas, text("lead",
    "所有交互组件都带 hover / focus / disabled 语义；颜色、圆角与间距绑定到 Variables，" +
    "因此切换 Light / Dark 模式时组件自动跟随。",
    "Body", V["text/secondary"], { w: 900 }));

  // 1. Status Pill -----------------------------------------------------------
  componentSet(canvas, "Status Pill", [
    { prop: "Tone=Ready", build: function (c) { pill(c, "Ready", "可用"); } },
    { prop: "Tone=Attention", build: function (c) { pill(c, "Attention", "需要处理"); } },
    { prop: "Tone=Critical", build: function (c) { pill(c, "Critical", "不可用"); } },
    { prop: "Tone=Info", build: function (c) { pill(c, "Info", "进行中"); } },
    { prop: "Tone=Off", build: function (c) { pill(c, "Off", "当前档位不支持"); } }
  ], 64, 320);

  // 2. Nav Item --------------------------------------------------------------
  componentSet(canvas, "Nav Item", [
    {
      prop: "State=Default",
      o: { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, w: 200, h: 30 },
      build: function (c) {
        c.cornerRadius = 7;
        icon(c, "audio-lines", 16, V["text/secondary"]);
        add(c, text("label", "配音台", "Body", V["text/primary"]));
      }
    },
    {
      prop: "State=Selected",
      o: { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, w: 200, h: 30, fill: V["surface/railTint"] },
      build: function (c) {
        c.cornerRadius = 7;
        icon(c, "audio-lines", 16, V["accent/rail"]);
        add(c, text("label", "配音台", "Body / Medium", V["text/primary"]));
      }
    }
  ], 64, 460);

  // 3. Buttons ---------------------------------------------------------------
  componentSet(canvas, "Button / Primary", [
    {
      prop: "State=Default",
      o: { layout: "HORIZONTAL", gap: 7, align: "CENTER", justify: "CENTER", padX: 14, w: 132, h: 34, fill: V["accent/rail"] },
      build: function (c) {
        c.cornerRadius = 8;
        icon(c, "play", 15, V["text/onAccent"]);
        add(c, text("label", "生成语音", "Body / Medium", V["text/onAccent"]));
      }
    },
    {
      prop: "State=Disabled",
      o: { layout: "HORIZONTAL", gap: 7, align: "CENTER", justify: "CENTER", padX: 14, w: 132, h: 34, fill: V["accent/rail"] },
      build: function (c) {
        c.cornerRadius = 8;
        c.opacity = 0.45;
        icon(c, "play", 15, V["text/onAccent"]);
        add(c, text("label", "生成语音", "Body / Medium", V["text/onAccent"]));
      }
    }
  ], 64, 570);

  componentSet(canvas, "Button / Secondary", [
    {
      prop: "State=Default",
      o: {
        layout: "HORIZONTAL", gap: 6, align: "CENTER", justify: "CENTER", padX: 11, w: 116, h: 30,
        fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
      },
      build: function (c) {
        c.cornerRadius = 8;
        icon(c, "download", 15, V["text/primary"]);
        add(c, text("label", "导出…", "Callout", V["text/primary"]));
      }
    },
    {
      prop: "State=Disabled",
      o: {
        layout: "HORIZONTAL", gap: 6, align: "CENTER", justify: "CENTER", padX: 11, w: 116, h: 30,
        fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
      },
      build: function (c) {
        c.cornerRadius = 8;
        c.opacity = 0.45;
        icon(c, "download", 15, V["text/primary"]);
        add(c, text("label", "导出…", "Callout", V["text/primary"]));
      }
    }
  ], 64, 680);

  // 4. Voice Chip ------------------------------------------------------------
  componentSet(canvas, "Voice Chip", [
    {
      prop: "State=Default",
      o: {
        layout: "HORIZONTAL", gap: 4, align: "CENTER", padX: 10, padY: 3, radius: 999,
        fill: V["surface/attentionTint"], stroke: V["accent/voice"], strokeWeight: 1
      },
      build: function (c) {
        icon(c, "plus", 13, V["accent/voice"]);
        add(c, text("label", "磁性胸腔", "Subheadline", V["accent/voice"]));
      }
    }
  ], 64, 790);

  // 5. Sidebar Status --------------------------------------------------------
  componentSet(canvas, "Sidebar Status", [
    {
      prop: "Tone=Ready",
      o: { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, padY: 7, w: 210 },
      build: function (c) {
        dot(c, 8, V["status/ready"]);
        add(c, text("label", "服务已就绪 · Quality", "Callout", V["text/secondary"]));
      }
    },
    {
      prop: "Tone=Attention",
      o: { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, padY: 7, w: 210 },
      build: function (c) {
        dot(c, 8, V["status/attention"]);
        add(c, text("label", "服务操作进行中", "Callout", V["text/secondary"]));
      }
    },
    {
      prop: "Tone=Critical",
      o: { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, padY: 7, w: 210 },
      build: function (c) {
        dot(c, 8, V["status/critical"]);
        add(c, text("label", "服务不可用", "Callout", V["text/secondary"]));
      }
    }
  ], 64, 890);

  // 6. Profile Card ----------------------------------------------------------
  componentSet(canvas, "Profile Card", [
    {
      prop: "State=Default",
      o: {
        layout: "VERTICAL", gap: 6, pad: 12, radius: 10,
        fill: V["surface/panel"], w: 220
      },
      build: function (c) {
        add(c, text("name", "Balanced · 分人和日常", "Body / Medium", V["text/primary"]));
        add(c, text("desc", "aligner-q8，可匿名分人", "Callout", V["text/secondary"], { w: 196 }));
      }
    },
    {
      prop: "State=Selected",
      o: {
        layout: "VERTICAL", gap: 6, pad: 12, radius: 10,
        fill: V["surface/panel"], stroke: V["accent/rail"], strokeWeight: 1.5, w: 220
      },
      build: function (c) {
        add(c, text("name", "Quality · 创作优先", "Body / Medium", V["text/primary"]));
        add(c, text("desc", "aligner-bf16，双 TTS lane", "Callout", V["text/secondary"], { w: 196 }));
      }
    }
  ], 64, 1010);

  // 7. Empty State -----------------------------------------------------------
  componentSet(canvas, "Empty State", [
    {
      prop: "Kind=NoData",
      o: { layout: "VERTICAL", gap: 8, pad: 32, align: "CENTER", w: 320 },
      build: function (c) {
        icon(c, "folder-open", 28, V["text/tertiary"]);
        add(c, text("title", "还没有作品", "Heading / Section", V["text/primary"]));
        add(c, text("body", "在配音台生成一段音频后，作品会保存在这里。", "Callout", V["text/secondary"], { w: 260, align: "CENTER" }));
      }
    },
    {
      prop: "Kind=NoResults",
      o: { layout: "VERTICAL", gap: 8, pad: 32, align: "CENTER", w: 320 },
      build: function (c) {
        icon(c, "search", 28, V["text/tertiary"]);
        add(c, text("title", "没有匹配结果", "Heading / Section", V["text/primary"]));
        add(c, text("body", "换一个关键词，或清空搜索条件。", "Callout", V["text/secondary"], { w: 260, align: "CENTER" }));
      }
    }
  ], 64, 1180);

  // 8. Result Bar ------------------------------------------------------------
  componentSet(canvas, "Result Bar", [
    {
      prop: "State=Success",
      o: {
        layout: "HORIZONTAL", gap: 12, align: "CENTER", pad: 12, radius: 10,
        fill: V["surface/railTint"], w: 720
      },
      build: function (c) {
        waveform(c, [5, 11, 16, 8, 14, 6, 12, 17, 9, 5, 13, 7], V["accent/voice"], 2);
        add(c, text("title", "星际航行 · 夜航主持   00:12", "Body / Medium", V["text/primary"]));
        spacer(c);
        secondaryButton(c, "播放", "play");
        secondaryButton(c, "导出…", "download");
      }
    },
    {
      prop: "State=Error",
      o: {
        layout: "HORIZONTAL", gap: 12, align: "CENTER", pad: 12, radius: 10,
        fill: V["surface/criticalTint"], w: 720
      },
      build: function (c) {
        icon(c, "triangle-alert", 18, V["status/critical"]);
        add(c, text("title", "生成未完成：服务端没有返回音频", "Body / Medium", V["text/primary"]));
        spacer(c);
        secondaryButton(c, "重试", "refresh-cw");
        secondaryButton(c, "查看诊断", "stethoscope");
      }
    }
  ], 64, 1400);

  // 9. List Row --------------------------------------------------------------
  componentSet(canvas, "List Row", [
    {
      prop: "Type=Voice",
      o: {
        layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 8, padY: 7, w: 560,
      },
      build: function (c) {
        const main = frame("main", { layout: "VERTICAL", gap: 1 });
        const head = frame("head", { layout: "HORIZONTAL", gap: 7, align: "CENTER" });
        add(head, text("name", "夜航主持", "Body / Medium", V["text/primary"]));
        voiceBadge(head, "系统");
        add(main, head);
        add(main, text("sub", "温暖、清晰、亲近", "Callout", V["text/secondary"]));
        main.layoutGrow = 1;
        add(c, main);
        iconButton(c, "play", 28);
      }
    },
    {
      prop: "Type=Work",
      o: {
        layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 8, padY: 7, w: 560,
      },
      build: function (c) {
        const main = frame("main", { layout: "VERTICAL", gap: 1 });
        add(main, text("name", "星际航行 · 夜航主持", "Body / Medium", V["text/primary"]));
        add(main, text("sub", "今天 12:04 · 夜航主持", "Callout", V["text/secondary"]));
        main.layoutGrow = 1;
        add(c, main);
        add(c, text("dur", "00:12", "Callout", V["text/secondary"]));
        iconButton(c, "play", 28);
        iconButton(c, "download", 28);
        iconButton(c, "ellipsis", 28);
      }
    }
  ], 820, 320);

  // 10. Candidate Tile -------------------------------------------------------
  componentSet(canvas, "Candidate Tile", [
    {
      prop: "State=Ready",
      o: {
        layout: "VERTICAL", gap: 9, pad: 12, radius: 10, w: 300,
        fill: V["surface/panel"]
      },
      build: function (c) {
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        add(head, text("slot", "候选 1", "Body / Medium", V["text/primary"]));
        pill(head, "Ready", "可试听");
        spacer(head);
        add(head, text("seed", "seed 101", "Caption", V["text/tertiary"]));
        // The spacer can only push the seed to the tile edge if the head itself
        // fills the card: hugging the row would leave the gap on the outside.
        add(c, stretch(head));
        waveform(c, [6, 13, 17, 9, 15, 7, 12, 16, 8, 11], V["accent/voice"], 2);
        const actions = frame("actions", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
        secondaryButton(actions, "试听", "play");
        primaryButton(actions, "保存为音色", null, 118);
        add(c, actions);
      }
    },
    {
      prop: "State=Failed",
      o: {
        layout: "VERTICAL", gap: 9, pad: 12, radius: 10, w: 300,
        fill: V["surface/panel"]
      },
      build: function (c) {
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        add(head, text("slot", "候选 4", "Body / Medium", V["text/primary"]));
        pill(head, "Attention", "生成失败");
        spacer(head);
        add(head, text("seed", "seed 404", "Caption", V["text/tertiary"]));
        add(c, stretch(head));
        add(c, text("msg", "服务端未返回预览音频，可单独重试这一组。", "Callout", V["text/secondary"], { w: 276 }));
        const actions = frame("actions", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
        secondaryButton(actions, "重试", "refresh-cw");
        add(c, actions);
      }
    }
  ], 820, 760);

  // 11. Text Field -----------------------------------------------------------
  componentSet(canvas, "Text Field", [
    {
      prop: "State=Default",
      o: {
        layout: "HORIZONTAL", align: "CENTER", padX: 12, w: 300, h: 60,
        fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
      },
      build: function (c) {
        c.cornerRadius = 8;
        add(c, text("value", "把你想要的声音描述写在这里…", "Body", V["text/tertiary"], { w: 276 }));
      }
    },
    {
      prop: "State=Focused",
      o: {
        layout: "HORIZONTAL", align: "CENTER", padX: 12, w: 300, h: 60,
        fill: V["surface/field"], stroke: V["accent/rail"], strokeWeight: 2
      },
      build: function (c) {
        c.cornerRadius = 8;
        add(c, text("value", "温暖、清晰、亲近，像一位深夜电台耐心的播客主持人。", "Body", V["text/primary"], { w: 276 }));
      }
    }
  ], 820, 1160);

  // 12. Prompt Option --------------------------------------------------------
  // 提词稿选项：选中态同时用底色与描边两处表示，不靠单一颜色区分（§9 无障碍）。
  componentSet(canvas, "Prompt Option", [
    {
      prop: "State=Default",
      o: {
        layout: "HORIZONTAL", gap: 4, align: "CENTER", padX: 10, padY: 4, radius: 999,
        fill: V["surface/content"], stroke: V["border/separator"], strokeWeight: 1
      },
      build: function (c) {
        add(c, text("label", "科技浪潮 · 现代叙述", "Subheadline", V["text/secondary"]));
      }
    },
    {
      prop: "State=Selected",
      o: {
        layout: "HORIZONTAL", gap: 4, align: "CENTER", padX: 10, padY: 4, radius: 999,
        fill: V["surface/railTint"], stroke: V["accent/rail"], strokeWeight: 1
      },
      build: function (c) {
        add(c, text("label", "盛唐气象 · 经典诗韵", "Subheadline", V["accent/rail"]));
      }
    }
  ], 64, 1260);

  // 13. Level Meter ----------------------------------------------------------
  // 录音电平：已经过去的片段用音色语义色，尚未到达的刻度用分隔色——同一行同时
  // 读得出「现在多响」和「离满还有多远」。
  componentSet(canvas, "Level Meter", [
    {
      prop: "State=Recording",
      o: { layout: "HORIZONTAL", gap: 3, align: "MAX", w: 320, h: 40 },
      build: function (c) {
        [10, 18, 28, 36, 22, 30, 38, 16, 24, 32, 20, 12, 8, 6, 6, 6].forEach(function (h, i) {
          rect(c, "level", 3, h, i < 12 ? V["accent/voice"] : V["border/separator"], 1.5);
        });
      }
    }
  ], 64, 1420);

  // 14. Doc Topic Row --------------------------------------------------------
  componentSet(canvas, "Doc Topic Row", [
    {
      prop: "State=Default",
      o: { layout: "VERTICAL", gap: 2, padX: 10, padY: 8, radius: 8, w: 248 },
      build: function (c) {
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        icon(head, "server", 15, V["text/secondary"]);
        add(head, text("title", "接口一览", "Body / Medium", V["text/primary"]));
        add(c, head);
        add(c, text("desc", "REST 与 WebSocket 的入口与用途", "Subheadline", V["text/secondary"], { w: 228 }));
      }
    },
    {
      prop: "State=Selected",
      o: { layout: "VERTICAL", gap: 2, padX: 10, padY: 8, radius: 8, w: 248, fill: V["surface/railTint"] },
      build: function (c) {
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        icon(head, "play", 15, V["accent/rail"]);
        add(head, text("title", "快速开始", "Body / Medium", V["text/primary"]));
        add(c, head);
        add(c, text("desc", "改 base_url 就能用的最小示例", "Subheadline", V["text/secondary"], { w: 228 }));
      }
    }
  ], 64, 1560);

  // 15. Code Block -----------------------------------------------------------
  componentSet(canvas, "Code Block", [
    {
      prop: "State=Default",
      o: {
        layout: "VERTICAL", gap: 8, padX: 14, padY: 12, radius: 8, w: 560,
        fill: V["surface/panel"], stroke: V["border/separator"], strokeWeight: 1
      },
      build: function (c) {
        const head = frame("codeHead", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        add(head, text("lang", "Python · OpenAI SDK", "Caption / Medium", V["text/tertiary"]));
        spacer(head);
        iconButton(head, "copy", 24);
        add(c, stretch(head));
        ["client = OpenAI(base_url=\"http://127.0.0.1:8201/v1\",",
          "                api_key=\"not-needed-for-loopback\")"].forEach(function (line) {
          add(c, text("line", line, "Callout", V["text/primary"], { w: 520 }));
        });
      }
    }
  ], 820, 1420);

  // 16. Session Status Bar --------------------------------------------------
  // 三个能力共用的第一块卡：点 + 阶段 + 主体 + 电平 + 计时。字号与高度都跟随内容，
  // 所以只固定宽度，让状态带在任何页面上都长成同一条。
  componentSet(canvas, "Session Status Bar", [
    {
      prop: "Mode=字幕",
      o: { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 14, padY: 10, w: 520 },
      build: function (c) {
        sessionDot(c, "ready");
        add(c, text("phase", "跟随中", "Body / Medium", V["text/primary"]));
        spacer(c);
        levelBars(c, 0.55, 12, 14);
        add(c, text("time", "00:08:12", "Body / Medium", V["text/primary"]));
      }
    },
    {
      prop: "Mode=会议",
      o: { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 14, padY: 10, w: 520 },
      build: function (c) {
        sessionDot(c, "attention");
        add(c, text("phase", "正在录音", "Body / Medium", V["text/primary"]));
        add(c, text("title", "周会 · 已标说话人", "Callout", V["text/secondary"]));
        spacer(c);
        levelBars(c, 0.55, 12, 14);
        add(c, text("time", "00:12:40", "Body / Medium", V["text/primary"]));
      }
    },
    {
      prop: "Mode=助手",
      o: { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 14, padY: 10, w: 520 },
      build: function (c) {
        sessionDot(c, "ready");
        add(c, text("phase", "正在说话", "Body / Medium", V["text/primary"]));
        add(c, text("title", "第 12 轮 · 一问一答（外放）", "Callout", V["text/secondary"]));
        spacer(c);
        levelBars(c, 0.35, 12, 14);
        add(c, text("time", "00:03:42", "Body / Medium", V["text/primary"]));
      }
    },
    {
      prop: "State=受阻",
      o: {
        layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 14, padY: 10, w: 520,
        fill: V["surface/attentionTint"], stroke: V["status/attention"], strokeWeight: 1
      },
      build: function (c) {
        c.cornerRadius = 12;
        icon(c, "triangle-alert", 16, V["status/attention"]);
        add(c, text("phase", "麦克风未授权", "Body / Medium", V["status/attention"]));
        spacer(c);
        add(c, text("hint", "打开系统设置", "Callout", V["status/attention"]));
      }
    }
  ], 64, 1700);

  // 17. Turn Row -------------------------------------------------------------
  // 对话行与转录行是同一条行：说话人 + （音色徽标 / 识别中）+ 时间 + 正文。
  componentSet(canvas, "Turn Row", [
    {
      prop: "Role=你",
      o: { layout: "VERTICAL", gap: 5, padX: 14, padY: 10, w: 420 },
      build: function (c) {
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        add(head, text("who", "你", "Body / Medium", V["text/primary"]));
        spacer(head);
        add(head, text("time", "14:02:11", "Callout", V["text/tertiary"]));
        iconButton(head, "play", 24);
        iconButton(head, "copy", 24);
        add(c, stretch(head));
        add(c, text("text", "今天这场分享的开头有点长，能不能压到三句话？", "Body",
          V["text/primary"], { w: 392 }));
      }
    },
    {
      prop: "Role=助手",
      o: { layout: "VERTICAL", gap: 5, padX: 14, padY: 10, w: 420 },
      build: function (c) {
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        add(head, text("who", "助手", "Body / Medium", V["accent/rail"]));
        voiceBadge(head, "夜航主持");
        spacer(head);
        add(head, text("time", "14:02:16", "Callout", V["text/tertiary"]));
        iconButton(head, "play", 24);
        add(c, stretch(head));
        add(c, text("text", "可以。三句话的版本是：我们做的是一个本机语音引擎……", "Body",
          V["text/primary"], { w: 392 }));
      }
    },
    {
      prop: "State=识别中",
      o: { layout: "VERTICAL", gap: 5, padX: 14, padY: 10, w: 420 },
      build: function (c) {
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        add(head, text("who", "你", "Body / Medium", V["text/primary"]));
        pill(head, "Info", "识别中");
        spacer(head);
        levelBars(head, 0.5, 10, 12);
        add(c, stretch(head));
        add(c, text("text", "那如果我想让它记住上一场会议的结论……", "Body",
          V["text/secondary"], { w: 392 }));
      }
    }
  ], 820, 1600);

  // 18. Caption Line ---------------------------------------------------------
  // 字幕正文的字号是三档设置的一部分，所以这一行用 Caption Band 样式，不用界面层级样式。
  componentSet(canvas, "Caption Line", [
    {
      prop: "State=定稿",
      o: { layout: "HORIZONTAL", gap: 10, align: "MIN", padX: 14, padY: 8, w: 560 },
      build: function (c) {
        speakerChip(c, "说话人 A");
        add(c, text("text", "先把实时字幕接进来，它只依赖语音识别。",
          "Caption Band / 标准", V["text/primary"], { w: 440 }));
      }
    },
    {
      prop: "State=星标",
      o: { layout: "HORIZONTAL", gap: 10, align: "MIN", padX: 14, padY: 8, w: 560 },
      build: function (c) {
        speakerChip(c, "说话人 B");
        add(c, text("text", "那字幕带的位置能不能记住？我习惯放在屏幕底部偏左。",
          "Caption Band / 标准", V["text/primary"], { w: 440 }));
        spacer(c);
        icon(c, "check", 14, V["accent/rail"]);
      }
    },
    {
      prop: "State=识别中",
      o: { layout: "HORIZONTAL", gap: 10, align: "MIN", padX: 14, padY: 8, w: 560 },
      build: function (c) {
        add(c, text("text", "回看的时候会不会被打断……", "Caption Band / 标准",
          V["text/secondary"], { w: 500 }));
      }
    }
  ], 64, 1900);

  // 19. Speaker Chip ---------------------------------------------------------
  // 说话人**可以**改名，正文**不可以**改写——这个区别要在控件上看得出来。
  componentSet(canvas, "Speaker Chip", [
    {
      prop: "State=默认",
      o: { layout: "HORIZONTAL", gap: 5, align: "CENTER", padX: 8, padY: 3, radius: 999,
        fill: V["surface/panel"] },
      build: function (c) {
        add(c, text("label", "说话人 A", "Caption", V["text/secondary"]));
      }
    },
    {
      prop: "State=已改名",
      o: { layout: "HORIZONTAL", gap: 5, align: "CENTER", padX: 8, padY: 3, radius: 999,
        fill: V["surface/voiceTint"] },
      build: function (c) {
        add(c, text("label", "张工", "Caption", V["accent/voice"]));
      }
    },
    {
      prop: "State=改名编辑中",
      o: { layout: "HORIZONTAL", gap: 5, align: "CENTER", padX: 8, padY: 3, radius: 6,
        fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1 },
      build: function (c) {
        add(c, text("label", "张工", "Caption", V["text/primary"]));
        icon(c, "pencil", 12, V["text/tertiary"]);
      }
    }
  ], 820, 1900);

  // 20. Meeting Row ----------------------------------------------------------
  componentSet(canvas, "Meeting Row", [
    {
      prop: "State=默认",
      o: { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 14, padY: 10, w: 400 },
      build: function (c) {
        const info = frame("info", { layout: "VERTICAL", gap: 3 });
        add(info, text("title", "产品评审", "Body / Medium", V["text/primary"]));
        add(info, text("sub", "9月16日 10:30 · 42 分钟 · 4 位说话人", "Callout",
          V["text/secondary"], { w: 300 }));
        add(c, grow(info));
      }
    },
    {
      prop: "State=录制中",
      o: { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 14, padY: 10, w: 400,
        fill: V["surface/railTint"] },
      build: function (c) {
        const info = frame("info", { layout: "VERTICAL", gap: 3 });
        const titleRow = frame("titleRow", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        add(titleRow, text("title", "周会 · 已标说话人", "Body / Medium", V["text/primary"]));
        const live = frame("live", { layout: "HORIZONTAL", gap: 5, align: "CENTER" });
        sessionDot(live, "attention");
        add(live, text("t", "录制中", "Caption", V["status/attention"]));
        add(titleRow, live);
        add(info, titleRow);
        add(info, text("sub", "今天 14:00 · 进行中", "Callout", V["text/secondary"], { w: 300 }));
        add(c, grow(info));
      }
    }
  ], 64, 2100);

  // 21. Model Provider Card --------------------------------------------------
  // 大模型是**服务之外**的依赖：未配置是一种正常状态，不是错误对话框（SESSIONS-SPEC §4 P7）。
  componentSet(canvas, "Model Provider Card", [
    {
      prop: "State=已连接",
      o: { layout: "VERTICAL", gap: 6, padX: 12, padY: 12, w: 340, fill: V["surface/content"] },
      build: function (c) {
        c.cornerRadius = 12;
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        icon(head, "bot", 15, V["text/secondary"]);
        add(head, text("title", "对话模型", "Body / Medium", V["text/primary"]));
        spacer(head);
        pill(head, "Ready", "已连接");
        add(c, stretch(head));
        add(c, text("addr", "127.0.0.1:8000/v1 · qwen3-30b-a3b", "Callout",
          V["text/secondary"], { w: 316 }));
      }
    },
    {
      prop: "State=未配置",
      o: { layout: "VERTICAL", gap: 6, padX: 12, padY: 12, w: 340, fill: V["surface/content"] },
      build: function (c) {
        c.cornerRadius = 12;
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        icon(head, "bot", 15, V["text/tertiary"]);
        add(head, text("title", "对话模型", "Body / Medium", V["text/primary"]));
        spacer(head);
        pill(head, "Off", "未配置");
        add(c, stretch(head));
        add(c, text("addr", "填一个兼容 OpenAI 的服务地址（须支持 Responses API）。", "Callout",
          V["text/tertiary"], { w: 316 }));
      }
    },
    {
      prop: "State=不可达",
      o: { layout: "VERTICAL", gap: 6, padX: 12, padY: 12, w: 340, fill: V["surface/attentionTint"] },
      build: function (c) {
        c.cornerRadius = 12;
        const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        icon(head, "triangle-alert", 15, V["status/attention"]);
        add(head, text("title", "对话模型", "Body / Medium", V["text/primary"]));
        spacer(head);
        pill(head, "Attention", "不可达");
        add(c, stretch(head));
        add(c, text("addr", "连接被拒绝：127.0.0.1:8000 上没有服务在监听。", "Callout",
          V["text/secondary"], { w: 316 }));
      }
    }
  ], 820, 2200);

  const bottom = Math.max(gridCursor[64] || 0, gridCursor[820] || 0);
  size(canvas, 1600, Math.max(2400, bottom + 16));
  return canvas;
}

// =============================================================================
// Screens
// =============================================================================

const ROUTES = [
  { key: "dubbing", group: "创作", label: "配音台", icon: "audio-lines" },
  { key: "voiceDesign", group: "创作", label: "音色创作", icon: "sparkles" },
  { key: "voiceClone", group: "创作", label: "音色克隆", icon: "mic" },
  { key: "voiceLibrary", group: "创作", label: "音色库", icon: "library" },
  { key: "works", group: "创作", label: "我的作品", icon: "folder-open" },
  { key: "assistant", group: "会话", label: "语音助手", icon: "message-circle" },
  { key: "meeting", group: "会话", label: "会议助手", icon: "users" },
  { key: "captions", group: "会话", label: "实时字幕", icon: "captions" },
  { key: "overview", group: "引擎", label: "服务状态", icon: "server" },
  { key: "monitoring", group: "引擎", label: "运行监控", icon: "activity" },
  { key: "models", group: "引擎", label: "模型", icon: "package" },
  { key: "diagnostics", group: "引擎", label: "诊断", icon: "stethoscope" },
  { key: "developerDocs", group: "引擎", label: "开发者文档", icon: "book-open" }
];

const ROUTE_GROUPS = ["创作", "会话", "引擎"];
// 侧边栏第二行（会话所有权）在每块画板上说的事实不同：这块画板的主路由负责给出它，
// 其余页面显示「麦克风空闲」——所有权不跟随页面，但必须常驻可见。
const SESSION_STATES = {
  idle: { label: "麦克风空闲", tone: "off" },
  assistant: { label: "语音助手进行中 · 00:03:42", tone: "ready" },
  meeting: { label: "会议录制中 · 00:12:40", tone: "attention" },
  captions: { label: "实时字幕进行中 · 08:12", tone: "ready" }
};
const TONE_DOTS = {
  ready: "status/ready",
  attention: "status/attention",
  info: "status/info",
  off: "text/tertiary"
};

function sessionDot(parent, tone) {
  dot(parent, 8, V[TONE_DOTS[tone] || TONE_DOTS.off]);
  return parent;
}

const TRAFFIC = ["#FF5F57", "#FEBC2E", "#28C840"];

function rawFill(node, hex) {
  node.fills = [{ type: "SOLID", color: hexToRgb(hex) }];
  return node;
}

function sectionHead(parent, title, detail, width) {
  const box = frame("sectionHead", { layout: "VERTICAL", gap: 3 });
  add(box, text("title", title, "Heading / Section", V["text/primary"]));
  if (detail) add(box, text("detail", detail, "Callout", V["text/secondary"], { w: width }));
  return add(parent, stretch(box));
}

// Every page opens with the same two lines and an optional trailing control, so
// the eight screens read as one product instead of eight variants.
function pageHead(parent, title, subtitle, trailing) {
  const row = frame("pageHead", { layout: "HORIZONTAL", gap: 16, align: "CENTER" });
  const col = frame("titles", { layout: "VERTICAL", gap: 3 });
  add(col, text("title", title, "Title / Page", V["text/primary"]));
  if (subtitle) add(col, text("sub", subtitle, "Callout", V["text/secondary"], { w: 780 }));
  add(row, col);
  spacer(row);
  if (trailing) trailing(row);
  return add(parent, stretch(row));
}

// 「非主框体」的收起控件（用户 2026-09-18：「本次对话」面板要能收起，其余非主框体同理）。
//
// 落点与形状沿用 app 里已经实测过的那一枚（REDESIGN-SPEC §11.6 第六十二轮）：**内容列首行
// 尾端**、`sidebar.right` 图标、28pt（= `Control.iconButton`，不新增数值 token）。它**不是
// 工具栏项**——工具栏里每一件动作的落点由系统按「固定项 + 浮动间隔」分配，锚不住「面板分界线」
// 这个位置；首行由内容列承载，它的右沿就是面板左沿，间隔就是这一行自己的内边距。
//
// 面板自己**不再画第二个收起按钮**：一个动作一屏只出现一次（第七轮去重 7 处之后成为门禁，
// 见 smoke.js 的「42 块闭环屏的动作没有重复」）。规则全文、清单与「收起之后主框体得到什么」
// 见 `closurePanelRulesBoard`。
function sideToggle(row, panelName) {
  const box = frame("sideToggle · " + panelName, {
    layout: "HORIZONTAL", gap: 4, align: "CENTER"
  });
  iconButton(box, "sidebar-right", 28);
  add(row, box);
  return box;
}

// One 1px divider that stretches to its container, used to separate list rows,
// card headers and card footers.
function hairline(parent) {
  return stretch(rect(parent, "hairline", 100, 1, V["border/separator"]));
}

// Reserved for window-level floating layers (menu panels, popovers), the only
// surfaces macOS itself gives a shadow. Static cards are flat by spec §5.2.
function elevate(node) {
  try {
    node.effects = [{
      type: "DROP_SHADOW",
      color: { r: 0, g: 0, b: 0, a: 0.07 },
      offset: { x: 0, y: 1 },
      radius: 4,
      spread: 0,
      visible: true,
      blendMode: "NORMAL"
    }];
  } catch (e) {}
  return node;
}

function card(parent, name, o) {
  o = o || {};
  const c = frame(name, {
    layout: o.layout || "VERTICAL",
    gap: o.gap == null ? 14 : o.gap,
    pad: o.pad == null ? 18 : o.pad,
    padX: o.padX,
    padY: o.padY,
    radius: o.radius == null ? 12 : o.radius,
    fill: o.fill || V["surface/content"],
    // REDESIGN-SPEC §5.2: a surface that neither carries interaction nor
    // expresses hierarchy gets no stroke and no shadow. Cards are containers,
    // so separation comes from the fill step and system dividers only; pass
    // o.stroke / o.elevated when a variant genuinely encodes state.
    stroke: o.stroke || null,
    strokeWeight: o.strokeWeight == null ? 1 : o.strokeWeight,
    clip: o.clip === true
  });
  if (o.elevated === true) elevate(c);
  return add(parent, stretch(c));
}

// Fixed-width table cell: a hugging label inside a sized holder is what keeps
// columns from drifting when a value gets longer.
function cell(parent, width, justify) {
  const holder = frame("cell", { layout: "HORIZONTAL", justify: justify || "MIN" });
  size(holder, width, null);
  if (width == null) grow(holder);
  return add(parent, holder);
}

function navItemRow(parent, route, selected) {
  const row = frame("nav/" + route.key, {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, radius: 7
  });
  size(row, 220, 30);
  if (selected) bindFill(row, V["surface/railTint"]);
  icon(row, route.icon, 16, selected ? V["accent/rail"] : V["text/secondary"]);
  add(row, text("label", route.label, selected ? "Body / Medium" : "Body", V["text/primary"]));
  return add(parent, row);
}

function searchField(parent, placeholder, width) {
  const box = frame("search", {
    layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 8, padY: 5, radius: 7,
    fill: V["surface/field"], stroke: V["border/separator"], strokeWeight: 1
  });
  size(box, width, 26);
  icon(box, "search", 14, V["text/tertiary"]);
  add(box, text("placeholder", placeholder, "Callout", V["text/tertiary"]));
  return add(parent, box);
}

// `names` 可选：给某一格一个稳定的节点名，好让原型连线指得到它（「大字」那一档是另
// 一块画板）。不传就仍然是 "cell"，与既有调用点完全一样。
function segmented(parent, items, activeIndex, names) {
  const seg = frame("segmented", {
    layout: "HORIZONTAL", gap: 1, pad: 1, radius: 7,
    fill: V["surface/window"], stroke: V["border/separator"], strokeWeight: 1
  });
  items.forEach(function (item, i) {
    const cell = frame(names && names[i] ? names[i] : "cell", {
      layout: "HORIZONTAL", align: "CENTER", justify: "CENTER", padX: 9, padY: 3, radius: 6
    });
    if (i === activeIndex) {
      bindFill(cell, V["surface/content"]);
      bindStroke(cell, V["border/separator"], 1);
    }
    add(cell, text("label", item, "Callout", V["text/primary"]));
    add(seg, cell);
  });
  return add(parent, seg);
}

// A bare "⌘⏎" next to a button reads as a stray glyph; a keycap reads as a
// shortcut. Every hint in the kit goes through this, so they stay identical.
function kbd(parent, label) {
  const k = frame("kbd", {
    layout: "HORIZONTAL", align: "CENTER", justify: "CENTER", padX: 5, padY: 2, radius: 5,
    fill: V["surface/panel"], stroke: V["border/separator"], strokeWeight: 1
  });
  add(k, text("label", label, "Caption", V["text/secondary"]));
  return add(parent, k);
}

// A keycap inside a row whose counter axis is MAX-aligned would sit on the
// baseline of a 34pt button, so hints travel in a control-height box.
function kbdInRow(parent, label, height) {
  const box = frame("hint", { layout: "HORIZONTAL", align: "CENTER" });
  kbd(box, label);
  size(box, null, height == null ? 34 : height);
  return add(parent, box);
}

// Label left, value right, label column optionally fixed: the single row shape
// shared by every inspector, so values line up across cards.
function kvRow(parent, label, value, labelW) {
  const row = frame("kv", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  const k = frame("kCell", { layout: "HORIZONTAL" });
  if (labelW) size(k, labelW, null);
  add(k, text("k", label, "Callout", V["text/secondary"]));
  add(row, k);
  spacer(row);
  add(row, text("v", value, "Callout", V["text/primary"]));
  return add(parent, stretch(row));
}

function buildShell(routeKey, title, iconName, contentFn, sessionState) {
  const win = frame("▸ " + title, {
    layout: "VERTICAL", fill: V["surface/window"], radius: 12, clip: true
  });
  size(win, 1440, 900);

  // Titlebar ---------------------------------------------------------------
  const bar = frame("titlebar", {
    layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 14, padY: 10,
    fill: V["surface/sidebar"]
  });
  const lights = frame("trafficLights", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  TRAFFIC.forEach(function (c) {
    const e = figma.createEllipse();
    e.name = "light";
    size(e, 12, 12);
    rawFill(e, c);
    add(lights, e);
  });
  add(bar, lights);
  const titleBox = frame("title", { layout: "HORIZONTAL", gap: 7, align: "CENTER" });
  icon(titleBox, iconName, 16, V["text/secondary"]);
  add(titleBox, text("label", title, "Heading / Section", V["text/primary"]));
  grow(titleBox);
  add(bar, titleBox);
  const actions = frame("actions", { layout: "HORIZONTAL", gap: 4, align: "CENTER" });
  iconButton(actions, "info", 28);
  iconButton(actions, "ellipsis", 28);
  add(bar, actions);
  add(win, stretch(bar));

  // Body -------------------------------------------------------------------
  const body = frame("body", { layout: "HORIZONTAL" });
  grow(body);
  add(win, stretch(body));

  const sidebar = frame("sidebar", {
    layout: "VERTICAL", gap: 14, padX: 10, padY: 12, fill: V["surface/sidebar"]
  });
  size(sidebar, 240, 100);
  stretch(sidebar);
  add(body, sidebar);

    searchField(sidebar, "搜索", 220);
    ROUTE_GROUPS.forEach(function (groupName) {
      const group = frame("group/" + groupName, { layout: "VERTICAL", gap: 1 });
      const label = frame("groupLabel", { layout: "HORIZONTAL", padX: 8, padY: 2 });
      add(label, text("label", groupName, "Caption / Medium", V["text/tertiary"]));
      add(group, stretch(label));
      // 三个能力在侧边栏里是同级项，第一次打开 App 的人要**在原地**知道该用哪个
      // （用户 2026-09-18 双视角审查 P0：全稿零处「该用哪个」的指引，三选一靠猜）。
      // 所以定位语常驻在分组里，不写在某一页的说明卡上——它是导航的一部分，不是知识点。
      if (groupName === "会话") {
        const note = frame("groupNote", { layout: "HORIZONTAL", padX: 8, padY: 1 });
        add(note, text("note", "要文字用字幕，要纪要用会议，要对话用助手。", "Caption",
          V["text/tertiary"], { w: 204 }));
        add(group, stretch(note));
      }
      ROUTES.filter(function (r) { return r.group === groupName; }).forEach(function (r) {
        navItemRow(group, r, r.key === routeKey);
      });
      add(sidebar, stretch(group));
    });
  spacer(sidebar);

  const statusWrap = frame("sidebarStatusWrap", { layout: "VERTICAL", gap: 6 });
  const hairline = rect(statusWrap, "hairline", 220, 1, V["border/separator"]);
  const status = frame("sidebarStatus", {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, padY: 7
  });
  size(status, 220, 30);
  dot(status, 8, V["status/ready"]);
  add(status, text("label", "服务已就绪 · Quality", "Callout", V["text/secondary"]));
  add(statusWrap, status);
  // 会话所有权与「服务是否就绪」同级常驻：本机只有一个麦克风，谁在用它是这个 App
  // 的首要事实，而不是「点了才被拒绝」的内部状态（SESSIONS-SPEC §4 P5）。
  const session = SESSION_STATES[sessionState || "idle"] || SESSION_STATES.idle;
  const sessionRow = frame("sidebarSession", {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, padY: 7
  });
  size(sessionRow, 220, 30);
  sessionDot(sessionRow, session.tone);
  add(sessionRow, text("label", session.label, "Callout", V["text/secondary"]));
  add(statusWrap, sessionRow);
  add(sidebar, stretch(statusWrap));

  // Detail -----------------------------------------------------------------
  // The page is the recessed surface and every card is content on top of it.
  // With detail at #FFFFFF and cards at #F5F5F7 the eight screens read as one
  // flat sheet: the delta was 2% and no group had an edge.
  const detail = frame("detail", {
    layout: "VERTICAL", gap: 20, padX: 20, padY: 20, fill: V["surface/window"]
  });
  grow(detail);
  stretch(detail);
  stretch(rect(body, "divider", 1, 100, V["border/separator"]));
  add(body, detail);
  contentFn(detail);

  return win;
}

// =============================================================================
// 会话共享件（SESSIONS-SPEC §6.7）
// =============================================================================
//
// 三个能力（语音助手 / 会议助手 / 实时字幕）共用同一套外壳：状态带、电平、说话人、
// 对话行、结论条。造第二套的代价不是多写代码，而是同一件事在三个地方有三种说法。

// 真实电平的形状：中间高两端低。读数靠**颜色**分辨（已到达 / 未到达），条高不跟着
// 电平动——条高动了，读数就变成动画（与既有 Level Meter 同一条约定）。
function levelBars(parent, ratio, count, height) {
  const box = frame("level", { layout: "HORIZONTAL", gap: 3, align: "MAX" });
  const n = count == null ? 20 : count;
  const h = height == null ? 22 : height;
  const lit = Math.max(0, Math.min(n, Math.round(n * Math.max(0, Math.min(1, ratio)))));
  for (let i = 0; i < n; i++) {
    const shape = n === 1 ? 1 : Math.sin(Math.PI * (i / (n - 1)));
    const bar = Math.max(3, Math.round(h * (0.35 + 0.65 * shape)));
    rect(box, "bar", 3, bar, i < lit ? V["accent/voice"] : V["border/separator"], 1.5);
  }
  return add(parent, box);
}

function speakerChip(parent, label, voice) {
  const chip = frame("Speaker Chip", {
    layout: "HORIZONTAL", align: "CENTER", padX: 7, padY: 2, radius: 999,
    fill: voice ? V["surface/voiceTint"] : V["surface/panel"]
  });
  add(chip, text("label", label, "Caption", voice ? V["accent/voice"] : V["text/secondary"]));
  return add(parent, chip);
}

// 对话行与转录行是同一条行：说话人 + （音色徽标 / 识别中）+ 时间 + 可选行内动作 + 正文。
function turnRow(parent, o) {
  o = o || {};
  const row = frame("Turn Row", { layout: "VERTICAL", gap: 5, padX: 16, padY: 12 });
  const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  add(head, text("who", o.who, "Body / Medium", o.accent ? V["accent/rail"] : V["text/primary"]));
  if (o.badge) voiceBadge(head, o.badge);
  if (o.partial) pill(head, "Info", "识别中");
  // 「被打断」这类**属于这一句**的状态挂在句子上，不挂在页面上：用户在回看时要知道
  // 助手那一句为什么停在四个字上，而不是去猜。
  if (o.pill) pill(head, o.pill[0], o.pill[1]);
  // 这一行是从哪一路来的（麦克风 / 本机音频）：混音之后，回看时最需要分清的
  // 就是「对方说的」与「屋里说的」，所以来源跟着行走，而不是藏在会话设置里。
  if (o.src) add(head, text("src", "· " + o.src, "Caption", V["text/tertiary"]));
  spacer(head);
  if (o.time) add(head, text("time", o.time, "Callout", V["text/tertiary"]));
  (o.actions || []).forEach(function (name) { iconButton(head, name, 26); });
  add(row, stretch(head));
  add(row, text("text", o.text, "Body", o.partial ? V["text/secondary"] : V["text/primary"],
    { w: o.width }));
  return add(parent, stretch(row));
}

// 会话状态带：三个能力的第一块卡。点 + 阶段 + 主体 + 电平 + 计时 + 事实 + 动作。
function sessionStatusBar(parent, o) {
  const bar = frame("Session Status Bar", {
    layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 13, radius: 12,
    fill: V["surface/content"]
  });
  sessionDot(bar, o.tone || "ready");
  add(bar, text("phase", o.phase, "Body / Medium", V["text/primary"]));
  if (o.title) add(bar, text("title", o.title, "Callout", V["text/secondary"]));
  spacer(bar);
  levelBars(bar, o.level == null ? 0.6 : o.level, o.bars || 20, 20);
  if (o.time) add(bar, text("time", o.time, "Body / Medium", V["text/primary"]));
  (o.facts || []).forEach(function (f) {
    add(bar, text("fact", f, "Callout", V["text/secondary"]));
  });
  (o.actions || []).forEach(function (a) {
    if (a[2] === "primary") primaryButton(bar, a[0], a[1]);
    else secondaryButton(bar, a[0], a[1]);
  });
  return add(parent, stretch(bar));
}

// 结论条：缺能力、缺授权、服务不可达，都走这一条形状（图标 + 结论 + 影响 + 出口）。
function conclusionBand(parent, o) {
  const t = PILL_TONES[o.tone || "Attention"];
  const band = frame("Status Conclusion", {
    layout: "HORIZONTAL", gap: 14, align: "CENTER", pad: 18, radius: 12,
    fill: V[t.fill], stroke: V[t.ink], strokeWeight: 1
  });
  icon(band, t.icon, 26, V[t.ink]);
  const box = frame("text", { layout: "VERTICAL", gap: 3 });
  add(box, text("title", o.title, "Title / Page", V["text/primary"]));
  add(box, text("body", o.body, "Callout", V["text/secondary"], { w: o.width || 640 }));
  if (o.hint) add(box, text("hint", o.hint, "Caption", V["text/tertiary"], { w: o.width || 640 }));
  add(band, grow(box));
  (o.actions || []).forEach(function (a) {
    if (a[2] === "primary") primaryButton(band, a[0], a[1]);
    else secondaryButton(band, a[0], a[1]);
  });
  return add(parent, stretch(band));
}

// 字幕行：说话人（可选）+ 正文。字幕带与记录窗共用，区别只在字号档与可用宽度。
function captionLine(parent, o) {
  const row = frame("Caption Line", {
    layout: "HORIZONTAL", gap: 10, align: "MIN",
    padX: o.padX == null ? 16 : o.padX, padY: o.padY == null ? 9 : o.padY
  });
  if (o.who) speakerChip(row, o.who);
  add(row, text("text", o.text, o.style || "Caption Band / 标准",
    o.partial ? V["text/secondary"] : V["text/primary"], { w: o.width }));
  if (o.right) {
    spacer(row);
    add(row, text("right", o.right, "Caption", V["text/tertiary"]));
  }
  return add(parent, stretch(row));
}

// 会议列表行：标题（+ 录制中 / 状态徽标）+ 副行（日期 · 时长 · 说话人数）+ 行尾取值。
function meetingRow(parent, o) {
  const row = frame("Meeting Row", {
    layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 12
  });
  if (o.selected) bindFill(row, V["surface/railTint"]);
  const info = frame("info", { layout: "VERTICAL", gap: 3 });
  const titleRow = frame("titleRow", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  add(titleRow, text("title", o.title, "Body / Medium", V["text/primary"]));
  if (o.live) {
    const live = frame("live", { layout: "HORIZONTAL", gap: 5, align: "CENTER" });
    sessionDot(live, "attention");
    add(live, text("t", "录制中", "Caption", V["status/attention"]));
    add(titleRow, live);
  }
  if (o.badge) pill(titleRow, o.badge[0], o.badge[1]);
  add(info, titleRow);
  add(info, text("sub", o.sub, "Callout", V["text/secondary"], { w: o.width || 200 }));
  add(row, grow(info));
  if (o.right) add(row, text("right", o.right, "Callout", V["text/tertiary"]));
  return add(parent, stretch(row));
}

// --- 1. 配音台 ---------------------------------------------------------------
function screenDubbing(d) {
  pageHead(d, "配音台", "输入文稿、选择音色，直接生成可交付的语音。");

  // The counter belongs to the field it counts, so the information line lives
  // inside the same card behind a divider instead of floating on the page.
  const editor = frame("editor", {
    layout: "VERTICAL", gap: 0, radius: 12,
    fill: V["surface/content"]
  });
  // 2026-09-15 用户复核 + 2026-09-16 三度／四度／五度／六度校准：输入区不再占满剩余高度，
  // 也不停在某个固定值。应用的高度**跟随正文**——下限 144pt（静止状态看得见 3 行写作区，
  // 六度校准后从 160 收到 144；滚动条已可接受，下限不必再为「拖后出现滚动条」多留一行）、
  // 上限 360pt（量的是整张卡：正文 + 页码行），中间由正文高度加一行余量决定，到上限后由
  // 原生滚动条承担。画板是静态的，按最常见的这一档画：本页示例文稿（3 行）在应用里已经
  // 越过下限、由正文自身高度决定（离屏实测 158），所以这里仍画 160。
  size(editor, null, 160);
  add(d, stretch(editor));

  const writing = frame("writing", { layout: "VERTICAL", gap: 10, padX: 18, padY: 16 });
  add(writing, text("body",
    "在星际航行的漫长岁月里，人类学会了倾听寂静。每当脉冲信号穿越猎户座悬臂，控制台都会闪烁起熟悉的琥珀色微光。" +
    "我们把这些信号记录下来，交给时间，也交给愿意聆听的人。",
    "Body", V["text/primary"], { w: 1080 }));
  add(writing, text("body2",
    "第二章从近地轨道开始：那是最后一次有人类在舱外挥手告别，也是第一条被完整保存下来的语音日志。",
    "Body", V["text/primary"], { w: 1080 }));
  // The writing area takes every pixel the editor's own metadata row leaves.
  add(editor, stretch(grow(writing)));
  hairline(editor);

  const meta = frame("meta", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 18, padY: 10 });
  add(meta, text("count", "62/5000 字", "Subheadline", V["text/secondary"]));
  spacer(meta);
  const clear = frame("quiet", { layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 8, padY: 3, radius: 7 });
  icon(clear, "eraser", 14, V["text/secondary"]);
  add(clear, text("label", "清空", "Subheadline", V["text/secondary"]));
  add(meta, clear);
  add(editor, stretch(meta));

  const controls = card(d, "composer", {
    layout: "HORIZONTAL", gap: 20, align: "MAX", padX: 16, padY: 12
  });
  const voiceGroup = frame("fieldGroup", { layout: "VERTICAL", gap: 5 });
  add(voiceGroup, text("label", "音色", "Subheadline", V["text/secondary"]));
  const capsule = frame("voiceCapsule", {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 10, padY: 4, radius: 999,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
  });
  icon(capsule, "audio-waveform", 15, V["accent/voice"]);
  add(capsule, text("name", "夜航主持", "Body / Medium", V["text/primary"]));
  voiceBadge(capsule, "系统");
  icon(capsule, "chevron-down", 14, V["text/secondary"]);
  add(voiceGroup, capsule);
  add(controls, voiceGroup);

  const speedGroup = frame("fieldGroup", { layout: "VERTICAL", gap: 5 });
  add(speedGroup, text("label", "语速", "Subheadline", V["text/secondary"]));
  const speedRow = frame("speedRow", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  const track = frame("slider", { layout: "HORIZONTAL", align: "CENTER", radius: 999 });
  size(track, 132, 4);
  bindFill(track, V["border/strong"]);
  // Non-auto-layout stack so the thumb can sit on top of the track instead of
  // beside it. Skipping this left the thumb as an orphan node on the page.
  const sliderBox = frame("sliderBox", { w: 132, h: 14 });
  add(sliderBox, track);
  track.x = 0;
  track.y = 5;
  const thumb = frame("thumb", { layout: "HORIZONTAL", radius: 999 });
  size(thumb, 14, 14);
  bindFill(thumb, V["accent/rail"]);
  add(sliderBox, thumb);
  thumb.x = 74;
  thumb.y = 0;
  add(speedRow, sliderBox);
  add(speedRow, text("value", "1.0x", "Body / Medium", V["text/primary"]));
  segmented(speedRow, ["0.8", "1.0", "1.2", "1.5"], 1);
  add(speedGroup, speedRow);
  add(controls, speedGroup);
  spacer(controls);
  kbdInRow(controls, "⌘⏎");
  primaryButton(controls, "生成语音", "play", 132);

  // Result bar -------------------------------------------------------------
  const result = frame("resultBar", {
    layout: "HORIZONTAL", gap: 12, align: "CENTER", pad: 14, radius: 12,
    fill: V["surface/railTint"]
  });
  waveform(result, [5, 11, 16, 8, 14, 6, 12, 17, 9, 5, 13, 7], V["accent/voice"], 2);
  const rtitle = frame("titles", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  add(rtitle, text("name", "星际航行 · 夜航主持", "Body / Medium", V["text/primary"]));
  add(rtitle, text("dur", "00:12", "Callout", V["text/secondary"]));
  add(result, rtitle);
  spacer(result);
  secondaryButton(result, "播放", "play");
  secondaryButton(result, "在 Finder 中显示", "folder-open");
  secondaryButton(result, "导出…", "download");
  const toWorks = frame("quiet", { layout: "HORIZONTAL", gap: 4, align: "CENTER", padX: 8, padY: 4, radius: 7 });
  add(toWorks, text("label", "查看我的作品", "Callout", V["text/secondary"]));
  icon(toWorks, "chevron-right", 13, V["text/tertiary"]);
  add(result, toWorks);
  add(d, stretch(result));
}

// --- 2. 音色创作 -------------------------------------------------------------
// One candidate in the 2×2 preview grid. The waveform row grows, so a tall
// window gives the preview more room instead of a dead band under the actions.
function candidateTile(def) {
  const playing = def.state === "playing";
  const tile = frame("Candidate Tile", {
    layout: "VERTICAL", gap: 12, pad: 14, radius: 12,
    fill: V["surface/content"],
    // Only the auditioning tile carries a stroke: it encodes playback state.
    stroke: playing ? V["accent/rail"] : null,
    strokeWeight: playing ? 1.5 : 1
  });

  const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  add(head, text("slot", def.slot, "Body / Medium", V["text/primary"]));
  pill(head, def.tone, def.toneLabel);
  spacer(head);
  add(head, text("seed", def.seed, "Caption", V["text/tertiary"]));
  add(tile, stretch(head));

  if (def.state === "failed") {
    // Same three bands as a ready tile - head / body / actions - so the grid
    // stays a grid instead of one card collapsing into a sentence.
    const box = frame("msgBox", { layout: "VERTICAL", gap: 8, align: "CENTER", justify: "CENTER" });
    icon(box, "triangle-alert", 20, V["status/attention"]);
    add(box, text("msg", "服务端未返回预览音频，可单独重试这一组。",
      "Callout", V["text/secondary"], { w: 380, align: "CENTER" }));
    add(tile, stretch(grow(box)));
    const actions = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
    secondaryButton(actions, "重试", "refresh-cw");
    spacer(actions);
    add(actions, text("dur", "—", "Callout", V["text/tertiary"]));
    add(tile, stretch(actions));
    return tile;
  }

  const waveRow = frame("waveRow", { layout: "HORIZONTAL", align: "CENTER", justify: "CENTER" });
  waveform(waveRow, [10, 22, 34, 16, 28, 12, 24, 36, 14, 20, 10, 26, 18, 30, 12, 22, 16, 28],
    V["accent/voice"], 3);
  add(tile, stretch(grow(waveRow)));

  const actions = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  if (playing) secondaryButton(actions, "停止", "pause");
  else secondaryButton(actions, "试听", "play");
  if (def.state === "saved") {
    // 保存成功后动作行给的是下一步，不是一枚静态徽标：「已保存」由头部状态胶囊
    // 承担，动作行的位置留给「在音色库中查看」（REDESIGN-SPEC §7.2）。
    secondaryButton(actions, "在音色库中查看", "library");
  } else {
    primaryButton(actions, "保存为音色", null, 118);
  }
  spacer(actions);
  add(actions, text("dur", def.dur, "Callout", V["text/tertiary"]));
  add(tile, stretch(actions));
  return tile;
}

function screenVoiceDesign(d) {
  pageHead(d, "音色创作", "用一句话描述你想要的音色，从真实预览里挑一个保存进音色库。");

  // The description box *is* the field: a white input nested inside a white card
  // only drew two borders around the same sentence.
  const prompt = frame("promptCard", {
    layout: "VERTICAL", gap: 12, pad: 18, radius: 12,
    fill: V["surface/content"]
  });
  const field = frame("promptField", { layout: "VERTICAL", gap: 4 });
  // 2026-09-16 三度校准：应用把字数与保存门禁那一行收进了框内（多一条分隔线，
  // 见 REDESIGN-SPEC §7.2），所以描述框整卡是 160pt。画板这里把字段本身也画成
  // 160，字段与卡同色，看过去仍是同一块。
  size(field, 1120, 160);
  add(field, text("body", "温暖、清晰、亲近，像一位深夜电台耐心的播客主持人。", "Body", V["text/primary"], { w: 1080 }));
  add(field, text("hint", "继续描述场景、听众或情绪，候选之间的差异会更明显。", "Callout", V["text/tertiary"], { w: 1080 }));
  add(prompt, stretch(field));

  const meta = frame("meta", { layout: "HORIZONTAL", align: "CENTER" });
  add(meta, text("count", "28/400 字", "Subheadline", V["text/tertiary"]));
  spacer(meta);
  add(meta, text("hint", "真实预览未返回前不可保存", "Subheadline", V["text/tertiary"]));
  add(prompt, stretch(meta));

  const chipsBox = frame("chipsBox", { layout: "VERTICAL", gap: 6 });
  add(chipsBox, text("label", "快速加入声学特征", "Subheadline", V["text/secondary"]));
  const chips = frame("chips", { layout: "HORIZONTAL", gap: 6, align: "CENTER", wrap: true });
  ["磁性胸腔", "治愈温暖", "播音质感", "微醺叙事", "少年清冽", "知性温婉"].forEach(function (chip) {
    const c2 = frame("Voice Chip", {
      layout: "HORIZONTAL", gap: 4, align: "CENTER", padX: 10, padY: 3, radius: 999,
      fill: V["surface/attentionTint"], stroke: V["accent/voice"], strokeWeight: 1
    });
    icon(c2, "plus", 13, V["accent/voice"]);
    add(c2, text("label", chip, "Subheadline", V["accent/voice"]));
    add(chips, c2);
  });
  // Width first, height left to hug: a wrapped row sized before wrapping keeps
  // the single-row height and the second row spills out of it.
  size(chips, 1128, null);
  add(chipsBox, stretch(chips));
  add(prompt, stretch(chipsBox));

  const foot = frame("foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  const disc = frame("disclosure", { layout: "HORIZONTAL", gap: 7, align: "CENTER", padX: 6, padY: 3, radius: 7 });
  icon(disc, "chevron-right", 14, V["text/secondary"]);
  add(disc, text("label", "更多设置：参考文案与保存名称", "Callout", V["text/secondary"]));
  add(foot, disc);
  spacer(foot);
  kbd(foot, "⌘⏎");
  primaryButton(foot, "生成候选音色", "sparkles", 168);
  add(prompt, stretch(foot));
  add(d, stretch(prompt));

  // Candidate grid ---------------------------------------------------------
  sectionHead(d, "候选试听", "只有收到真实预览音频的候选才可试听或按其参数注册。", 900);
  // Two explicit rows that split the remaining height: a wrapping grid cannot
  // grow its rows, so it always left the lower half of the page empty.
  const grid = frame("candidateGrid", { layout: "VERTICAL", gap: 12 });
  add(d, stretch(grow(grid)));
  const defs = [
    { slot: "候选 1", seed: "seed 101", dur: "00:03", tone: "Ready", toneLabel: "可试听", state: "playing" },
    { slot: "候选 2", seed: "seed 202", dur: "00:03", tone: "Ready", toneLabel: "可试听", state: "ready" },
    { slot: "候选 3", seed: "seed 303", dur: "00:03", tone: "Ready", toneLabel: "已保存", state: "saved" },
    { slot: "候选 4", seed: "seed 404", dur: "—", tone: "Attention", toneLabel: "生成失败", state: "failed" }
  ];
  [[0, 1], [2, 3]].forEach(function (pair) {
    const row = frame("gridRow", { layout: "HORIZONTAL", gap: 12 });
    add(grid, stretch(grow(row)));
    pair.forEach(function (i) {
      add(row, stretch(grow(candidateTile(defs[i]))));
    });
  });
}

// --- 3. 音色克隆 -------------------------------------------------------------
// 录音链路（选稿 → 录制 → 回听核对 → 预检 → 注册）在同一页里走完；每一步都留在
// 页面上，因为它同时也是「这段录音能不能用」的证据链。画板画的是刚录完、还没
// 注册的那一档：提词稿已选、录音 00:11、本地检查通过、名称空着。
function screenVoiceClone(d) {
  pageHead(d, "音色克隆", "读一段提词稿，用你自己的声音注册一个可复用的音色。");

  // 1. 提词稿 ---------------------------------------------------------------
  // 稿件是这一页唯一的大字对象（朗读时眼睛只看它），所以它自己占一层
  // `surface/panel`，其余说明都退到 Callout。
  const script = card(d, "scriptCard", { gap: 14 });
  const scriptHead = frame("scriptHead", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  add(scriptHead, text("title", "提词稿", "Heading / Section", V["text/primary"]));
  spacer(scriptHead);
  add(scriptHead, text("hint", "建议朗读 10–30 秒；服务接受 2–45 秒。", "Subheadline", V["text/tertiary"]));
  add(script, stretch(scriptHead));

  const picks = frame("promptPicks", { layout: "HORIZONTAL", gap: 6, align: "CENTER", wrap: true });
  [
    ["📜 盛唐气象 · 经典诗韵", true], ["⚡ 科技浪潮 · 现代叙述", false],
    ["☕ 晨光午后 · 日常伴随", false], ["🌌 星辰大海 · 哲思沉稳", false],
    ["自己写一段", false]
  ].forEach(function (p) {
    const chip = frame("Prompt Option", {
      layout: "HORIZONTAL", gap: 4, align: "CENTER", padX: 10, padY: 4, radius: 999,
      fill: p[1] ? V["surface/railTint"] : V["surface/content"],
      stroke: p[1] ? V["accent/rail"] : V["border/separator"], strokeWeight: 1
    });
    add(chip, text("label", p[0], "Subheadline", p[1] ? V["accent/rail"] : V["text/secondary"]));
    add(picks, chip);
  });
  size(picks, 1123, null);
  add(script, stretch(picks));

  const scriptBody = frame("scriptBody", {
    layout: "VERTICAL", gap: 8, padX: 16, padY: 14, radius: 8, fill: V["surface/panel"]
  });
  add(scriptBody, text("line", "白日依山尽，黄河入海流。欲穷千里目，更上一层楼。", "Title / Page", V["text/primary"], { w: 1060 }));
  add(scriptBody, text("line", "春江潮水连海平，海上明月共潮生。", "Title / Page", V["text/primary"], { w: 1060 }));
  add(script, stretch(scriptBody));

  const scriptTips = frame("tips", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
  icon(scriptTips, "info", 13, V["text/secondary"]);
  add(scriptTips, text("label", "字正腔圆，声调平稳从容，注意句尾自然停顿。", "Callout", V["text/secondary"]));
  add(script, stretch(scriptTips));

  // 2. 录制 ---------------------------------------------------------------
  const record = card(d, "recordCard", { gap: 14 });
  const recordHead = frame("recordHead", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  add(recordHead, text("title", "录制", "Heading / Section", V["text/primary"]));
  pill(recordHead, "Attention", "录音中");
  spacer(recordHead);
  add(recordHead, text("device", "内建麦克风 · 48 kHz 单声道", "Subheadline", V["text/tertiary"]));
  add(record, stretch(recordHead));

  const recordRow = frame("recordRow", { layout: "HORIZONTAL", gap: 16, align: "CENTER" });
  const recordButton = frame("recordButton", {
    layout: "HORIZONTAL", align: "CENTER", justify: "CENTER", radius: 999, fill: V["status/critical"]
  });
  size(recordButton, 56, 56);
  icon(recordButton, "square", 20, V["text/onAccent"]);
  add(recordRow, recordButton);
  const meter = frame("Level Meter", { layout: "HORIZONTAL", gap: 3, align: "MAX" });
  grow(meter);
  // 已经过去的电平用 `accent/voice`（这是「声音」的形状），尚未到达的刻度用
  // `border/separator`：录音的电平表必须同时读得出「现在多响」和「离满有多远」。
  [
    [8, true], [14, true], [22, true], [30, true], [18, true], [26, true], [34, true],
    [12, true], [20, true], [28, true], [36, true], [16, true], [24, true], [30, true],
    [22, true], [14, true], [10, true], [6, false], [6, false], [6, false], [6, false],
    [6, false], [6, false], [6, false], [6, false], [6, false], [6, false], [6, false]
  ].forEach(function (bar) {
    rect(meter, "level", 3, bar[0], bar[1] ? V["accent/voice"] : V["border/separator"], 1.5);
  });
  add(recordRow, stretch(meter));
  const timer = frame("timerBox", { layout: "HORIZONTAL", align: "CENTER" });
  add(timer, text("timer", "00:11", "Body / Medium", V["text/primary"]));
  size(timer, 48, null);
  add(recordRow, timer);
  add(record, stretch(recordRow));

  add(record, text("note",
    "录音只用于这次注册；取消或注册完成后临时文件立刻删除，应用不保存原始录音。",
    "Subheadline", V["text/tertiary"], { w: 1123 }));

  // 3. 回听与核对 -----------------------------------------------------------
  const review = card(d, "reviewCard", { gap: 14 });
  const reviewHead = frame("reviewHead", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  add(reviewHead, text("title", "回听与核对", "Heading / Section", V["text/primary"]));
  pill(reviewHead, "Ready", "本地检查通过");
  spacer(reviewHead);
  add(reviewHead, text("hint", "波形来自刚才这段录音本身", "Subheadline", V["text/tertiary"]));
  add(review, stretch(reviewHead));

  const take = frame("take", {
    layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 14, padY: 10, radius: 8,
    fill: V["surface/panel"]
  });
  waveform(take, [7, 15, 22, 11, 19, 9, 16, 24, 12, 20, 8, 14, 21, 10], V["accent/voice"], 2);
  add(take, text("dur", "00:11", "Callout", V["text/tertiary"]));
  spacer(take);
  secondaryButton(take, "播放", "play");
  secondaryButton(take, "重录", "mic");
  add(review, stretch(take));

  const spokenLabel = text("fieldLabel", "实际朗读的文本（服务用它给参考音频做内容校验）", "Caption / Medium", V["text/secondary"]);
  add(review, spokenLabel);
  const spoken = frame("Text Field", {
    layout: "HORIZONTAL", align: "CENTER", padX: 12, padY: 9, radius: 8,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
  });
  add(spoken, text("value", "白日依山尽，黄河入海流。欲穷千里目，更上一层楼。春江潮水连海平，海上明月共潮生。",
    "Body", V["text/primary"], { w: 1097 }));
  add(review, stretch(spoken));

  // 4. 注册 ---------------------------------------------------------------
  const register = card(d, "registerCard", { gap: 12 });
  const registerRow = frame("registerRow", { layout: "HORIZONTAL", gap: 12, align: "CENTER" });
  const nameField = frame("Text Field", {
    layout: "HORIZONTAL", align: "CENTER", padX: 12, padY: 9, radius: 8,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
  });
  add(nameField, text("value", "给这个音色起个名字", "Body", V["text/tertiary"]));
  size(nameField, 360, 34);
  add(registerRow, nameField);
  spacer(registerRow);
  secondaryButton(registerRow, "先检查参考音频", "shield-check");
  primaryButton(registerRow, "注册音色", "mic", 140);
  add(register, stretch(registerRow));

  const conclusions = frame("conclusions", { layout: "HORIZONTAL", gap: 14, align: "CENTER" });
  [
    ["时长", "00:11"],
    ["人声占比", "82%"],
    ["估计信噪比", "24 dB"],
    ["削波", "无"]
  ].forEach(function (item) {
    const k = frame("conclusion", { layout: "HORIZONTAL", gap: 5, align: "CENTER" });
    add(k, text("k", item[0], "Subheadline", V["text/tertiary"]));
    add(k, text("v", item[1], "Subheadline", V["text/secondary"]));
    add(conclusions, k);
  });
  spacer(conclusions);
  add(conclusions, text("hint", "注册需要 quality 档位；档位不支持时这里给出切换入口。",
    "Subheadline", V["text/tertiary"]));
  add(register, stretch(conclusions));
}

// --- 4. 音色库 ---------------------------------------------------------------
function screenVoiceLibrary(d) {
  pageHead(d, "音色库", "管理系统音色，以及用参考音频复刻出来的音色。");

  const filters = frame("filters", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  searchField(filters, "按名称或描述搜索", 300);
  segmented(filters, ["全部", "系统", "我的"], 0);
  spacer(filters);
  add(filters, text("count", "8 个音色 · 3 个来自复刻", "Callout", V["text/secondary"]));
  add(d, stretch(filters));

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  // Master list ------------------------------------------------------------
  const list = card(split, "list", { pad: 0, gap: 0, clip: true });
  grow(list);
  const listHead = frame("listHead", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 12 });
  add(listHead, text("title", "音色", "Heading / Section", V["text/primary"]));
  add(list, stretch(listHead));
  hairline(list);
  const voices = [
    { name: "夜航主持", badge: "系统", sub: "温暖、清晰、亲近", sel: true },
    { name: "书卷 · 温和叙述", badge: "系统", sub: "从容、偏慢，适合长篇叙述" },
    { name: "沙哑沉郁", badge: "我的", sub: "低沉、有颗粒感 · 用参考音频复刻" },
    { name: "少年清冽", badge: "系统", sub: "需要 Quality 档位的 VoiceDesign", unavailable: true },
    { name: "午后书场", badge: "我的", sub: "明亮、利落 · 用参考音频复刻" },
    { name: "晨间播报", badge: "系统", sub: "明亮、标准，适合资讯类口播" },
    { name: "纪录旁白", badge: "系统", sub: "沉稳、克制，适合纪录片解说" },
    { name: "远山低语", badge: "我的", sub: "气声、接近耳语 · 用描述生成" }
  ];
  voices.forEach(function (v) {
    const row = frame("row", { layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 12 });
    if (v.sel) bindFill(row, V["surface/railTint"]);
    const info = frame("info", { layout: "VERTICAL", gap: 2 });
    const titleRow = frame("titleRow", { layout: "HORIZONTAL", gap: 7, align: "CENTER" });
    add(titleRow, text("name", v.name, "Body / Medium", V["text/primary"]));
    // 来源徽标每一行都有（系统 / 我的）：应用的 sourceBadge 不做条件分支，
    // §7.3 也把「来源徽标」写成行内固定项。
    voiceBadge(titleRow, v.badge);
    add(info, titleRow);
    add(info, text("sub", v.sub, "Callout", V["text/secondary"]));
    add(row, info);
    spacer(row);
    // 不可用说明只在不可用的那一行出现，位置与写法照应用：行尾、图标 + 文字，
    // 不与可用行共享一个常驻胶囊（macOS App 设计系统 §4.2.3）。
    if (v.unavailable) {
      const warn = frame("warn", { layout: "HORIZONTAL", gap: 5, align: "CENTER" });
      icon(warn, "triangle-alert", 13, V["status/attention"]);
      add(warn, text("t", "当前档位不可用", "Caption", V["status/attention"]));
      add(row, warn);
    }
    iconButton(row, "play", 28);
    add(list, stretch(row));
    if (v !== voices[voices.length - 1]) hairline(list);
  });
  spacer(list);
  hairline(list);
  const listFoot = frame("listFoot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 12 });
  add(listFoot, text("note", "复刻音色保存在本机，不会上传。", "Subheadline", V["text/tertiary"]));
  spacer(listFoot);
  secondaryButton(listFoot, "新建音色", "sparkles");
  add(list, stretch(listFoot));

  // Inspector --------------------------------------------------------------
  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sideHead = frame("sideHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(sideHead, text("title", "夜航主持", "Title / Page", V["text/primary"]));
  add(sideHead, text("badge", "系统音色", "Caption", V["text/tertiary"]));
  add(side, stretch(sideHead));
  hairline(side);
  // A voice is an object you audition, so the inspector opens with the sound
  // itself instead of a wall of metadata.
  const previewWrap = frame("previewWrap", { layout: "VERTICAL", padX: 16, padY: 14 });
  const preview = frame("preview", {
    layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 12, padY: 10, radius: 10,
    fill: V["surface/panel"]
  });
  iconButton(preview, "play", 28);
  const wave = frame("wave", { layout: "HORIZONTAL", gap: 3, align: "CENTER", justify: "CENTER" });
  waveform(wave, [8, 16, 26, 12, 22, 9, 18, 30, 11, 15, 8, 20, 13, 24, 10, 17], V["accent/voice"], 3);
  add(preview, stretch(grow(wave)));
  add(previewWrap, stretch(preview));
  add(side, stretch(previewWrap));
  hairline(side);
  const sideBody = frame("sideBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
  // 取值行与应用 Inspector 同序同标签：变体与模式是两行，不合并
  // （macOS App 设计系统 §4.2.3）。
  [
    ["可用性", "可用"],
    ["采样种子", "101"],
    ["创建时间", "今天 12:04"],
    ["变体", "默认"],
    ["模式", "描述生成"],
    ["音频时长", "6.2 s"],
    ["使用次数", "12 个作品"],
    ["关联作品", "最近：雨夜独白"]
  ]
    .forEach(function (kv) { kvRow(sideBody, kv[0], kv[1]); });
  add(sideBody, text("label", "描述", "Caption / Medium", V["text/secondary"]));
  // 这一行量的是侧栏内宽，所以跟着 SESSION_SIDE_W 走：D7 之前列宽 300、文字 268
  // （= 300 − 16 × 2），列宽归一到 360 之后内宽是 328。
  add(sideBody, stretch(text("desc", "温暖、清晰、亲近，像一位深夜电台耐心的播客主持人。",
    "Callout", V["text/secondary"], { w: SESSION_SIDE_W - 32 })));
  add(side, stretch(sideBody));
  spacer(side);
  hairline(side);
  const acts = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
  secondaryButton(acts, "重命名");
  secondaryButton(acts, "编辑描述");
  secondaryButton(acts, "删除");
  spacer(acts);
  add(side, stretch(acts));
}

// --- 5. 我的作品 -------------------------------------------------------------
function screenWorks(d) {
  pageHead(d, "我的作品", "本机生成过的音频都留在这里，可随时播放、导出或删除。");

  const bar = frame("toolbar", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  // 排序控件是应用工具栏行左侧的第一个控件（WorkSortOrder），§7.4 也写着
  // 「按时间排序」。稿之前只画了搜索框，等于把这一页唯一的设置项漏掉了。
  segmented(bar, ["最新优先", "最早优先"], 0);
  searchField(bar, "按标题搜索", 300);
  spacer(bar);
  add(bar, text("count", "8 个作品 · 共 11:05", "Callout", V["text/secondary"]));
  add(d, stretch(bar));

  // The card hugs its rows: a growing list card pushed the footer to the window
  // edge and left a 300pt hole between the last row and the toolbar.
  const list = card(d, "list", { pad: 0, gap: 0, clip: true });

  // Column header, so the right-hand numbers and icons stop looking accidental.
  const cols = frame("cols", { layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 10 });
  add(cols, text("h1", "作品", "Caption / Medium", V["text/secondary"]));
  spacer(cols);
  const hDur = frame("cell", { layout: "HORIZONTAL", justify: "MAX" });
  size(hDur, 64, null);
  add(hDur, text("h2", "时长", "Caption / Medium", V["text/secondary"]));
  add(cols, hDur);
  const hAct = frame("cell", { layout: "HORIZONTAL", justify: "MAX" });
  size(hAct, 92, null);
  add(hAct, text("h3", "操作", "Caption / Medium", V["text/secondary"]));
  add(cols, hAct);
  add(list, stretch(cols));
  hairline(list);

  const works = [
    // 行内副行就是应用 workListSummary 的输出：系统格式的时间 + 音色名。稿上不写
    // 「24-bit 44.1 kHz」——服务的公开 PCM profile 是 24 kHz / 16-bit / 单声道，
    // 应用明确不写与实测不符的格式声明（ModelManagementView 同款判断）。
    { name: "星际航行", sub: "2026年9月15日 12:04 · 夜航主持", dur: "00:12", sel: true },
    { name: "雨夜独白", sub: "2026年9月14日 21:38 · 书卷", dur: "01:47" },
    { name: "开场白 v3", sub: "2026年9月13日 09:15 · 沙哑沉郁", dur: "00:26" },
    { name: "有声书试读", sub: "2026年9月12日 20:04 · 书卷", dur: "03:18" },
    { name: "产品短片旁白", sub: "2026年9月11日 15:42 · 夜航主持", dur: "00:48" },
    { name: "深夜电台片头", sub: "2026年9月9日 23:07 · 沙哑沉郁", dur: "00:09" },
    { name: "客服话术样本", sub: "2026年9月6日 11:26 · 夜航主持", dur: "02:31" },
    { name: "课程引言", sub: "2026年9月2日 08:53 · 晨间播报", dur: "01:54" }
  ];
  works.forEach(function (w) {
    const row = frame("row", { layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 12 });
    if (w.sel) bindFill(row, V["surface/railTint"]);
    const info = frame("info", { layout: "VERTICAL", gap: 2 });
    add(info, text("name", w.name, "Body / Medium", V["text/primary"]));
    add(info, text("sub", w.sub, "Callout", V["text/secondary"]));
    add(row, grow(info));
    const dur = frame("cell", { layout: "HORIZONTAL", justify: "MAX" });
    size(dur, 64, null);
    add(dur, text("dur", w.dur, "Callout", V["text/secondary"]));
    add(row, dur);
    const acts = frame("actions", { layout: "HORIZONTAL", gap: 4, justify: "MAX" });
    size(acts, 92, null);
    iconButton(acts, "play", 28);
    iconButton(acts, "download", 28);
    iconButton(acts, "ellipsis", 28);
    add(row, acts);
    add(list, stretch(row));
    if (w !== works[works.length - 1]) hairline(list);
  });
  hairline(list);
  const foot = frame("foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(foot, text("note", "导出快捷键 ⌘E。删除作品会同时移除本地音频文件。", "Subheadline", V["text/tertiary"]));
  spacer(foot);
  secondaryButton(foot, "新建配音", "audio-lines");
  add(list, stretch(foot));
}

// --- 6. 服务状态 -------------------------------------------------------------
function screenOverview(d) {
  pageHead(d, "服务状态", "本机语音引擎的当前结论与运行事实。");

  const conclusion = frame("conclusion", {
    layout: "HORIZONTAL", gap: 14, align: "CENTER", pad: 18, radius: 12,
    fill: V["surface/readyTint"], stroke: V["status/ready"], strokeWeight: 1
  });
  icon(conclusion, "circle-check", 26, V["status/ready"]);
  const textBox = frame("text", { layout: "VERTICAL", gap: 3 });
  add(textBox, text("title", "服务已就绪", "Title / Page", V["text/primary"]));
  add(textBox, text("sub", "本地语音服务正在 8201 端口运行；离线也有完整的识别与合成能力。", "Callout", V["text/secondary"], { w: 700 }));
  add(conclusion, grow(textBox));
  secondaryButton(conclusion, "打开诊断", "stethoscope");
  add(d, stretch(conclusion));

  const c = card(d, "capabilities", { pad: 0, gap: 0, clip: true });
  const cHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 18, padY: 16 });
  add(cHead, text("title", "能力", "Heading / Section", V["text/primary"]));
  // 这一行取自应用的原样输出（ServiceOverviewView.capabilitiesCard）：应用不写
  // 「Quality」这一档的名字，因为卡片在任何档位下都要成立。
  add(cHead, text("detail", "按当前运行档位如实发布，不做能力预支。", "Callout", V["text/secondary"]));
  add(c, stretch(cHead));
  hairline(c);
  // 行序与措辞对齐 REDESIGN-SPEC §7.5（ASR → TTS VoiceDesign / Base → 音色复刻 →
  // 实时 VAD → 分人）与 App 的 ServiceOverviewView.capabilities；稿上原先把最后
  // 两行接反了。
  const caps = [
    // 原因列逐字取自应用能力矩阵（ServiceOverviewView.capabilities）：这一列是运行时
    // 事实，不是设计文案，稿上的示例串必须能在应用里原样出现。
    ["语音识别", "Ready", "可用", "运行中；词级时间戳由 ASR 原生提供。"],
    ["语音合成 · VoiceDesign", "Ready", "可用", "服务已公开可用的 VoiceDesign capability。"],
    ["语音合成 · Base", "Ready", "可用", "运行中"],
    ["音色复刻", "Ready", "可用", "服务已公开可用的音色复刻 capability。"],
    ["实时语音 VAD", "Ready", "可用", "运行中"],
    ["分人识别", "Ready", "可用", "只输出本次会话的匿名标签；不管理实名或声纹库。"]
  ];
  caps.forEach(function (cap, i) {
    const row = frame("cap", { layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 18, padY: 12 });
    const name = frame("name", { layout: "HORIZONTAL" });
    add(name, text("label", cap[0], "Body / Medium", V["text/primary"]));
    size(name, 250, null);
    add(row, name);
    // Fixed pill column: without it every note starts at a different x and the
    // matrix stops reading as a matrix.
    const pillCell = frame("cell", { layout: "HORIZONTAL" });
    size(pillCell, 96, null);
    pill(pillCell, cap[1], cap[2]);
    add(row, pillCell);
    add(row, text("note", cap[3], "Callout", V["text/secondary"]));
    add(c, stretch(row));
    if (i < caps.length - 1) hairline(c);
  });

  // The facts the collapsed disclosure used to hide are the ones a status page
  // is opened for; printing them as plain rows fills the page and removes a
  // click. Everything below this line is still read-only information.
  const runtime = card(d, "runtime", { pad: 0, gap: 0, clip: true });
  const rHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 18, padY: 16 });
  add(rHead, text("title", "运行信息", "Heading / Section", V["text/primary"]));
  add(rHead, text("detail", "只反映本机当前取值；修改运行态一律走 profile 与 preflight。", "Callout", V["text/secondary"]));
  add(runtime, stretch(rHead));
  hairline(runtime);
  [
    // 取值行与应用同源：档位用「档位 · 取向」，端口用 host:port 原样，版本就是版本。
    // aligner 精度与 TTS lane 数属于模型页的档位卡，LaunchAgent 与 runtime 归属属于
    // 开发者详情，都不在这四行里重复。
    ["当前档位", "Quality · 创作优先"],
    ["服务端口", "127.0.0.1:8201"],
    ["运行版本", "0.4.0"],
    ["常驻 worker", "asr · tts-design · tts-base"]
  ].forEach(function (r, i) {
    const row = frame("infoRow", { layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 18, padY: 10 });
    const k = frame("kCell", { layout: "HORIZONTAL" });
    size(k, 120, null);
    add(k, text("k", r[0], "Body / Medium", V["text/primary"]));
    add(row, k);
    spacer(row);
    add(row, text("v", r[1], "Callout", V["text/secondary"]));
    add(runtime, stretch(row));
    if (i < 3) hairline(runtime);
  });
}

// --- 7. 运行监控 -------------------------------------------------------------
function screenMonitoring(d) {
  // 页首那句话与应用 `AppRoute.monitoring.pageSubtitle` 一致：先说这一页看什么，
  // 再提读取节奏（REDESIGN-SPEC §7.6 第六十三轮）。稿上原先的「最近 60 个样本 ·
  // 刷新间隔 5 秒」讲的是采样机制，没有一个字在说这一页看什么。
  pageHead(d, "运行监控", "服务最近在做什么、快不快、占多少内存；每 5 秒读一次本机服务。", function (row) {
    // 与 §7.6 / RuntimeMonitoringView.MonitoringTimeWindow 对齐：三档时间窗，
    // 默认停在 5 分钟（与应用默认值一致）。
    segmented(row, ["1 分钟", "5 分钟", "本次会话"], 1);
  });

  const c = card(d, "chart", { gap: 10 });
  // 应用侧这张卡的标题是「使用趋势」，副标题说明采样范围；图上只画并发那一张曲线，
  // 时延图是同一张卡里的第二张图（见 RuntimeMonitoringView.chartPanel）。
  const chHead = frame("head", { layout: "VERTICAL", gap: 3 });
  add(chHead, text("title", "使用趋势", "Heading / Section", V["text/primary"]));
  add(chHead, text(
    "detail",
    "同时处理的请求数；每 5 秒记录一次，只覆盖 App 打开期间。",
    "Callout",
    V["text/secondary"]
  ));
  add(c, stretch(chHead));
  // Drawn at the panel's real size: an SVG imported at a fixed height cannot be
  // stretched to fill a taller card without distorting the series.
  const chartSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="1124" height="300" viewBox="0 0 1124 300">' +
    '<line x1="56" y1="24" x2="1116" y2="24" stroke="#DCDCE0" stroke-width="1"/>' +
    '<line x1="56" y1="138" x2="1116" y2="138" stroke="#DCDCE0" stroke-width="1"/>' +
    '<line x1="56" y1="252" x2="1116" y2="252" stroke="#C6C6CB" stroke-width="1"/>' +
    '<polyline points="56,252 197,252 326,138 456,138 586,252 716,252 846,138 975,138 1116,252" fill="none" stroke="#2A4E57" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>' +
    '<polyline points="56,252 197,252 326,252 456,252 586,252 716,252 846,252 975,252 1116,252" fill="none" stroke="#A1A1A6" stroke-width="2" stroke-dasharray="5 5" stroke-linecap="round"/>' +
    '<text x="44" y="28" font-size="11" fill="#6E6E73" text-anchor="end">2</text>' +
    '<text x="44" y="142" font-size="11" fill="#6E6E73" text-anchor="end">1</text>' +
    '<text x="44" y="256" font-size="11" fill="#6E6E73" text-anchor="end">0</text>' +
    '<text x="56" y="282" font-size="11" fill="#6E6E73">-5 分钟</text>' +
    '<text x="1116" y="282" font-size="11" fill="#6E6E73" text-anchor="end">现在</text>' +
    '</svg>';
  const chartNode = figma.createNodeFromSvg(chartSvg);
  chartNode.name = "lineChart";
  add(c, chartNode);
  add(c, text("legend", "实线：实时语音会话 · 虚线：单次请求", "Subheadline", V["text/secondary"]));
  add(d, stretch(c));

  const table = card(d, "workers", { pad: 0, gap: 0, clip: true });
  grow(table);
  const tHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 18, padY: 16 });
  add(tHead, text("title", "运行组件", "Heading / Section", V["text/primary"]));
  add(tHead, text(
    "detail",
    "哪些模型现在留在内存里、哪些已经释放；空闲一段时间后会自动释放，下次使用再加载。",
    "Callout",
    V["text/secondary"]
  ));
  add(table, stretch(tHead));
  hairline(table);

  // Fixed columns plus one column that absorbs the remainder, so the header can
  // never be a couple of pixels narrower than its own content.
  // 两列够了：worker 生命周期（状态）在应用里就是这张表的全部内容，平均时延与
  // 样本数来自直方图摘要，是下面另一张表的字段（REDESIGN-SPEC §7.6）。
  const COLS = [380];
  const header = frame("header", { layout: "HORIZONTAL", gap: 0, padX: 18, padY: 9 });
  ["组件", "状态"].forEach(function (label, i) {
    const holder = frame("cell", { layout: "HORIZONTAL", justify: "MIN" });
    if (i === 0) size(holder, COLS[0], null); else grow(holder);
    add(holder, text("h", label, "Caption / Medium", V["text/secondary"]));
    add(header, holder);
  });
  add(table, stretch(header));
  hairline(table);
  const WORKERS = [
    ["语音识别", "运行中"],
    ["语音合成", "温待机"],
    ["实时语音", "已释放"]
  ];
  WORKERS.forEach(function (r, ri) {
    const row = frame("row", { layout: "HORIZONTAL", gap: 0, padX: 18, padY: 11 });
    r.forEach(function (value, i) {
      const holder = frame("cell", { layout: "HORIZONTAL", justify: "MIN" });
      if (i === 0) size(holder, COLS[0], null); else grow(holder);
      add(holder, text("v", value, "Callout", i === 0 ? V["text/primary"] : V["text/secondary"]));
      add(row, holder);
    });
    add(table, stretch(row));
    if (ri < WORKERS.length - 1) hairline(table);
  });
  hairline(table);
  const foot = frame("foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 18, padY: 12 });
  add(foot, text("note", "采样窗口 60 · 上次刷新 2 秒前", "Subheadline", V["text/tertiary"]));
  spacer(foot);
  secondaryButton(foot, "立即刷新", "refresh-cw");
  add(table, stretch(foot));
}

// --- 8. 模型 -----------------------------------------------------------------
function screenModels(d) {
  pageHead(d, "模型", "先下载并校验，再应用到运行档位；两者是独立操作。");

  const profiles = frame("profiles", { layout: "HORIZONTAL", gap: 12, align: "MIN" });
  add(d, stretch(profiles));
  [
    {
      // 卡片文案取自应用 ProfileChoiceCard：标题是「档位 · 取向」，副行是它的适用场景
      // 说明（profilePurpose），下面三行规格只列差异。
      name: "Light · 轻量快速", sub: "无 aligner、无分人；单个 TTS worker —— 更小的 ASR 组合，启动最快", sel: false,
      specs: [["分人", "不支持"], ["aligner", "无"], ["TTS lane", "1 个"]]
    },
    {
      name: "Balanced · 分人和日常", sub: "aligner-q8，可分人；单个 TTS worker —— 日常配音的平衡选择", sel: false,
      specs: [["分人", "支持"], ["aligner", "aligner-q8"], ["TTS lane", "1 个"]]
    },
    {
      name: "Quality · 创作优先", sub: "aligner-bf16，可分人；VoiceDesign 与 Base 双常驻，可跨 lane 并发 —— 适合音色创作", sel: true,
      specs: [["分人", "支持"], ["aligner", "aligner-bf16"], ["TTS lane", "2 个 · 跨 lane 并发"]]
    }
  ].forEach(function (p) {
    const c = frame("Profile Card", {
      layout: "VERTICAL", gap: 8, pad: 16, radius: 12,
      fill: p.sel ? V["surface/railTint"] : V["surface/content"],
      // Only the active profile carries a stroke: it encodes selection.
      stroke: p.sel ? V["accent/rail"] : null,
      strokeWeight: p.sel ? 1.5 : 1
    });
    const top = frame("top", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
    add(top, text("name", p.name, "Title / Page", V["text/primary"]));
    spacer(top);
    // "当前" as a pill instead of a heavy 2px outline: the outline read as an
    // error state rather than a selection.
    if (p.sel) pill(top, "Ready", "当前使用");
    add(c, stretch(top));
    add(c, text("sub", p.sub, "Callout", V["text/secondary"], { w: 320 }));
    // Three facts per card, so the choice is made on the difference that
    // matters (分人 / aligner / lane) instead of on the tier name.
    hairline(c);
    const spec = frame("spec", { layout: "VERTICAL", gap: 6 });
    p.specs.forEach(function (s) { kvRow(spec, s[0], s[1], 76); });
    add(c, stretch(spec));
    add(profiles, stretch(grow(c)));
  });

  const actions = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  primaryButton(actions, "下载并校验", "download", 148);
  secondaryButton(actions, "应用此档位");
  spacer(actions);
  // 应用报的是「模型已用」而不是整盘已用：这一行只在准备模型前回答「有没有地方放」。
  add(actions, text("disk", "磁盘：模型已用 6.4 GB · 可用 182 GB", "Callout", V["text/secondary"]));
  add(d, stretch(actions));

  const table = card(d, "artifacts", { pad: 0, gap: 0, clip: true });
  const aHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 18, padY: 16 });
  add(aHead, text("title", "模型制品", "Heading / Section", V["text/primary"]));
  add(aHead, text("detail", "只显示脱敏的制品 key、量化与校验状态，不显示本地路径。", "Callout", V["text/secondary"]));
  add(table, stretch(aHead));
  hairline(table);

  const COLS = [440, 200, 140];
  const header = frame("header", { layout: "HORIZONTAL", gap: 0, padX: 18, padY: 9 });
  ["制品", "量化", "文件", "校验"].forEach(function (label, i) {
    const holder = frame("cell", { layout: "HORIZONTAL", justify: i >= 2 ? "MAX" : "MIN" });
    if (i === 3) grow(holder); else size(holder, COLS[i], null);
    add(holder, text("h", label, "Caption / Medium", V["text/secondary"]));
    add(header, holder);
  });
  add(table, stretch(header));
  hairline(table);
  [
    // 校验列逐字取自应用 ArtifactChoiceRow 的 statusPresentation.title：
    // 这一列是运行时事实，稿上的示例串必须能在应用里原样出现。
    ["asr", "8-bit", "12", "已验证", "status/ready"],
    ["tts-1.7b-design", "8-bit", "9", "已验证", "status/ready"],
    ["tts-1.7b-base", "8-bit", "9", "已验证", "status/ready"],
    ["aligner-bf16", "bf16", "4", "已验证", "status/ready"],
    ["diarization-coreml", "fp16", "6", "未下载", "status/attention"]
  ].forEach(function (r, ri) {
    const row = frame("row", { layout: "HORIZONTAL", gap: 0, padX: 18, padY: 11 });
    [r[0], r[1], r[2], r[3]].forEach(function (value, i) {
      const holder = frame("cell", { layout: "HORIZONTAL", justify: i >= 2 ? "MAX" : "MIN" });
      if (i === 3) grow(holder); else size(holder, COLS[i], null);
      add(holder, text("v", value, "Callout", i === 3 ? V[r[4]] : V["text/primary"]));
      add(row, holder);
    });
    add(table, stretch(row));
    if (ri < 4) hairline(table);
  });
  hairline(table);
  const foot = frame("foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 18, padY: 12 });
  add(foot, text("note", "5 个制品 · 1 个待校验，分人能力在补齐前不可用。", "Subheadline", V["text/tertiary"]));
  spacer(foot);
  secondaryButton(foot, "仅校验缺失项", "refresh-cw");
  add(table, stretch(foot));
}

// --- 9. 诊断 -----------------------------------------------------------------
function screenDiagnostics(d) {
  pageHead(d, "诊断", "本机自检结论与可执行的修复动作。", function (row) {
    secondaryButton(row, "重新运行预检", "refresh-cw");
  });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16, align: "MIN" });
  add(d, stretch(grow(split)));

  const list = card(split, "checks", { pad: 0, gap: 0, clip: true });
  grow(list);
  const lHead = frame("listHead", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 12 });
  add(lHead, text("title", "检查项", "Heading / Section", V["text/primary"]));
  spacer(lHead);
  add(lHead, text("note", "1 项需要处理", "Caption", V["status/attention"]));
  add(list, stretch(lHead));
  hairline(list);
  [
    // 检查项名称与副标题逐字取自应用：名称来自 PreflightDiagnosticsView.checkTitle，
    // 副标题来自 explanation(for:)。稿上不能出现应用里不存在的检查项。
    { tone: "Ready", icon: "check", ink: "status/ready", title: "应用目录", sub: "确认 SpeechRail 的本机应用目录可访问。" },
    { tone: "Ready", icon: "check", ink: "status/ready", title: "配置文件", sub: "确认服务配置文件存在且可以被受管 runtime 读取。" },
    { tone: "Ready", icon: "check", ink: "status/ready", title: "音频编解码", sub: "确认音频编解码依赖可用，上传和输出流程能够正常工作。" },
    { tone: "Ready", icon: "check", ink: "status/ready", title: "运行设置", sub: "确认当前 profile 和运行参数可以被服务读取。" },
    { tone: "Ready", icon: "check", ink: "status/ready", title: "ASR 制品", sub: "确认语音识别能力的配置、制品和运行状态满足启动条件。" },
    { tone: "Ready", icon: "check", ink: "status/ready", title: "TTS 制品", sub: "确认语音合成能力的配置、制品和运行状态满足启动条件。" },
    { tone: "Attention", icon: "triangle-alert", ink: "status/attention", title: "分人对齐制品", sub: "确认分人对齐制品满足 SpeechRail 服务运行的前置条件。", cur: true },
    { tone: "Ready", icon: "check", ink: "status/ready", title: "实时语音检测", sub: "确认实时语音检测满足 SpeechRail 服务运行的前置条件。" }
  ].forEach(function (item, i) {
    const row = frame("diagRow", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
    if (item.cur) bindFill(row, V["surface/railTint"]);
    icon(row, item.icon, 16, V[item.ink]);
    const info = frame("info", { layout: "VERTICAL", gap: 2 });
    add(info, text("title", item.title, "Body / Medium", V["text/primary"]));
    add(info, text("sub", item.sub, "Callout", V["text/secondary"]));
    add(row, grow(info));
    icon(row, "chevron-right", 14, V["text/tertiary"]);
    add(list, stretch(row));
    hairline(list);
  });
  spacer(list);
  hairline(list);
  const lFoot = frame("listFoot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 12 });
  add(lFoot, text("note", "上次预检 2 分钟前 · 共 8 项", "Subheadline", V["text/tertiary"]));
  spacer(lFoot);
  secondaryButton(lFoot, "复制诊断报告", "copy");
  add(list, stretch(lFoot));

  // Detail -----------------------------------------------------------------
  const side = card(split, "detail", { pad: 0, gap: 0, clip: true });
  size(side, 340, null);
  add(split, stretch(side));
  const sHead = frame("sideHead", { layout: "VERTICAL", gap: 8, padX: 18, padY: 18 });
  const pillRow = frame("pillRow", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  pill(pillRow, "Attention", "需要处理");
  spacer(pillRow);
  add(pillRow, text("when", "刚刚", "Caption", V["text/tertiary"]));
  add(sHead, stretch(pillRow));
  add(sHead, text("title", "分人对齐制品", "Title / Page", V["text/primary"]));
  // 影响句取自应用 PreflightDiagnosticsView.impact(for:)：这一行说的是后果，不是重复结论。
  add(sHead, text(
    "body",
    "相关模型或语音能力无法被证明可用；继续启动可能导致对应请求返回未就绪。",
    "Callout",
    V["text/secondary"],
    { w: 288 }
  ));
  const fix = frame("fix", { layout: "HORIZONTAL" });
  primaryButton(fix, "打开模型管理", "download", 268);
  add(sHead, fix);
  add(side, stretch(sHead));
  hairline(side);
  const sBody = frame("sideBody", { layout: "VERTICAL", gap: 10, padX: 18, padY: 16 });
  const disc = frame("disclosure", { layout: "HORIZONTAL", gap: 7, align: "CENTER" });
  icon(disc, "chevron-right", 14, V["text/secondary"]);
  add(disc, text("label", "开发者详情", "Callout", V["text/secondary"]));
  add(sBody, stretch(disc));
  const code = frame("codeBox", {
    layout: "VERTICAL", gap: 4, pad: 10, radius: 8,
    fill: V["surface/panel"]
  });
  // 字段与脱敏口径对齐应用：这一块只放标识、脱敏结果与当时的运行态，不放本地路径。
  add(code, text("k", "检查标识         diarization_aligner_snapshot", "Caption", V["text/secondary"], { w: 264 }));
  add(code, text("k", "安全技术结果     已通过脱敏", "Caption", V["text/secondary"], { w: 264 }));
  add(code, text("k", "结果            失败", "Caption", V["text/secondary"], { w: 264 }));
  add(sBody, stretch(code));
  // The card is the tallest thing on the page, so it carries the repair route
  // rather than trailing off after the error code.
  add(sBody, text("label", "修复步骤", "Heading / Section", V["text/primary"]));
  [
    "打开模型管理，确认目标档位需要的制品都已登记。",
    "运行「下载并校验」，直到每项的存在状态与校验状态都通过。",
    "回到本页重新运行预检，确认这一项已经通过。"
  ].forEach(function (step, i) {
    const row = frame("step", { layout: "HORIZONTAL", gap: 8, align: "MIN" });
    const num = frame("num", { layout: "HORIZONTAL", align: "CENTER", justify: "CENTER", radius: 999 });
    size(num, 18, 18);
    bindFill(num, V["surface/panel"]);
    add(num, text("n", String(i + 1), "Caption / Medium", V["text/secondary"]));
    add(row, num);
    add(row, text("t", step, "Callout", V["text/secondary"], { w: 262 }));
    add(sBody, stretch(row));
  });
  add(side, stretch(sBody));
  spacer(side);
}

// --- 10. 开发者文档 ----------------------------------------------------------
// 接入方要的三件事按顺序摆：地址与鉴权 → 例子 → 接口与故障。主题列表本身是目录，
// 右栏一次只展开一个主题（渐进式披露）：文档页最忌讳的是一屏接一屏的正文。
// 对象形式而不是数组元组：图标名带 `icon:` 键，静态自检才扫得到它（数组里第 3 位
// 的字符串对 audit.js 是不可见的，等于静默失去覆盖）。
const DOC_TOPICS = [
  { title: "快速开始", desc: "改 base_url 就能用的最小示例", icon: "play" },
  { title: "接口一览", desc: "REST 与 WebSocket 的入口与用途", icon: "server" },
  { title: "实时语音", desc: "全双工流式 ASR/TTS 的协议子集", icon: "activity" },
  { title: "音色与克隆", desc: "系统音色、声音设计、参考录音注册", icon: "sparkles" },
  { title: "分档能力对照", desc: "light / balanced / quality 的差异", icon: "sliders-horizontal" },
  { title: "MCP 接入", desc: "给 Agent 的 stdio 与 streamable-http", icon: "package" },
  { title: "错误与排查", desc: "统一错误信封与常见码的下一步", icon: "triangle-alert" },
  { title: "安全与部署", desc: "回环默认、密钥与日志脱敏", icon: "shield-check" }
];

// 接口表的一行：方法 / 路径 / 用途。三列固定，值再长也不推着邻居漂移。
function endpointRow(parent, method, path, detail) {
  const row = frame("endpoint", { layout: "HORIZONTAL", gap: 12, align: "CENTER" });
  const methodCell = frame("methodCell", { layout: "HORIZONTAL" });
  size(methodCell, 42, null);
  add(methodCell, text("method", method, "Caption / Medium", V["accent/rail"]));
  add(row, methodCell);
  const pathCell = frame("pathCell", { layout: "HORIZONTAL" });
  size(pathCell, 250, null);
  add(pathCell, text("path", path, "Callout", V["text/primary"]));
  add(row, pathCell);
  add(row, text("detail", detail, "Callout", V["text/secondary"], { w: 440 }));
  return add(parent, stretch(row));
}

// 代码块：一行语言标签 + 复制按钮，下面是原始行。稿用 Inter，生产映射到系统等宽
// 字体（REDESIGN-SPEC §12.4 决定 16）。
function codeBlock(parent, language, lines) {
  const block = frame("Code Block", {
    layout: "VERTICAL", gap: 8, padX: 14, padY: 12, radius: 8,
    fill: V["surface/panel"], stroke: V["border/separator"], strokeWeight: 1
  });
  const head = frame("codeHead", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  add(head, text("lang", language, "Caption / Medium", V["text/tertiary"]));
  spacer(head);
  iconButton(head, "copy", 24);
  add(block, stretch(head));
  lines.forEach(function (line) {
    add(block, text("line", line, "Callout", V["text/primary"], { w: 720 }));
  });
  return add(parent, stretch(block));
}

function screenDeveloperDocs(d) {
  pageHead(d, "开发者文档", "把本机语音能力接入你的应用：地址、接口、示例与排查。",
    function (row) {
      secondaryButton(row, "复制接入信息", "copy");
    });

  // 接入信息 ---------------------------------------------------------------
  const access = card(d, "accessCard", { gap: 12, padY: 14 });
  const facts = frame("facts", { layout: "HORIZONTAL", gap: 24, align: "MIN" });
  [
    ["服务地址", "http://127.0.0.1:8201"],
    ["鉴权", "回环免密钥；非回环需 Bearer"],
    ["运行档位", "Quality"],
    ["发布的能力", "识别 · 合成 · 匿名分人 · 声音复刻"]
  ].forEach(function (fact) {
    const col = frame("fact", { layout: "VERTICAL", gap: 3 });
    add(col, text("k", fact[0], "Caption / Medium", V["text/tertiary"]));
    add(col, text("v", fact[1], "Body", V["text/primary"]));
    add(facts, col);
  });
  add(access, stretch(facts));

  const accessNote = frame("accessNote", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
  icon(accessNote, "info", 13, V["text/secondary"]);
  add(accessNote, text("label",
    "这里的档位与能力来自当前服务的真实声明；换档后回到本页即可看到新的能力集合。",
    "Subheadline", V["text/secondary"]));
  add(access, stretch(accessNote));

  // 主题目录 + 正文 ---------------------------------------------------------
  const docs = card(d, "docsCard", { gap: 0, pad: 0, layout: "HORIZONTAL" });
  // 文档卡吃满剩余高度：这是唯一一页「读」的界面，让它像窗口里的一个面板，
  // 而不是内容结束后空半屏。
  grow(docs);
  const topics = frame("topics", { layout: "VERTICAL", gap: 2, padX: 12, padY: 14 });
  size(topics, SESSION_LIST_W, null);
  DOC_TOPICS.forEach(function (topic, i) {
    const selected = i === 0;
    const row = frame("Doc Topic Row", {
      layout: "VERTICAL", gap: 2, padX: 10, padY: 8, radius: 8
    });
    if (selected) bindFill(row, V["surface/railTint"]);
    const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
    icon(head, topic.icon, 15, selected ? V["accent/rail"] : V["text/secondary"]);
    add(head, text("title", topic.title, "Body / Medium", V["text/primary"]));
    add(row, stretch(head));
    const desc = text("desc", topic.desc, "Subheadline", V["text/secondary"], { w: 230 });
    add(row, desc);
    add(topics, stretch(row));
  });
  add(docs, stretch(topics));
  stretch(rect(docs, "topicsDivider", 1, 100, V["border/separator"]));

  const body = frame("docBody", { layout: "VERTICAL", gap: 14, padX: 20, padY: 18 });
  grow(body);
  add(docs, stretch(body));

  const topicHead = frame("topicHead", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  add(topicHead, text("title", "快速开始", "Title / Page", V["text/primary"]));
  pill(topicHead, "Ready", "已按当前档位核对");
  add(body, stretch(topicHead));
  add(body, text("lead",
    "服务默认只监听回环地址。任何 OpenAI 兼容客户端把 base_url 指到本机端口即可接入，" +
    "不需要改模型名，也不需要感知 worker 的加载与回收。",
    "Body", V["text/secondary"], { w: 740 }));

  codeBlock(body, "Python · OpenAI SDK", [
    "from openai import OpenAI",
    "",
    "client = OpenAI(base_url=\"http://127.0.0.1:8201/v1\",",
    "                api_key=\"not-needed-for-loopback\")",
    "",
    "with open(\"meeting.wav\", \"rb\") as audio:",
    "    print(client.audio.transcriptions.create(",
    "        model=\"whisper-1\", file=audio).text)"
  ]);

  const endpoints = frame("endpoints", { layout: "VERTICAL", gap: 7 });
  add(endpoints, text("label", "先认这四个入口", "Heading / Section", V["text/primary"]));
  endpointRow(endpoints, "POST", "/v1/audio/transcriptions", "上传音频，拿回文本与可选词级时间戳");
  endpointRow(endpoints, "POST", "/v1/audio/speech", "输入文本，拿回 wav 音频");
  endpointRow(endpoints, "GET", "/v1/voices", "列出系统音色与已保存音色");
  endpointRow(endpoints, "POST", "/v1/voices/clone", "用参考录音注册音色（需要 quality 档）");
  endpointRow(endpoints, "WS", "/v1/realtime", "全双工流式识别与合成");
  add(body, stretch(endpoints));
  add(body, text("footnote",
    "完整契约以仓库里的 contracts/openapi.yaml、contracts/realtime-openai.md 与 docs/users/ 为准。",
    "Subheadline", V["text/tertiary"], { w: 740 }));
}

// --- 11. 语音助手 -------------------------------------------------------------
//
// 这一页回答四件事：机器在听吗、它正在干什么、刚才那句说了什么、下一句怎么说。
// 大模型是**服务之外**的依赖（SESSIONS-SPEC §4 P7），所以「未配置」是本模块的一等状态，
// 不是错误对话框。
function screenAssistant(d, o) {
  // `o.collapsed` 是「本次对话」右栏收起后的同一屏（用户 2026-09-18）。收起不是另画一屏，
  // 而是这个面板的另一个状态：那一栏 360pt 全归主框体，对话行按新宽度重排，
  // 状态带与结论条原地不动——「不看面板也不会做错事」是收起的前提，
  // 规则与清单见 `closurePanelRulesBoard`。
  const collapsed = !!(o && o.collapsed);
  pageHead(d, "语音助手", "和它一来一往：说也行，打字也行；对话只留在这台 Mac 上。",
    function (row) {
      kbdInRow(row, "⌘⇧.", 34);
      // 「换人设」不能出现在这一页的动作里（用户 2026-09-17：会话开始后不允许换人设）。
      // 页头这个入口通向对比板，而不是直接换：先说清代价，再决定换哪个。
      secondaryButton(row, "音色与风格", "sliders-horizontal");
      primaryButton(row, "结束对话", "square", 118);
      sideToggle(row, "本次对话");
    });

  sessionStatusBar(d, {
    tone: "ready", phase: "正在说话", title: "第 12 轮 · 一问一答（外放）",
    time: "00:03:42", level: 0.72, facts: ["大模型 qwen3-30b · 已连接"],
    // 静音只在下面合成器那一行给一处：状态带是状态，不是第二个控制区
    // （2026-09-18 第七轮：同一个动作在一屏画两遍，用户与实现者都要猜点哪个）。
    actions: []
  });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const stream = card(split, "stream", { pad: 0, gap: 0, clip: true });
  grow(stream);
  const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(head, text("title", "对话", "Heading / Section", V["text/primary"]));
  spacer(head);
  add(head, text("mem", "已记住 12 轮 · 余量 38%", "Callout", V["text/secondary"]));
  add(stream, stretch(head));
  hairline(stream);
  [
    { who: "你", time: "14:02:11", text: "今天这场分享的开头有点长，能不能压到三句话？",
      actions: ["play", "copy"] },
    { who: "助手", accent: true, badge: "夜航主持", time: "14:02:16",
      text: "可以。三句话的版本是：我们做的是一个本机语音引擎；它把语音变成文字，也把文字变成声音；" +
        "整个过程不出这台 Mac。", actions: ["play", "copy"] },
    { who: "你", time: "14:02:31", text: "第二句再短一点。" },
    { who: "助手", accent: true, badge: "夜航主持", time: "14:02:35",
      text: "好的：语音进来，文字和声音出去，全程离线。", actions: ["play", "copy"] },
    { who: "你", time: "14:03:40", partial: true, text: "那如果我想让它记住上一场会议的结论……" }
  ].forEach(function (t) {
    turnRow(stream, {
      who: t.who, accent: t.accent, badge: t.badge, time: t.time, text: t.text,
      partial: t.partial, actions: t.actions, width: collapsed ? 1128 : 760
    });
  });
  spacer(stream);
  hairline(stream);
  const streamFoot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(streamFoot, text("note",
    "对话记录只在这台 Mac 上；带多少上下文由设置里那一项控制，服务侧不存对话。",
    "Subheadline", V["text/tertiary"]));
  add(stream, stretch(streamFoot));

  if (!collapsed) {
  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sideHead = frame("sideHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(sideHead, text("title", "本次会话", "Title / Page", V["text/primary"]));
  add(sideHead, text("badge", "语音助手 · 进行中", "Caption", V["text/tertiary"]));
  add(side, stretch(sideHead));
  hairline(side);
  const sideBody = frame("sideBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
  [
    ["大模型", "已连接 · qwen3-30b"],
    ["音色", "夜航主持 · 下一句可换"],
    ["人设", "耐心讲解 · 本轮已定"],
    ["打断", "实时对讲时生效"],
    ["上下文", "12 轮"],
    ["输入", "语音或打字"],
    ["麦克风", "MacBook 麦克风"]
  ].forEach(function (kv) { kvRow(sideBody, kv[0], kv[1]); });
  add(sideBody, text("label", "打字提问时为什么不朗读", "Caption / Medium", V["text/secondary"]));
  add(sideBody, text("desc",
    "「我在打字」通常说明我在静音场景：回复只出现在这里，点一下播放按钮才会读出来。" +
      "想边听边说，切到实时对讲（耳机）。",
    "Subheadline", V["text/secondary"], { w: 308 }));
  add(side, stretch(sideBody));
  spacer(side);
  hairline(side);
  const sideActs = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
  secondaryButton(sideActs, "换音色", "audio-waveform");
  spacer(sideActs);
  secondaryButton(sideActs, "新开一轮以换人设", "plus");
  add(side, stretch(sideActs));
  }

  const controls = card(d, "controls", {
    layout: "VERTICAL", gap: 10, padX: 16, padY: 12
  });

  // 第一行是**输入**。语音是默认，但打字是一条随时可用的替代路径（用户 2026-09-18）：
  // 麦克风被占、环境吵、只是想安静问一句，都不该逼人换工具。打字提问时不朗读回复——
  // 「我在打字」本身就说明我在静音场景；每一条回复仍然可以点播放按钮听。
  const compose = frame("compose", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  const askField = frame("Text Field", {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 12, padY: 9, radius: 8,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
  });
  add(askField, text("placeholder", "输入消息（↵ 发送 · 静音不外放）…", "Body", V["text/tertiary"]));
  add(compose, stretch(grow(askField)));
  iconButton(compose, "pencil", 28);
  primaryButton(compose, "发送", "message-circle", 96).opacity = 0.45;
  add(controls, stretch(compose));

  const controlsRow = frame("row", { layout: "HORIZONTAL", gap: 12, align: "CENTER" });
  secondaryButton(controlsRow, "静音麦克风", "mic-off");
  // 2026-09-17 收口：这一行只有「对讲模式」一条分段控件。原来的「免持 / 按住说话」
  // 与 Inspector 的「允许插话打断」开关都被它取代——模式本身就是打断开关（SESSIONS-SPEC §14.5）。
  segmented(controlsRow, ["一问一答（外放）", "实时对讲（耳机）"], 0,
    ["seg/一问一答（外放）", "seg/实时对讲（耳机）"]);
  spacer(controlsRow);
  add(controlsRow, text("k2", "音色", "Callout", V["text/secondary"]));
  const capsule = frame("voiceCapsule", {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 10, padY: 4, radius: 999,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
  });
  icon(capsule, "audio-waveform", 15, V["accent/voice"]);
  add(capsule, text("name", "夜航主持", "Body / Medium", V["text/primary"]));
  icon(capsule, "chevron-down", 14, V["text/secondary"]);
  add(controlsRow, capsule);
  add(controls, stretch(controlsRow));
}

// --- A7. 语音助手 · 对话页 · 对话中（本次对话收起） -------------------------------
//
// 用户 2026-09-18：「本次对话」面板需要可收起，举一反三，其他非主框体也通用要求。
// 收起不是「少了一个面板」，而是同一个面板的另一个状态——所以它不是另画一屏，而是
// `screenAssistant` 的另一个状态：右栏那 360pt 全归主框体，对话行按新宽度重排；
// 状态带里「这一轮怎么进行的」仍在原地（收起的前提是不看面板也不会做错事）。
// 判据与清单见「非主框体 · 收起规则（通用）」那一块板。
function screenClosureAssistantCollapsed(d) {
  return screenAssistant(d, { collapsed: true });
}

// --- 12. 语音助手 · 未配置对话模型 ---------------------------------------------
function screenAssistantBlocked(d) {
  pageHead(d, "语音助手", "和本机大模型用语音一来一往；转录与对话只留在这台 Mac 上。",
    function (row) {
      secondaryButton(row, "设置 · 会话", "sliders-horizontal");
      sideToggle(row, "本次对话");
    });

  conclusionBand(d, {
    tone: "Attention",
    title: "还没有配置对话模型",
    body: "语音识别和语音合成现在就能用；助手需要一台兼容 OpenAI 的服务：" +
      "把地址、模型与密钥填进设置即可，地址是本机还是局域网都行。",
    hint: "对接要求只有一条：服务要实现 Responses API（只支持 Chat Completions 的服务接不上）。" +
      "密钥只存钥匙串，不写进配置文件，也不出现在日志或导出物里。",
    actions: [["打开设置…", "sliders-horizontal", "primary"], ["了解如何配置", "book-open"]]
  });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const caps = card(split, "caps", { pad: 0, gap: 0, clip: true });
  grow(caps);
  const capsHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 16, padY: 14 });
  add(capsHead, text("title", "本机能做什么", "Heading / Section", V["text/primary"]));
  add(capsHead, text("detail", "按当前运行档位如实发布；不做能力预支。", "Callout", V["text/secondary"]));
  add(caps, stretch(capsHead));
  hairline(caps);
  [
    ["语音识别", "Ready", "可用", "实时字幕与会议转录都靠它，现在就能用。"],
    ["语音合成", "Ready", "可用", "助手说话用它；音色可以在设置里换。"],
    ["分人识别", "Ready", "可用", "只输出本次会话的匿名标签；不管理实名或声纹库。"],
    ["对话模型", "Off", "未配置", "填一个兼容 OpenAI、且支持 Responses API 的服务地址与模型。"]
  ].forEach(function (cap, i, all) {
    const row = frame("cap", { layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 12 });
    const name = frame("name", { layout: "HORIZONTAL" });
    add(name, text("label", cap[0], "Body / Medium", V["text/primary"]));
    size(name, 140, null);
    add(row, name);
    const cell = frame("cell", { layout: "HORIZONTAL" });
    size(cell, 88, null);
    pill(cell, cap[1], cap[2]);
    add(row, cell);
    // 496, not 520：这一行的可用宽 = 卡片 783 − padX 16×2 − 名字格 140 − 胶囊格 88 − gap 12×2
    // = 499。520 会让 note 越出 5px（实测 `detail ▸ cap ▸ note +5R [520 in 783]`）。
    add(row, text("note", cap[3], "Callout", V["text/secondary"], { w: 496 }));
    add(caps, stretch(row));
    if (i < all.length - 1) hairline(caps);
  });
  spacer(caps);
  hairline(caps);
  const capsFoot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(capsFoot, text("note", "设置里改完不用重启：连接检查会立刻给出结论。",
    "Subheadline", V["text/tertiary"]));
  add(caps, stretch(capsFoot));

  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sideHead = frame("sideHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(sideHead, text("title", "本次会话", "Title / Page", V["text/primary"]));
  add(sideHead, text("badge", "还不能开始", "Caption", V["text/tertiary"]));
  add(side, stretch(sideHead));
  hairline(side);
  const sideBody = frame("sideBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
  [
    ["大模型", "未配置"],
    ["服务地址", "—"],
    ["密钥", "—"],
    ["音色", "夜航主持"],
    ["人设", "耐心讲解"],
    ["采集设备", "MacBook 麦克风"]
  ].forEach(function (kv) { kvRow(sideBody, kv[0], kv[1]); });
  add(sideBody, text("label", "配好之后", "Caption / Medium", V["text/secondary"]));
  add(sideBody, text("desc",
    "这里会显示模型名、连接延迟与记忆轮数；对话本身从第一轮开始记，之前的不用补。",
    "Subheadline", V["text/secondary"], { w: 308 }));
  add(side, stretch(sideBody));
  spacer(side);
  hairline(side);
  const sideActs = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
  secondaryButton(sideActs, "检查连接", "refresh-cw");
  spacer(sideActs);
  add(side, stretch(sideActs));

  const controls = card(d, "controls", {
    layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 12
  });
  controls.opacity = 0.45;
  secondaryButton(controls, "开始对话", "mic");
  // 受阻态画的是同一行控件被禁用（整卡 0.45 不透明度），所以模式名与可用态一致。
  segmented(controls, ["一问一答（外放）", "实时对讲（耳机）"], 0,
    ["seg/一问一答（外放）", "seg/实时对讲（耳机）"]);
  spacer(controls);
  add(controls, text("hint", "配好对话模型后这里会亮起来。", "Subheadline", V["text/tertiary"]));
}

// --- 13. 会议助手 · 录制中 -----------------------------------------------------
//
// 转录是主体、会议信息在右、内心 OS 贴底收起一行。三块各就各位之后，会中最常做的三件事
// （看刚才那句、确认谁在说、问一句私密的）都不需要换页。
function screenMeetingRecording(d) {
  meetingShell(d, {
    headActions: function (row) {
      kbdInRow(row, "⌘⇧.", 34);
      secondaryButton(row, "静音麦克风", "mic-off");
      primaryButton(row, "结束会议", "square", 118);
    },
      status: {
        tone: "attention", phase: "正在录音", title: "周会 · 本机音频 + 麦克风",
        time: "00:12:40", level: 0.52,
        facts: ["3 位说话人 · 已标出", "148 段已存好"],
        actions: [["内心 OS", "sparkles"]]
      },
    transcript: function (stream) {
      const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
      add(head, text("title", "转录", "Heading / Section", V["text/primary"]));
      spacer(head);
      add(head, text("detail", "麦克风 + 腾讯会议 · 每行标来源", "Callout", V["text/secondary"]));
      // 会中人工标注的入口必须看得见（用户 2026-09-18：「讲话人支持会中和会后人工标注」）：
      // 点说话人标签就能改名或合并，这个按钮是同一件事的第二条路径——会中不想找标签时，
      // 从这里进。会后那一套更重的批处理在 screenMeetingMinutes 的右栏。
      secondaryButton(head, "标注说话人", "users");
      add(stream, stretch(head));
      hairline(stream);
      [
        { who: "说话人 A", src: "本机音频", time: "00:12:22",
          text: "那我先按这个排期，等一下再确认一下名字。" },
        { who: "说话人 B", src: "麦克风", time: "00:12:31", text: "好，先把这段记下来。" },
        { who: "说话人 A", src: "本机音频", time: "00:12:36",
          text: "我们这边按 8 月 22 日交付，测试前一天拿到就行。" },
        { who: "说话人 C", src: "本机音频", time: "00:12:40",
          text: "对，那天前给到测试，我这边留两天回归。", partial: true }
      ].forEach(function (t) {
        turnRow(stream, {
          who: t.who, src: t.src, time: t.time, text: t.text, partial: t.partial, width: 600
        });
      });
      spacer(stream);
      hairline(stream);
      const foot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
      add(foot, text("note", "点说话人标签就能改名或合并——会中会后都可以，正文一个字不会动。",
        "Subheadline", V["text/tertiary"], { w: 640 }));
      add(stream, stretch(foot));
    },
    side: function (side) {
      meetingInfoSide(side, {
        badge: "录制中 · 还没存好",
        rows: [
          ["时长", "00:12:40"],
            ["转录", "148 段"],
            ["说话人", "3 位 · 自动编号"],
            ["音频来源", "麦克风 + 腾讯会议"],
            ["说话人标签", "已开 · 最多 4 位"],
            ["保存位置", "记录库"],
            ["整理", "结束后自动开始"]
          ],
          noteLabel: "这一段还没结束",
          noteBody: "结束时会等最后半句也标好说话人再存好（末段不丢）；整理失败也不会把转录弄丢。"
        });
    },
    drawer: function (page) { meetingOSBar(page); }
  });
}

// --- 14. 会议助手 · 会后纪要 ---------------------------------------------------
//
// 会中与会后是同一件事的两种节奏：会中点一下就改；会后可以批量、可以合并、可以拆分。
// 所以「说话人」这一栏在会后比会中重——它是用户把匿名标签变成真人的唯一入口。
  function screenMeetingMinutes(d) {
    meetingShell(d, {
      subtitle: "会后：核对说话人、看纪要、导出。这一段永远留在记录库里。",
    headActions: function (row) {
      secondaryButton(row, "导出…", "download");
      primaryButton(row, "重新生成纪要", "refresh-cw", 148);
    },
    status: {
      tone: "ready", phase: "已归档", title: "周会 · 本机音频 + 麦克风",
      time: "00:12:40", level: 0.02,
      facts: ["3 位说话人 · 已标注", "纪要 2 个版本"], actions: []
    },
    transcript: function (stream) {
      const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
      add(head, text("title", "转录", "Heading / Section", V["text/primary"]));
      spacer(head);
      segmented(head, ["纪要", "转录"], 1, ["seg/纪要", "seg/转录"]);
      add(stream, stretch(head));
      hairline(stream);
      [
        { who: "张工", src: "本机音频", time: "00:12:22",
          text: "那我先按这个排期，等一下再确认一下名字。" },
        { who: "我", src: "麦克风", time: "00:12:31", text: "好，先把这段记下来。" },
        { who: "张工", src: "本机音频", time: "00:12:36",
          text: "我们这边按 8 月 22 日交付，测试前一天拿到就行。" },
        { who: "未命名 C", src: "本机音频", time: "00:12:40",
          text: "对，那天前给到测试，我这边留两天回归。" }
      ].forEach(function (t) {
        turnRow(stream, { who: t.who, src: t.src, time: t.time, text: t.text, width: 600 });
      });
      spacer(stream);
      hairline(stream);
        const foot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
        add(foot, text("note", "改名只改这一场的标注：自动编号的标签、正文与时间码都不动。",
          "Subheadline", V["text/tertiary"], { w: 640 }));
      add(stream, stretch(foot));
    },
    side: function (side) {
      const head = frame("sideHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
      add(head, text("title", "说话人", "Title / Page", V["text/primary"]));
      add(head, text("badge", "会中与会后都能改", "Caption", V["text/tertiary"]));
      add(side, stretch(head));
      hairline(side);
      const body = frame("sideBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 12 });
      [
        ["A", "张工", "Ready", "已标注"],
        ["B", "我", "Ready", "已标注"],
        ["C", "未命名", "Attention", "待标注"],
        ["D", "已并入 A", "Off", "已合并"]
      ].forEach(function (sp) {
        const row = frame("speaker", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
        speakerChip(row, "说话人 " + sp[0]);
        add(row, text("name", sp[1], "Body / Medium", V["text/primary"]));
        spacer(row);
        pill(row, sp[2], sp[3]);
        iconButton(row, "pencil", 24);
        add(body, stretch(row));
      });
      hairline(body);
      add(body, text("label", "正在改名：说话人 C", "Caption / Medium", V["text/secondary"]));
      const field = frame("Text Field", {
        layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 12, padY: 9, radius: 8,
        fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
      });
      add(field, text("value", "李工", "Body", V["text/primary"]));
      add(body, stretch(field));
      const chips = frame("chips", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
      add(chips, text("k", "已有：", "Caption", V["text/tertiary"]));
      ["张工", "我"].forEach(function (n) { secondaryButton(chips, n); });
      add(body, stretch(chips));
      const ops = frame("ops", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
      secondaryButton(ops, "标记为「我」");
      secondaryButton(ops, "与 A 合并");
      add(body, stretch(ops));
      const ops2 = frame("ops2", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
      secondaryButton(ops2, "从 C 拆出…");
      spacer(ops2);
      primaryButton(ops2, "保存", "check", 88);
      add(body, stretch(ops2));
      add(body, text("hint",
        "合并与拆分只改标签的归属：正文、时间码与导出物里的引用都按新名字渲染。",
        "Caption", V["text/tertiary"], { w: 308 }));
      add(side, stretch(body));
      spacer(side);
      hairline(side);
      const acts = frame("acts", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
      add(acts, text("label", "纪要", "Caption / Medium", V["text/secondary"]));
      const ver = frame("ver", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
      secondaryButton(ver, "最新 · 第 2 版");
      secondaryButton(ver, "第 1 版", "clock");
      add(acts, stretch(ver));
      add(side, stretch(acts));
    },
    drawer: function (page) {
      // 抽屉在这里**只有一行**（2026-09-18 实跑教训：原来在收起态下面又挂了一句说明，整页就
      // 比 900 高 21px，`overflow → note+21`）。会后的差别写进那一行的说明里，不额外占高——
      // 「会后也能问」是这一行要说的事，不是第二行。
      const wrap = frame("osWrap", { layout: "VERTICAL", gap: 0 });
      meetingOSBar(wrap, {
        note: "会后也能问 · 证据指向这一场已归档的转录 · 已写进纪要的在这里标出来"
      });
      add(page, stretch(wrap));
    }
  });
}

// --- 15. 会议助手 · 空态 -------------------------------------------------------
function screenMeetingEmpty(d) {
  pageHead(d, "会议助手", "把一段多人谈话变成可检索的文本和纪要；音频不留存。");

  const empty = frame("Empty State", {
    layout: "VERTICAL", gap: 12, align: "CENTER", justify: "CENTER",
    fill: V["surface/content"], radius: 12
  });
  icon(empty, "users", 34, V["text/tertiary"]);
  add(empty, text("title", "还没有会议", "Title / Page", V["text/primary"]));
    add(empty, text("body",
      "开始会议后，转录会边听边出现；结束后可以生成纪要、改说话人的名字，并导出 Markdown 或 SRT。" +
      "原始音频不留存；记录写进这台 Mac 上的记录库，长期保留。",
      "Callout", V["text/secondary"], { w: 460, align: "CENTER" }));
  const acts = frame("actions", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  primaryButton(acts, "开始会议", "mic", 132);
  secondaryButton(acts, "查看设置", "sliders-horizontal");
  add(empty, acts);
    const caps = frame("caps", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
    pill(caps, "Ready", "可标说话人 · Quality 档");
    add(caps, text("note", "换到 light 档（最省资源）时会议照录，只是不标说话人。", "Caption", V["text/tertiary"]));
    add(empty, caps);
    add(d, stretch(grow(empty)));
  }

// --- 16. 实时字幕 · 记录窗 -----------------------------------------------------
  function screenCaptions(d) {
    pageHead(d, "实时字幕", "字幕带贴在屏幕上看；记录长期留在记录库，这里回看、搜索和导出。",
      function (row) {
      secondaryButton(row, "导出 SRT", "download");
      primaryButton(row, "打开字幕带", "captions", 132);
    });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  // 左：字幕记录库。字幕会话不是「一次演示」——记录长期保留，所以入口是列表，与语音
  // 助手、会议助手共用同一种形状：列表 + 选中 + 详情。
  const library = card(split, "library", { pad: 0, gap: 0, clip: true });
  size(library, SESSION_LIST_W, null);
  add(split, stretch(library));
  const lHead = frame("lHead", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 12 });
  add(lHead, text("title", "字幕记录", "Heading / Section", V["text/primary"]));
  spacer(lHead);
  add(lHead, text("count", "42 段", "Callout", V["text/secondary"]));
  add(library, stretch(lHead));
  const lSearch = frame("lSearch", { layout: "HORIZONTAL", padX: 16, padY: 4 });
  searchField(lSearch, "搜索记录", 248);
  add(library, stretch(lSearch));
  hairline(library);
  [
    { title: "今天 14:02", sub: "38 分钟 · 412 行 · 3 位", badge: ["Ready", "刚刚"], selected: true },
    { title: "今天 09:30", sub: "12 分钟 · 128 行 · 2 位" },
    { title: "9月16日 20:10", sub: "1 小时 02 分 · 640 行 · 4 位" },
    { title: "9月15日 14:00", sub: "26 分钟 · 240 行 · 3 位", badge: ["Info", "已导出"] },
    { title: "9月12日 10:05", sub: "18 分钟 · 176 行 · 2 位" }
  ].forEach(function (m, i, all) {
    meetingRow(library, { title: m.title, sub: m.sub, badge: m.badge, selected: m.selected, width: 196 });
    if (i < all.length - 1) hairline(library);
  });
  spacer(library);
  hairline(library);
  const lFoot = frame("lFoot", { layout: "HORIZONTAL", padX: 16, padY: 10 });
  add(lFoot, text("note", "按开始时间倒序；原始音频不留存。",
    "Subheadline", V["text/tertiary"], { w: 248 }));
  add(library, stretch(lFoot));

  const list = card(split, "list", { pad: 0, gap: 0, clip: true });
  grow(list);
  const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(head, text("title", "今天 14:02", "Heading / Section", V["text/primary"]));
  add(head, text("badge", "已保存 · 412 行 · 38 分钟", "Caption", V["text/tertiary"]));
  spacer(head);
  const who = frame("who", { layout: "HORIZONTAL", gap: 7, align: "CENTER", padX: 10, padY: 5, radius: 7,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1 });
  add(who, text("label", "说话人：全部", "Callout", V["text/primary"]));
  icon(who, "chevron-down", 13, V["text/secondary"]);
  add(head, who);
  add(list, stretch(head));
  const bar = frame("toolbar", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 6 });
  searchField(bar, "按内容或说话人搜索", 260);
  segmented(bar, ["全部", "仅星标"], 0);
  spacer(bar);
  add(bar, text("k", "字号", "Callout", V["text/secondary"]));
  segmented(bar, ["紧凑", "标准", "大字"], 1, ["seg/紧凑", "seg/标准", "seg/大字"]);
  add(list, stretch(bar));
  hairline(list);
  const cols = frame("cols", { layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 10 });
  const c1 = frame("cell", { layout: "HORIZONTAL" });
  size(c1, 96, null);
  add(c1, text("h1", "说话人", "Caption / Medium", V["text/secondary"]));
  add(cols, c1);
  const c2 = frame("cell", { layout: "HORIZONTAL" });
  size(c2, 64, null);
  add(c2, text("h2", "时间", "Caption / Medium", V["text/secondary"]));
  add(cols, c2);
  add(cols, text("h3", "字幕", "Caption / Medium", V["text/secondary"]));
  add(list, stretch(cols));
  hairline(list);
  [
    { who: "说话人 A", time: "00:31:02", text: "先把实时字幕接进来，它只依赖语音识别，不依赖大模型。", star: true },
    { who: "说话人 B", time: "00:31:11", text: "那字幕带的位置能不能记住？我习惯放在屏幕底部偏左。" },
    { who: "说话人 A", time: "00:31:20", text: "记住，每块屏幕一套位置；字号也记住。" },
    { who: "说话人 C", time: "00:31:29", text: "回看的时候会不会被打断？", voice: true },
    { who: "说话人 A", time: "00:31:33", text: "上滚就暂停跟随，出现「回到最新」；不点它就一直停在那。" },
      { who: "说话人 B", time: "00:31:44", text: "导出 SRT 保留说话人吗？" },
      { who: "说话人 A", time: "00:31:49", text: "能标说话人时保留；否则只导出纯文本。" }
  ].forEach(function (s, i, all) {
    // 700, not 880: this card now shares the window with the record library, so its
    // content box is 871 — 880 hung past the right edge of its own card (实测推算
    // 2026-09-17；同页的溢出审计会直接报出来)。
    captionLine(list, { who: s.who, text: s.text, width: 700,
      padX: 16, padY: 11, right: s.time });
    if (i < all.length - 1) hairline(list);
  });
  spacer(list);
  hairline(list);
  const foot = frame("foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
    add(foot, text("note",
      "字幕记录留在记录库里，长期保留；原始音频不留存。双击一行可以复制。",
      "Subheadline", V["text/tertiary"]));
  spacer(foot);
  secondaryButton(foot, "复制全文", "copy");
  add(list, stretch(foot));
}

// --- 17. 会话占用 · 结束会议并切换 ---------------------------------------------
//
// 本机只有一个麦克风（项目约束）、服务只有一个实时 worker。所以「换会话」是一条
// 有确认、有出口的流程：说清楚丢什么、保什么、还能不能回来（SESSIONS-SPEC §6.4）。
function screenSessionGuard(d) { screenMeetingRecording(d); }

function buildSessionGuardBoard() {
  const win = buildShell("meeting", "会议助手", "users", screenSessionGuard, "meeting");
  win.name = "▸ 会话占用 · 结束会议并切换";
  const scrim = figma.createRectangle();
  scrim.name = "scrim";
  size(scrim, 1440, 900);
  scrim.fills = [{ type: "SOLID", color: { r: 0, g: 0, b: 0 }, opacity: 0.32 }];
  // layoutPositioning = ABSOLUTE is only accepted on a node that already has an
  // auto-layout parent: set it before appendChild and Figma throws
  // "Can only set layoutPositioning = ABSOLUTE if the parent node has layoutMode
  // == NONE" (实测 2026-09-17) and the whole board is lost.
  win.appendChild(scrim);
  scrim.layoutPositioning = "ABSOLUTE";
  scrim.x = 0;
  scrim.y = 0;

  const sheet = frame("Sheet", {
    layout: "VERTICAL", gap: 12, padX: 20, padY: 18, radius: 12,
    fill: V["surface/panel"], stroke: V["border/separator"], strokeWeight: 1
  });
  size(sheet, 520, null);
  elevate(sheet);
  add(sheet, text("title", "结束会议并切换到语音助手？", "Title / Page", V["text/primary"]));
  add(sheet, text("body",
    "正在录制的「周会 · 已标说话人」还有 00:12:40 的转录没有整理。结束后仍会生成纪要，" +
    "但麦克风同一时刻只能由一个会话使用。",
    "Callout", V["text/secondary"], { w: 460 }));
  hairline(sheet);
  add(sheet, text("note", "会议录制结束前始终会确认，这个提示不会被记住。",
    "Subheadline", V["text/tertiary"], { w: 460 }));
  const acts = frame("actions", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  spacer(acts);
  secondaryButton(acts, "取消");
  primaryButton(acts, "结束会议并切换", "square", 168).name = "guardPrimary";
  add(sheet, stretch(acts));
  win.appendChild(sheet);
  sheet.layoutPositioning = "ABSOLUTE";
  sheet.x = 460;
  sheet.y = 250;
  return win;
}

// --- 18. 会话浮层 · 字幕带 -----------------------------------------------------
//
// 字幕带是窗口级浮层，不是页面：最常见的用法是「我在别处干活，字幕贴在屏幕上」。
// 材质由系统提供（NSVisualEffectView · hudWindow）；稿里以 surface/panel + 1px hairline
// 表示——稿画不出真材质，这一点在交接包里如实登记。
function captionBandFrame(o) {
  o = o || {};
  const band = frame("Caption Band", {
    layout: "VERTICAL", gap: 4, padY: 10, radius: 12,
    fill: V["surface/panel"], stroke: V["border/separator"], strokeWeight: 1
  });
  size(band, o.w || 760, null);
  elevate(band);
  if (o.toolbar) {
    const tb = frame("hoverToolbar", {
      layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 10, padY: 5, radius: 8,
      fill: V["surface/content"], stroke: V["border/separator"], strokeWeight: 1
    });
    size(tb, o.w || 760, null);
    iconButton(tb, "pause", 26);
    const sizeTag = frame("sizeTag", { layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 8, padY: 3, radius: 7 });
    add(sizeTag, text("k", "字号", "Callout", V["text/secondary"]));
    add(sizeTag, text("v", "标准", "Callout", V["text/primary"]));
    icon(sizeTag, "chevron-down", 13, V["text/secondary"]);
    add(tb, sizeTag);
    spacer(tb);
    ["copy", "download", "pin", "x"].forEach(function (n) { iconButton(tb, n, 26); });
    add(band, stretch(tb));
  }
  (o.lines || []).forEach(function (l) {
    captionLine(band, {
      who: l.who, text: l.text, partial: l.partial, style: o.style,
      width: l.width, padX: 16, padY: l.padY == null ? 8 : l.padY
    });
  });
  const foot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 4 });
  add(foot, text("hint", o.hint, "Caption", V["text/tertiary"]));
  spacer(foot);
  if (o.returnPill) {
    const p = frame("returnPill", {
      layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 9, padY: 3, radius: 999,
      fill: V["surface/railTint"]
    });
    icon(p, "chevron-down", 12, V["accent/rail"]);
    add(p, text("label", "回到最新", "Caption", V["accent/rail"]));
    add(foot, p);
  }
  levelBars(foot, o.level == null ? 0.6 : o.level, 14, 13);
  add(band, stretch(foot));
  return band;
}

function floatBoard(name, title, noteText, build, noteW) {
  const board = frame(name, { layout: "VERTICAL", gap: 14, pad: 24, fill: V["surface/window"],
    radius: 12, clip: true });
  add(board, text("caption", title, "Callout", V["text/secondary"]));
  build(board);
  add(board, text("note", noteText, "Subheadline", V["text/tertiary"], { w: noteW || 1040 }));
  return board;
}

function buildFloatBoards(group) {
  const page = P[group || "08 会话浮层"];
  const boards = [];

  boards.push(floatBoard("浮层 · 字幕带 · 跟随中", "字幕带 · 跟随中（默认，2 行）",
    "半透明材质由系统提供（NSVisualEffectView · hudWindow）；稿里以 surface/panel + 1px hairline 表示。" +
    "高度跟随行数（2–4 行），宽度可拖 420–1200，位置按屏幕记忆。",
    function (b) {
      add(b, captionBandFrame({
        hint: "跟随中 · ⌘⇧L 暂停 · 上滚回看", level: 0.62,
        lines: [
          { who: "说话人 A", text: "先把实时字幕接进来，它只依赖语音识别。", width: 600 },
          { text: "会议助手再单独排一轮。", width: 700, padY: 2 }
        ]
      }));
    }));

  boards.push(floatBoard("浮层 · 字幕带 · 回看", "字幕带 · 回看（跟随已暂停 + 悬停工具条）",
    "上滚即停止跟随，出现「回到最新」；悬停才出现工具条，它是一条贴在屏幕上的薄片，不是窗口。" +
    "esc 不会关掉它——它不持有焦点。",
    function (b) {
      add(b, captionBandFrame({
        toolbar: true, hint: "回看中 · 3 分钟前", level: 0.28, returnPill: true,
        lines: [
          { text: "……所以字幕带的宽度和位置要按屏幕记，换显示器不会跑到别处。", width: 700 },
          { who: "说话人 B", text: "那字号呢？", width: 600, padY: 2 }
        ]
      }));
    }));

  boards.push(floatBoard("浮层 · 字幕带 · 大字", "字幕带 · 大字（字号档，26pt）",
    "字号三档：紧凑 17 / 标准 20 / 大字 26，映射系统 .title2 / .title / .largeTitle。" +
    "大字档是同一块浮层的档位，不是另一个模式：不做镜像翻转与视线导轨（SESSIONS-SPEC §2.3）。",
    function (b) {
      add(b, captionBandFrame({
        w: 1100, style: "Caption Band / 大字", hint: "大字 · ⌘⇧L 暂停", level: 0.5,
        lines: [{ text: "语音进来，文字和声音出去，全程离线。", width: 1040, padY: 12 }]
      }));
    }));

  boards.push(floatBoard("浮层 · 字幕带 · 受阻", "字幕带 · 受阻（麦克风未授权）",
    "受阻时保留最后一句字幕（可读、可复制），并给唯一出口。服务未就绪时同一条带子换成" +
    "「语音服务未就绪 · 去服务状态」——两个受阻态共用同一个形状。",
    function (b) {
      const band = frame("Caption Band", {
        layout: "VERTICAL", gap: 8, padY: 12, radius: 12,
        fill: V["surface/attentionTint"], stroke: V["status/attention"], strokeWeight: 1
      });
      size(band, 760, null);
      elevate(band);
      const row = frame("row", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16 });
      icon(row, "triangle-alert", 16, V["status/attention"]);
      add(row, text("t", "麦克风未授权，字幕带已暂停", "Callout", V["status/attention"]));
      spacer(row);
      secondaryButton(row, "打开系统设置");
      add(band, stretch(row));
      captionLine(band, {
        text: "……会议助手再单独排一轮。", partial: true, width: 700, padX: 16, padY: 2
      });
      add(b, band);
    }));

  // 用户 2026-09-18：「没有看到字幕带的 UI。」字幕带是一条贴在屏幕上的薄片，只有**盖在别的
  // 内容之上**才看得出它是什么；单独摆一条 760×80 的卡，评审时会被当成一张普通卡片。所以这块
  // 板把它放回真实场景：正在播放的画面 + 浮在最上面的字幕带（含悬停工具条与三档字号之一）。
  //
  // 只在闭环稿里加：全量稿那一批已经交付并导出过，加板会改它的板数（见 HANDOFF 已知偏差）。
  if (CLOSURE_SCOPE) {
    boards.push(floatBoard("浮层 · 字幕带 · 贴在画面上（在用时）",
      "字幕带 · 在用时（浮在任何画面之上）",
      "材质由系统提供（NSVisualEffectView · hudWindow / .glassEffect）；稿里以 surface/panel + 1px hairline 表示。" +
        "它不抢焦点、不激活 App，可以盖在别人的全屏演示之上；工具条只在悬停时出现，它不是窗口。",
      function (b) {
        // 1px 描边会把自动布局的内容盒各收进 1px（实测：1040 的容器里，STRETCH 的子节点
        // 得到 1038）。所以里面的画面与字幕带按 1038 画——写 1040 会在右侧溢出 2px
        // （实测 `scene/bandWrap/Caption Band +2R w1040/1038`）。子节点比父级窄不会溢出，
        // 1038 在两种解释下都成立，比按 1040 写更稳。
        const SCENE_W = 1040, SCENE_INNER = SCENE_W - 2;
        const scene = frame("scene", {
          layout: "VERTICAL", gap: 0, radius: 12, clip: true,
          fill: V["surface/window"], stroke: V["border/separator"], strokeWeight: 1
        });
        size(scene, SCENE_W, null);
        const pic = frame("picture", {
          layout: "VERTICAL", gap: 6, padX: 22, padY: 20, fill: V["surface/panel"]
        });
        size(pic, SCENE_INNER, 300);
        add(pic, text("k", "正在播放的视频 / 全屏演示", "Heading / Section", V["text/primary"]));
        add(pic, text("s", "字幕带浮在它上面：不暂停、不改变这一段播放，也不抢走键盘焦点。",
          "Callout", V["text/secondary"], { w: 700 }));
        add(scene, stretch(pic));
        const bandWrap = frame("bandWrap", { layout: "VERTICAL", gap: 6, padY: 16 });
        add(bandWrap, captionBandFrame({
          w: SCENE_INNER, toolbar: true, hint: "跟随中 · 上滚回看 · ⌘⇧L 暂停 · 悬停出现工具条",
          level: 0.58,
          lines: [
            { who: "说话人 A", text: "先把实时字幕接进来，它只依赖语音识别。", width: 880 },
            { text: "会议助手再单独排一轮。", width: 960, padY: 2 }
          ]
        }));
        add(scene, stretch(bandWrap));
        add(b, scene);
      }));
  }

  // 浮层高度各不相同（一行 / 两行 / 工具条），所以按游标往下排，不用固定步长——
  // 固定步长会在两块画板之间留下压边或者空档。
  let cursorY = 0;
  boards.forEach(function (board) {
    board.x = 0;
    board.y = cursorY;
    add(page, board);
    cursorY += board.height + 60;
  });
  return boards;
}

// =============================================================================
// 会话闭环稿（SPEECHRAIL_SCOPE = "closures"）
// =============================================================================
//
// 这份稿只画三个能力（语音助手 / 会议助手 / 实时字幕）的**完整闭环**：
// 入口 → 前置与受阻 → 主交互 → 交还与守卫 → 产物回看。
//
// 它不是全量稿的裁剪。全量稿按**页面**组织（每一页画全），闭环稿按**路径**组织：
// 每条路径的两端——从哪进、产物落在哪——都必须出现在稿里，否则路径没画完。三条闭环
// 共用同一根脊柱（谁在用麦克风 / 大模型在哪配 / 系统级入口在哪），那根脊柱也要画出来，
// 否则三条路径会在「麦克风被占」这一类交叉点上各自说一套。

const CLOSURE_GROUPS = ["10 闭环总览", "11 会话闭环", "12 会话浮层"];
const CLOSURE_LANE_W = 168;   // 泳道名那一列的宽
const CLOSURE_CELL_W = 250;   // 每个阶段格子的宽
const CLOSURE_CELL_H = 124;   // 固定高：五格一行要能横向比较，不能被自己的文案撑成阶梯
const CLOSURE_GAP = 12;
const CLOSURE_W = 1600;
const CLOSURE_PAD = 48;
const CLOSURE_STAGES = ["① 入口", "② 前置与受阻", "③ 主交互", "④ 交还与守卫", "⑤ 产物与回看"];
// 291 × 5 + 12 × 4 = 1503：**这行现在是 5 格**（系统入口 / 大模型 / 记录落点 / 麦克风所有权 /
// 分人链路）。2026-09-17 实测教训：这里原先按 3 格写成 490，第 4 格越出画板右边缘 444px，
// 报告里表现为 `root overflow=4 · spine/3+444`。格子宽度必须跟着**当前**条目数算，不能跟着
// 上一版的条目数算——每次往这根脊柱上添一条，都要连带改这里与下一行的格高。
const CLOSURE_SPINE_W = 291;

// 「能力 / 状态 / 影响 / 出口」是这一稿里出现最多的行：开始前的检查、受阻分支、连接
// 检查的三种结论都是同一个形状。造三套的代价不是多写代码，而是同一件事在三个地方有
// 三种说法。
function closureCheckRow(parent, tone, label, note, trailing, noteW, nodeName) {
  const row = frame(nodeName || "checkRow", {
    layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 12
  });
  const cell = frame("cell", { layout: "HORIZONTAL" });
  // 132, not 96: 格子按**最长的那条胶囊文案**定宽，不是按最短的那条。两次实测教训——
  // 「Attention」在 96 里要 103（`Status Pill +7R [103 in 96]`），「腾讯会议」在 116 里要
  // 122。胶囊里的字是这一行的名字，改文案之前先量一遍。
  size(cell, 132, null);
  pill(cell, tone, label);
  add(row, cell);
  add(row, text("note", note, "Callout", V["text/secondary"], { w: noteW == null ? 700 : noteW }));
  spacer(row);
  if (trailing) {
    const box = frame("trailing", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
    trailing(box);
    add(row, box);
  }
  return add(parent, stretch(row));
}

// --- C1. 实时字幕 · 未开始与前置检查 -------------------------------------------
//
// 字幕这条闭环的入口不在主窗口里：⌘⇧L 或菜单栏。所以这一块画板要把「从哪进、开始
// 之前要满足什么、三种受阻各给哪个出口」一次说清——闭环的起点没画清，后面全是悬空的。
  function screenClosureCaptionsIdle(d) {
    pageHead(d, "实时字幕", "字幕带贴在屏幕上看；这里回看、搜索和导出。", function (row) {
      kbdInRow(row, "⌘⇧L", 34);
      secondaryButton(row, "打开记录库", "clock");
      primaryButton(row, "开始字幕", "captions", 132);
      sideToggle(row, "本次字幕");
    });

  conclusionBand(d, {
    tone: "Ready",
      title: "现在就可以开始字幕",
      body: "它只依赖语音识别，不依赖大模型；开始后字幕带贴在屏幕底部，SpeechRail 不必在前台。",
      hint: "再按一次 ⌘⇧L 结束并保存。字幕带不持有焦点，所以 esc 不会关掉它。",
      actions: [["字幕设置", "sliders-horizontal"]]
    });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const ready = card(split, "ready", { pad: 0, gap: 0, clip: true });
  grow(ready);
  const rHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 16, padY: 14 });
  add(rHead, text("title", "开始之前", "Heading / Section", V["text/primary"]));
  add(rHead, text("detail", "三件事里只有前两件是必须的；第三件决定字幕里有没有说话人。",
    "Callout", V["text/secondary"]));
  add(ready, stretch(rHead));
  hairline(ready);
    [
      ["Ready", "麦克风", "第一次开始时会请求授权；拒绝后这一行会变成受阻态并给出出口。"],
      ["Ready", "语音服务", "识别在本机跑；服务未就绪时字幕带会换成同一条受阻带。"],
      ["Off", "说话人标签 · 可选", "档位不够时只记文字、不标说话人，正文照常；它也不接大模型，不需要另配模型。"]
    ].forEach(function (r, i, all) {
      closureCheckRow(ready, r[0], r[1], r[2], null, 520);
      if (i < all.length - 1) hairline(ready);
    });
  spacer(ready);
  hairline(ready);
  const rFoot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
    add(rFoot, text("note", "字幕带只做识别与显示：不接大模型，也不替你做总结。记录库空着的时候，这里只有「开始字幕」。",
      "Subheadline", V["text/tertiary"]));
  add(ready, stretch(rFoot));

  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sHead = frame("sHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
    add(sHead, text("title", "本次字幕", "Title / Page", V["text/primary"]));
    add(sHead, text("badge", "还没有开始", "Caption", V["text/tertiary"]));
    add(side, stretch(sHead));
    hairline(side);
    const sBody = frame("sBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
    [
      ["运行档位", "Quality（本机最强）"],
      ["默认字号", "标准"],
      ["字幕带位置", "屏幕底部居中 · 每块屏各记一套"],
      ["采集设备", "MacBook 麦克风"],
      ["保存位置", "记录库 · 长期保留"],
      ["最近一条记录", "今天 08:12 · 412 行"]
    ].forEach(function (kv) { kvRow(sBody, kv[0], kv[1]); });
    add(sBody, text("label", "运行档位是什么意思", "Caption / Medium", V["text/secondary"]));
    add(sBody, text("desc",
      "Quality 是这台 Mac 现在跑的那一档：认得最准，所以能标出说话人。换档在设置里，" +
        "已经存下的记录不跟着变。",
      "Subheadline", V["text/secondary"], { w: 308 }));
    add(side, stretch(sBody));

    const blocked = card(d, "blocked", { pad: 0, gap: 0, clip: true });
  const bHead = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(bHead, text("title", "受阻时", "Heading / Section", V["text/primary"]));
  spacer(bHead);
  add(bHead, text("detail", "三种受阻共用同一个形状：说明影响 + 唯一出口；不弹对话框。",
    "Callout", V["text/secondary"]));
  add(blocked, stretch(bHead));
  hairline(blocked);
  [
    ["Attention", "麦克风未授权", "系统设置里给过权限才能采音。拒绝一次不会反复弹窗。", "打开系统设置"],
    ["Attention", "语音服务未就绪", "识别服务没起来时，字幕带换成同一条受阻带并保留最后一句。", "去服务状态"],
    ["Attention", "麦克风被占用", "同一时刻只有一个会话能用麦克风；交还要确认，不会静默抢。", "结束会话并切换"]
  ].forEach(function (r, i, all) {
    closureCheckRow(blocked, r[0], r[1], r[2], function (box) {
      secondaryButton(box, r[3]);
    }, 520);
    if (i < all.length - 1) hairline(blocked);
  });
  spacer(blocked);
  return blocked;
}

// --- C3. 实时字幕 · 结束并保存 -------------------------------------------------
//
// 「结束」是字幕闭环里唯一会产生产物的一步，所以它必须自己画出来：结束方式、补写的
// 最后一句、文件落在哪、导出什么格式。字幕带上的「回到最新」只暂停跟随，不等于结束。
  function screenClosureCaptionsSaved(d) {
    pageHead(d, "实时字幕", "字幕带贴在屏幕上看；这里回看、搜索和导出。", function (row) {
      secondaryButton(row, "复制全文", "copy");
      primaryButton(row, "导出 SRT", "download", 118);
      sideToggle(row, "字幕文件");
    });

    conclusionBand(d, {
      tone: "Ready",
      title: "字幕已结束并保存",
      body: "本次 38 分钟 · 412 行 · 3 位说话人。结束那一刻会把最后半句补上，末句不会丢；" +
        "麦克风采集的音频在流里用完即弃。",
      hint: "记录留在记录库，长期保留；导出 SRT 才会生成文件。再按一次 ⌘⇧L 就能结束下一段。",
      actions: [["打开数据目录", "folder-open"], ["打开记录库", "captions"]]
    });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const list = card(split, "tail", { pad: 0, gap: 0, clip: true });
  grow(list);
  const lHead = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
    add(lHead, text("title", "本次字幕 · 结尾", "Heading / Section", V["text/primary"]));
    spacer(lHead);
    add(lHead, text("detail", "412 行 · 3 位说话人 · 已存进记录库", "Callout", V["text/secondary"]));
  add(list, stretch(lHead));
  hairline(list);
  [
    { who: "说话人 A", time: "00:37:41", text: "导出 SRT 保留说话人吗？" },
    { who: "说话人 B", time: "00:37:50", text: "能标说话人时导出会保留；不能的话就是纯文字。" },
    { who: "说话人 C", time: "00:38:01", text: "那结尾这一句呢——", partial: true },
    { who: "说话人 A", time: "00:38:05",
      text: "结束时会把它补上：字幕带停下之前听到的那半句也会存进去。" },
    { who: "说话人 B", time: "00:38:11", text: "好，那我把 SRT 拿去剪素材。" }
  ].forEach(function (l, i, all) {
    captionLine(list, {
      who: l.who, text: l.text, partial: l.partial, width: 640, padX: 16, padY: 11, right: l.time
    });
    if (i < all.length - 1) hairline(list);
  });
  spacer(list);
  hairline(list);
    const lFoot = frame("foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
    add(lFoot, text("note", "最后两行是结束那一刻补写的；再往前的内容在记录库里搜索。",
      "Subheadline", V["text/tertiary"]));
    add(list, stretch(lFoot));

  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sHead = frame("sHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(sHead, text("title", "字幕文件", "Title / Page", V["text/primary"]));
  add(sHead, text("badge", "已结束 · 已保存", "Caption", V["text/tertiary"]));
  add(side, stretch(sHead));
  hairline(side);
  const sBody = frame("sBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
    [
      ["记录", "字幕记录 · 今天 14:02"],
      ["时长", "38 分钟"],
      ["行数", "412 行"],
      ["说话人", "3 位 · 自动编号"],
      ["说话人标签", "已开 · Quality"],
      ["保存位置", "记录库 · 长期保留"],
      ["导出格式", "SRT / Markdown / 纯文本"]
    ].forEach(function (kv) { kvRow(sBody, kv[0], kv[1]); });
  add(sBody, text("label", "导出保留说话人", "Caption / Medium", V["text/secondary"]));
    add(sBody, text("desc",
      "能标说话人时导出保留，否则只导出文字。改名改的是这个编号显示成什么，" +
        "不改正文，也不改时间码。",
      "Subheadline", V["text/secondary"], { w: 308 }));
  add(side, stretch(sBody));
  spacer(side);
  hairline(side);
  const sActs = frame("actions", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  secondaryButton(sActs, "导出纯文本");
  const actsRow = frame("row", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  secondaryButton(actsRow, "导出 Markdown");
  add(sActs, stretch(actsRow));
  add(side, stretch(sActs));
}

// --- M3. 会议助手 · 结束并整理中 -----------------------------------------------
//
// 「整理中」是会议闭环里最容易被漏掉的一步：录制已经结束、纪要还没生成，用户这时要
// 知道三件事——转录有没有保住、还要多久、能不能离开。三句话答完，这一步就不需要再看。
function screenClosureMeetingProcessing(d) {
  meetingShell(d, {
    subtitle: "已经结束录制：先把转录存好，再生成纪要。这一步可以离开这一页。",
    headActions: function (row) {
      secondaryButton(row, "先导出转录…", "download");
      primaryButton(row, "查看纪要", "book-open", 118).opacity = 0.45;
    },
      status: {
        tone: "info", phase: "正在整理", title: "周会 · 本机音频 + 麦克风",
        time: "00:12:40", level: 0.02,
        facts: ["148 段已存好 · 末段没丢", "最后半句也标完了"],
        actions: [["停止整理", "square"]]
      },
    transcript: function (stream) {
      const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
      add(head, text("title", "正在整理：说话人分段 → 摘要 → 结论与待办",
        "Heading / Section", V["text/primary"]));
      spacer(head);
      add(head, text("time", "已用 20 秒 · 通常 20–40 秒", "Callout", V["text/secondary"]));
      add(stream, stretch(head));
      const prog = frame("progress", { layout: "HORIZONTAL", padX: 16, padY: 0 });
      const track = frame("track", { layout: "HORIZONTAL", radius: 999, fill: V["surface/field"] });
      size(track, 560, 6);
      rect(track, "fill", 348, 6, V["accent/rail"], 999);
      add(prog, stretch(track));
      add(stream, stretch(prog));
      hairline(stream);
      [
        { who: "说话人 A", src: "本机音频", time: "00:12:22",
          text: "那我先按这个排期，等一下再确认一下名字。" },
        { who: "说话人 B", src: "麦克风", time: "00:12:31", text: "好，先把这段记下来。" },
        { who: "说话人 A", src: "本机音频", time: "00:12:36",
          text: "我们这边按 8 月 22 日交付，测试前一天拿到就行。" },
        { who: "说话人 C", src: "本机音频", time: "00:12:40",
          text: "对，那天前给到测试，我这边留两天回归。" }
      ].forEach(function (t) {
        turnRow(stream, { who: t.who, src: t.src, time: t.time, text: t.text, width: 600 });
      });
      spacer(stream);
      hairline(stream);
      const foot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
        add(foot, text("note",
          "纪要还没好，转录已经存进记录库：整理失败也不会把这一段弄丢，可以只导出 SRT。",
          "Subheadline", V["text/tertiary"], { w: 640 }));
      add(stream, stretch(foot));
    },
    side: function (side) {
      meetingInfoSide(side, {
        badge: "已结束 · 整理中",
        rows: [
          ["时长", "00:12:40"],
          ["转录", "148 段 · 已存好"],
            ["说话人", "4 位（可改）"],
            ["音频来源", "麦克风 + 腾讯会议"],
            ["说话人标签", "已开 · 末段已对齐"],
            ["保存位置", "记录库"],
            ["纪要", "生成中 · 已有 1 个旧版本"]
          ],
        noteLabel: "整理只读转录正文",
        noteBody: "改名和重新生成纪要只改标注与版本：正文不动，旧版本仍可回看与导出。"
      });
    },
    drawer: function (page) { meetingOSBar(page); }
  });
}
// =============================================================================
// 会议页的骨架（2026-09-18 用户：「会议助手整体布局需要重新构思」「内心 OS 需要为随时可
// 展开可关闭的组件」）
// =============================================================================
//
// 原来那一版把内心 OS 画成了一个**独立状态**：想看回答，整页就得换成 OS 版式，转录被挤走。
// 结果是一个会中的小动作变成了「离开你正在看的东西」——与「边听边记」的用法正好相反。
//
// 现在只有一套骨架，四种状态共用：
//
//   页头 → 状态带 → 主区（转录 + 会议信息栏）→ 贴底的 OS 抽屉
//
// 抽屉默认收起成一行（「已问 N 次 · M 条已写进纪要」），任何时候都能展开或收起（⌘⇧I）。
// 它不占主区，也不用离开转录——这样它才是「组件」，而不是「模式」。
function meetingShell(d, o) {
  pageHead(d, "会议助手", o.subtitle || "把一段多人谈话变成可检索的文本与纪要；音频不留存。",
    function (row) {
      if (o.headActions) o.headActions(row);
      // 会议页的全部状态共用这一处右栏收起控件；空态的右栏是「音频来源」，不是会议信息。
      sideToggle(row, o.sideName || "会议信息");
    });
  sessionStatusBar(d, o.status);
  if (o.banner) o.banner();
  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));
  const stream = card(split, "stream", { pad: 0, gap: 0, clip: true });
  grow(stream);
  o.transcript(stream);
  const side = card(split, "side", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  // **不 stretch**（2026-09-18 实跑教训）：split 的高由非 stretch 的那个孩子（转录）决定，
  // 被 stretch 的右栏会被压到那个高度，内容一长就在底部溢出（实测 `detail ▸ side ▸ sideBody
  // +50B [360 in 360]`）。让右栏按内容撑高，split 取两者较高的那个。
  add(split, side);
  o.side(side);
  if (o.drawer) o.drawer(d);
  return d;
}

// OS 抽屉 · 收起态：一行。它常驻，所以「问一句」随时找得到，不必先想「我现在在哪个模式」。
function meetingOSBar(parent, o) {
  o = o || {};
  const bar = card(parent, "osBar", {
    layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12
  });
  icon(bar, "sparkles", 16, V["accent/rail"]);
  add(bar, text("title", "内心 OS", "Body / Medium", V["text/primary"]));
  pill(bar, "Info", "只你可见");
  add(bar, text("note", o.note || "已问 3 次 · 2 条已写进纪要 · 不进转录、不读出来",
    "Callout", V["text/secondary"]));
  spacer(bar);
  kbd(bar, "⌘⇧I");
  iconButton(bar, "chevron-up", 28);
  return bar;
}

// OS 抽屉 · 展开态：提问 + 多轮追问 + 一条带证据的答案 + 三种「问不出来」的出口。
// 展开时转录仍在上面——这就是它必须做成组件而不是状态的证据。
function meetingOSPanel(parent) {
  const panel = card(parent, "osPanel", { pad: 0, gap: 0, clip: true });
  const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  icon(head, "sparkles", 16, V["accent/rail"]);
  add(head, text("title", "内心 OS", "Heading / Section", V["text/primary"]));
  pill(head, "Info", "只有你看得到");
  add(head, text("note", "不进会议音频、不进转录；默认不进纪要。", "Callout", V["text/secondary"]));
  spacer(head);
  kbd(head, "⌘⇧I");
  iconButton(head, "chevron-down", 28);
  add(panel, stretch(head));
  hairline(panel);

  const body = frame("body", { layout: "HORIZONTAL", gap: 16, padX: 16, padY: 14 });
  add(panel, stretch(body));

  const ask = frame("ask", { layout: "VERTICAL", gap: 8 });
  size(ask, 460, null);
  add(body, ask);
  const askField = frame("Text Field", {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 12, padY: 9, radius: 8,
    fill: V["surface/field"], stroke: V["border/strong"], strokeWeight: 1
  });
  add(askField, text("placeholder", "问点什么…（它只看这一场的转录，不联网）",
    "Body", V["text/tertiary"]));
  add(ask, stretch(askField));
  // 这一栏是**这一场的问答历史**，不是示例问题：状态带上写着「已问 3 次」，
  // 展开后却看不到那 3 次，用户就没法追问「刚才你那条」——多轮在这里不是附加项，
  // 是「已问 N 次」这个数字的兑现。
  add(ask, text("label", "这一场问过（3）", "Caption / Medium", V["text/secondary"]));
  [
    ["刚才说的交付日期是多少？", "已答 · 2 处证据", true],
    ["这是谁说的？", "已答 · 1 处证据", false],
    ["帮我起一个可以直接念的说法", "已写进纪要", false]
  ].forEach(function (q) {
    const row = frame("qRow", {
      layout: "VERTICAL", gap: 3, padX: 10, padY: 8, radius: 8,
      fill: q[2] ? V["surface/field"] : null
    });
    add(row, text("q", q[0], q[2] ? "Body / Medium" : "Body",
      q[2] ? V["text/primary"] : V["text/secondary"], { w: 428 }));
    add(row, text("meta", q[1], "Caption", V["text/tertiary"]));
    add(ask, stretch(row));
  });
  add(ask, text("hint", "追问接着上一问的上下文，不用重复背景；生成中可以取消。",
    "Caption", V["text/tertiary"], { w: 440 }));

  const ans = frame("answer", {
    layout: "VERTICAL", gap: 6, padX: 14, padY: 12, radius: 10, fill: V["surface/panel"]
  });
  grow(ans);
  add(body, stretch(ans));
  const aHead = frame("aHead", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  pill(aHead, "Ready", "2 处证据");
  add(aHead, text("who", "你 · 00:12:41", "Caption", V["text/tertiary"]));
  spacer(aHead);
  add(aHead, text("conf", "两次口述一致 · 不确定度低", "Caption", V["text/tertiary"]));
  add(ans, stretch(aHead));
  add(ans, text("a1", "交付日期是 8 月 22 日，周五；测试在此之前拿到。",
    "Body / Medium", V["text/primary"], { w: 560 }));
  hairline(ans);
  const ev = frame("evidence", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  speakerChip(ev, "说话人 A");
  add(ev, text("t", "00:11:58", "Caption", V["text/tertiary"]));
  spacer(ev);
  add(ev, text("q", "「我们这边按 8 月 22 日交付……」", "Caption", V["text/secondary"]));
  iconButton(ev, "play", 24);
  add(ans, stretch(ev));
  hairline(ans);
  add(ans, text("draft", "可以直接念：「8 月 22 日，周五，测试在此之前拿到。」",
    "Callout", V["text/primary"], { w: 560 }));
  const acts = frame("acts", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  secondaryButton(acts, "继续追问", "pencil");
  secondaryButton(acts, "复制", "copy");
  spacer(acts);
  secondaryButton(acts, "写进纪要");
  add(ans, stretch(acts));
  return panel;
}

// 会议信息栏：四种状态共用，只有「当前进展」那几行随状态变。
function meetingInfoSide(side, o) {
  const head = frame("sideHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(head, text("title", "会议信息", "Title / Page", V["text/primary"]));
  add(head, text("badge", o.badge, "Caption", V["text/tertiary"]));
  add(side, stretch(head));
  hairline(side);
  const body = frame("sideBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
  o.rows.forEach(function (kv) { kvRow(body, kv[0], kv[1]); });
  add(body, text("label", o.noteLabel, "Caption / Medium", V["text/secondary"]));
  add(body, text("desc", o.noteBody, "Subheadline", V["text/secondary"], { w: 308 }));
  add(side, stretch(body));
  if (!o.actions) { spacer(side); return side; }
  hairline(side);
  const acts = frame("acts", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
  o.actions(acts);
  add(side, stretch(acts));
  return side;
}

// --- M1. 会议助手 · 空态与音频来源 ---------------------------------------------
//
// 麦克风不再是唯一来源：会议室里开着线上会时，真实的声音一半在这台 Mac 里播放
// （腾讯会议 / QQ 音乐）。所以「从哪听」是开始会议之前必须答的一件事，而不是设置页
// 里的一行配置——它决定这份记录里有没有对方说的话。
//
// macOS 26 的取音方式是系统给的按进程 tap（Core Audio `CATapDescription` + `bundleIDs`），
// 不是虚拟声卡：不要求用户装驱动，也不把整机声音拷走，还能显式排除自己。
function screenClosureMeetingSources(d) {
  pageHead(d, "会议助手", "把一段多人谈话变成可检索的文本和纪要；音频不留存。", function (row) {
    kbdInRow(row, "⌘⇧N", 34);
    secondaryButton(row, "查看设置", "sliders-horizontal");
    primaryButton(row, "开始会议", "mic", 132);
    sideToggle(row, "音频来源");
  });

    conclusionBand(d, {
      tone: "Ready",
      title: "选好音频来源就能开始",
      body: "房间里的人走麦克风；这台 Mac 正在播放的声音（腾讯会议、QQ 音乐等）按 App 抓取。" +
        "两边可以一起录，记录里会标出每一段来自哪一路。",
      hint: "本机音频不改变你听到的音量与内容，也不保存：原始音频和麦克风一样用完即弃；" +
        "按 App 抓不需要装虚拟声卡。",
      actions: [["说话人设置", "sliders-horizontal"]]
    });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const src = card(split, "sources", { pad: 0, gap: 0, clip: true });
  grow(src);
  const sHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 16, padY: 14 });
    add(sHead, text("title", "音频来源", "Heading / Section", V["text/primary"]));
    add(sHead, text("detail",
      "麦克风单选；本机音频按 App 多选。两路一起来时分别标注来源，转录里看得出哪句来自麦克风、哪句来自本机播放。",
      "Callout", V["text/secondary"]));
  add(src, stretch(sHead));
  hairline(src);
  [
    // 第一栏是胶囊里的名字，必须短；句子进第二栏。三栏的名字一起定这行的格宽（132）。
    ["Ready", "麦克风", "房间里的人。第一次开始时会请求授权；拒绝后这一行变受阻并给出出口。", "已选"],
    ["Ready", "腾讯会议", "本机音频：抓这个 App 正在播放的声音；它退出再启动会自动接回，不用重新选。", "已选"],
    ["Ready", "QQ 音乐", "本机音频：会中放背景音乐时用它；歌词也会进转录，回看时能按来源区分。", "已选"],
    ["Ready", "自动混音", "多来源同时勾选时自动合流处理；转录中为每一句独立保留专属来源标签。", "生效中"]
  ].forEach(function (r, i, all) {
    closureCheckRow(src, r[0], r[1], r[2], function (box) {
      pill(box, r[0] === "Off" ? "Off" : "Ready", r[3]);
    }, 520);
    if (i < all.length - 1) hairline(src);
  });
  spacer(src);
  hairline(src);
  const sFoot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(sFoot, text("note", "来源列表只列正在出声或最近出过声的 App；列表为空时先去那个 App 里放一声。",
    "Subheadline", V["text/tertiary"], { w: 620 }));
  add(src, stretch(sFoot));

  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sSideHead = frame("sHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(sSideHead, text("title", "本次会议", "Title / Page", V["text/primary"]));
  add(sSideHead, text("badge", "还没有开始", "Caption", V["text/tertiary"]));
  add(side, stretch(sSideHead));
  hairline(side);
  const sBody = frame("sBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
    [
      ["运行档位", "Quality（本机最强）"],
      ["音频来源", "麦克风 + 本机音频"],
      ["说话人标签", "已开 · 最多 4 位"],
      ["采集格式", "24 kHz → 内部 16 kHz"],
      ["保存位置", "记录库 · 长期保留"]
    ].forEach(function (kv) { kvRow(sBody, kv[0], kv[1]); });
    add(side, stretch(sBody));
  spacer(side);
  hairline(side);
  const sActs = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
  secondaryButton(sActs, "检查输入电平", "audio-waveform");
  spacer(sActs);
  add(side, stretch(sActs));

  const blocked = card(d, "blocked", { pad: 0, gap: 0, clip: true });
  const bHead = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(bHead, text("title", "来源不可用时", "Heading / Section", V["text/primary"]));
  spacer(bHead);
  add(bHead, text("detail", "三种情况各自一行，说明影响与唯一出口；不弹对话框、不静默留空。",
    "Callout", V["text/secondary"]));
  add(blocked, stretch(bHead));
  hairline(blocked);
  [
      ["Attention", "未授权", "本机音频：系统里没给「音频录制」权限时那一路会是空音轨——不如现在说清楚。", "打开系统设置"],
      ["Attention", "列表为空", "没有正在出声的 App：先去那个 App 里放一声再回来选；麦克风这一路不受影响。", "重新扫描"],
      ["Attention", "来源中断", "所选 App 退出了：它重新出声时会自动接回，记录里标一段「来源中断」。",
        "知道了"]
  ].forEach(function (r, i, all) {
    closureCheckRow(blocked, r[0], r[1], r[2], function (box) {
      secondaryButton(box, r[3]);
    }, 520);
    if (i < all.length - 1) hairline(blocked);
  });
  spacer(blocked);
  return blocked;
}

// --- M4. 会议助手 · 内心 OS（私密问答） ----------------------------------------
//
// 会中提问的答案**只有提问的人看得到**：不进会议音频、不进转录、默认不进纪要。这三条
// 是这块画板存在的理由——它是会议闭环里唯一一条「不打断录制、也不被别人听见」的分支。
//
// 答案必须带证据（哪一段、谁说的），因为会中判断不能靠猜：引用来自本次会议的转录，
// 不联网检索。
function screenClosureMeetingInnerOS(d) {
  meetingShell(d, {
    subtitle: "会中问一句：答案只有你看得到，且不会打断这一场录音。",
    headActions: function (row) {
      kbdInRow(row, "⌘⇧.", 34);
      secondaryButton(row, "静音麦克风", "mic-off");
      primaryButton(row, "结束会议", "square", 118);
    },
      status: {
        tone: "attention", phase: "正在录音 · 正在生成回答", title: "周会 · 本机音频 + 麦克风",
        time: "00:12:47", level: 0.44,
        facts: ["3 位说话人 · 已标出", "OS 已问 3 次"],
        actions: [["取消生成", "x"]]
      },
    transcript: function (stream) {
      const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
      add(head, text("title", "转录", "Heading / Section", V["text/primary"]));
      spacer(head);
      add(head, text("detail", "提问不打断录音：转录照常往下走", "Callout", V["text/secondary"]));
      add(stream, stretch(head));
      hairline(stream);
      [
        { who: "说话人 B", src: "麦克风", time: "00:12:31", text: "好，先把这段记下来。" },
        { who: "说话人 A", src: "本机音频", time: "00:12:36",
          text: "我们这边按 8 月 22 日交付，测试前一天拿到就行。" },
        { who: "说话人 C", src: "本机音频", time: "00:12:40",
          text: "对，那天前给到测试，我这边留两天回归。" }
      ].forEach(function (t) {
        turnRow(stream, { who: t.who, src: t.src, time: t.time, text: t.text, width: 600 });
      });
      spacer(stream);
      hairline(stream);
        const foot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
        add(foot, text("note", "问答只给你看，不混进转录：这一段无论你问不问，录到的都只是会议本身。",
          "Subheadline", V["text/tertiary"], { w: 640 }));
      add(stream, stretch(foot));
    },
    side: function (side) {
      meetingInfoSide(side, {
        badge: "录制中 · 还没存好",
        // 右栏的高度是「这一行剩下的高度」，不是按内容撑——展开的 OS 抽屉把这一段吃掉一大截
        // （实测 2026-09-18：`sideBody +50B h275/302`）。所以这一态只留 5 行，把「分人」「整理」
        // 让给状态条与其它态（那两条在状态条上已经写着）。右栏不是信息仓库，是当前状态的摘要。
        rows: [
          ["时长", "00:12:47"],
          ["转录", "149 段"],
          ["说话人", "3 位（匿名标签）"],
          ["音频来源", "麦克风 + 腾讯会议"],
          ["保存位置", "记录库"]
        ],
        noteLabel: "问不出来的时候",
        noteBody: "没证据就说没证据；模型没配走设置；生成中可以取消，不影响录制。"
      });
    },
    drawer: function (page) { meetingOSPanel(page); }
  });
}

// --- M5. 会议助手 · 录制中断 ---------------------------------------------------
//
// 端到端旅程里唯一一处「会议已经开了、但声音断了」：服务重启、系统睡眠、App 自己退出、
// 以及被 tap 的来源 App 退出。四种断法的后果不一样，所以不能只写一句「出错了」——
// 哪一种会自动接回、哪一种必须人来决定，就是这块板要回答的事。
//
// 一条硬规则：**不静默续录**。断点之后如果悄悄接着写，记录里会出现一段没有来源的文本，
// 事后没人分得清那是「这段没人说话」还是「这一段根本没录上」。所以续接一定是一个动作，
// 并且把中断区间写进记录——导出物里也看得见。
function screenClosureMeetingInterrupted(d) {
  pageHead(d, "会议助手", "把一段多人谈话变成可检索的文本和纪要；音频不留存。",
    function (row) {
      secondaryButton(row, "打开数据目录", "folder-open");
      primaryButton(row, "继续这一段", "play", 132);
      sideToggle(row, "会议信息");
    });

  sessionStatusBar(d, {
    tone: "attention", phase: "录制中断", title: "周会 · 本机音频 + 麦克风",
    time: "00:12:40", level: 0.02, facts: ["停在 00:12:40 · 语音服务重启", "148 段已存好"],
    actions: [["结束并整理", "square"]]
  });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const stream = card(split, "transcript", { pad: 0, gap: 0, clip: true });
  grow(stream);
  const tHead = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
    add(tHead, text("title", "转录停在断点", "Heading / Section", V["text/primary"]));
    spacer(tHead);
    add(tHead, text("detail", "148 段 · 已经存进记录库", "Callout", V["text/secondary"]));
  add(stream, stretch(tHead));
  hairline(stream);
  [
    { who: "说话人 B", time: "00:12:22", text: "那我先按这个排期，等一下再确认一下名字。" },
    { who: "说话人 A", time: "00:12:31", text: "好，先把这段记下来。" },
    { who: "说话人 C", time: "00:12:40", text: "……那我这边先挂一下。" }
  ].forEach(function (t) {
    turnRow(stream, { who: t.who, time: t.time, text: t.text, width: 700 });
  });
  const gapRow = frame("gap", { layout: "HORIZONTAL", gap: 10, align: "CENTER",
    padX: 16, padY: 10 });
  icon(gapRow, "triangle-alert", 16, V["status/attention"]);
  add(gapRow, text("t", "00:12:40 起中断 · 这一段没有文本", "Callout", V["status/attention"]));
  spacer(gapRow);
  add(gapRow, text("hint", "中断区间进记录，导出物里也标出来。", "Caption", V["text/tertiary"]));
  add(stream, stretch(gapRow));
  spacer(stream);
  hairline(stream);
  const tFoot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(tFoot, text("note",
    "断点之前的正文照常可读、可搜、可导出：中断不会把已经存下的内容回滚掉。",
    "Subheadline", V["text/tertiary"], { w: 700 }));
  add(stream, stretch(tFoot));

  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sHead = frame("sHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(sHead, text("title", "会议信息", "Title / Page", V["text/primary"]));
  add(sHead, text("badge", "中断 · 还没存好", "Caption", V["text/tertiary"]));
  add(side, stretch(sHead));
  hairline(side);
  const sBody = frame("sBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
  [
      ["中断时刻", "00:12:40"],
      ["中断原因", "语音服务重启"],
      ["已存好", "148 段 · 不受影响"],
      ["说话人标签", "已降级 · 停在断点"],
      ["来源", "腾讯会议 + 麦克风"],
      ["保存位置", "记录库 · 长期保留"]
    ].forEach(function (kv) { kvRow(sBody, kv[0], kv[1]); });
  add(sBody, text("label", "续接是显式动作", "Caption / Medium", V["text/secondary"]));
  add(sBody, text("desc",
    "断点之后不会悄悄接着写：否则事后分不清「这段没人说话」和「这段没录上」。",
    "Subheadline", V["text/secondary"], { w: 308 }));
    add(side, stretch(sBody));

    const kinds = card(d, "kinds", { pad: 0, gap: 0, clip: true });
  const kHead = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(kHead, text("title", "四种断法，各自的出口", "Heading / Section", V["text/primary"]));
  spacer(kHead);
  add(kHead, text("detail", "会自动接回的只有一种；其余都要你决定。",
    "Callout", V["text/secondary"]));
  add(kinds, stretch(kHead));
  hairline(kinds);
  [
    ["Attention", "语音服务重启或不可达", "收声先停，正文照旧；服务回来后「继续这一段」新开一路音频，并把中断区间写进记录。", "继续这一段"],
      ["Attention", "系统睡眠 / 合盖", "醒来就是中断态：麦克风与音频来源都要重新拿一次，所以不自动续——续接要你点一下。", "继续这一段"],
    ["Critical", "App 退出或崩溃", "下次启动把这条记录标成「未正常结束」并存好；转录一条不丢，也不留一条永远「录制中」的记录。", "打开记录库"]
  ].forEach(function (r, i, all) {
    closureCheckRow(kinds, r[0], r[1], r[2], function (box) {
      secondaryButton(box, r[3]);
    }, 620);
    if (i < all.length - 1) hairline(kinds);
  });
  hairline(kinds);
  const kFoot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
    add(kFoot, text("note",
      "来源 App 退出不算中断：它重新出声就自动接回，录制不打断，只写一条中断区间。",
      "Subheadline", V["text/tertiary"], { w: 900 }));
  add(kinds, stretch(kFoot));
  return kinds;
}

// --- J0. 会话 · 首次使用 · 空态引导（三能力起点） ---------------------------------
//
// 产品经理面向用户旅程审查（未决项 4 / G6 缺口闭环）：全新安装或清空数据库后，
// `sessions.sqlite3` 为空。此画板呈现无历史记录时的初见引导体验：
// 顶部欢迎横幅（本地引擎就绪、音频不存盘、数据长期保留）+ 三条核心会话能力卡片
// （语音助手 ⌘6 / 会议助手 ⌘7 / 实时字幕 ⌘8），每张卡片给出明确的起手入口与说明，
// 底部标注数据存储位置与本地安全承诺。
function screenClosureFirstRunEmpty(d) {
  pageHead(d, "会话", "单人 Apple Silicon Mac 上的本地语音会话中心；音频不存盘，记录在库长期保留。",
    function (row) {
      secondaryButton(row, "会话设置", "sliders-horizontal");
    });

  conclusionBand(d, {
    tone: "Ready",
    title: "本地语音引擎已就绪",
    body: "语音识别、语音合成与说话人分离常驻本机，不访问外部网络，原始音频不存盘。",
    hint: "会话记录保存在本机 SQLite 数据库，跨启动长期留存。从下方三项任选一项开启。",
    actions: []
  });

  const cardsRow = frame("cardsRow", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(cardsRow)));

  // 卡片 1：语音助手 (J1)
  const cAssistant = card(cardsRow, "cardAssistant", { pad: 20, gap: 14, clip: true });
  grow(cAssistant);
  const aHead = frame("aHead", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  icon(aHead, "message-circle", 20, V["accent/rail"]);
  add(aHead, text("title", "语音助手", "Heading / Section", V["text/primary"]));
  spacer(aHead);
  kbd(aHead, "⌘6");
  add(cAssistant, stretch(aHead));
  add(cAssistant, text("desc",
    "与大模型进行语音与文字互动。支持自然打字、耳机实时对讲插话、随时切换音色，对话与记忆沉淀在本地。",
    "Callout", V["text/secondary"], { w: 320 }));
  hairline(cAssistant);
  const aFeatures = frame("aFeatures", { layout: "VERTICAL", gap: 6 });
  [
    "语音与打字双通道输入",
    "耳机实时对讲（支持自然插话打断）",
    "对话跨启动记忆，音色随时可换"
  ].forEach(function (ft) {
    const fRow = frame("ft", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
    icon(fRow, "check", 13, V["status/ready"]);
    add(fRow, text("t", ft, "Subheadline", V["text/secondary"]));
    add(aFeatures, fRow);
  });
  add(cAssistant, stretch(aFeatures));
  spacer(cAssistant);
  primaryButton(cAssistant, "进入语音助手", "message-circle");

  // 卡片 2：会议助手 (J2)
  const cMeeting = card(cardsRow, "cardMeeting", { pad: 20, gap: 14, clip: true });
  grow(cMeeting);
  const mHead = frame("mHead", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  icon(mHead, "users", 20, V["accent/voice"]);
  add(mHead, text("title", "会议助手", "Heading / Section", V["text/primary"]));
  spacer(mHead);
  kbd(mHead, "⌘7");
  add(cMeeting, stretch(mHead));
  add(cMeeting, text("desc",
    "多人会谈或线上会议记录。支持麦克风与本机 App 音频独立混音，CoreML 本地说话人分离与会后智能纪要。",
    "Callout", V["text/secondary"], { w: 320 }));
  hairline(cMeeting);
  const mFeatures = frame("mFeatures", { layout: "VERTICAL", gap: 6 });
  [
    "麦克风与系统音频按 App 多选录制",
    "CoreML 本地说话人分离（不上传声纹）",
    "会中内心 OS 提问，会后多版本纪要"
  ].forEach(function (ft) {
    const fRow = frame("ft", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
    icon(fRow, "check", 13, V["status/ready"]);
    add(fRow, text("t", ft, "Subheadline", V["text/secondary"]));
    add(mFeatures, fRow);
  });
  add(cMeeting, stretch(mFeatures));
  spacer(cMeeting);
  primaryButton(cMeeting, "进入会议助手", "users");

  // 卡片 3：实时字幕 (J3)
  const cCaptions = card(cardsRow, "cardCaptions", { pad: 20, gap: 14, clip: true });
  grow(cCaptions);
  const cpHead = frame("cpHead", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  icon(cpHead, "captions", 20, V["status/info"]);
  add(cpHead, text("title", "实时字幕", "Heading / Section", V["text/primary"]));
  spacer(cpHead);
  kbd(cpHead, "⌘8");
  add(cCaptions, stretch(cpHead));
  add(cCaptions, text("desc",
    "无感贴屏实时转录。轻量悬浮字幕带浮在任意窗口之上，不抢焦点；会后自动归档到记录库，支持导出 SRT。",
    "Callout", V["text/secondary"], { w: 320 }));
  hairline(cCaptions);
  const cpFeatures = frame("cpFeatures", { layout: "VERTICAL", gap: 6 });
  [
    "悬浮字幕带贴屏跟随，不抢占焦点",
    "上滚回看即停，支持大字档位切换",
    "结束自动归档，一键导出标准 SRT"
  ].forEach(function (ft) {
    const fRow = frame("ft", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
    icon(fRow, "check", 13, V["status/ready"]);
    add(fRow, text("t", ft, "Subheadline", V["text/secondary"]));
    add(cpFeatures, fRow);
  });
  add(cCaptions, stretch(cpFeatures));
  spacer(cCaptions);
  primaryButton(cCaptions, "启动实时字幕", "captions");

  // 底部资产提示条
  const foot = card(d, "foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 10 });
  icon(foot, "shield-check", 15, V["status/ready"]);
  add(foot, text("storage",
    "隐私与资产：原始音频不上传也不存盘；转录、纪要与对话记录保存在本地 SQLite（~/Library/Application Support/SpeechRail/sessions.sqlite3）。",
    "Caption", V["text/secondary"]));
  spacer(foot);
  add(foot, text("hint", "随时可在设置页备份或导出记录库", "Caption", V["text/tertiary"]));
  add(d, stretch(foot));
}

// --- A0. 语音助手 · 未开始（先定人设与音色） -------------------------------------
//
// 人设为什么必须在这里定死：它是 system prompt 的一部分。会话开始之后再换，大模型的前缀
// 缓存从改动点之后整段失效，之后每一轮都要重算前缀——用户感受到的是「莫名其妙变慢」。
// 所以「定人设」只在这一块板上存在，对话中那一块（A5）给的是锁 + 出口（用户 2026-09-17）。
//
// 这块板也顺便补上原本缺的一格：助手此前只有「未配置模型」（受阻）与「对话中」两态，
// 没有「已经就绪、但还没开始」这一态——而人设恰好只能在那一态里问。
  function screenClosureAssistantReady(d) {
    pageHead(d, "语音助手", "定好人设与音色就能开始；说也行，打字也行。", function (row) {
      secondaryButton(row, "打开设置", "sliders-horizontal");
      primaryButton(row, "开始对话", "message-circle", 132);
      sideToggle(row, "本次对话");
    });

    conclusionBand(d, {
      tone: "Ready",
      title: "现在就能开始",
      body: "人设是它开口前读的第一段话，只在这一步定——开始之后再改，之后每一轮都会慢一点。" +
        "音色只影响朗读，随时能换，下一句就听得出来。",
      hint: "两条都随这段记录保存；从记录库「继续这一轮」是一轮新对话，所以那里可以重新选人设。",
      actions: [["试听音色", "play"]]
    });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const persona = card(split, "persona", { pad: 0, gap: 0, clip: true });
  grow(persona);
  const pHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 16, padY: 14 });
    add(pHead, text("title", "人设（角色风格）", "Heading / Section", V["text/primary"]));
    add(pHead, text("detail",
      "只改「怎么答」，不改「知道什么」：助手记住的事归「记忆」那一栏管，不在这里改。",
    "Callout", V["text/secondary"]));
  add(persona, stretch(pHead));
  hairline(persona);
  [
    // 第一栏是胶囊里的名字，必须短（这一行的格宽按最长的那条定，见 closureCheckRow）。
    ["Ready", "耐心讲解", "默认：先给结论，再补一句为什么；适合边看材料边问。", "已选"],
    ["Off", "简洁答问", "一次只答被问到的那件事，不展开；适合连续追问。", "可选"],
    ["Off", "主持人", "会主动复述结论并收口；适合会议里当场用。", "可选"]
  ].forEach(function (r, i, all) {
    closureCheckRow(persona, r[0], r[1], r[2], function (box) {
      pill(box, r[0], r[3]);
    }, 520);
    if (i < all.length - 1) hairline(persona);
  });
  spacer(persona);
  hairline(persona);
  const pFoot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(pFoot, text("note", "开始之后这一项变成只读：要换人设就新开一轮对话，记录不会丢。",
    "Subheadline", V["text/tertiary"], { w: 520 }));
  spacer(pFoot);
  secondaryButton(pFoot, "新建自定义人设");
  add(persona, stretch(pFoot));

  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sHead = frame("sHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(sHead, text("title", "本次对话", "Title / Page", V["text/primary"]));
  add(sHead, text("badge", "还没有开始", "Caption", V["text/tertiary"]));
  add(side, stretch(sHead));
  hairline(side);
  const sBody = frame("sBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
    [
      ["对话模型", "已连接 · 本机服务"],
      ["输入方式", "语音或打字"],
      ["对讲模式", "一问一答（外放）"],
      ["输入设备", "系统默认"],
      ["人设", "耐心讲解 · 本轮定"],
      ["音色", "夜航主持"]
    ].forEach(function (kv) { kvRow(sBody, kv[0], kv[1]); });
    add(side, stretch(sBody));
  spacer(side);
  hairline(side);
  const sActs = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
  secondaryButton(sActs, "检查输入电平", "audio-waveform");
  spacer(sActs);
  add(side, stretch(sActs));

  const voices = card(d, "voices", { pad: 0, gap: 0, clip: true });
  const vHead = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(vHead, text("title", "音色", "Heading / Section", V["text/primary"]));
  spacer(vHead);
    add(vHead, text("detail", "音色只影响朗读，所以开始之后仍然能随时换，下一句就听得见。",
      "Callout", V["text/secondary"], { w: 520 }));
  add(voices, stretch(vHead));
  hairline(voices);
    [
      ["Ready", "夜航主持", "内置声音 · 一直在用", "当前"],
      ["Off", "温柔讲解", "内置声音", "可选"],
      ["Off", "播报腔", "内置声音", "可选"],
      // 胶囊里放短名，原因在第三栏说明——与音频来源那张表同一个规矩。
      ["Attention", "会议备用", "用一段录音做的 · 这台 Mac 现在跑不了它", "现在用不了"]
    ].forEach(function (r, i, all) {
    closureCheckRow(voices, r[0], r[1], r[2], function (box) {
      pill(box, r[0], r[3]);
    }, 520);
    if (i < all.length - 1) hairline(voices);
  });
  return voices;
}

// --- A3. 语音助手 · 会话记录（记录库） -----------------------------------------
//
// 对话记录是**资产**，不是一次会话的残影（用户 2026-09-17：三个功能的记录都写进本机
// SQLite，长期保存）。所以这块画板画的不是「刚才那段」，而是一个记录库：列表里有历史、
// 选中的一条能继续、能导出、能改名、能移除。
//
// 只画「结束语 + 这一段 + 一个删除按钮」是一次性设计——它默认用户关掉窗口就不再回来，
// 而记录既然长期保留，回来看见的第一件事就该是列表，不是一段孤立的转录。
  function screenClosureAssistantClosed(d) {
    pageHead(d, "语音助手", "和本机大模型用语音一来一往；记录长期留在记录库。",
      function (row) {
        kbdInRow(row, "⌘⇧.", 34);
        secondaryButton(row, "导出 Markdown", "download");
        secondaryButton(row, "新建对话", "message-circle");
        sideToggle(row, "记录信息");
      });

  conclusionBand(d, {
      tone: "Ready",
      title: "刚结束的这段已写进记录库",
      body: "「分享开场」12 轮 · 00:06:18，排在列表最上面并已选中。记录留在记录库、长期保存，" +
        "人设与音色随记录一起存；接着聊会从这一轮的上下文继续。",
      hint: "「结束对话」只结束这一次交互，不删除记录——移除是另一个动作，只在这一页给，并且会先确认。",
      // 复制全文在这一屏只给一处（记录卡页脚那一处）：结论条是说明，不是第二个动作区。
      actions: []
    });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  // 左：记录库。三条闭环的产物长同一个样子——列表 + 选中 + 详情，因为三种记录住在
  // 同一个本机数据库里，没有理由让它们长得不一样。
  const library = card(split, "library", { pad: 0, gap: 0, clip: true });
  size(library, SESSION_LIST_W, null);
  add(split, stretch(library));
  const lHead = frame("lHead", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 12 });
    add(lHead, text("title", "对话记录", "Heading / Section", V["text/primary"]));
  spacer(lHead);
  add(lHead, text("count", "38 段", "Callout", V["text/secondary"]));
  add(library, stretch(lHead));
  const lSearch = frame("lSearch", { layout: "HORIZONTAL", padX: 16, padY: 4 });
  searchField(lSearch, "搜索记录", 248);
  add(library, stretch(lSearch));
  hairline(library);
  [
    { title: "分享开场", sub: "今天 14:02 · 12 轮", badge: ["Ready", "刚刚"], selected: true },
    { title: "Podcast 提纲", sub: "今天 11:20 · 8 轮" },
    { title: "纪要追问", sub: "9月16日 16:40 · 23 轮" },
    { title: "英文发音练习", sub: "9月15日 09:05 · 41 轮", badge: ["Info", "已导出"] },
    { title: "读书笔记口述", sub: "9月12日 21:10 · 17 轮" },
    { title: "文件命名讨论", sub: "9月11日 08:30 · 6 轮" }
  ].forEach(function (m, i, all) {
    meetingRow(library, {
      title: m.title, sub: m.sub, badge: m.badge, selected: m.selected, width: 196
    });
    if (i < all.length - 1) hairline(library);
  });
  spacer(library);
  hairline(library);
  const lFoot = frame("lFoot", { layout: "HORIZONTAL", padX: 16, padY: 10 });
    add(lFoot, text("note", "搜索标题与正文；记录长期留在记录库，App 重启也在。",
      "Subheadline", V["text/tertiary"], { w: 248 }));
  add(library, stretch(lFoot));

  const record = card(split, "record", { pad: 0, gap: 0, clip: true });
  grow(record);
  const rHead = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(rHead, text("title", "分享开场", "Title / Page", V["text/primary"]));
  add(rHead, text("badge", "已结束 · 14:08", "Caption", V["text/tertiary"]));
  spacer(rHead);
  add(rHead, text("detail", "12 轮 · 人设与音色随记录一起存", "Callout", V["text/secondary"]));
  add(record, stretch(rHead));
  hairline(record);
  [
    { who: "你", time: "14:02:11", text: "今天这场分享的开头有点长，能不能压到三句话？" },
    { who: "助手", accent: true, badge: "夜航主持", time: "14:02:16",
      text: "可以。三句话的版本是：我们做的是一个本机语音引擎；它把语音变成文字，也把文字变成声音；" +
        "整个过程不出这台 Mac。" },
    { who: "你", time: "14:02:31", text: "第二句再短一点。" },
    { who: "助手", accent: true, badge: "夜航主持", time: "14:02:35",
      text: "好的：语音进来，文字和声音出去，全程离线。" },
    { who: "你", time: "14:03:40", text: "那如果我想让它记住上一场会议的结论……" }
  ].forEach(function (t) {
    turnRow(record, {
      who: t.who, accent: t.accent, badge: t.badge, time: t.time, text: t.text, width: 520
    });
  });
  spacer(record);
  hairline(record);
  const rFoot = frame("foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 10 });
  add(rFoot, text("note", "继续这一轮会接在第 12 轮后面，不会新建一段记录。",
    "Subheadline", V["text/tertiary"]));
  spacer(rFoot);
  secondaryButton(rFoot, "复制全文", "copy");
  add(record, stretch(rFoot));

  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sHead = frame("sHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
  add(sHead, text("title", "记录信息", "Title / Page", V["text/primary"]));
  add(sHead, text("badge", "从记录库打开 · 已保存", "Caption", V["text/tertiary"]));
  add(side, stretch(sHead));
  hairline(side);
  const sBody = frame("sBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
  [
    ["结束于", "14:08"],
    ["轮数", "12 轮"],
    ["时长", "00:06:18"],
    ["音色", "夜航主持"],
    ["人设", "耐心讲解"],
      ["大模型", "qwen3-30b"],
      ["记录库", "38 段对话 · 长期保留"],
      ["保存位置", "记录库 · 长期保留"]
    ].forEach(function (kv) { kvRow(sBody, kv[0], kv[1]); });
  add(sBody, text("label", "移除只在这一页给", "Caption / Medium", V["text/secondary"]));
  add(sBody, text("desc",
    "记录是资产：App 或服务重启都不会丢。移除一条会先确认；对话正文不写日志，导出物里也只有文本。",
    "Subheadline", V["text/secondary"], { w: 308 }));
  add(side, stretch(sBody));
  spacer(side);
  hairline(side);
  const sActs = frame("actions", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  primaryButton(sActs, "继续这一轮", "message-circle");
  const actsRow = frame("row", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  secondaryButton(actsRow, "重命名");
  secondaryButton(actsRow, "从记录库移除");
  add(sActs, stretch(actsRow));
  add(side, stretch(sActs));
}

// --- A4. 语音助手 · 实时对讲（耳机 · 可打断） ----------------------------------
//
// 两种模式的差别不是「免持 / 按住说话」，而是**能不能打断它**：
//   一问一答（外放）：它说话时闭麦，你说完它再答——半双工，回声靠闭麦挡住。
//   实时对讲（耳机）：全双工，你一开口它就停——服务端在 `speech_started` 时原子取消
//   正在播的 TTS（`response.cancel`），随后 250ms 冷却防自激。这一条是 SpeechRail
//   `/v1/realtime` 已有的能力（contracts/realtime-openai.md §全双工打断），不是新造的。
//
// 打断要画出来，否则用户只看到「助手话没说完」：那一句上挂「被打断」，详情说清它停在哪。
  function screenClosureAssistantDuplex(d) {
  pageHead(d, "语音助手", "和本机大模型用语音一来一往；两种对讲模式随时切。", function (row) {
    kbdInRow(row, "⌘⇧.", 34);
    secondaryButton(row, "人设与音色", "sliders-horizontal");
    primaryButton(row, "结束对话", "square", 118);
    sideToggle(row, "本次对话");
  });

    sessionStatusBar(d, {
      tone: "ready", phase: "刚被你打断", title: "第 12 轮 · 实时对讲",
      time: "00:03:42", level: 0.16,
      facts: ["耳机 · AirPods Pro", "打断生效 · 冷却 0.25 秒"],
      actions: [["静音麦克风", "mic-off"]]
    });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const stream = card(split, "stream", { pad: 0, gap: 0, clip: true });
  grow(stream);
  const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(head, text("title", "对话", "Heading / Section", V["text/primary"]));
  spacer(head);
    add(head, text("mem", "12 轮 · 实时对讲", "Callout", V["text/secondary"]));
  add(stream, stretch(head));
  hairline(stream);
  [
    { who: "你", time: "14:03:40", text: "我想加一个：它能记住上一场会议的结论吗？" },
    { who: "助手", accent: true, badge: "夜航主持", time: "14:03:52",
      pill: ["Attention", "被打断"],
      text: "可以。上一场会议的纪要就在本机", actions: ["play", "copy"] },
    { who: "你", time: "14:03:58", text: "先别念了，直接给我三条要点。" },
      { who: "助手", accent: true, badge: "夜航主持", time: "14:04:06",
        text: "一、纪要和转录都长期留在记录库；二、字幕记录也能导出 SRT；三、换音色不影响已经说过的内容。",
        actions: ["play", "copy"], partial: false }
  ].forEach(function (t) {
    turnRow(stream, {
      who: t.who, accent: t.accent, badge: t.badge, pill: t.pill, time: t.time,
      text: t.text, actions: t.actions, width: 700
    });
  });
  spacer(stream);
  hairline(stream);
  const foot = frame("foot", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 10 });
    add(foot, text("note",
      "被打断的那一句停在「纪要就在本机」：你一开口它就停下正在说的这句；正文保留到停下为止。",
      "Subheadline", V["text/tertiary"], { w: 560 }));
  spacer(foot);
  secondaryButton(foot, "重放这一句", "play");
  add(stream, stretch(foot));

  const side = card(split, "inspector", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const sHead = frame("sHead", { layout: "VERTICAL", gap: 4, padX: 16, padY: 16 });
    add(sHead, text("title", "本次对话", "Title / Page", V["text/primary"]));
    add(sHead, text("badge", "实时对讲 · 进行中", "Caption", V["text/tertiary"]));
  add(side, stretch(sHead));
  hairline(side);
  const sBody = frame("sBody", { layout: "VERTICAL", gap: 10, padX: 16, padY: 16 });
  [
      ["对讲模式", "实时对讲（耳机）"],
      ["打断", "开启 · 你一开口就停"],
      ["冷却", "0.25 秒"],
      ["输入设备", "AirPods Pro"],
      ["音色", "夜航主持"],
      ["回声防护", "系统回声消除"]
    ].forEach(function (kv) { kvRow(sBody, kv[0], kv[1]); });
  add(sBody, text("label", "两种模式的差别", "Caption / Medium", V["text/secondary"]));
    add(sBody, text("desc",
      "一问一答（外放）：它说话时闭麦。实时对讲（耳机）：你随时能插话，一开口就打断它；" +
        "外放也能用，回声由系统消除。",
      "Subheadline", V["text/secondary"], { w: 308 }));
  add(side, stretch(sBody));
  spacer(side);
  hairline(side);
  const sActs = frame("actions", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
  secondaryButton(sActs, "回声自检", "audio-waveform");
  spacer(sActs);
  add(side, stretch(sActs));

  const controls = card(d, "controls", {
    layout: "VERTICAL", gap: 8, padX: 16, padY: 12
  });
  const cRow = frame("row", { layout: "HORIZONTAL", gap: 12, align: "CENTER" });
  segmented(cRow, ["一问一答（外放）", "实时对讲（耳机）"], 1,
    ["seg/一问一答（外放）", "seg/实时对讲（耳机）"]);
  spacer(cRow);
    add(cRow, text("note",
      "换输入设备会重开这一段：已经说过的不会丢，当前这一轮标成「换设备」。",
      "Caption", V["text/tertiary"], { w: 700 }));
  add(controls, stretch(cRow));
  return controls;
}

// --- A5. 语音助手 · 对话页 · 换音色（下一句生效） -------------------------------
//
// 「随时换」只对音色成立。音色的关键不是选择器而是**边界**：下一句生效，已经说过的内容与
// 已经存下的记录都不被改写——这句话要写在结论条里，否则用户会怀疑「换了音色，前面说的是
// 不是也变了」。
//
// 人设相反：它是这一段对话开始时的常量（用户 2026-09-17）。它改的是「它怎么和你说话」，
// 中途换掉就得把开头重读一遍。所以这块板上人设只有**锁 + 一个出口**，没有选择器；两个
// 动作的差别不在这里讲，讲完整的地方是 closureVoicePersonaBoard（用户 2026-09-18：
// 「换音色 与 换人设 的影响 请深入分析，重新绘制」）。
function screenClosureAssistantVoice(d) {
  pageHead(d, "语音助手", "声音随时能换，下一句就听得出来；要换人设得新开一轮。",
    function (row) {
      primaryButton(row, "结束对话", "square", 118);
      sideToggle(row, "本次对话");
    });

  conclusionBand(d, {
    tone: "Ready",
    title: "换音色只改声音，这一段对话不重来",
    body: "字、记录、纪要一个字都不动，刚才聊的还接得上。这个音色用不了时（这台 Mac 现在" +
      "跑不了它，或者它已经不在列表里）这一句仍用原来的声音说，并当场写明原因——不静默失败。",
    hint: "人设是另一回事：它改的是它怎么和你说话，本轮锁住，要换得新开一轮。",
    actions: [["它俩差在哪？", "audio-waveform"], ["新开一轮以换人设", "plus"]]
  });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const stream = card(split, "stream", { pad: 0, gap: 0, clip: true });
  grow(stream);
  const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(head, text("title", "对话", "Heading / Section", V["text/primary"]));
  spacer(head);
  add(head, text("detail", "第 13 句起：音色 温柔讲解 · 人设仍是「耐心讲解」",
    "Callout", V["text/secondary"]));
  add(stream, stretch(head));
  hairline(stream);
  // 这一轮里两种请求同时出现——这正是用户真实的说法。所以回复把它拆开：能立刻办的那半句
  // 办了，属于人设的那半句给出口，而不是含糊地「好的」。
  [
    { who: "你", time: "14:05:10", text: "换个声音，讲得温柔一点，回答短一些。" },
    { who: "助手", accent: true, badge: "夜航主持", time: "14:05:14",
      text: "换声音随时可以，下一句就换。「回答短一些」是说话的方式，属于人设——本轮改不了，"
        + "要的话我们下一轮用新的开始。", actions: ["play"] },
    { who: "助手", accent: true, badge: "温柔讲解", time: "14:05:19",
      text: "纪要在记录库里，长期保存。随时能翻。", actions: ["play", "copy"] },
    { who: "你", time: "14:05:31", text: "好，那先这样，下一轮再调。" }
  ].forEach(function (t) {
    turnRow(stream, {
      who: t.who, accent: t.accent, badge: t.badge, time: t.time, text: t.text,
      actions: t.actions, width: 620
    });
  });
  spacer(stream);
  hairline(stream);
  const foot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(foot, text("note",
    "第 12 句以前仍是「夜航主持」；换音色只改标签和之后说出来的声音，不改正文，也不改写" +
      "已经存下的记录。属于人设的那半句请求没有静默丢掉——它给了一个出口。",
    "Subheadline", V["text/tertiary"], { w: 620 }));
  add(stream, stretch(foot));

  const side = card(split, "voices", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const vHead = frame("vHead", { layout: "VERTICAL", gap: 3, padX: 16, padY: 14 });
  add(vHead, text("title", "音色", "Heading / Section", V["text/primary"]));
  add(vHead, text("detail", "这台 Mac 现在用不了的那几个会写明原因，不藏起来。",
    "Callout", V["text/secondary"]));
  add(side, stretch(vHead));
  hairline(side);
  [
    ["夜航主持", "内置声音 · 一直在用", ["Ready", "当前"]],
    ["温柔讲解", "内置声音", ["Ready", "使用中"]],
    ["播报腔", "内置声音", ["Off", "可选"]],
    ["我的音色 · 会议备用", "用一段 6 秒录音做的 · 现在跑不了它",
      ["Attention", "现在用不了"]]
  ].forEach(function (v, i, all) {
    const row = frame("voice", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 11 });
    const info = frame("info", { layout: "VERTICAL", gap: 3 });
    add(info, text("name", v[0], "Body / Medium", V["text/primary"]));
    add(info, text("sub", v[1], "Caption", V["text/tertiary"], { w: 176 }));
    add(row, grow(info));
    pill(row, v[2][0], v[2][1]);
    iconButton(row, "play", 26);
    add(side, stretch(row));
    if (i < all.length - 1) hairline(side);
  });
  spacer(side);
  hairline(side);
  const pBody = frame("pBody", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(pBody, text("label", "人设（说话的方式） · 本轮已定", "Caption / Medium", V["text/secondary"]));
  // 只读，不是「选不动的选择器」：锁 + 名字 + 出口。画成灰掉的 chip 会让用户以为
  // 「条件是没满足」，而这里的事实是「规则不允许」——两者的出口不一样。
  const chips = frame("chips", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  const chip = frame("Persona Chip", {
    layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 10, padY: 4, radius: 999,
    fill: V["surface/field"], stroke: V["border/separator"], strokeWeight: 1
  });
  icon(chip, "lock", 12, V["text/tertiary"]);
  add(chip, text("label", "耐心讲解 · 只读", "Callout", V["text/secondary"]));
  add(chips, chip);
  add(pBody, stretch(chips));
  add(pBody, text("desc",
    "开始那一刻就定了，本轮不再变：留着这段开头，回答才快。中途换掉，" +
      "之后每一轮都要重读一遍——你会觉得它突然变慢，也不像刚才那个助手。" +
      "要换：新开一轮。",
    "Subheadline", V["text/secondary"], { w: 300 }));
  add(side, stretch(pBody));
  spacer(side);
  hairline(side);
  const vActs = frame("acts", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
  spacer(vActs);
  secondaryButton(vActs, "用它继续", "message-circle");
  add(side, stretch(vActs));
}

// --- A6. 语音助手 · 记忆（跨会话的长期信息） ------------------------------------
//
// 用户 2026-09-17：「语音助手信息也是要长期保存。」记录回答的是「这一轮说了什么」，
// 记忆回答的是「跨轮次仍然成立的事」——两者不是同一张表：删掉一轮对话不该让助手忘掉
// 你的偏好，所以 `assistant_memory` 与 `session` 解耦（来源会话可以为空，SET NULL）。
// 这块板回答三件事：记忆在哪、是谁写进去的、什么时候生效。
//
// **记忆只在下一轮生效**，和人设是同一条推理：它也进 system prompt，会话中途改同样会让
// 大模型的前缀缓存从改动点之后整段失效（§14.4）。所以本轮这一栏是只读的，生效点写在
// 按钮上（「新开一轮以生效」），不是藏在说明文字里让用户自己推。
//
// 写入要用户确认：助手在会话里提议「要不要记下来」，点了才落库——静默积累的记忆，
// 用户下次只会觉得「它怎么知道这个」。
function screenClosureAssistantMemory(d) {
  pageHead(d, "语音助手", "和本机大模型用语音一来一往；记忆跨轮次留着。", function (row) {
    kbdInRow(row, "⌘⇧.", 34);
    primaryButton(row, "结束对话", "square", 118);
    sideToggle(row, "本次对话");
  });

  conclusionBand(d, {
    tone: "Info",
    title: "记忆跨轮次留着，但只在下一轮生效",
    body: "记忆是一批跨对话留下来、长期成立的事实与偏好：删掉某一段对话，不会让助手忘掉你的习惯。" +
      "它和人设一样，是它开口前读的一段话——本轮中途改会让它变慢，" +
      "所以这一栏本轮只读，改动下一轮生效。",
    hint: "写入要你确认：助手在会话里提议「要不要记下来」，你点了才存；不会自己悄悄记。",
    actions: []
  });

  const split = frame("split", { layout: "HORIZONTAL", gap: 16 });
  add(d, stretch(grow(split)));

  const stream = card(split, "stream", { pad: 0, gap: 0, clip: true });
  grow(stream);
  const head = frame("head", { layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 12 });
  add(head, text("title", "对话", "Heading / Section", V["text/primary"]));
  spacer(head);
  add(head, text("detail", "第 12 轮 · 本轮用了 6 条记忆", "Callout", V["text/secondary"]));
  add(stream, stretch(head));
  hairline(stream);
  const turns = [
    { who: "你", time: "14:06:02", text: "以后回答先给结论，再给依据。" },
    { who: "助手", accent: true, badge: "夜航主持", time: "14:06:05",
      pill: ["Info", "记忆下一轮生效"],
      text: "记下了。不过它进的是下一轮的上下文：这一轮剩下的部分，我还会按原来的说法来。" },
    { who: "你", time: "14:06:14", text: "行，那就在这一轮里先凑合。" }
  ];
  turns.forEach(function (t) {
    turnRow(stream, {
      who: t.who, accent: t.accent, badge: t.badge, pill: t.pill, time: t.time,
      text: t.text, width: 700
    });
  });
  spacer(stream);
  hairline(stream);
  const foot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(foot, text("note",
    "这一轮用的是开始那一刻的那 6 条；右边这一栏的改动，下一轮才进上下文，和换人设同一个道理。",
    "Subheadline", V["text/tertiary"], { w: 700 }));
  add(stream, stretch(foot));

  // 右栏这一块与「记录库」是同一个位置：资产区常驻，标签在「记录 / 记忆」之间切。
  const side = card(split, "memory", { pad: 0, gap: 0, clip: true });
  size(side, SESSION_SIDE_W, null);
  add(split, stretch(side));
  const mHead = frame("mHead", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(mHead, text("title", "记忆", "Heading / Section", V["text/primary"]));
  add(mHead, text("detail", "跨对话留存的事实与偏好；本轮只读，下一轮生效。",
    "Callout", V["text/secondary"], { w: 308 }));
  segmented(mHead, ["记录", "记忆"], 1);
  add(side, stretch(mHead));
  hairline(side);
  [
    ["Info", "偏好", "回答先给结论，再给依据", "9月16日 16:40 · 纪要追问"],
    ["Info", "事实", "常用中文，技术名词保留英文", "9月15日 09:05 · 英文发音练习"],
    ["Info", "摘要", "周会结论：交付日期 8 月 22 日", "周会 · 已标说话人 · 已归档"],
    ["Off", "已停用", "这条不再被引用，但留着可回溯", "9月12日 21:10 · 读书笔记口述"]
  ].forEach(function (m, i, all) {
    const row = frame("memory", {
      layout: "HORIZONTAL", gap: 10, align: "CENTER", padX: 16, padY: 11
    });
    const info = frame("info", { layout: "VERTICAL", gap: 3 });
    add(info, text("body", m[2], "Body / Medium", V["text/primary"], { w: 216 }));
    add(info, text("sub", m[3], "Caption", V["text/tertiary"], { w: 216 }));
    add(row, grow(info));
    pill(row, m[0], m[1]);
    iconButton(row, "ellipsis", 26);
    add(side, stretch(row));
    if (i < all.length - 1) hairline(side);
  });
  spacer(side);
  hairline(side);
  const mBody = frame("mBody", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(mBody, text("label", "记忆和对话分开记", "Caption / Medium", V["text/secondary"]));
  add(mBody, text("desc",
    "移除一条记忆不改任何一段历史记录——那段对话里它仍然在；反过来，删掉一段对话，" +
      "助手也不会忘掉你的偏好。",
    "Subheadline", V["text/secondary"], { w: 308 }));
  add(side, stretch(mBody));
  spacer(side);
  hairline(side);
    const mActs = frame("acts", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 14 });
    secondaryButton(mActs, "回到对话");
    spacer(mActs);
    secondaryButton(mActs, "新开一轮以生效", "plus");
    add(side, stretch(mActs));
}

// --- S5. 非主框体 · 收起规则（通用） --------------------------------------------
//
// 用户 2026-09-18 的这条要求是**通用**的：先有「什么算非主框体」，再有「收起之后必须成立
// 什么」，最后才是某一个面板上那枚按钮。所以这一块板不画某一个面板，而是把判据与清单摆在
// 一起——它管现在这三屏，也管以后新加的面板。
function closurePanelRulesBoard() {
  const board = frame("▸ 非主框体 · 收起规则（通用）", {
    layout: "VERTICAL", gap: 16, pad: 24, fill: V["surface/window"], radius: 12, clip: true
  });
  size(board, 1440, null);
  pageHead(board, "非主框体 · 收起规则",
    "凡是「关掉它，主任务照样能做完」的面板，都要能收起：收起是它的正常状态，不是缺省。");

  const row = frame("row", { layout: "HORIZONTAL", gap: 24 });
  add(board, stretch(row));

  // 左：六条判据。缺哪一条，收起就会变成「东西不见了」。
  const rules = card(row, "rules", { pad: 0, gap: 0, clip: true });
  grow(rules);
  const rHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 16, padY: 14 });
  add(rHead, text("title", "六条判据", "Heading / Section", V["text/primary"]));
  add(rHead, text("detail", "逐条对照：缺一条，就不算「可收起」。", "Callout", V["text/secondary"]));
  add(rules, stretch(rHead));
  hairline(rules);
  [
    ["Ready", "① 有收起态",
      "面板必须有「收起」这一态，而且它是正常状态：不是被窗口挤没的，也不是把功能藏起来。"],
    ["Ready", "② 控件贴着分界线",
      "内容列首行尾端一枚 sidebar-right 图标按钮（28pt，复用现成 token）。它不是工具栏项——" +
        "工具栏里每个动作的落点由系统分配，锚不住这条分界线。"],
    ["Ready", "③ 一处唯一",
      "面板自己不再画第二个收起按钮：同一个动作一屏只出现一次，由离线门禁守着。"],
    ["Ready", "④ 收起后主框体吃满",
      "让出来的宽度归主任务：对话行、转录、字幕按新宽度重排；不留空栏，也不退化成分隔线。"],
    ["Ready", "⑤ 不看面板也不会做错事",
      "这是收起的前提：关键状态在主框体里也要有一份——会议怎么记的、来源是什么、" +
        "这一轮的人设与音色。做不到，这个面板就不该允许收起。"],
    ["Ready", "⑥ 记得住",
      "收起态按屏记忆、跨启动保留；菜单项与快捷键给键盘路径，不逼人去画布上找那枚图标。"]
  ].forEach(function (r, i, all) {
    closureCheckRow(rules, r[0], r[1], r[2], null, 556, "rule/" + i);
    if (i < all.length - 1) hairline(rules);
  });
  spacer(rules);

  // 右：清单。一次说清「现在算进来的」与「这一轮先不画的」，免得下一轮又从头猜一遍。
  const list = card(row, "list", { pad: 0, gap: 0, clip: true });
  size(list, 620, null);
  const lHead = frame("head", { layout: "VERTICAL", gap: 3, padX: 16, padY: 14 });
  add(lHead, text("title", "非主框体清单", "Heading / Section", V["text/primary"]));
  add(lHead, text("detail", "每一项：方位 · 收起控件 · 快捷键 · 记忆范围",
    "Callout", V["text/secondary"]));
  add(list, stretch(lHead));
  hairline(list);
  [
    ["Ready", "本轮补齐", "详情列 360（本次对话 / 记录信息 / 会议信息 / 音频来源 / 本次字幕 / " +
      "字幕文件）· 右 · 首行尾端的 sidebar-right · ⌘⌃I · 按屏"],
    ["Info", "已有", "贴底抽屉（内心 OS）· 底 · 那一行上的 chevron · ⌘⇧I · 按屏"],
    ["Info", "已有", "字幕带浮层 · 浮 · 悬停工具条上的 x · ⌘⇧. · 全局"],
    ["Info", "已有", "导航侧栏 240 · 左 · 系统那一枚侧栏按钮 · ⌘⌃S · 系统"],
    ["Info", "已有", "卡内明细（运行监控的「逐指标明细」等）· 卡内 · chevron-down · 无 · 按页"],
    ["Ready", "本轮补齐", "目录列 280（统一会议 / 记录库 / 助手 / 文档）· 内 · " +
      "⌘⌥S · 按屏记忆——列宽已归一化收敛至 280pt"],
    ["Off", "不在这一版", "音色库与我的作品的详情列（全量稿那一份）· 右 · 同一枚按钮（应用里已在用）"]
  ].forEach(function (r, i, all) {
    closureCheckRow(list, r[0], r[1], r[2], null, 428, "panel/" + i);
    if (i < all.length - 1) hairline(list);
  });
  spacer(list);

  const acts = frame("actions", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  add(acts, text("note",
    "两条边界：① 收起 ≠ 关掉功能——面板收起时任务照跑；②「开发者详情」（⌥⌘I）住在面板里，" +
      "面板收起时它跟着收走、展开时回来，不因此拦住收起。",
    "Caption", V["text/tertiary"], { w: 860 }));
  spacer(acts);
  secondaryButton(acts, "收起后的对话页", "sidebar-right");
  secondaryButton(acts, "回到对话中", "message-circle");
  add(board, stretch(acts));
  return board;
}

// --- S1. 设置 · 会话 ------------------------------------------------------------
//
// 大模型是会话模块唯一的外部依赖（SESSIONS-SPEC §4 P7）：配不上它，助手整条闭环断在
// 起点。所以「配大模型」不是一句说明，而是一块画板——地址、模型、密钥、以及「检查
// 连接」会给出的三种结论都在上面。
function closureSettingsBoard() {
  const board = frame("▸ 设置 · 会话（配置大模型）", {
    layout: "VERTICAL", gap: 16, pad: 24, fill: V["surface/window"], radius: 12, clip: true
  });
  size(board, 1440, null);
  pageHead(board, "设置 · 会话",
    "大模型是会话模块唯一的外部依赖：地址、模型与密钥都在这一页配，改完不用重启。");

  const row = frame("row", { layout: "HORIZONTAL", gap: 24 });
  add(board, stretch(row));
  add(row, settingsWindow(2));

  const side = frame("notes", { layout: "VERTICAL", gap: 16 });
  grow(side);
  add(row, stretch(side));

  const conn = card(side, "conn", { layout: "VERTICAL", gap: 10, padX: 16, padY: 14 });
  add(conn, text("title", "「检查连接」会给出四种结论", "Heading / Section", V["text/primary"]));
  add(conn, text("detail",
    "点一次检查两件事：服务通不通、接口对不对。给的是可判定的结论，不是转圈；" +
      "结论决定助手页上那条提示还在不在。",
    "Callout", V["text/secondary"], { w: 600 }));
  [
    ["Ready", "已连接 · 12 ms", "模型列表可达：助手与会议纪要都能用。"],
    ["Attention", "服务可达，但这个模型没加载", "地址对、模型名不对：列表为空时先让服务加载模型。"],
    ["Attention", "接口不对：没有 Responses API", "地址与密钥都对，但只提供 Chat Completions——" +
      "换一个实现了 Responses API 的服务，或让对方把 Responses 打开。"],
    ["Critical", "连不上", "地址或端口不对，或服务没起来；密钥不在这里回显。"]
  ].forEach(function (r, i, all) {
    const line = frame("line", { layout: "HORIZONTAL", gap: 12, align: "CENTER" });
    const cell = frame("cell", { layout: "HORIZONTAL" });
    size(cell, 116, null);
    pill(cell, r[0], r[0]);
    add(line, cell);
    add(line, text("note", r[2], "Callout", V["text/secondary"], { w: 520 }));
    add(conn, stretch(line));
    if (i < all.length - 1) hairline(conn);
  });
  spacer(conn);

  // 用户 2026-09-18：「配置 llm，无需体现本机 oMLX，兼容 openai 即可，说清楚需要支持是
  // response api」。所以这一格不是自我介绍，而是**对接清单**：把「兼容 OpenAI」落在
  // 一条能验的要求上——Responses，而不是 Chat Completions。
  const req = card(side, "req", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(req, text("title", "对接要求", "Heading / Section", V["text/primary"]));
  add(req, text("body",
    "只说「兼容 OpenAI」不够：助手与纪要走的是 Responses API，" +
      "只实现 Chat Completions 的服务在「检查连接」里会被直接指出来。",
    "Callout", V["text/secondary"], { w: 600 }));
  hairline(req);
  [
    ["接口", "Responses API（必须）"],
    ["模型列表", "GET /v1/models"],
    ["鉴权", "Bearer；密钥存钥匙串"],
    ["部署位置", "本机或局域网都行"]
  ].forEach(function (kv) { kvRow(req, kv[0], kv[1], 120); });
  spacer(req);

  // 设置页最容易产生的误会：把「默认人设」当成「随时可改的风格」。所以这一张卡不是
  // 复述控件说明，而是解释为什么它会锁（用户 2026-09-17 的裁决理由）。
  const persona = card(side, "persona", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(persona, text("title", "默认人设只在开始时用一次", "Heading / Section", V["text/primary"]));
  add(persona, text("body",
    "新对话开始之后再改人设，它就得把开头重读一遍——用户感受到的是「莫名其妙变慢」。" +
      "所以会话内人设只读，要换就新开一轮；音色不受此限（差别见「换音色 vs 换人设」）。",
    "Callout", V["text/secondary"], { w: 600 }));
  spacer(persona);

  const key = card(side, "key", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(key, text("title", "密钥只进钥匙串", "Heading / Section", V["text/primary"]));
  add(key, text("body",
    "设置里也不回显：不进配置文件、不进日志，也不进导出物与诊断报告。",
    "Callout", V["text/secondary"], { w: 600 }));
  hairline(key);
  [["存储位置", "钥匙串"], ["配置文件", "不含密钥"], ["诊断报告", "不含密钥与地址"]].forEach(function (kv) {
    kvRow(key, kv[0], kv[1], 120);
  });
  spacer(key);

  const mins = card(side, "minutes", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(mins, text("title", "纪要模型默认跟随它", "Heading / Section", V["text/primary"]));
  add(mins, text("body",
    "单场会议可以在会议页覆盖一次，不改这里的默认值。",
    "Callout", V["text/secondary"], { w: 600 }));
  spacer(mins);

  // 记录是资产：这一条不是「保存位置」的复述，而是把它当成资产之后才有的一组决定——
  // 备份怎么备份、导出有哪些格式、什么不存。
  const store = card(side, "store", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(store, text("title", "记录是长期资产", "Heading / Section", V["text/primary"]));
  add(store, text("body",
    "会议、纪要、字幕与对话写进同一个本机数据库：App 重启、服务重启都不丢，搜索走数据库索引。",
    "Callout", V["text/secondary"], { w: 600 }));
  hairline(store);
  [["备份", "复制数据库文件即可"], ["导出", "Markdown / SRT / 纯文本"], ["原始音频", "不留存"]]
    .forEach(function (kv) { kvRow(store, kv[0], kv[1], 96); });
  spacer(store);

  const acts = frame("actions", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  add(acts, text("note", "配好之后，助手页那条「还没有配置对话模型」会自己消失。",
    "Caption", V["text/tertiary"], { w: 700 }));
  spacer(acts);
  secondaryButton(acts, "回到语音助手", "message-circle");
  add(board, stretch(acts));
  return board;
}

// --- S4. 换音色 vs 换人设（影响面） --------------------------------------------
//
// 用户 2026-09-18：「换音色 与 换人设 的影响 请深入分析，重新绘制」。这两个动作在界面上
// 长得像——都在右栏、都是「换一个」——代价却完全不同，所以它们不能共用一句解释。
//
//   换音色改的是它**说出来的声音**：下一句生效，改错了换回来即可；正文、记录、纪要一个字
//   都不动，刚才聊的还接得上。
//
//   换人设改的是它**每次开口前读的第一段话**（身份、语气、答多长）。这段话它只在开始时读
//   一次，读过的那份留着复用——答得快就是靠这个。中途换掉，留着的那份作废，之后每一轮都
//   要重读一遍：用户感受到的是「突然变慢，而且接下来几轮都不像刚才那个助手」。所以本轮
//   不给选择器，只给锁和一个出口。
//
// 这块板是「深入分析」的落点，不是复述控件：生效时机、影响面、代价、留痕、上下文是否
// 延续都放在同一张表里比，再用一条时间线看它们各自断在哪。表里写的是**用户看得见的现象**，
// 机制留在代码注释里（用户 2026-09-18：面向终端用户，不是技术人员）。
function closureVoicePersonaBoard() {
  const board = frame("▸ 换音色 vs 换人设（影响面）", {
    layout: "VERTICAL", gap: 16, pad: 24, fill: V["surface/window"], radius: 12, clip: true
  });
  size(board, 1440, null);
  pageHead(board, "换音色 vs 换人设",
    "两个动作都叫「换」，代价不一样：一个只改声音，一个改的是它怎么和你说话。");

  const row = frame("row", { layout: "HORIZONTAL", gap: 16 });
  add(board, stretch(row));

  // 左：七行对比表。第三列按剩余宽度伸展，所以第一列是固定宽、第二列也是固定宽——
  // 两条文案的最大长度决定列宽，改文案之前先用同样的字数试一遍。
  const table = card(row, "compare", { pad: 0, gap: 0, clip: true });
  grow(table);
  const thead = frame("thead", {
    layout: "HORIZONTAL", gap: 16, align: "CENTER", padX: 16, padY: 12,
    fill: V["surface/sidebar"]
  });
  [
    ["", 150],
    ["换音色 · 随时", 290],
    ["换人设 · 本轮锁定", null]
  ].forEach(function (c) {
    const cell = frame("hCell", { layout: "HORIZONTAL" });
    if (c[1]) size(cell, c[1], null);
    if (c[0]) add(cell, text("h", c[0], "Caption / Medium", V["text/secondary"]));
    if (c[1]) add(thead, cell); else add(thead, grow(cell));
  });
  add(table, stretch(thead));
  hairline(table);

  const COMPARE_ROWS = [
    ["改的是什么", "它说出来的声音", "它每次开口前读的第一段话：身份、语气、答多长"],
    ["什么时候生效", "下一句", "下一次开始对话；本轮不动"],
    ["会变什么", "只有声音不同；字、记录、纪要一个字都不动",
      "之后每一轮的语气、长度、用词、答法都会变"],
    ["要付什么代价", "几乎没有：下一句就听得出来",
      "它得把开头重读一遍：第一句明显变慢，之后每轮都慢一点"],
    ["改错了怎么办", "换回来就行，从下一句恢复",
      "本轮改不回来；换回来也要新开一轮"],
    ["记录里怎么标", "第 13 句起：温柔讲解", "本轮：耐心讲解"],
    ["刚才聊的还接得上吗", "接得上：同一轮，上下文都在",
      "不带过去：记忆和记录都在，刚才那段对话不带过去"]
  ];
  COMPARE_ROWS.forEach(function (r, i, all) {
    const line = frame("cRow", { layout: "HORIZONTAL", gap: 16, align: "MIN", padX: 16, padY: 11 });
    const c0 = frame("c0", { layout: "HORIZONTAL" });
    size(c0, 150, null);
    add(c0, text("k", r[0], "Body / Medium", V["text/secondary"]));
    add(line, c0);
    const c1 = frame("c1", { layout: "HORIZONTAL" });
    size(c1, 290, null);
    add(c1, text("v", r[1], "Callout", V["text/primary"], { w: 278 }));
    add(line, c1);
    // 1440 − 24×2（页边）− 420（右栏）− 16（栏间距）= 956 是这张表的宽；再减去 padX 16×2 与
    // 两个 gap 16×2，剩 892 分给三列：150 + 290 + 420（列宽必须按**当前**列数算，同
    // CLOSURE_SPINE_W / CLOSURE_STATE_W 的那条教训）。
    add(line, grow(text("v", r[2], "Callout", V["text/primary"], { w: 420 })));
    add(table, stretch(line));
    if (i < all.length - 1) hairline(table);
  });
  spacer(table);
  hairline(table);
  const tFoot = frame("tFoot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(tFoot, text("note",
    "两个都随这段记录一起存：音色按句标，人设按轮标——回看时能分清哪几句是哪个声音、" +
      "哪一段换了风格。",
    "Subheadline", V["text/tertiary"], { w: 720 }));
  add(table, stretch(tFoot));

  const side = frame("notes", { layout: "VERTICAL", gap: 16 });
  size(side, 420, null);
  // 同 meetingShell：伸到行高的那一栏会被压短，内容在底部溢出（实测 `notes ▸ timeline ▸ foot
  // +10B [380 in 420]`）。右栏按内容撑高。
  add(row, side);

  // 时间线：两条改动各自断在哪，一行说清。块的宽度是示意，不是比例尺。
  const tl = card(side, "timeline", { layout: "VERTICAL", gap: 10, padX: 16, padY: 14 });
  add(tl, text("title", "它们各自断在哪", "Heading / Section", V["text/primary"]));
  [
    ["音色", [["第 1 句", "On"], ["换音色", "Ready"], ["第 40 句", "On"]], "同一轮不断"],
    ["人设", [["本轮", "On"], ["锁定", "Attention"], ["新的一轮", "Ready"]], "这里断开"]
  ].forEach(function (t) {
    const line = frame("tlRow", { layout: "VERTICAL", gap: 6 });
    const head = frame("head", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
    add(head, text("k", t[0], "Body / Medium", V["text/primary"]));
    spacer(head);
    add(head, text("v", t[2], "Caption", V["text/tertiary"]));
    add(line, stretch(head));
    const track = frame("track", { layout: "HORIZONTAL", gap: 6 });
    t[1].forEach(function (seg) {
      const b = frame("seg", { layout: "HORIZONTAL", align: "CENTER", justify: "CENTER",
        padX: 10, padY: 6, radius: 8, fill: V["surface/field"] });
      add(b, text("t", seg[0], "Caption", V["text/primary"]));
      add(track, stretch(b));
    });
    add(line, stretch(track));
    add(tl, stretch(line));
  });
  // 不能放 spacer()：这张卡按内容撑高（height=AUTO），而 spacer 的 GROW 会让 Figma 在
  // 撑高时把它连它前面那个 gap 一起略过——后面的 foot 就整段溢出（gap=10 时正好 +10B，
  // 实测 2026-09-18 `row/notes/timeline/foot +10B h14/181`）。要分隔就用 hairline()，
  // 这跟 2026-09-17 那条经验是同一条（见下面那张表上方的注释）。
  hairline(tl);
  add(tl, text("foot", "音色换了，这一段还是同一段；人设换了，是另起一段跟着走。",
    "Caption", V["text/tertiary"], { w: 380 }));

  const why = card(side, "why", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  add(why, text("title", "为什么人设只在开始时定", "Heading / Section", V["text/primary"]));
  add(why, text("body",
    "它一开始会先读一遍「你是谁、该怎么说话」，读过的那段留着复用——答得快就是靠这个。" +
      "中途把这段换掉，留着的那份就不能用了，只能重读一遍：你会觉得它突然变慢，" +
      "而且接下来几轮都不像刚才那个助手。",
    "Callout", V["text/secondary"], { w: 380 }));
  hairline(why);
  add(why, text("body2",
    "所以这一栏本轮不是「灰掉的选择」，是锁加一个出口——两者的出路不一样。",
    "Subheadline", V["text/secondary"], { w: 380 }));
  spacer(why);

  const exits = card(side, "exits", { layout: "VERTICAL", gap: 10, padX: 16, padY: 14 });
  add(exits, text("title", "两个出口", "Heading / Section", V["text/primary"]));
  [
    ["换音色", "会话里随时改，下一句生效。", "换音色", "audio-waveform"],
    ["换人设", "新开一轮；记忆和记录都还在。", "新开一轮以换人设", "plus"]
  ].forEach(function (e, i, all) {
    const line = frame("exitRow", { layout: "VERTICAL", gap: 4 });
    add(line, text("k", e[0], "Body / Medium", V["text/primary"]));
    add(line, text("d", e[1], "Callout", V["text/secondary"], { w: 380 }));
    const acts = frame("acts", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
    if (i === 0) secondaryButton(acts, e[2], e[3]);
    else primaryButton(acts, e[2], e[3], 168);
    spacer(acts);
    add(line, stretch(acts));
    add(exits, stretch(line));
    if (i < all.length - 1) hairline(exits);
  });
  hairline(exits);
  add(exits, text("foot", "记录库里的「继续这一轮」就是新开一轮的入口：那一段已经选中。",
    "Caption", V["text/tertiary"], { w: 380 }));
  return board;
}

// --- S2. 菜单栏 · 三个入口 -----------------------------------------------------
// --- S3. 分人 · 会议与字幕共用一条链路 -----------------------------------------
//
// 「会议与字幕都要对接 SpeechRail 的分人能力」在稿上只有一个答案：它们走**同一条**链路——
// 同一个 `/v1/realtime` 分人扩展（`session.speechrail.diarization.enabled`）、同一套会话内
// 匿名标签、同一套降级话术、同一处改名。两边各造一套的话，同一个说话人在会议里叫
// 「说话人 A」、在字幕里又叫「Speaker 1」，用户得学两遍。
//
// 三种状态都画出来，是因为档位差异（light 没有分人）与运行期降级（overloaded / 结束超时）
// 都是正常状态：真正的判断是「降级时正文不许丢」，而不是把提示吞掉。
function closureDiarizationBoard() {
  const board = frame("▸ 分人 · 说话人标签（会议与字幕共用）", {
    layout: "VERTICAL", gap: 16, pad: 24, fill: V["surface/window"], radius: 12, clip: true
  });
  size(board, 1440, null);
  pageHead(board, "分人 · 会议与字幕共用一条链路",
    "同一个分人扩展、同一套匿名标签、同一套降级话术：会议与字幕只是这条链路的两个出口。");

  // 220 + 550 + 550 + 12 × 2 = 1344，留在行内边距之后的 1360 里；2026-09-17 实测
  // 570 的第三列会顶出 8px（`head ▸ cell +8R [570 in 1392]`）。列宽要按「扣掉行内边距
  // 之后的可用宽」算，不是按画板宽度算。
  const w1 = 220, w2 = 550, w3 = 550;
  const table = card(board, "states", { pad: 0, gap: 0, clip: true });
  const head = frame("head", { layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 16, padY: 10 });
  ["状态", "会议里", "字幕里"].forEach(function (label, i) {
    const cell = frame("cell", { layout: "HORIZONTAL" });
    size(cell, i === 0 ? w1 : (i === 1 ? w2 : w3), null);
    add(cell, text("label", label, "Caption / Medium", V["text/tertiary"]));
    add(head, cell);
  });
  add(table, stretch(head));
  hairline(table);
  [
    ["Attention", "档位不支持（light）",
      "会议照录，没有说话人标签：开关置灰并写明「light 档位不分人」。",
      "字幕带照常跟随，历史里只有正文；按说话人筛这一项不可用，不假装是空结果。"],
    ["Ready", "已启用（balanced / quality）",
      "会话内匿名标签「说话人 A/B/C」，最多 4 位；随时可以改名。",
      "字幕带上带标签；记录库里能改名、能按说话人筛，筛完再导出 SRT。"],
    ["Attention", "降级（overloaded / 结束超时）",
      "正文继续写进记录，标签停止更新，已经给出的标签保留；这一刻也写进记录。",
      "同一条带子换成降级提示，不静默：你已经看到的最后一句仍然是有主的。"]
  ].forEach(function (r, i, all) {
    const row = frame("state", { layout: "HORIZONTAL", gap: 12, align: "MIN", padX: 16, padY: 12 });
    const c1 = frame("c1", { layout: "VERTICAL", gap: 4 });
    size(c1, w1, null);
    pill(c1, r[0], r[0] === "Ready" ? "可用" : "受限");
    add(c1, text("t", r[1], "Body / Medium", V["text/primary"], { w: w1 }));
    add(row, c1);
    const c2 = frame("c2", { layout: "VERTICAL" });
    size(c2, w2, null);
    add(c2, text("t", r[2], "Callout", V["text/secondary"], { w: w2 - 12 }));
    add(row, c2);
    const c3 = frame("c3", { layout: "VERTICAL" });
    size(c3, w3, null);
    add(c3, text("t", r[3], "Callout", V["text/secondary"], { w: w3 - 12 }));
    add(row, c3);
    add(table, stretch(row));
    if (i < all.length - 1) hairline(table);
  });
  // 这里不能放 spacer()：这张表是按内容撑高的卡片，spacer 的 STRETCH + GROW 会在卡片
  // 内部制造 30px 溢出（2026-09-17 实测 `desc+21, spacer+30`）。要分隔就用 hairline()。
  hairline(table);
  const tFoot = frame("foot", { layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 16, padY: 10 });
  add(tFoot, text("note",
    "两侧的开关粒度一样：每个会话一个开关、默认关；打开时才声明分人，未声明就按无分人跑。",
    "Subheadline", V["text/tertiary"], { w: 900 }));
  add(table, stretch(tFoot));

  const row = frame("row", { layout: "HORIZONTAL", gap: 16, align: "MIN" });
  add(board, stretch(row));

  const same = card(row, "shared", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  grow(same);
  add(same, text("title", "共用的是哪几件事", "Heading / Section", V["text/primary"]));
  [
    ["开关", "session.speechrail.diarization.enabled"],
    ["标签", "会话内匿名「说话人 A…D」，会话结束即弃"],
    ["改名", "只改显示名，不改正文、不改时间线"],
    ["结束", "finish 屏障：等水位对齐再封存，末段不丢"],
    ["边界", "不做声纹库、不做跨会话身份、不留 embedding"]
  ].forEach(function (kv) { kvRow(same, kv[0], kv[1], 96); });
  add(same, text("desc",
    "说话人是谁由用户手写的显示名决定；SpeechRail 只给本次会话的匿名标签，不管理实名。",
    "Subheadline", V["text/tertiary"], { w: 620 }));

  const ends = card(row, "ends", { layout: "VERTICAL", gap: 8, padX: 16, padY: 14 });
  size(ends, SESSION_SIDE_W, null);
  add(ends, text("title", "两个出口", "Heading / Section", V["text/primary"]));
  add(ends, text("body",
    "会议把它写进转录与纪要；字幕把它写上字幕带、写进记录库。同一段音频在两边得到同一套标签。",
    "Callout", V["text/secondary"], { w: 300 }));
  const acts = frame("acts", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  secondaryButton(acts, "打开会议页");
  secondaryButton(acts, "打开字幕记录库");
  add(ends, stretch(acts));
  // `add()` 返回的是**被加进去的那个节点**（row），不是父节点：写 `return add(board, row)`
  // 会让 buildClosureScreens 把这一行当成整块画板挂到页面上，而真正的画板留在画布外
  // （2026-09-17 实测：报告里 `stray top-level=1` + 少一个深色克隆 + 画板数 43 而不是 45）。
  return board;
}

//
// 字幕带与会议的真实用法是「App 不在前台」，所以三个能力的启停必须在系统里。这一块
// 画板同时回答一件常被漏掉的事：语音助手**没有**全局快捷键，因为它需要主窗口在场。
function closureMenuBoard() {
  const board = frame("▸ 菜单栏 · 三个入口", {
    layout: "VERTICAL", gap: 18, pad: 24, fill: V["surface/window"], radius: 12, clip: true
  });
  size(board, 1440, null);
  pageHead(board, "菜单栏 · 会话入口",
    "字幕与会议要在后台启动，所以入口在系统里；语音助手需要主窗口在场，所以它没有全局快捷键。");

  const strips = frame("strips", { layout: "VERTICAL", gap: 12 });
  add(board, stretch(strips));
  add(strips, text("title", "状态项：只有图标，或带会话名与状态点", "Heading / Section", V["text/primary"]));
  [
    [{ label: false, busy: false }, "空闲：只有图标。菜单栏属于系统，不属于产品。"],
    [{ label: true, busy: true, tone: "status/ready" },
      "字幕进行中：图标旁边出现会话名；这是除主窗口之外唯一常驻的「谁在用麦克风」提示。"],
    [{ label: true, busy: true, tone: "status/attention" },
      "会议录制中：同一个位置换成琥珀色，提醒「现在正在被别人用着」。"],
    [{ label: true, busy: true, tone: "status/critical" },
      "受阻：麦克风未授权或服务不可达时，状态项是红的——不必打开 App 才知道。"]
  ].forEach(function (s) {
    const col = frame("state", { layout: "VERTICAL", gap: 6 });
    menuBarStrip(col, s[0]);
    add(col, text("note", s[1], "Caption", V["text/tertiary"], { w: 1200 }));
    add(strips, stretch(col));
  });

  const row = frame("row", { layout: "HORIZONTAL", gap: 32, align: "MIN" });
  add(board, stretch(row));
  const idle = menuPanel("菜单栏面板 · 空闲", {});
  const active = menuPanel("菜单栏面板 · 字幕进行中", {
    sessionActive: true, status: "实时字幕进行中 · 08:12"
  });
  const panelH = Math.max(idle.height, active.height);
  size(idle, 288, panelH);
  size(active, 288, panelH);
  [["空闲：三个能力都从这三行进", idle], ["会话进行中：结束是一条要确认的命令", active]]
    .forEach(function (p) {
      const col = frame("column", { layout: "VERTICAL", gap: 8 });
      add(col, text("caption", p[0], "Callout", V["text/secondary"]));
      add(col, p[1]);
      add(row, col);
    });

  const entry = card(row, "entry", { layout: "VERTICAL", gap: 10, padX: 16, padY: 14 });
  grow(entry);
  add(entry, text("title", "四个会话命令", "Heading / Section", V["text/primary"]));
  add(entry, text("detail", "菜单里只有启停与跳转；模型、音色、人设都属于主窗口。",
    "Callout", V["text/secondary"], { w: 420 }));
  hairline(entry);
  [
    ["开始实时字幕", "⌘⇧L · 全局"],
    ["开始会议", "⌘⇧N · 全局"],
    ["结束当前会话…", "⌘⇧. · 全局（先确认）"],
    ["打开语音助手", "主窗口 · 侧边栏"]
  ].forEach(function (kv, i, all) {
    kvRow(entry, kv[0], kv[1], 150);
    if (i < all.length - 1) hairline(entry);
  });
  spacer(entry);
  add(entry, text("foot",
    "没有正在进行的会话时，「结束当前会话…」是灰的，并在原地说明原因——灰按钮不解释为什么，" +
    "用户只能猜。",
    "Caption", V["text/tertiary"], { w: 420 }));
  return board;
}

// --- 闭环的画板清单 -------------------------------------------------------------
//
// 20 块屏幕：三条闭环各 4–7 块（入口 / 前置 / 主交互 / 交还 / 产物），外加四块共用
// 脊柱（设置 · 会话、菜单栏入口、会话占用守卫）。每条 links 都是一句「这块画板上哪个
// 控件通向哪一块画板」——闭环稿的连线不是装饰，是路径本身。
const CLOSURE_BOARDS = [
  { anchor: "assistantReady", title: "语音助手 · 对话页 · 未开始（先定人设与音色）",
    icon: "message-circle", route: "assistant", session: "idle",
    screen: screenClosureAssistantReady,
    links: [["开始对话", "assistant"], ["新建自定义人设", "assistantVoice"],
      ["打开设置", "settingsSession"]] },
  { anchor: "assistantBlocked", title: "语音助手 · 对话页 · 未配置模型", icon: "message-circle",
    route: "assistant", session: "assistant", screen: screenAssistantBlocked,
    links: [["打开设置…", "settingsSession"]] },
  { anchor: "assistant", title: "语音助手 · 对话页 · 对话中", icon: "message-circle",
    route: "assistant", session: "assistant", primary: true, screen: screenAssistant,
    // 页头「音色与风格」通向对比板（先说清代价），侧栏「换音色」直接通向换音色的那一态，
    // 「新开一轮以换人设」是锁住的人设唯一的出口。
    links: [["结束对话", "assistantClosed"], ["音色与风格", "voicePersona"],
      ["实时对讲（耳机）", "assistantDuplex"], ["换音色", "assistantVoice"],
      ["新开一轮以换人设", "assistantReady"]] },
  { anchor: "assistantDuplex", title: "语音助手 · 对话页 · 实时对讲（耳机 · 可打断）",
    icon: "message-circle", route: "assistant", session: "assistant",
    screen: screenClosureAssistantDuplex,
    links: [["一问一答（外放）", "assistant"], ["人设与音色", "assistantVoice"],
      ["结束对话", "assistantClosed"]] },
  { anchor: "assistantVoice", title: "语音助手 · 对话页 · 换音色（下一句生效）",
    icon: "message-circle",
    route: "assistant", session: "assistant", screen: screenClosureAssistantVoice,
    links: [["用它继续", "assistantDuplex"], ["新开一轮以换人设", "assistantReady"],
      ["它俩差在哪？", "voicePersona"], ["结束对话", "assistantClosed"]] },
  // 「换音色 vs 换人设」是同一条闭环上的岔路口，不是第二个设置页：所以它和设置页一样
  // 挂成一张解释板，两个出口各自连回那条闭环要走的那一块。
  // 名字必须与 closureVoicePersonaBoard 里那块画板的 frame 名一致（去掉「▸ 」）：连线的
  // 落点是按 title 反查的，对不上就静默不成线——这一条是实测踩到的（第一版写成
  // 「语音助手 · 换音色 vs 换人设（影响面）」，画板却叫「换音色 vs 换人设（影响面）」，
  // 于是两条连线一条都没接上，smoke 只报 205/205 而不报错）。
  { anchor: "voicePersona", title: "换音色 vs 换人设（影响面）",
    icon: "audio-waveform",
    route: "assistant", session: "assistant", full: closureVoicePersonaBoard,
    links: [["换音色", "assistantVoice"], ["新开一轮以换人设", "assistantReady"]] },
  // 记忆不是一个时刻，是跨轮次的资产：删掉一段对话不该让助手忘掉你的偏好。它由
  // 「旅程还会走到这里」那一节进入（不是从某个按钮进入的），所以这里不挂来源连线。
  { anchor: "assistantMemory", title: "语音助手 · 对话页 · 记忆（跨会话 · 下一轮生效）",
    icon: "bot",
    route: "assistant", session: "assistant", screen: screenClosureAssistantMemory,
    links: [["回到对话", "assistant"], ["新开一轮以生效", "assistantReady"]] },
  { anchor: "assistantClosed", title: "语音助手 · 记录库 · 刚结束", icon: "message-circle",
    route: "assistant", session: "assistant", screen: screenClosureAssistantClosed,
    links: [["继续这一轮", "assistantReady"], ["新建对话", "assistantReady"]] },
  { anchor: "meetingEmpty", title: "会议助手 · 会议页 · 空态（选音频来源）", icon: "users",
    route: "meeting", session: "idle", screen: screenClosureMeetingSources,
    links: [["开始会议", "meetingRecording"], ["查看设置", "settingsSession"]] },
  { anchor: "meetingRecording", title: "会议助手 · 会议页 · 录制中", icon: "users",
    route: "meeting", session: "meeting", primary: true, screen: screenMeetingRecording,
    // 「内心 OS」不在这里挂按钮：这块画板是全量稿与闭环稿共用的，改它会动到已经交付过的
    // 48 板。内心 OS 的入口画在 M4 那块板自己身上，并从总览的状态格与泳道格进入。
    links: [["结束会议", "meetingProcessing"]] },
  { anchor: "meetingInnerOS", title: "会议助手 · 会议页 · 录制中 · 内心 OS", icon: "users",
    route: "meeting", session: "meeting", screen: screenClosureMeetingInnerOS,
    links: [["写进纪要", "meetingMinutes"], ["结束会议", "meetingProcessing"]] },
  { anchor: "meetingProcessing", title: "会议助手 · 会议页 · 整理中", icon: "users",
    route: "meeting", session: "meeting", screen: screenClosureMeetingProcessing,
    links: [["查看纪要", "meetingMinutes"], ["先导出转录…", "meetingMinutes"]] },
  // 中断不是点出来的，是发生的：所以它由总览的「旅程还会走到这里」进入，不挂来源
  // 连线；它自己有两个出口（继续这一段 / 结束并整理）。
  { anchor: "meetingInterrupted", title: "会议助手 · 会议页 · 录制中断（服务或来源断了）",
    icon: "triangle-alert",
    route: "meeting", session: "meeting", screen: screenClosureMeetingInterrupted,
    links: [["继续这一段", "meetingRecording"], ["结束并整理", "meetingProcessing"],
      ["打开记录库", "meetingMinutes"]] },
  { anchor: "meetingMinutes", title: "会议助手 · 会议页 · 已归档（改名与导出）", icon: "users",
    route: "meeting", session: "meeting", screen: screenMeetingMinutes,
    links: [["重新生成纪要", "meetingProcessing"]] },
  { anchor: "captionsIdle", title: "实时字幕 · 记录库 · 未开始（前置检查）", icon: "captions",
    route: "captions", session: "idle", screen: screenClosureCaptionsIdle,
    links: [["开始字幕", "bandFollow"], ["结束会话并切换", "meetingGuard"]] },
  { anchor: "captions", title: "实时字幕 · 记录库 · 回看中", icon: "captions",
    route: "captions", session: "captions", primary: true, screen: screenCaptions,
    // 「打开字幕带」落到「贴在画面上」那一块：从记录库按下去，用户看到的第一件事就是带子
    // 压在正在播的画面上方——这正是这一版补上的那一块 UI。
    links: [["打开字幕带", "bandOnScreen"], ["大字", "bandLarge"]] },
  { anchor: "captionsSaved", title: "实时字幕 · 记录库 · 刚结束（已保存）", icon: "captions",
    route: "captions", session: "captions", screen: screenClosureCaptionsSaved,
    links: [["打开记录库", "captions"]] },
  { anchor: "settingsSession", title: "设置 · 会话（配置大模型）", icon: "sliders-horizontal",
    route: "assistant", session: "idle", full: closureSettingsBoard,
    links: [["回到语音助手", "assistant"]] },
  { anchor: "menuSession", title: "菜单栏 · 三个入口", icon: "app-window",
    route: "assistant", session: "idle", full: closureMenuBoard,
    links: [["开始实时字幕", "bandFollow"], ["开始会议", "meetingRecording"],
      ["结束当前会话…", "meetingGuard"]] },
  { anchor: "meetingGuard", title: "会话占用 · 结束会议并切换", icon: "shield-check",
    route: "meeting", session: "meeting", full: buildSessionGuardBoard,
    links: [["取消", "meetingRecording"]] }
  ,
  { anchor: "diarization", title: "分人 · 说话人标签（会议与字幕共用）", icon: "users",
    route: "meeting", session: "meeting", full: closureDiarizationBoard,
    links: [["打开会议页", "meetingRecording"], ["打开字幕记录库", "captions"]] }
  ,
  // 用户 2026-09-18：「本次对话」要能收起，其余非主框体同理。左边这块是**规则**（判据 +
  // 清单），右边那块是规则落到具体一屏上的样子——收起态不是另一屏，是同一屏的另一个状态。
  { anchor: "panelRules", title: "非主框体 · 收起规则（通用）", icon: "sidebar-right",
    route: "assistant", session: "assistant", full: closurePanelRulesBoard,
    links: [["收起后的对话页", "assistantCollapsed"], ["回到对话中", "assistant"]] },
  { anchor: "assistantCollapsed", title: "语音助手 · 对话页 · 对话中（本次对话收起）",
    icon: "sidebar-right", route: "assistant", session: "assistant",
    screen: screenClosureAssistantCollapsed,
    links: [["结束对话", "assistantClosed"]] },
  { anchor: "sessionFirstRun", title: "会话 · 首次使用 · 空态引导（三能力起点）",
    icon: "sparkles", route: "assistant", session: "idle",
    screen: screenClosureFirstRunEmpty,
    links: [["进入语音助手", "assistantReady"], ["进入会议助手", "meetingEmpty"],
      ["启动实时字幕", "bandFollow"], ["会话设置", "settingsSession"]] }
];

// 字幕带是浮层，不是页面：它自己不成对出现，所以只作为连线目标登记。
const CLOSURE_BANDS = [
  // 「在用时」这一块是用户 2026-09-18「没有看到字幕带的 UI」的落点：前面四块画的都是带子
  // 本身（跟随 / 回看 / 大字 / 受阻），没有一块回答「它贴在画面上长什么样」。它同样是浮层，
  // 所以登记在这里，而不是当一块新屏幕。
  { anchor: "bandOnScreen", title: "浮层 · 字幕带 · 贴在画面上（在用时）" },
  { anchor: "bandFollow", title: "浮层 · 字幕带 · 跟随中" },
  { anchor: "bandReview", title: "浮层 · 字幕带 · 回看" },
  { anchor: "bandLarge", title: "浮层 · 字幕带 · 大字" },
  { anchor: "bandBlocked", title: "浮层 · 字幕带 · 受阻" }
];
// 字幕带上的「x」是这条闭环唯一会结束字幕的地方：点它才会走「结束并保存」。
const CLOSURE_BAND_LINKS = [["浮层 · 字幕带 · 回看", "x", "captionsSaved"]];

// 三条泳道：每一格都必须有落点。格子里的 target 不是装饰用的编号，而是连线目标。
const CLOSURE_LANES = [
  {
    key: "assistant", icon: "message-circle", title: "语音助手",
    detail: "麦克风在前台：它需要主窗口在场。",
    stages: [
      ["① 入口", "先定人设与音色",
        "侧边栏「语音助手」；App 必须在前台。人设与音色在「开始对话」这一步定，开始之后人设不再变。",
        "assistantReady"],
      ["② 前置与受阻", "对话模型没配", "结论条说明影响并给出唯一出口，不弹错误框。", "assistantBlocked"],
      ["③ 主交互", "一问一答 / 实时对讲",
        "外放用半双工（输出期闭麦）；耳机用全双工，你一开口就打断它。", "assistantDuplex"],
      ["④ 交还与守卫", "换音色 / 结束",
        "只有音色能中途换（下一句生效）；人设已锁，两者的差别见对比板。结束只结束交互，" +
          "不删记录。",
        "assistantVoice"],
      ["⑤ 产物与回看", "会话记录库", "列表 + 选中 + 详情；可继续、可导出、可从库里移除（先确认）。", "assistantClosed"]
    ]
  },
  {
    key: "meeting", icon: "users", title: "会议助手",
    detail: "麦克风在后台：边听边记，App 可以不在前台。",
    stages: [
      ["① 入口", "开始会议 · 先选来源", "麦克风 / 本机音频（按 App 抓）/ 两者混音；⌘⇧N 直接开始。",
        "meetingEmpty"],
      ["② 前置与受阻", "占用 · 未授权 · 来源中断",
        "谁在用麦克风要确认；本机音频未授权、来源 App 退出各有一条出口。", "meetingGuard"],
      ["③ 主交互", "录制中 · 内心 OS",
        "转录边听边出现，每行标来源；内心 OS 贴底一行，随时展开或收起，提问不打断录音。",
        "meetingInnerOS"],
      ["④ 交还与守卫", "结束并整理",
        "结束时要等最后半句分完人再存档；没等到也保住正文，不会少一段。", "meetingProcessing"],
      ["⑤ 产物与回看", "纪要 / 改名 / 导出",
        "说话人改名、合并、拆出会中会后都能做；纪要重新生成只新增版本，导出 Markdown 或 SRT。",
        "meetingMinutes"]
    ]
  },
  {
    key: "captions", icon: "captions", title: "实时字幕",
    detail: "麦克风在后台，界面是浮层：App 不必在前台。",
    stages: [
      ["① 入口", "⌘⇧L 或菜单栏", "字幕带贴在任何 App 之上；不改变当前页面。", "captionsIdle"],
      ["② 前置与受阻", "未授权 · 未就绪 · 被占用", "三种受阻共用一条带子，各给一个出口。", "bandBlocked"],
      ["③ 主交互", "跟随中 · 可分人", "贴底跟随；分人档位上带说话人标签，light 档位只有正文。", "bandFollow"],
      ["④ 交还与守卫", "上滚回看", "上滚即暂停跟随并出现「回到最新」；它不持焦点，esc 不会关它。", "bandReview"],
      ["⑤ 产物与回看", "字幕记录库", "点字幕带上的 ✕ 结束并保存；记录库里搜索、按说话人筛、导出 SRT。", "captions"]
    ]
  }
];

// 共用脊柱：三条闭环在这五件事上必须只有一种说法，否则同一台 Mac 上会出现三套解释。
// 第五条（分人）是用户 2026-09-17 要求「会议与字幕都要对接分人能力」的落点：两个功能共用
// 同一条链路，答案不是各画一套，而是这根脊柱上多一格。
const CLOSURE_SPINE = [
  ["共用脊柱", "系统级入口 · 菜单栏",
    "字幕与会议的真实用法是 App 不在前台，所以启停与「结束当前会话…」都在系统里。", "menuSession"],
  ["共用脊柱", "唯一外部依赖 · 设置 · 会话",
    "对话与纪要靠一台兼容 OpenAI 的服务（须支持 Responses API）；密钥只进钥匙串，不进日志。",
    "settingsSession"],
  ["资产的落点", "记录 · 本机数据库",
    "会议、纪要、字幕与对话长期保存在同一个本机数据库里；导出才生成文件。", "settingsSession"],
  ["首要事实", "谁在用麦克风 · 会话占用",
    "本机只有一个麦克风、一个实时 worker：所有权常驻可见，交还要确认。", "meetingGuard"]
  ,
  ["同一条链路", "分人 · 会议与字幕共用",
    "同一个分人扩展、同一套匿名标签与降级话术；档位不支持时两边都不分人，正文照常。", "diarization"]
];

// 页面不是一次性画面（用户 2026-09-17：会改变一些页面设计的交互方式，现在的设计有些
// 是一次性的）。三条闭环各自**只有一个产品页**加一个浮层，其余都是这一页的状态：
//
//   未配置 / 空态 / 未开始  →  进行中  →  刚结束（还没整理完）  →  归档 · 从库里再来一轮
//
// 所以「结束」不是把用户留在一块结束页上，而是同一页换成「刚结束」这一态，产物直接落在
// 页内那个长期存在的资产区（记录库）。以后改交互，重画的是这里的一格状态，不是一整块画板
// ——这就是这份稿抗改动的部分：变的是状态内容，不变的是页骨架。
//
// 每格最后一栏是画着那个状态的画板 anchor：格子可点，点进去就是那一态。
const CLOSURE_STATES = [
  {
    key: "assistant", title: "语音助手 · 对话页", detail: "页骨架：页头 + 结论区 + 主区 + 记录库",
    states: [
      ["状态① · 未开始", "先定人设与音色",
        "人设与音色在「开始对话」这一步定；人设是它开口前读的第一段话，开始后不再变。" +
          "没配模型时这一态换成受阻态，出口仍是设置 · 会话。", "assistantReady"],
      ["状态② · 对话中", "只有主区在长",
        "一问一答（外放）：它说话时闭麦；滚动区随轮次变高，记录库栏位已经在。", "assistant"],
      ["状态③ · 实时对讲", "全双工 · 可打断",
        "耳机下你一开口就打断它（它立刻停下正在说的这句）；这一句标「被打断」并留住正文。",
        "assistantDuplex"],
      ["状态④ · 换过音色", "人设已锁",
        "音色下一句生效并标「第 N 句起」；人设保持本轮开始时那个值，只给锁与新开一轮的出口。",
        "assistantVoice"],
      ["状态⑤ · 刚结束", "记录库接手",
        "结束时不是留在结束页：同一页换成「刚结束」，这一段已经选中，可以继续、重命名、导出、移除。",
        "assistantClosed"]
    ]
  },
  {
    key: "meeting", title: "会议助手 · 会议页",
    // 用户 2026-09-18：「会议助手整体布局需要重新构思」。页骨架因此从「状态条 + 转录区 +
    // 纪要栏 + 会议库」改成「页头 + 状态带 + 转录区 + 会议信息栏 + 贴底的内心 OS 抽屉」，
    // 这一行与 closureStateCell 里的五态一起，就是改版后「哪一段固定」的书面答案。
    detail: "页骨架：页头 + 状态带 + 转录 + 会议信息 + 贴底 OS 抽屉",
    states: [
      ["状态① · 空态", "没有进行中的会议",
        "先选音频来源（麦克风 / 本机音频按 App 抓 / 两者），再开始；三种受阻各有一条出口。",
        "meetingEmpty"],
      ["状态② · 录制中", "状态条接管页头",
        "转录边听边出现，两行标明来源；内心 OS 收在底部一行，随时展开——换页不再是提问的前提。",
        "meetingRecording"],
      ["状态③ · 内心 OS", "私密问答开着",
        "答案只有你看得到：不进会议音频、不进转录，带证据引用，能追问，也能写进纪要。",
        "meetingInnerOS"],
      ["状态④ · 整理中", "转录先写进记录，纪要留空位",
        "「查看纪要」占位不可点——它在等自己的下一个状态；完成后落到同一页的已归档。",
        "meetingProcessing"],
      ["状态⑤ · 会后", "纪要 / 改名 / 导出",
        "会中会后都能给说话人改名、合并、拆出；纪要只有最新版可点，旧版本仍可回看与导出。",
        "meetingMinutes"]
    ]
  },
  {
    key: "captions", title: "实时字幕 · 浮层 + 记录库", detail: "页骨架：窗口记录库 + 一条浮层字幕带",
    states: [
      ["状态① · 未开始", "窗口里是前置检查",
        "窗口开着但不必在前台；开始字幕这个动作发生在浮层那侧，窗口不换页。", "captionsIdle"],
      ["状态② · 跟随中", "浮层贴底跟随",
        "窗口可以关掉，记录照写；分人档位上带说话人标签，位置与字号按屏幕记住。", "bandFollow"],
      ["状态③ · 回看", "同一个浮层上滚",
        "上滚只是换成了回看态（出现「回到最新」），不是第二个界面，也不结束会话。", "bandReview"],
      ["状态④ · 已保存", "浮层收起，记录库接手",
        "结束并保存后回到记录库：刚结束的这一段已选中，可搜、可改说话人标签、可导出 SRT。",
        "captionsSaved"],
      ["状态⑤ · 受阻", "未授权 / 未就绪 / 被占用",
        "三种受阻共用同一条带子，各给一个出口；被占用那一种的出口是「结束前一个会话并切换」。",
        "bandBlocked"]
    ]
  }
];

// 页骨架里哪一段固定、哪一段随状态换——这是「改交互时重画什么」的答案，所以它必须写进
// 稿里，而不是只存在于设计者的记忆里。
const CLOSURE_FIXED_VARIABLE = [
  ["固定 · 页骨架", "页头与路由选中态",
    "三条闭环各自的页名字、图标与侧边栏选中行不随状态变；状态永远写在页头下面那条结论区里，" +
      "不占页头本身。"],
  ["固定 · 资产区", "记录库栏位常驻",
    "列表 + 选中 + 详情这一栏一直在同一位置：没有记录时是空态，有一条时选它，有三十条时滚它。" +
      "三种记录同住一个数据库，所以它们长得一样。"],
  ["可变 · 结论区", "一条结论条换文案与动作",
    "顺利态、受阻态、刚结束态共用同一条结论条：换的是标题、说明与那一两个按钮，位置与高度不变。"],
  ["可变 · 主区", "主区按状态换内容",
    "对话滚动区 / 录制转录区 / 前置检查清单都在同一块主区里，因此页面之间不会因为状态变化而跳版。"],
  ["可变 · 可用性", "按钮的禁用与占位",
    "「查看纪要」在整理完成前不可点、主按钮在受阻时换成次要动作：禁用是状态，不是缺一个页面。"],
  ["可变但不新建页", "浮层与窗口的分工",
    "字幕带的跟随 / 回看 / 大字三档都发生在同一条浮层上；窗口里的记录库不参与这三档切换。"],
  ["可变 · 会话配置", "音频来源与对讲模式",
    "换来源（麦克风 / 本机音频 / 混音）与换对讲模式（一问一答 / 实时对讲）都是会话内的设置：" +
      "换完接着录、接着聊，页骨架不动，配置随这一段记录存。" +
      "人设不在此列：它一开轮就锁住，改它得新开一轮——为什么，见「换音色 vs 换人设」那块板。"],
  ["固定 · 缺什么就说什么", "授权 · 档位 · 模型",
    "这三类缺失永远是同一条结论条 + 一个出口；能力变多不会让它们变成三套说法。"]
];

// 旅程里还会走到这里：这四种情况不属于「一条闭环的五个阶段」，但按用户故事真的走一遍
// 一定会遇到，所以它们同样要有落点与出口。前三条各有落点，第四条按既有 sheet 形状在
// 实现阶段补——逐条对账在 2026-09-17-session-closures/USER-JOURNEYS.md 的缺口表里。
//
// 它们不进「状态演进」那张表，因为那张表量的是**一条闭环的时间轴**；中断是事件、记忆是
// 跨会话资产、抢麦克风是三条闭环的交叉点、移除是资产维护——四者都不是「这一页的第 N 态」。
const CLOSURE_JOURNEY = [
  ["Attention", "录制断了（会议）",
    "服务重启、系统睡眠、App 退出：正文照旧写进记录，续接是一个动作——不偷偷接着录。",
    "meetingInterrupted"],
  ["Info", "记忆（助手）",
    "跨会话的事实与偏好，与对话分开存；本轮用的是开始那一刻那一份，改动下一轮生效。",
    "assistantMemory"],
  ["Attention", "两个会话抢一个麦克风",
    "后到的那个以受阻态出现，只给两个出口：结束前一个会话并切换，或先看它的转录。",
    "bandBlocked"],
  ["Critical", "移除与清空（记录库）",
    "移除一条记录 / 清空字幕记录共用一张破坏性确认：写清影响面与能不能恢复。",
    null],
  ["Info", "面板收起（每一屏）",
    "右栏、贴底抽屉、浮层、目录列都算非主框体：收起是正常状态，主框体吃满，关键状态留在主框体里。",
    "panelRules"],
  ["Ready", "首次启动 · 空态引导（初见）",
    "全新安装或清空数据库：会话三能力起手导航，声明本地隐私保障与 SQLite 长期资产。",
    "sessionFirstRun"]
];

// 格子的节点名带上泳道与序号：同一格里两条路径可能指向同一块画板（语音助手的入口与主
// 交互都是「对话中」），按 anchor 命名会让第二个格子永远连不上——它连的是同一个名字，
// 而 findByName 只会找到第一个。
function closureStageCell(parent, nodeName, stage, title, detail) {
  const cell = frame(nodeName, {
    layout: "VERTICAL", gap: 5, pad: 12, radius: 10, fill: V["surface/content"]
  });
  size(cell, CLOSURE_CELL_W, CLOSURE_CELL_H);
  add(cell, text("stage", stage, "Caption / Medium", V["accent/rail"]));
  add(cell, text("title", title, "Body / Medium", V["text/primary"], { w: CLOSURE_CELL_W - 24 }));
  add(cell, text("detail", detail, "Caption", V["text/secondary"], { w: CLOSURE_CELL_W - 24 }));
  return add(parent, cell);
}

function closureSpineCell(parent, nodeName, kicker, title, detail) {
  const cell = frame(nodeName, {
    layout: "VERTICAL", gap: 5, pad: 14, radius: 10, fill: V["surface/panel"]
  });
  // 140, not 96: 五格之后每格从 490 收到 291，明细要折到三行；按最长的条目定高，
  // 不是按最短的那条（同 closureCheckRow 的格宽教训）。
  size(cell, CLOSURE_SPINE_W, 140);
  add(cell, text("kicker", kicker, "Caption / Medium", V["text/tertiary"]));
  add(cell, text("title", title, "Body / Medium", V["text/primary"], { w: CLOSURE_SPINE_W - 28 }));
  add(cell, text("detail", detail, "Caption", V["text/secondary"], { w: CLOSURE_SPINE_W - 28 }));
  return add(parent, cell);
}

// 状态格：与泳道格同一个形状（同一件事不该有两套画法），但带一个「这一态里换掉什么」的
// 行——那一行就是「哪些交互以后可以改、改了不用重画这一页」的书面答案。
//
// 格子宽度必须跟着**当前**状态数算，不能跟着上一版的数算（与 CLOSURE_SPINE_W 同一条
// 教训）：255 × 5 + 168 + 12 × 5 = 1503 ≤ 1504（画板内容宽）。三条闭环现在都是 5 态
// ——2026-09-18 补上「刚结束 / 会后 / 受阻」这一态，因为端到端旅程的终点原本不在表里。
const CLOSURE_STATE_W = 255;
const CLOSURE_STATE_H = 140;

function closureStateCell(parent, nodeName, state, title, detail) {
  const cell = frame(nodeName, {
    layout: "VERTICAL", gap: 5, pad: 12, radius: 10, fill: V["surface/content"]
  });
  size(cell, CLOSURE_STATE_W, CLOSURE_STATE_H);
  add(cell, text("state", state, "Caption / Medium", V["accent/rail"]));
  add(cell, text("title", title, "Body / Medium", V["text/primary"], { w: CLOSURE_STATE_W - 24 }));
  add(cell, text("detail", detail, "Caption", V["text/secondary"], { w: CLOSURE_STATE_W - 24 }));
  return add(parent, cell);
}

// 状态模型 · 三分之一个画板：左边是三条闭环各自的状态演进，右边是「固定 / 可变」的答案。
// 它存在的理由不是好看：这份稿以后一定会被改，改之前得先知道哪一段不动。
function buildClosureStateModel(parent) {
  const section = frame("stateModel", { layout: "VERTICAL", gap: 12 });
  add(section, text("title", "状态演进 · 每条闭环只有一个产品页", "Heading / Section",
    V["text/primary"]));
  add(section, text("detail",
    "同一个页面按状态换内容，不为每个时刻单开一块画板：未配置 / 空态 / 未开始回到「进行中」，" +
      "结束时落进页内那个长期存在的资产区。下面每一格都可以点，跳到画着那一态的画板。",
    "Callout", V["text/secondary"], { w: 1200 }));

  const head = frame("stageHead", { layout: "HORIZONTAL", gap: CLOSURE_GAP, align: "CENTER" });
  add(head, text("lane", "产品页", "Caption / Medium", V["text/tertiary"], { w: CLOSURE_LANE_W }));
  CLOSURE_STATES[0].states.forEach(function (s, i) {
    const box = frame("stage", { layout: "HORIZONTAL" });
    size(box, CLOSURE_STATE_W, null);
    add(box, text("label", "状态 " + (i + 1), "Caption / Medium", V["text/tertiary"]));
    add(head, box);
  });
  add(section, stretch(head));

  CLOSURE_STATES.forEach(function (lane) {
    const row = frame("stateRow", { layout: "HORIZONTAL", gap: CLOSURE_GAP });
    const label = frame("laneLabel", { layout: "VERTICAL", gap: 4, padY: 4 });
    size(label, CLOSURE_LANE_W, CLOSURE_STATE_H);
    add(label, text("title", lane.title, "Body / Medium", V["text/primary"], { w: CLOSURE_LANE_W }));
    add(label, text("detail", lane.detail, "Caption", V["text/tertiary"], { w: CLOSURE_LANE_W }));
    add(row, label);
    lane.states.forEach(function (s, i) {
      closureStateCell(row, "state/" + lane.key + "/" + i, s[0], s[1], s[2]);
    });
    add(section, stretch(row));
  });

  hairline(section);
  add(section, text("title", "改这一页之前：哪一段固定、哪一段可变", "Heading / Section",
    V["text/primary"]));
  const pairs = [CLOSURE_FIXED_VARIABLE.slice(0, 3), CLOSURE_FIXED_VARIABLE.slice(3)];
  const cols = frame("columns", { layout: "HORIZONTAL", gap: CLOSURE_GAP, align: "MIN" });
  const colW = (1504 - CLOSURE_GAP) / 2;
  pairs.forEach(function (col) {
    const stack = frame("column", { layout: "VERTICAL", gap: CLOSURE_GAP });
    size(stack, colW, null);
    col.forEach(function (r) {
      const cell = frame("factor", {
        layout: "VERTICAL", gap: 5, pad: 14, radius: 10, fill: V["surface/panel"]
      });
      size(cell, colW, null);
      add(cell, text("kicker", r[0], "Caption / Medium", V["text/tertiary"]));
      add(cell, text("title", r[1], "Body / Medium", V["text/primary"], { w: colW - 28 }));
      add(cell, text("detail", r[2], "Caption", V["text/secondary"], { w: colW - 28 }));
      add(stack, stretch(cell));
    });
    add(cols, stack);
  });
  add(section, stretch(cols));
  return add(parent, stretch(section));
}

// 旅程那一节：把「不属于五个阶段、但一定会遇到」的四种情况画在总览上。它排在状态模型
// 之后，因为读法是一样的——先看「一页怎么换态」，再看「换不到的那几种怎么办」。
function buildClosureJourneyNotes(parent) {
  const section = frame("journey", { layout: "VERTICAL", gap: 12 });
  add(section, text("title", "旅程还会走到这里：不是每个时刻都点得出来", "Heading / Section",
    V["text/primary"]));
  add(section, text("detail",
    "这五种情况不属于「一条闭环的五个阶段」，但按用户故事走一遍一定会遇到：中断是事件，" +
      "记忆是跨会话的资产，抢麦克风是三条闭环的交叉点，面板收起是每一屏都会有的状态，" +
      "移除与清空是资产的维护。除最后一条按既有 sheet 形状在实现阶段补，其余都点得进画板。",
    "Callout", V["text/secondary"], { w: 1200 }));
  const table = frame("table", {
    layout: "VERTICAL", gap: 0, radius: 12, fill: V["surface/content"], clip: true
  });
  CLOSURE_JOURNEY.forEach(function (j, i, all) {
    closureCheckRow(table, j[0], j[1], j[2], function (box) {
      add(box, text("hint", j[3] ? "点这一行看这一态" : "实现阶段按既有形状补",
        "Caption", V["text/tertiary"]));
    }, 820, "journey/" + i);
    if (i < all.length - 1) hairline(table);
  });
  add(section, stretch(table));
  return add(parent, stretch(section));
}

// 闭环总览：三条泳道 + 一根脊柱。每个格子都是一个可点的原型节点，所以这张图不是
// 索引页，而是这套稿的入口——从它出发可以走完任意一条闭环。
function buildClosureOverview() {
  const page = P[CLOSURE_GROUPS[0]];
  const board = frame("闭环总览 · 三条闭环", {
    layout: "VERTICAL", gap: 18, padX: CLOSURE_PAD, padY: 40, fill: V["surface/content"]
  });
  size(board, CLOSURE_W, null);
  board.x = 0;
  board.y = 0;
  add(page, board);

  boardHead(board, "三条闭环 · 一次画完",
    "每个节点都可以点，跳到承载它的那块画板。三条闭环共用同一根脊柱：谁在用麦克风、" +
    "大模型在哪里配、系统级入口在哪。闭环的判据是两端都在稿里——从哪进、产物落在哪。", 1200);

  const stageHead = frame("stageHead", { layout: "HORIZONTAL", gap: CLOSURE_GAP, align: "CENTER" });
  add(stageHead, text("lane", "闭环阶段", "Caption / Medium", V["text/tertiary"], { w: CLOSURE_LANE_W }));
  CLOSURE_STAGES.forEach(function (s) {
    const box = frame("stage", { layout: "HORIZONTAL" });
    size(box, CLOSURE_CELL_W, null);
    add(box, text("label", s, "Caption / Medium", V["text/tertiary"]));
    add(stageHead, box);
  });
  add(board, stretch(stageHead));

  CLOSURE_LANES.forEach(function (lane) {
    const row = frame("lane", { layout: "HORIZONTAL", gap: CLOSURE_GAP });
    const label = frame("laneLabel", { layout: "VERTICAL", gap: 5, padY: 4 });
    size(label, CLOSURE_LANE_W, CLOSURE_CELL_H);
    icon(label, lane.icon, 18, V["accent/rail"]);
    add(label, text("title", lane.title, "Body / Medium", V["text/primary"]));
    add(label, text("detail", lane.detail, "Caption", V["text/tertiary"], { w: CLOSURE_LANE_W }));
    add(row, label);
    lane.stages.forEach(function (s, i) {
      closureStageCell(row, "lane/" + lane.key + "/" + i, s[0], s[1], s[2]);
    });
    add(board, stretch(row));
  });

  hairline(board);

  const spine = frame("spine", { layout: "VERTICAL", gap: 12 });
  add(spine, text("title", "共用脊柱 · 三条闭环都跑在它上面", "Heading / Section", V["text/primary"]));
  const spineRow = frame("spineRow", { layout: "HORIZONTAL", gap: CLOSURE_GAP });
  CLOSURE_SPINE.forEach(function (s, i) {
    closureSpineCell(spineRow, "spine/" + i, s[0], s[1], s[2]);
  });
  add(spine, stretch(spineRow));
  add(board, stretch(spine));

  hairline(board);

  // 状态模型放在脊柱之后：读完「三条闭环共用什么」，紧接着读「同一页怎么换状态」——
  // 这两段一起回答的是同一个问题：这份稿以后被改的时候，什么动、什么不动。
  buildClosureStateModel(board);

  hairline(board);
  buildClosureJourneyNotes(board);

  add(board, text("foot",
    "读法：任意一格点进去，就是那条闭环的那一步。受阻、占用、结束这三种「中途」在每一行里" +
      "都有自己的格子——闭环画完整，靠的就是这三种情况都有出口。状态格里写的「换掉什么」是" +
      "这份稿的改动面：改交互改的是那一格的状态，页骨架与资产区不动。",
    "Caption", V["text/tertiary"], { w: CLOSURE_W - CLOSURE_PAD * 2 }));
  return board;
}

// 闭环稿的画板高度各不相同（设置与菜单栏按内容取高），所以按游标往下排，不用固定
// 步长：固定步长会在两块画板之间留下压边或者空档。
function buildClosureScreens() {
  const page = P[CLOSURE_GROUPS[1]];
  const built = [];
  let y = 0;
  CLOSURE_BOARDS.forEach(function (def) {
    const win = def.full
      ? def.full()
      : buildShell(def.route, def.title, def.icon, def.screen, def.session);
    win.x = 0;
    win.y = y;
    add(page, win);
    y += win.height + 80;
    built.push(win);
  });
  return built;
}

function closureDarkVariants(windows, collection, modeId) {
  return darkVariants(windows, CLOSURE_GROUPS[1], collection, modeId, function (clone, i) {
    clone.x = 1560;
    clone.y = windows[i].y;
  });
}

const SCREEN_DEFS = [
  ["dubbing", "配音台", "audio-lines", screenDubbing],
  ["voiceDesign", "音色创作", "sparkles", screenVoiceDesign],
  ["voiceClone", "音色克隆", "mic", screenVoiceClone],
  ["voiceLibrary", "音色库", "library", screenVoiceLibrary],
  ["works", "我的作品", "folder-open", screenWorks],
  ["overview", "服务状态", "server", screenOverview],
  ["monitoring", "运行监控", "activity", screenMonitoring],
  ["models", "模型", "package", screenModels],
  ["diagnostics", "诊断", "stethoscope", screenDiagnostics],
  ["developerDocs", "开发者文档", "book-open", screenDeveloperDocs]
];

// 会话模块的七块屏幕画板。同一块画板上「路由」与「所有权」可以不同：会议录制的三块
// 画板都是会议页，只有一块是它的默认落点（primary）——侧边栏连线需要一个确定的目标，
// 而状态矩阵需要多个状态。
const SESSION_BOARDS = [
  { key: "assistant", title: "语音助手", icon: "message-circle",
    screen: screenAssistant, session: "assistant", primary: true },
  { key: "assistant", title: "语音助手 · 未配置对话模型", icon: "message-circle",
    screen: screenAssistantBlocked, session: "assistant" },
  { key: "meeting", title: "会议助手 · 录制中", icon: "users",
    screen: screenMeetingRecording, session: "meeting", primary: true },
  { key: "meeting", title: "会议助手 · 会后纪要", icon: "users",
    screen: screenMeetingMinutes, session: "meeting" },
  { key: "meeting", title: "会议助手 · 空态", icon: "users",
    screen: screenMeetingEmpty, session: "idle" },
  { key: "captions", title: "实时字幕", icon: "captions",
    screen: screenCaptions, session: "captions", primary: true },
  { key: "meeting", title: "会话占用 · 结束会议并切换", icon: "users",
    full: buildSessionGuardBoard, session: "meeting" }
];

function buildBoardList(defs, group) {
  const page = P[group];
  const built = [];
  defs.forEach(function (def, i) {
    const win = def.full
      ? def.full()
      // def[4] is the session state the sidebar row renders: dropping it leaves
      // every session board claiming "麦克风空闲", which is exactly the state
      // these screens exist to distinguish.
      : buildShell(def[0], def[1], def[2], def[3], def[4]);
    win.x = 0;
    win.y = i * 1020;
    // Export settings come from add() — every page-level frame gets the same
    // PNG @4x + SVG pair.
    add(page, win);
    built.push(win);
  });
  return built;
}

function buildScreens() {
  return buildBoardList(SCREEN_DEFS, "04 Screens");
}

function buildSessionScreens() {
  return buildBoardList(SESSION_BOARDS.map(function (b) {
    const def = [b.key, b.title, b.icon, b.screen, b.session];
    def.full = b.full;
    return def;
  }), "07 会话");
}

// 深色不是第二个 mode（免费版每个变量集合只允许一个 mode），而是把每块浅色画板克隆
// 一份、逐节点改绑到深色集合。屏幕与浮层都要走同一条路，所以这里只有一个实现。
function darkVariants(windows, group, collection, modeId, place) {
  const page = P[group];
  return windows.map(function (win, i) {
    const clone = win.clone();
    clone.name = win.name + " · Dark";
    if (modeId) {
      try {
        clone.setExplicitVariableModeForCollection(collection, modeId);
      } catch (e) {
        try { clone.setExplicitVariableModeForCollection(collection.id, modeId); } catch (e2) {}
      }
    } else {
      darkReference(clone);
    }
    place(clone, i);
    add(page, clone);
    return clone;
  });
}

function buildDarkVariants(windows, collection, modeId) {
  return darkVariants(windows, "04 Screens", collection, modeId, function (c, i) {
    c.x = 1560;
    c.y = i * 1020;
  });
}

function buildSessionDarkVariants(windows, collection, modeId) {
  return darkVariants(windows, "07 会话", collection, modeId, function (c, i) {
    c.x = 1560;
    c.y = i * 1020;
  });
}

function buildFloatDarkVariants(windows, collection, modeId, group) {
  let y = 0;
  return darkVariants(windows, group || "08 会话浮层", collection, modeId, function (c) {
    c.x = 1500;
    c.y = y;
    y += c.height + 60;
  });
}

// Free-plan files cannot add a second variable mode, so the dark appearance is
// produced by re-binding every variable-backed fill/stroke to the matching
// variable in the "SpeechRail (Dark reference)" collection.
function darkReference(node) {
  ["fills", "strokes"].forEach(function (field) {
    const varId = paintVarId(node, field);
    if (!varId) return;
    const original = figma.variables.getVariableById(varId);
    if (!original) return;
    const darkVar = V["dark/" + original.name];
    if (!darkVar) return;
    bindPaint(node, field, darkVar);
  });
  if ("children" in node) node.children.forEach(darkReference);
}

function buildDarkReferenceVariants(windows) {
  return windows.map(function (win) {
    const clone = win.clone();
    clone.name = win.name + " · Dark";
    clone.x = 1560;
    clone.y = win.y;
    add(P["04 Screens"], clone);
    darkReference(clone);
    return clone;
  });
}

function buildCover() {
  const page = P["00 Cover"];
  const canvas = frame("Cover", { layout: "VERTICAL", gap: 24, pad: 96, fill: V["surface/content"] });
  size(canvas, 1600, 1040);
  add(page, canvas);
  add(canvas, text("kicker", "SPEECHRAIL · macOS 26", "Caption / Medium", V["accent/rail"]));
  add(canvas, text("h1", "SpeechRail 管理控制台", "Title / Large", V["text/primary"]));
  add(canvas, text("h2", "UI/UX 重设计 + 实时会话模块 · 提案 v1.1.0", "Title / Page", V["text/primary"]));
  add(canvas, text("lead",
    "让 App 同时符合两件事：产品定位（本机语音引擎的唯一产品化入口）与 macOS 26 最佳实践" +
    "（材质、层级、圆角、工具栏与键盘路径交还给系统）。v1.1.0 增加「会话」模块：" +
    "语音助手、会议助手、实时字幕，以及会话所有权与设置里的对话模型。",
    "Body", V["text/secondary"], { w: 820 }));
  add(canvas, text("date", "2026-09-15 → 2026-09-17 · Status: Proposed", "Callout", V["text/tertiary"]));
  const list = frame("contents", { layout: "VERTICAL", gap: 6 });
  [
    "01 Foundations — 颜色、字体层级、间距、圆角、图标（全部为 Variables）",
    "02 Components — 状态胶囊、导航项、按钮、卡片、列表行、候选卡、空状态",
    "03 Flows — 七条主流程连线，并注明跨页连线需在 Prototype 面板手动接入",
    "04 Screens — 10 个创作与引擎页面 × Light / Dark 两种外观",
    "07 会话 — 语音助手 / 会议助手 / 实时字幕共 7 块屏幕画板 × Light / Dark",
    "08 会话浮层 — 字幕带的四个状态（跟随 / 回看 / 大字 / 受阻）× Light / Dark",
    "05 Menu & Settings — 菜单栏面板（空闲 / 会话进行中 / 控制受限 / 深色）与设置窗口四个页签",
    "06 Archive — 迁移前的机架视觉对照，只作历史记录",
    "设计依据：docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md（视觉语言）",
    "会话模块：docs/design/2026-09-17-live-sessions/SESSIONS-SPEC.md"
  ].forEach(function (line) {
    add(list, text("line", line, "Callout", V["text/secondary"]));
  });
  add(canvas, list);
  return canvas;
}

// =============================================================================
// 03 Flows · 05 Menu & Settings · 06 Archive
// =============================================================================
//
// These three pages are documentation with a job. Flows explains why the eight
// screens are shaped the way they are and doubles as the clickable prototype,
// Menu & Settings covers the two surfaces that are not the main window, and
// Archive keeps the retired rack visual on record so the direction cannot drift
// back by accident.

const MENU_ROW_W = 278;      // 288pt panel minus its 5pt inset on both sides
const SETTINGS_CARD_W = 604; // 640pt window minus the 18pt pane padding
const WIRE_ERRORS = [];      // prototype-link failures, surfaced in the report

// Review PNGs. Off by default: a build should not write files. Set to true when
// the pages need to be shared as images; each frame downloads at 0.5x through the
// plugin UI, so the files land in the browser/desktop download folder.
const EXPORT_PNGS = false;
const EXPORT_PAGES = ["05 Menu & Settings", "06 Archive"];

// The single frame each documentation page is allowed to own at the top level,
// so a node that never got appended is reported instead of floating on canvas.
const CANVAS_NAMES = {
  "00 Cover": "Cover",
  "01 Foundations": "Foundations",
  "02 Components": "Components",
  "03 Flows": "Flows",
  "05 Menu & Settings": "Menu & Settings",
  "06 Archive": "Archive",
  // 闭环稿：总览是一张可点的图（不是屏幕），字幕带浮层与全量稿同名同形。
  "10 闭环总览": "闭环总览 · 三条闭环",
  "12 会话浮层": [
    "浮层 · 字幕带 · 跟随中",
    "浮层 · 字幕带 · 回看",
    "浮层 · 字幕带 · 大字",
    "浮层 · 字幕带 · 受阻",
    // 2026-09-18 用户：「没有看到字幕带的 UI」。四块浮层板画的都是**带子本身**，没有一块
    // 画「它贴在画面上是什么样」——于是这块板补上：半透明的带子压在一段正在播放的画面上。
    "浮层 · 字幕带 · 贴在画面上（在用时）"
  ],
  // 会话浮层不是屏幕：它们是窗口级面板，各自一块画板，所以按名字逐个声明。
  "08 会话浮层": [
    "浮层 · 字幕带 · 跟随中",
    "浮层 · 字幕带 · 回看",
    "浮层 · 字幕带 · 大字",
    "浮层 · 字幕带 · 受阻"
  ]
};

function findByName(root, name) {
  if (root.name === name) return root;
  if (!("children" in root)) return null;
  for (let i = 0; i < root.children.length; i++) {
    const hit = findByName(root.children[i], name);
    if (hit) return hit;
  }
  return null;
}

// 连线源：按钮在稿里是「一个有标签的形状」，不是唯一命名的节点。按标签找回离它最近的
// 按钮，比在每个按钮调用点补一个名字更难写错——按钮的文案本来就是这条连线的语义。
// 同一个标签在一页里出现两次时取树序在前的那一个，所以侧边栏里的顺序是有意义的：
// 可点的那个排在前面，灰掉的那个（菜单栏空闲面板里的「结束当前会话…」）不该被连上。
function findButton(root, label) {
  let hit = null;
  (function walk(node) {
    if (hit) return;
    if (node.type === "TEXT" && node.characters === label) {
      for (let up = node.parent; up && up !== root; up = up.parent) {
        if (up.name && up.name.indexOf("Button /") === 0) { hit = up; return; }
      }
    }
    if (node.children) node.children.forEach(walk);
  })(root);
  return hit;
}

function findIconButton(root, iconName) {
  let hit = null;
  (function walk(node) {
    if (hit) return;
    if (node.name === "icon/" + iconName) {
      for (let up = node.parent; up && up !== root; up = up.parent) {
        if (up.name === "iconButton") { hit = up; return; }
      }
    }
    if (node.children) node.children.forEach(walk);
  })(root);
  return hit;
}

// 闭环稿的连线源有三种形状：菜单行（按行名）、按钮（按标签）、字幕带工具条（按图标）。
// 一个入口只管一件事：调用点说「这块画板上的那一句文案通向哪」，不必知道它是哪种形状。
function closureLinkSource(root, label) {
  return findByName(root, "menu/" + label) || findByName(root, "seg/" + label) ||
    findButton(root, label) || findIconButton(root, label);
}

function trafficLights(parent) {
  const box = frame("trafficLights", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
  TRAFFIC.forEach(function (c) {
    const e = figma.createEllipse();
    e.name = "light";
    size(e, 12, 12);
    rawFill(e, c);
    add(box, e);
  });
  return add(parent, box);
}

function boardHead(parent, title, subtitle, width) {
  const box = frame("boardHead", { layout: "VERTICAL", gap: 6 });
  add(box, text("kicker", "SPEECHRAIL · macOS 26", "Caption / Medium", V["accent/rail"]));
  add(box, text("title", title, "Title / Large", V["text/primary"]));
  add(box, text("sub", subtitle, "Body", V["text/secondary"], { w: width }));
  return add(parent, stretch(box));
}

// --- 03 Flows -----------------------------------------------------------------

const FLOWS = [
  {
    key: "dubbing",
    title: "配音主流程",
    detail: "文稿进、音频出。四个动作都发生在配音台，不跳页、不打断输入。",
    steps: [
      ["配音台", "输入文稿", "正文区自动计数，⌘⏎ 直接触发生成", "dubbing"],
      ["配音台", "选择音色", "胶囊展开 popover，行内试听后落定", "dubbing"],
      ["配音台", "生成语音", "主按钮进入进行中态，结果条接住产物", "dubbing"],
      ["配音台", "播放与导出", "波形播放、回到作品列表、导出文件", "dubbing"]
    ]
  },
  {
    key: "voice",
    title: "音色创作流程",
    detail: "从一句描述到可复用的音色；描述、候选、试听、保存都在同一页完成。",
    steps: [
      ["音色创作", "描述音色", "名称 + 一句话特征，容量边界写在字段旁", "voiceDesign"],
      ["音色创作", "生成候选", "2×2 网格，每格显示自己的生成阶段", "voiceDesign"],
      ["音色创作", "试听 A/B", "逐格播放，波形与音色语义色对应", "voiceDesign"],
      ["音色创作", "保存音色", "命名后写入本机音色目录", "voiceDesign"],
      ["音色库", "出现在音色库", "带「我的」徽标，可在配音台直接选用", "voiceLibrary"]
    ]
  },
  {
    key: "clone",
    title: "音色克隆流程",
    detail: "用用户自己的录音注册音色。录音、核对、预检都在同一页，注册前先给出可读的结论。",
    steps: [
      ["音色克隆", "选提词稿", "四段官方提词稿任选，也可自己写一段", "voiceClone"],
      ["音色克隆", "录制", "实时电平与计时；越过时长上下限就地提示", "voiceClone"],
      ["音色克隆", "回听与核对", "回放原始录音，按实际说出的内容修正文本", "voiceClone"],
      ["音色克隆", "先检查参考音频", "服务端预检给出信噪比、削波与内容匹配", "voiceClone"],
      ["音色克隆", "注册音色", "保存为可复用音色；失败时保留录音与填好的名称", "voiceClone"],
      ["音色库", "试听与使用", "在音色库试听新音色，并在配音台选用", "voiceLibrary"]
    ]
  },
  {
    key: "recovery",
    title: "受阻恢复流程",
    detail: "能力缺失时不把错误丢给用户：先说明影响，再给出唯一的修复路径。",
    steps: [
      ["配音台", "能力缺失", "结论条：缺失档位 + 影响 + 唯一主动作", "dubbing"],
      ["模型", "切换档位", "档位卡显示差异与本机资源预算", "models"],
      ["配音台", "返回并重试", "返回后文稿与设置保持原样", "dubbing"]
    ]
  },
  {
    key: "captions",
    title: "实时字幕流程",
    detail: "字幕带不占主窗口：入口在系统里（菜单栏与快捷键），页面只负责回看与导出。",
    steps: [
      ["任意位置", "打开字幕带", "⌘⇧L 或菜单栏「开始实时字幕」，不改变当前页面", "captions"],
      ["浮层 · 字幕带", "跟随中", "贴底跟随；上滚回看会暂停跟随并出现「回到最新」", "captions"],
      ["浮层 · 字幕带", "复制某一段", "悬停出工具条；复制进剪贴板", "captions"],
      ["实时字幕", "回看与导出", "记录库里搜索、按说话人筛、导出 SRT", "captions"]
    ]
  },
  {
    key: "meeting",
    title: "会议流程",
    detail: "开始 → 边听边记 → 结束整理 → 纪要 → 导出；音频不留存。",
    steps: [
      ["会议助手", "开始会议", "会议一开始就切到会议页：它必须看得见", "meeting"],
      ["会议助手", "边听边记", "是否出现说话人标签，由档位决定而不是由开关决定", "meeting"],
      ["会议助手", "结束会议", "EOF 屏障：等分人水位对齐再封存，未对齐时保留正文", "meeting"],
      ["会议助手", "生成纪要", "本机大模型；重新生成新增版本，不覆盖旧版本", "meeting"],
      ["会议助手", "改名与导出", "说话人改名是元数据修订，正文不改写", "meeting"]
    ]
  },
  {
    key: "session",
    title: "会话受阻与交还",
    detail: "缺能力、缺授权、被占用——三种受阻都指向一个可执行的下一步。",
    steps: [
      ["语音助手", "缺对话模型", "结论条 + 去设置；识别与合成仍然可用", "assistant"],
      ["设置 · 会话", "配置与检查", "地址、模型、密钥（钥匙串）+ 一次连接检查", "assistant"],
      ["任意会话页", "被占用", "守卫说清丢什么、保什么，再决定是否交还", "meeting"],
      ["会议助手", "仍可整理", "结束后照样生成纪要，已录内容不丢", "meeting"]
    ]
  }
];

// One step of a flow. Fixed height so the row reads as a rail instead of a
// staircase: hugging each card to its own copy left the arrows floating.
function flowStep(parent, where, title, detail) {
  const step = frame("step · " + title, {
    layout: "VERTICAL", gap: 6, pad: 14, radius: 12,
    fill: V["surface/content"]
  });
  size(step, 236, 104);
  add(step, text("where", where, "Caption / Medium", V["accent/rail"]));
  add(step, text("title", title, "Body / Medium", V["text/primary"]));
  add(step, text("detail", detail, "Caption", V["text/secondary"], { w: 208 }));
  return add(parent, step);
}

function flowArrow(parent) {
  const box = frame("arrow", { layout: "HORIZONTAL", align: "CENTER", justify: "CENTER" });
  size(box, 26, 104);
  icon(box, "chevron-right", 15, V["text/tertiary"]);
  return add(parent, box);
}

function buildFlows() {
  const page = P["03 Flows"];
  const canvas = frame("Flows", { layout: "VERTICAL", gap: 44, pad: 64, fill: V["surface/window"] });
  // 1840, not 1680: the longest flow (音色克隆) is six 236pt steps with arrows and
  // gaps = 1646pt, which is 94pt wider than a 1680 board's content box; the last
  // card was clipped by its own board edge in the export (实测 2026-09-17).
  size(canvas, 1840, null);
  add(page, canvas);
  boardHead(canvas, "七条主流程",
    "产品只有七条主路径，其余界面都是它们的入口或解释。每个节点都可点击，" +
    "跳到承载它的那个页面——这张图同时是可点击原型。", 1120);

  FLOWS.forEach(function (flow) {
    const section = frame("flow/" + flow.key, { layout: "VERTICAL", gap: 14 });
    const head = frame("head", { layout: "VERTICAL", gap: 3 });
    add(head, text("title", flow.title, "Heading / Section", V["text/primary"]));
    add(head, text("detail", flow.detail, "Callout", V["text/secondary"], { w: 900 }));
    add(section, stretch(head));
    const row = frame("steps", { layout: "HORIZONTAL", gap: 10 });
    flow.steps.forEach(function (s, i) {
      if (i) flowArrow(row);
      flowStep(row, s[0], s[1], s[2]);
    });
    add(section, stretch(row));
    add(canvas, stretch(section));
  });

  // Prototype note, printed on the page: the plugin API can only write a link
  // whose target is a top-level frame on the same page, and these steps point at
  // 04 Screens. The connection is left to the Prototype panel.
  add(canvas, text("footnote",
    "连同线说明：Figma 插件只能写入「同页 + 顶层 frame」的连线，" +
    "因此本页节点需要在 Prototype 面板手动连接；侧边栏导航已在 04 Screens 接通。",
    "Caption", V["text/tertiary"], { w: 1120 }));
  return canvas;
}

// --- 05 Menu & Settings -------------------------------------------------------

function menuSeparator(parent) {
  const box = frame("separator", { layout: "VERTICAL", padY: 5 });
  size(box, MENU_ROW_W, null);
  hairline(box);
  return add(parent, box);
}

// A menu row is a 26pt line, not a 34pt control: a menu bar panel is scanned
// rather than clicked through, and the kit keeps that density everywhere.
function menuRow(parent, label, o) {
  o = o || {};
  const row = frame("menu/" + label, {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 12, radius: 6
  });
  size(row, MENU_ROW_W, 26);
  const slot = frame("slot", { layout: "HORIZONTAL", align: "CENTER", justify: "CENTER" });
  size(slot, 15, 15);
  if (o.icon) icon(slot, o.icon, 15, V["text/secondary"]);
  add(row, slot);
  add(row, text("label", label, "Callout", V["text/primary"]));
  spacer(row);
  if (o.shortcut) kbd(row, o.shortcut);
  if (o.disabled) row.opacity = 0.45;
  return add(parent, row);
}

function menuPanel(name, o) {
  o = o || {};
  const panel = frame(name, {
    layout: "VERTICAL", gap: 0, pad: 5, radius: 12,
    fill: V["surface/panel"], stroke: V["border/separator"], strokeWeight: 1
  });
  size(panel, 288, null);
  elevate(panel);

  const head = frame("menuHead", { layout: "VERTICAL", gap: 4, padX: 10, padY: 8 });
  size(head, MENU_ROW_W, null);
  const title = frame("title", { layout: "HORIZONTAL", gap: 7, align: "CENTER" });
  icon(title, "audio-lines", 15, V["accent/rail"]);
  add(title, text("label", "SpeechRail", "Heading / Section", V["text/primary"]));
  add(head, stretch(title));
  // 状态行与副行都取自应用 ControlMenuView：档位用短名，副行是「版本 X · 端口 Y」。
  add(head, text("status", o.status || "服务已就绪 · Quality", "Callout", V["text/secondary"], { w: 246 }));
  add(head, text("detail", o.detail || "版本 0.7.3 · 端口 8201", "Subheadline", V["text/tertiary"], { w: 246 }));
  add(panel, head);

  menuSeparator(panel);
  menuRow(panel, "打开 SpeechRail", { icon: "app-window", shortcut: "⌘O" });
  // 会话命令进菜单栏而不是只进主窗口：字幕带与会议的真实用法是「App 不在前台」。
  menuSeparator(panel);
  menuRow(panel, o.sessionActive ? "暂停实时字幕" : "开始实时字幕",
    { icon: "captions", shortcut: "⌘⇧L" });
  menuRow(panel, "开始会议", { icon: "users", shortcut: "⌘⇧N" });
  menuRow(panel, "结束当前会话…", { icon: "square", shortcut: "⌘⇧.", disabled: !o.sessionActive });
  if (!o.sessionActive) {
    // 禁用项要就地解释为什么不能点，否则用户只能猜（与「控制通道不可用」同一条约定）。
    const why = frame("menuNote", { layout: "HORIZONTAL", padX: 12, padY: 2 });
    size(why, MENU_ROW_W, null);
    add(why, text("t", "没有正在进行的会话", "Subheadline", V["text/tertiary"]));
    add(panel, why);
  }
  menuSeparator(panel);
  menuRow(panel, "开始配音", { icon: "audio-lines", shortcut: "⌘N" });
  menuRow(panel, "音色创作", { icon: "sparkles" });
  menuSeparator(panel);
  menuRow(panel, "运行预检", { icon: "stethoscope" });
  if (o.restricted) {
    // The disabled group is explained where it appears: a greyed-out row with no
    // reason on screen is the failure mode this line exists to prevent.
    const warn = frame("warning", {
      layout: "HORIZONTAL", gap: 7, align: "CENTER", padX: 10, padY: 6, radius: 8,
      fill: V["surface/attentionTint"]
    });
    size(warn, MENU_ROW_W, null);
    icon(warn, "triangle-alert", 14, V["status/attention"]);
    add(warn, text("text", "控制通道不可用，服务操作已禁用", "Subheadline", V["status/attention"], { w: 220 }));
    add(panel, warn);
  }
  // 省略号是承诺：这三个动作都会先弹确认对话框（REDESIGN-SPEC §7.9）。
  [["启动服务…", "play"], ["停止服务…", "pause"], ["重启服务…", "refresh-cw"]].forEach(function (r) {
    menuRow(panel, r[0], { icon: r[1], disabled: o.restricted === true });
  });
  menuSeparator(panel);
  menuRow(panel, "打开设置…", { icon: "sliders-horizontal", shortcut: "⌘," });
  menuRow(panel, "退出 SpeechRail", { icon: "power", shortcut: "⌘Q" });
  return panel;
}

// The status item belongs to the window chrome, so it is judged in its own
// context instead of floating as a lone icon on the page.
function menuBarStrip(parent, o) {
  const bar = frame("menuBar", {
    layout: "HORIZONTAL", gap: 14, align: "CENTER", padX: 18, padY: 6, fill: V["surface/sidebar"]
  });
  size(bar, 900, 34);
  spacer(bar);
  const item = frame("statusItem", {
    layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 7, padY: 3, radius: 6
  });
  if (o.label) bindFill(item, V["surface/railTint"]);
  icon(item, "audio-lines", 15, V["text/primary"]);
  if (o.label) add(item, text("label", "SpeechRail", "Subheadline", V["text/primary"]));
  if (o.busy) dot(item, 6, V[o.tone || "accent/voice"]);
  add(bar, item);
  add(bar, text("clock", "09:41", "Callout", V["text/secondary"]));
  return add(parent, bar);
}

function switchControl(parent, on, disabled) {
  const track = frame("switch", {
    layout: "HORIZONTAL", pad: 2, radius: 999, justify: on ? "MAX" : "MIN"
  });
  size(track, 34, 20);
  bindFill(track, on ? V["accent/rail"] : V["border/strong"]);
  const knob = figma.createEllipse();
  knob.name = "knob";
  size(knob, 16, 16);
  rawFill(knob, "#FFFFFF");
  add(track, knob);
  if (disabled) track.opacity = 0.45;
  return add(parent, track);
}

// Slider built the way the dubbing speed control is built: a fixed box with the
// track, the filled part and the thumb stacked, because auto layout cannot
// overlap three nodes.
function sliderControl(parent, width, ratio, value) {
  const box = frame("sliderBox", { w: width, h: 14 });
  const track = frame("track", { layout: "HORIZONTAL", radius: 999 });
  size(track, width, 4);
  bindFill(track, V["border/strong"]);
  add(box, track);
  track.x = 0;
  track.y = 5;
  const filled = Math.round(width * ratio);
  const fill = frame("fill", { layout: "HORIZONTAL", radius: 999 });
  size(fill, filled, 4);
  bindFill(fill, V["accent/rail"]);
  add(box, fill);
  fill.x = 0;
  fill.y = 5;
  const thumb = frame("thumb", {
    layout: "HORIZONTAL", radius: 999, stroke: V["surface/content"], strokeWeight: 2
  });
  size(thumb, 14, 14);
  bindFill(thumb, V["accent/rail"]);
  add(box, thumb);
  thumb.x = Math.max(0, Math.min(width - 14, filled - 7));
  thumb.y = 0;
  const group = frame("sliderRow", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  add(group, box);
  add(group, text("value", value, "Body / Medium", V["text/primary"]));
  return add(parent, group);
}

function controlRow(parent, label, caption, trailing, o) {
  o = o || {};
  const row = frame("row", {
    layout: "HORIZONTAL", gap: 16, align: "CENTER", padX: 16, padY: 11
  });
  if (o.disabled) row.opacity = 0.45;
  const labels = frame("labels", { layout: "VERTICAL", gap: 3 });
  add(labels, text("label", label, "Body", V["text/primary"]));
  if (caption) {
    add(labels, text("caption", caption, "Caption", V["text/secondary"], { w: o.captionWidth || 340 }));
  }
  add(row, grow(labels));
  if (trailing) trailing(row);
  return add(parent, stretch(row));
}

// Section title outside the group, rows inside it: the shape macOS grouped forms
// use, so the settings window does not have to invent its own hierarchy.
function settingsSection(parent, title) {
  const head = frame("sectionHead", { layout: "HORIZONTAL", padX: 4, padY: 6 });
  add(head, text("title", title, "Caption / Medium", V["text/secondary"]));
  add(parent, stretch(head));
  const group = frame("group", {
    layout: "VERTICAL", gap: 0, radius: 12,
    fill: V["surface/content"]
  });
  size(group, SETTINGS_CARD_W, null);
  add(parent, stretch(group));
  return group;
}

function valueText(parent, chars, styleName) {
  return add(parent, text("v", chars, styleName || "Callout", V["text/primary"]));
}

function paneGeneral(c) {
  // 三个页签逐行对应应用 SettingsView 的 Section：稿上不放应用里不存在的开关
  // （登录时启动服务、启动后打开管理控制台、菜单栏图标都不在产品设置里）。
  const basics = settingsSection(c, "启动与窗口");
  controlRow(basics, "启动时读取服务状态",
    "控制台仍可在任意页面手动刷新。",
    function (p) { switchControl(p, true); });
  const dev = settingsSection(c, "开发者");
  controlRow(dev, "默认展开技术详情",
    "面向开发者的接口状态、阶段和标识信息仍只在管理控制台中展开。",
    function (p) { switchControl(p, false); });
}

function paneCreative(c) {
  const defaults = settingsSection(c, "创作默认值");
  controlRow(defaults, "默认音色",
    "新打开的配音台优先选中这个音色；参考音色仍固定 1.0x。",
    function (p) {
      const v = frame("value", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
      valueText(v, "夜航主持");
      voiceBadge(v, "系统");
      icon(v, "chevron-right", 13, V["text/tertiary"]);
      add(p, v);
    }, { captionWidth: 300 });
  hairline(defaults);
  controlRow(defaults, "默认语速",
    "0.5×–2.0×，可在配音台逐条覆盖。",
    function (p) { sliderControl(p, 132, 0.5, "1.0×"); }, { captionWidth: 260 });
}

// 会话页签是这一轮唯一新增的设置面：SpeechRail 只提供识别、合成与分人，对话与纪要
// 要靠用户在**这台 Mac 上**运行的 OpenAI 兼容服务（SESSIONS-SPEC §6.5 / §10）。
function paneSession(c) {
  const llm = settingsSection(c, "大模型（对话与纪要）");
  controlRow(llm, "服务地址",
    "兼容 OpenAI 的服务地址，本机或局域网都行；须支持 Responses API。",
    function (p) { valueText(p, "http://127.0.0.1:8000/v1", "Body"); }, { captionWidth: 300 });
  hairline(llm);
  controlRow(llm, "接口",
    "助手与纪要都走 Responses API；只提供 Chat Completions 的服务连不上。",
    function (p) {
      const v = frame("value", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
      valueText(v, "Responses");
      pill(v, "Ready", "必须");
      add(p, v);
    }, { captionWidth: 300 });
  hairline(llm);
  controlRow(llm, "模型",
    "从该服务的模型列表里选；列表为空时说明服务还没加载模型。",
    function (p) {
      const v = frame("value", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
      valueText(v, "qwen3-30b-a3b");
      icon(v, "chevron-right", 13, V["text/tertiary"]);
      add(p, v);
    }, { captionWidth: 300 });
  hairline(llm);
  controlRow(llm, "密钥",
    "只写入钥匙串：不落配置文件，不进日志，也不进导出物。",
    function (p) { valueText(p, "已存入钥匙串"); }, { captionWidth: 300 });
  hairline(llm);
  controlRow(llm, "连接",
    "点一次检查两件事：服务可达，且支持 Responses API；改完不用重启。",
    function (p) {
      const v = frame("value", { layout: "HORIZONTAL", gap: 8, align: "CENTER" });
      pill(v, "Ready", "已连接 · 12 ms");
      secondaryButton(v, "检查连接", "refresh-cw");
      add(p, v);
    }, { captionWidth: 300 });

  const sub = settingsSection(c, "实时字幕");
  controlRow(sub, "默认字号",
    "字幕带与记录库共用这一档；在浮层上也能随时改。",
    function (p) { segmented(p, ["紧凑", "标准", "大字"], 1); }, { captionWidth: 240 });
  hairline(sub);
  controlRow(sub, "字幕带位置",
    "按屏幕记忆；改乱了可以重置回「屏幕底部居中」。",
    function (p) { secondaryButton(p, "重置位置"); }, { captionWidth: 240 });
  hairline(sub);
  controlRow(sub, "分人标签",
    "只给这一段标出「说话人 A/B/C」；需要 balanced 或 quality 档位。",
    function (p) { switchControl(p, false); }, { captionWidth: 240 });

  // 人设在设置里的位置要短、要准：这里定的是「新对话开始时预填什么」，不是
  // 「随时可改的风格」。用户 2026-09-17：会话开始后不允许换人设。
  const assistant = settingsSection(c, "语音助手");
  controlRow(assistant, "默认人设",
    "只在新对话开始时预填；开始之后本轮不再变，要换就新开一轮。",
    function (p) {
      const v = frame("value", { layout: "HORIZONTAL", gap: 6, align: "CENTER" });
      valueText(v, "耐心讲解");
      icon(v, "chevron-right", 13, V["text/tertiary"]);
      add(p, v);
    }, { captionWidth: 240 });
  hairline(assistant);
  controlRow(assistant, "默认音色",
    "开始后仍然可以换，下一句生效；不影响已经说过的内容。",
    function (p) { valueText(p, "夜航主持"); }, { captionWidth: 240 });
  hairline(assistant);
  controlRow(assistant, "对讲模式",
    "一问一答（外放）它说话时闭麦；实时对讲（耳机）你可以随时插话打断它。",
    function (p) { segmented(p, ["一问一答", "实时对讲"], 0); }, { captionWidth: 240 });

  const meet = settingsSection(c, "会议");
  controlRow(meet, "会议说话人标签",
    "light 档位只保留正文，不出现说话人标签。",
    function (p) { switchControl(p, true); }, { captionWidth: 240 });
  hairline(meet);
  controlRow(meet, "纪要模型",
    "默认跟随上面的大模型；单场会议也可以用别的模型。",
    function (p) { valueText(p, "同大模型"); }, { captionWidth: 240 });
  hairline(meet);
  controlRow(meet, "保存位置",
    "会议、纪要、字幕与对话都写进本机的记录库，长期保留；导出时才生成文件。",
    function (p) { secondaryButton(p, "打开数据目录"); }, { captionWidth: 240 });

  const note = frame("note", { layout: "HORIZONTAL", padX: 4, padY: 8 });
  add(note, text("t",
    "对话与纪要都要靠一台兼容 OpenAI、支持 Responses API 的服务；" +
      "SpeechRail 只提供识别、合成与说话人标签。",
    "Caption", V["text/tertiary"], { w: 560 }));
  add(c, stretch(note));
}

function paneService(c) {
  const conn = settingsSection(c, "连接");
  controlRow(conn, "服务端口", null,
    function (p) { valueText(p, "8201", "Body / Medium"); });
  const diag = settingsSection(c, "诊断");
  controlRow(diag, "诊断报告包含运行档位与版本",
    "报告始终不含凭据、原始音频、完整转写或本地绝对路径。",
    function (p) { switchControl(p, false); });
  const about = settingsSection(c, "关于");
  controlRow(about, "产品定位", null,
    function (p) { valueText(p, "本机 Apple Silicon 语音服务控制面"); });
  hairline(about);
  controlRow(about, "最低系统", null, function (p) { valueText(p, "macOS 26.0"); });
  hairline(about);
  controlRow(about, "版本", null, function (p) { valueText(p, "0.7.3"); });
}

const SETTINGS_TABS = [
  { key: "general", title: "通用", icon: "sliders-horizontal", build: paneGeneral },
  { key: "creative", title: "创作", icon: "sparkles", build: paneCreative },
  { key: "session", title: "会话", icon: "bot", build: paneSession },
  { key: "service", title: "服务", icon: "server", build: paneService }
];

function settingsWindow(tabIndex) {
  const tab = SETTINGS_TABS[tabIndex];
  const win = frame("窗口 · 设置 · " + tab.title, {
    layout: "VERTICAL", fill: V["surface/window"], radius: 12, clip: true
  });
  // Height hugs the pane; buildMenuAndSettings levels the three panes to the
  // tallest one, so switching tabs never resizes the window in the design and the
  // live window keeps its own minimum with scrolling.
  size(win, 640, null);

  const bar = frame("titlebar", {
    layout: "HORIZONTAL", gap: 12, align: "CENTER", padX: 14, padY: 10, fill: V["surface/sidebar"]
  });
  trafficLights(bar);
  const titleBox = frame("title", { layout: "HORIZONTAL", align: "CENTER", justify: "CENTER" });
  grow(titleBox);
  add(titleBox, text("label", "设置", "Heading / Section", V["text/primary"]));
  add(bar, titleBox);
  const rightPad = frame("rightPad", { layout: "HORIZONTAL" });
  size(rightPad, 52, 12);
  add(bar, rightPad);
  add(win, stretch(bar));

  // Icon + label tabs, centred: settings has three destinations, so the picker
  // stays a picker instead of becoming a second sidebar.
  const tabs = frame("tabs", {
    layout: "HORIZONTAL", gap: 4, align: "CENTER", justify: "CENTER", padY: 7, fill: V["surface/sidebar"]
  });
  SETTINGS_TABS.forEach(function (t, i) {
    const item = frame("tab/" + t.key, {
      layout: "HORIZONTAL", gap: 6, align: "CENTER", padX: 12, padY: 5, radius: 8
    });
    if (i === tabIndex) {
      bindFill(item, V["surface/content"]);
      bindStroke(item, V["border/separator"], 1);
    }
    icon(item, t.icon, 14, i === tabIndex ? V["accent/rail"] : V["text/secondary"]);
    add(item, text("label", t.title, i === tabIndex ? "Body / Medium" : "Body", V["text/primary"]));
    add(tabs, item);
  });
  add(win, stretch(tabs));
  hairline(win);

  // The pane is a fixed-height column: when a group grows past it, the
  // self-audit flags the spill instead of the window silently clipping it.
  const content = frame("content", {
    layout: "VERTICAL", gap: 16, pad: 16, fill: V["surface/window"]
  });
  grow(content);
  stretch(content);
  tab.build(content);
  add(win, content);
  return win;
}

function buildMenuAndSettings() {
  const page = P["05 Menu & Settings"];
  const canvas = frame("Menu & Settings", {
    layout: "VERTICAL", gap: 44, pad: 64, fill: V["surface/window"]
  });
  size(canvas, 2144, null);
  add(page, canvas);
  boardHead(canvas, "菜单栏与设置",
    "两个不在主窗口里的界面。菜单栏面板承担「一句话状态 + 常用动作」（会话命令也在这里，" +
    "因为字幕带与会议的真实用法是 App 不在前台），设置只保留会影响默认行为的几项；" +
    "模型管理仍然属于控制台。", 1180);

  const menuBox = frame("menus", { layout: "HORIZONTAL", gap: 48 });
  add(canvas, stretch(menuBox));
  const labels = [
    "菜单栏面板 · 默认（空闲）",
    "菜单栏面板 · 会话进行中",
    "菜单栏面板 · 控制受限",
    "菜单栏面板 · 深色"
  ];
  const panels = [
    menuPanel("panel · 默认", {}),
    menuPanel("panel · 会话进行中", {
      sessionActive: true,
      status: "实时字幕进行中 · 08:12"
    }),
    menuPanel("panel · 控制受限", {
      restricted: true,
      // 控制受限只改状态行：副行仍然是「版本 · 端口」，应用不会为它换一句话。
      status: "服务已就绪 · 控制受限 · Quality"
    }),
    menuPanel("panel · 深色", {})
  ];
  // A menu panel is as tall as its item list. Level the three appearances to the
  // tallest so they can be compared side by side without a ragged bottom edge.
  const panelH = Math.max.apply(null, panels.map(function (p) { return p.height; }));
  panels.forEach(function (p) { size(p, 288, panelH); });
  panels.forEach(function (p, i) {
    const col = frame("column/" + i, { layout: "VERTICAL", gap: 8 });
    add(col, text("caption", labels[i], "Callout", V["text/secondary"]));
    add(col, p);
    add(menuBox, col);
  });
  darkReference(panels[3]);

  const stripBox = frame("menuBarRow", { layout: "VERTICAL", gap: 20 });
  add(canvas, stretch(stripBox));
  add(stripBox, text("title", "菜单栏状态项", "Heading / Section", V["text/primary"]));
  [
    ["常态 · 服务就绪且空闲", { label: false, busy: false }, "只有图标：菜单栏属于系统，不属于产品。"],
    ["展开态 · 操作进行中", { label: true, busy: true }, "悬停或操作进行中才出现文字与琥珀色状态点。"],
    ["会话进行中 · 字幕带在屏上", { label: true, busy: true, tone: "status/attention" },
      "有会话占用麦克风时，菜单栏显示会话名与状态点：这是除侧边栏之外唯一常驻的所有权提示。"]
  ].forEach(function (def) {
    const col = frame("state", { layout: "VERTICAL", gap: 8 });
    add(col, text("caption", def[0], "Callout", V["text/secondary"]));
    menuBarStrip(col, def[1]);
    add(col, text("note", def[2], "Caption", V["text/tertiary"], { w: 900 }));
    add(stripBox, stretch(col));
  });

  // Four 640-wide windows in one row need 2680px and the canvas content box is
  // 2016: the last one would hang off the right edge of its own board. Two rows
  // of two keep every window inside, and side-by-side comparison is still what
  // the pairing buys (通用/创作 above, 会话/服务 below).
  const settingsRows = [
    frame("settingsRow/1", { layout: "HORIZONTAL", gap: 40 }),
    frame("settingsRow/2", { layout: "HORIZONTAL", gap: 40 })
  ];
  settingsRows.forEach(function (row) { add(canvas, stretch(row)); });
  const windows = SETTINGS_TABS.map(function (t, i) {
    const col = frame("column/" + t.key, { layout: "VERTICAL", gap: 8 });
    add(col, text("caption", "设置 · " + t.title, "Callout", V["text/secondary"]));
    const win = settingsWindow(i);
    add(col, win);
    add(settingsRows[i < 2 ? 0 : 1], col);
    return win;
  });
  const winH = Math.max.apply(null, windows.map(function (w) { return w.height; }));
  windows.forEach(function (w) { size(w, 640, winH); });
  return canvas;
}

// --- 06 Archive ---------------------------------------------------------------

function literalFill(node, hex) {
  rawFill(node, hex);
  return node;
}

function literalStroke(node, hex, weight) {
  node.strokes = [{ type: "SOLID", color: hexToRgb(hex) }];
  node.strokeWeight = weight == null ? 1 : weight;
  node.strokeAlign = "INSIDE";
  return node;
}

function literalRect(parent, name, w, h, hex, radius) {
  const r = figma.createRectangle();
  r.name = name;
  size(r, w, h);
  rawFill(r, hex);
  if (radius != null) r.cornerRadius = radius;
  return add(parent, r);
}

// A few lines of retired values, printed as text: the archive page has to stay
// readable after those tokens are deleted from the codebase.
function archiveList(parent, lines) {
  const box = frame("list", { layout: "VERTICAL", gap: 6 });
  lines.forEach(function (line) {
    add(box, text("line", line, "Callout", V["text/secondary"], { w: 660 }));
  });
  return add(parent, stretch(box));
}

function buildArchive() {
  const page = P["06 Archive"];
  const canvas = frame("Archive", { layout: "VERTICAL", gap: 36, pad: 64, fill: V["surface/window"] });
  size(canvas, 1680, null);
  add(page, canvas);
  boardHead(canvas, "归档 · 迁移前的机架视觉",
    "旧视觉作为历史对照保留在这里：它解释了这次为什么要收手，而不是留成一套可选主题。" +
    "色值取自 docs/developers/macos-app-design-system.md §3.1 记录的旧 token，" +
    "本页是按这些数值重建的示意，不是原稿截图。", 1180);

  const cols = frame("columns", { layout: "HORIZONTAL", gap: 40 });
  add(canvas, stretch(cols));

  // 迁移前
  const before = frame("before", {
    layout: "VERTICAL", gap: 16, pad: 20, radius: 12,
    fill: V["surface/field"]
  });
  size(before, 720, 452);
  add(cols, before);
  add(before, text("title", "迁移前 · 机加工机架", "Heading / Section", V["text/primary"]));
  add(before, text("lead",
    "自绘三层机架面板 + 冶金隐喻：切削边、沉降声学槽、滚花胶囊。",
    "Callout", V["text/secondary"], { w: 660 }));

  const deck = frame("deck", { layout: "VERTICAL", gap: 12, pad: 16, radius: 12 });
  size(deck, 680, 196);
  literalFill(deck, "#151719");
  add(before, deck);
  literalRect(deck, "machinedBevel", 648, 1, "#2E3338");
  add(deck, text("label", "Chassis.enclosure #151719", "Caption", V["text/tertiary"]));
  const well = frame("recessedWell", { layout: "VERTICAL", gap: 8, pad: 12, radius: 10 });
  size(well, 648, 84);
  literalFill(well, "#101214");
  literalStroke(well, "#33373B", 1);
  add(deck, well);
  add(well, text("label", "recessedWell · grooveStroke #33373B", "Caption", V["text/tertiary"]));
  const knurl = frame("knurledCapsule", {
    layout: "HORIZONTAL", gap: 2, align: "CENTER", justify: "CENTER", padX: 10, padY: 6, radius: 999
  });
  size(knurl, 240, 28);
  literalFill(knurl, "#1F2327");
  for (let i = 0; i < 22; i++) literalRect(knurl, "knurl", 2, 12, "#3A3F45", 1);
  add(well, knurl);
  archiveList(before, [
    "Chassis.enclosure / deck / recessedWell：三层自绘容器，每层都有自己的圆角与阴影。",
    "speechRailConsoleChassis() / speechRailRecessedSlot() / speechRailKnurledCapsule()。",
    "Dark 模式额外叠加 0.5px specularEdge 高光切线与 ambientShadow 微距阴影。"
  ]);

  // 迁移后
  const after = frame("after", {
    layout: "VERTICAL", gap: 16, pad: 20, radius: 12,
    fill: V["surface/content"]
  });
  size(after, 720, 452);
  add(cols, after);
  add(after, text("title", "迁移后 · macOS 26 原生", "Heading / Section", V["text/primary"]));
  add(after, text("lead",
    "同样的信息层级，改用系统材质 + 一个强调色：深度由层级承担，不由阴影层数承担。",
    "Callout", V["text/secondary"], { w: 660 }));

  const newDeck = frame("deck", {
    layout: "VERTICAL", gap: 12, pad: 16, radius: 12,
    fill: V["surface/panel"]
  });
  size(newDeck, 680, 196);
  add(after, newDeck);
  add(newDeck, text("label", "surface/panel · 无描边，靠填充分层", "Caption", V["text/tertiary"]));
  const grouped = frame("groupedCard", {
    layout: "VERTICAL", gap: 6, pad: 12, radius: 10,
    fill: V["surface/content"]
  });
  size(grouped, 648, 84);
  add(newDeck, grouped);
  add(grouped, text("label", "分组卡片 · surface/content", "Callout", V["text/secondary"]));
  add(grouped, text("note", "深度来自层级与 1px 分隔，不再来自自绘高光和微距阴影。",
    "Caption", V["text/tertiary"], { w: 620 }));
  const newControls = frame("controls", { layout: "HORIZONTAL", gap: 10, align: "CENTER" });
  secondaryButton(newControls, "音色", "audio-lines");
  segmented(newControls, ["0.8", "1.0", "1.2"], 1);
  primaryButton(newControls, "生成语音", "play", 132);
  add(newDeck, newControls);
  archiveList(after, [
    "机架基座 → 系统窗口材质 surface/window；机架面板 → surface/panel。",
    "沉降槽 → 分组卡片（surface/content + 1px border/separator）。",
    "切削边与微距阴影 → 系统窗口阴影；自绘效果全部删除。"
  ]);

  const tails = frame("contrast", { layout: "HORIZONTAL", gap: 40 });
  add(canvas, stretch(tails));
  [["保留的 DNA", [
    "钢轨道床冷青 #2A4E57 与钢轨反光 #4FA4BA：唯一的强调色。",
    "声音语义琥珀 #F59E0B 只出现在音色与播放相关的位置。",
    "磷光绿 #10B981 只用于就绪状态，不做装饰。",
    "等宽数字与稳定的信息密度：控制台先读得懂，再谈好看。"
  ]], ["移除的部分", [
    "#007AFF 系统蓝高亮：选中与焦点交还系统强调色。",
    "0.5px specularEdge 自绘高光与 ambientShadow 微距阴影。",
    "滚花、切削、冶炼等机架隐喻与手挑圆角数值。",
    "同屏三层以上嵌套容器，每层都带边框和阴影。"
  ]]].forEach(function (def) {
    const card = frame("list · " + def[0], {
      layout: "VERTICAL", gap: 8, pad: 18, radius: 12,
      fill: V["surface/content"]
    });
    size(card, 720, null);
    add(card, text("title", def[0], "Heading / Section", V["text/primary"]));
    archiveList(card, def[1]);
    add(tails, card);
  });
  return canvas;
}

// --- Prototype wiring ---------------------------------------------------------
//
// A kit is only a design until it can be clicked. What the plugin API allows is
// narrower than the Prototype panel: a connection can only be written when the
// target is a top-level frame on the same page. The eight screens are exactly
// that, so sidebar rows move between the screens of the same appearance and the
// status row opens 服务状态. The flow nodes point at another page and the
// settings panes sit inside this board, so both stay manual.
function wireClick(node, target, from) {
  try {
    node.reactions = [{
      trigger: { type: "ON_CLICK" },
      actions: [{
        type: "NODE",
        destinationId: target.id,
        navigation: "NAVIGATE",
        transition: { type: "SMART_ANIMATE", easing: { type: "EASE_OUT" }, duration: 0.3 },
        preserveScrollPosition: false
      }]
    }];
    return true;
  } catch (e) {
    const why = e && e.message ? String(e.message) : String(e);
    WIRE_ERRORS.push((from || "?") + " · " + node.name + " → " + target.name + ": " +
      why.replace(/^Reaction at index 0 was invalid \(/, "").slice(0, 90));
    return false;
  }
}

function appearanceOf(frame) {
  return / · Dark$/.test(frame.name) ? "dark" : "light";
}

// What a frame is called without its appearance suffix and its screen prefix —
// the key both the target map and the per-board lookup work on.
function bareNameOf(frame) {
  return frame.name.replace(/^▸ /, "").replace(/ · Dark$/, "");
}

// 侧边栏连线：13 个路由 × 两种外观。目标是「每条路由的默认落点」，同一个路由有多个
// 状态画板时只连 default（primary）那一块——连线要的是一个确定的目的地。
// 插件只能写「同页 + 顶层 frame」的连线，所以 13 块屏幕排在同一个真实页上。
function wirePrototype(screens, overview) {
  const targets = {};
  screens.forEach(function (f) {
    const appearance = appearanceOf(f);
    const base = bareNameOf(f);
    if (CLOSURE_SCOPE) {
      // 闭环稿的落点按 anchor 登记：一块画板一个语义位置，连线的两端因此都能被读出来。
      // 会话键只登记三块主画板——侧边栏那一行需要一个确定的目的地，不是一组。
      CLOSURE_BOARDS.forEach(function (b) {
        if (b.title !== base) return;
        targets[appearance + ":" + b.anchor] = f;
        if (b.primary === true && b.session) targets[appearance + ":" + b.session] = f;
      });
      CLOSURE_BANDS.forEach(function (b) {
        if (b.title === base) targets[appearance + ":" + b.anchor] = f;
      });
      return;
    }
    SCREEN_DEFS.forEach(function (d) {
      if (d[1] === base) targets[appearance + ":" + d[0]] = f;
    });
    SESSION_BOARDS.forEach(function (b) {
      if (b.primary === true && b.title === base) targets[appearance + ":" + b.key] = f;
    });
  });

  const total = { wired: 0, attempts: 0 };
  function attempt(node, target, from) {
    if (!node || !target || target === node) return;
    // A frame cannot carry a NAVIGATE reaction to itself, and Figma rejects the
    // write as "Reaction at index 0 was invalid". The row for the page you are
    // already on is exactly that case: its target is the frame it sits in. So the
    // guard has to walk up the tree — comparing the row to the frame never
    // matched, and 34 of 512 links were rejected for it (实测 2026-09-17).
    for (let up = node.parent; up; up = up.parent) if (up === target) return;
    total.attempts++;
    if (wireClick(node, target, from)) total.wired++;
  }

  screens.forEach(function (win) {
    const appearance = appearanceOf(win);
    ROUTES.forEach(function (r) {
      // The row for the page you are already on is the selected row, not a
      // link: pointing a frame at itself is rejected and means nothing.
      attempt(findByName(win, "nav/" + r.key), targets[appearance + ":" + r.key], win.name);
    });
    attempt(findByName(win, "sidebarStatus"), targets[appearance + ":overview"], win.name);
    // 会话行指向「当前会话所在页」；这块画板不是会话页时指向实时字幕页（空闲时的落点）。
    const own = (CLOSURE_SCOPE ? CLOSURE_BOARDS : SESSION_BOARDS).find(function (b) {
      return b.title === bareNameOf(win);
    });
    // 全量稿用 route key，闭环稿用会话键：两边各自的表里那一栏是权威，不要互相猜
    // （全量稿的会议空态是 route key "meeting"、会话键 "idle"，取错就少一条连线）。
    const ownKey = own ? (CLOSURE_SCOPE ? own.session : own.key) : null;
    attempt(findByName(win, "sidebarSession"),
      targets[appearance + ":" + (ownKey || "captions")], win.name);
    // 占用守卫的主按钮：结束会议并切换到语音助手。
    attempt(findByName(win, "guardPrimary"), targets[appearance + ":assistant"], win.name);
    if (!CLOSURE_SCOPE) return;
    // 闭环稿自己的连线：每块画板上「哪个控件通向哪一块画板」，逐条写在 CLOSURE_BOARDS
    // 里，不藏在画板内部——路径是这一稿的一等对象。
    const def = CLOSURE_BOARDS.find(function (b) { return b.title === bareNameOf(win); });
    ((def && def.links) || []).forEach(function (l) {
      attempt(closureLinkSource(win, l[0]), targets[appearance + ":" + l[1]], win.name);
    });
    CLOSURE_BAND_LINKS.forEach(function (l) {
      if (bareNameOf(win) !== l[0]) return;
      attempt(findIconButton(win, l[1]), targets[appearance + ":" + l[2]], win.name);
    });
  });

  // 总览上的每一格都指向承载它的那块画板。总览只有浅色一份（它是图，不是界面的第二种
  // 外观），所以它只连浅色落点。
  if (overview) {
    CLOSURE_LANES.forEach(function (lane) {
      lane.stages.forEach(function (s, i) {
        attempt(findByName(overview, "lane/" + lane.key + "/" + i), targets["light:" + s[3]], "闭环总览");
      });
    });
    CLOSURE_SPINE.forEach(function (s, i) {
      attempt(findByName(overview, "spine/" + i), targets["light:" + s[3]], "闭环总览");
    });
    // 状态格与泳道格一样是可点的：点「状态③ · 刚结束」就跳到画着那一态的画板。
    CLOSURE_STATES.forEach(function (lane) {
      lane.states.forEach(function (s, i) {
        attempt(findByName(overview, "state/" + lane.key + "/" + i),
          targets["light:" + s[3]], "闭环总览");
      });
    });
    // 旅程那一节：有落点的三行做成可点，第四行（出板在实现阶段）本来就没有目的地。
    CLOSURE_JOURNEY.forEach(function (j, i) {
      if (!j[3]) return;
      attempt(findByName(overview, "journey/" + i), targets["light:" + j[3]], "闭环总览");
    });
  }
  return total;
}

// =============================================================================
// Entry point
// =============================================================================

// --- Self-audit --------------------------------------------------------------
// Runs on the built document so the run report can distinguish "generated" from
// "generated and actually looks right".

// 逐帧审计的合计值：报告里的 key=value 行由它产出，离线冒烟门禁（smoke.js）读的也是
// 这几行——它不依赖替身算不出来的几何结论。
const AUDIT_TOTALS = { frames: 0, gray: 0, root: 0, inner: 0 };

function auditUnboundGray(root) {
  let n = 0;
  function walk(node) {
    ["fills", "strokes"].forEach(function (field) {
      const paints = node[field];
      if (!paints || paints.length !== 1) return;
      const paint = paints[0];
      if (paint.type !== "SOLID" || !paint.color) return;
      const c = paint.color;
      const gray = Math.abs(c.r - 0.502) < 0.02 && Math.abs(c.g - 0.502) < 0.02 &&
        Math.abs(c.b - 0.502) < 0.02;
      const bound = paint.boundVariables && paint.boundVariables.color;
      if (gray && !bound) n++;
    });
    if ("children" in node) node.children.forEach(walk);
  }
  walk(root);
  return n;
}

function auditOverflow(root) {
  const box = root.absoluteBoundingBox;
  const out = [];
  if (!box) return out;
  // `clipped` only reflects ancestors: a container's own clipsContent must not
  // suppress the check of its children, or every clipping screen frame reports
  // "no overflow" by construction.
  function walk(node, clipped) {
    if (node.visible === false) return;
    const b = node.absoluteBoundingBox;
    if (b && !clipped) {
      const worst = Math.max(
        b.x + b.width - (box.x + box.width),
        b.y + b.height - (box.y + box.height),
        box.x - b.x,
        box.y - b.y
      );
      if (worst > 1) out.push(node.name + "+" + Math.round(worst));
    }
    const clip = clipped || ("clipsContent" in node && node.clipsContent === true);
    if ("children" in node) node.children.forEach(function (c) { walk(c, clip); });
  }
  root.children.forEach(function (c) { walk(c, false); });
  return out;
}

function samplePaint(root) {
  let found = null;
  function walk(node) {
    if (found) return;
    const varId = paintVarId(node, "fills");
    if (varId) {
      const v = figma.variables.getVariableById(varId);
      if (v) {
        const modes = Object.keys(v.valuesByMode);
        const value = v.valuesByMode[modes[0]];
        if (value && value.r != null) {
          found = rgbToHex(value) + " " + v.name;
          return;
        }
      }
    }
    if ("children" in node) node.children.forEach(walk);
  }
  walk(root);
  return found || "unbound";
}

// Counts which collection each bound paint points at, so a frame that claims to
// be "Dark" can be checked instead of trusted.
function auditBindings(root) {
  let dark = 0;
  let light = 0;
  const samples = [];
  function walk(node) {
    const varId = paintVarId(node, "fills");
    if (varId) {
      const v = figma.variables.getVariableById(varId);
      if (v) {
        const isDark = DARK_COLLECTION_ID != null && v.variableCollectionId === DARK_COLLECTION_ID;
        if (isDark) dark++; else light++;
        if (samples.length < 3) {
          const modes = Object.keys(v.valuesByMode);
          const value = v.valuesByMode[modes[0]];
          const paints = node.fills;
          const literal = paints && paints[0] && paints[0].color
            ? rgbToHex(paints[0].color)
            : "?";
          samples.push(node.name + " lit:" + literal + " var:" +
            (value && value.r != null ? rgbToHex(value) : "?") + (isDark ? "/dark" : "/light"));
        }
      }
    }
    if ("children" in node) node.children.forEach(walk);
  }
  walk(root);
  return { dark: dark, light: light, samples: samples };
}

// A child that spills out of its own auto-layout parent is the signature of a
// collapsed container: the frame kept AUTO (hug) sizing, so an explicit size was
// ignored and the row/column got squeezed to something smaller than its content.
// Screen-level bounds do not catch this, because the spill stays inside the
// screen. This walks every parent/child pair instead.
//
// 「溢出多少」不足以定位：hug 的容器会跟着内容长，所以溢出的根因永远是**某一层被写死**
// （FIXED）或者被 STRETCH 到父级的交叉轴。结论里因此直接带上两层的大小定位模式与
// 发生溢出的那个轴的尺寸——2026-09-18 实跑时靠猜是哪一层花了两轮，加上这一段之后
// 一轮就能读出根因。路径是「从被审画板往下到溢出节点」的完整路径。
function sizingTag(n) {
  if (n.type === "TEXT") {
    return "T:" + (n.textAutoResize === "HEIGHT" ? "H" : n.textAutoResize === "WIDTH_AND_HEIGHT" ? "WH" : "N");
  }
  if (n.layoutMode && n.layoutMode !== "NONE") {
    return n.layoutMode.slice(0, 1) + ":" +
      (n.primaryAxisSizingMode === "FIXED" ? "F" : "A") +
      (n.counterAxisSizingMode === "FIXED" ? "F" : "A") +
      (n.layoutGrow ? "|G" : "") +
      (n.layoutAlign === "STRETCH" ? "|S" : "");
  }
  return n.type.slice(0, 3).toLowerCase();
}

function auditInnerOverflow(root) {
  const out = [];
  // `path` is the full path from the audited frame down to `node`. A board holds
  // several windows, and "content ▸ group +8B" does not say which.
  function walk(node, path) {
    const auto = node.layoutMode && node.layoutMode !== "NONE";
    const pb = node.absoluteBoundingBox;
    if (auto && pb && "children" in node) {
      node.children.forEach(function (child) {
        if (child.visible === false) return;
        const cb = child.absoluteBoundingBox;
        if (!cb) return;
        const worst = Math.max(
          cb.x + cb.width - (pb.x + pb.width),
          cb.y + cb.height - (pb.y + pb.height),
          pb.x - cb.x,
          pb.y - cb.y
        );
        if (worst > 1) {
          const sides = {
            R: cb.x + cb.width - (pb.x + pb.width),
            B: cb.y + cb.height - (pb.y + pb.height),
            L: pb.x - cb.x,
            T: pb.y - cb.y
          };
          const dir = Object.keys(sides).sort(function (a, b) { return sides[b] - sides[a]; })[0];
          // 溢出轴上「子多少 / 父多少」才是要修的那一对数字：横向溢出看宽，纵向溢出的
          // 版面里看高。原来固定打宽度，纵向溢出时给的是两个用不上的数。
          const horiz = dir === "R" || dir === "L";
          // 路径里的每一段都带自己的大小定位模式：**只有 FIXED 的那一层才会溢出**，
          // 而「谁把它设成 FIXED」看不出来的话就得再跑一轮（2026-09-18 实测代价）。
          const seg = child.name + "{" + sizingTag(child) + "}";
          out.push((path ? path + "/" : "") + seg +
            " +" + Math.round(worst) + dir +
            " " + (horiz ? "w" : "h") +
            Math.round(horiz ? child.width : child.height) + "/" +
            Math.round(horiz ? node.width : node.height));
        }
      });
    }
    if ("children" in node) {
      node.children.forEach(function (c) {
        const seg = c.name + "{" + sizingTag(c) + "}";
        walk(c, path ? path + "/" + seg : seg);
      });
    }
  }
  walk(root, null);
  return out;
}

// Width chain for the containers that keep collapsing, so a 2px drift can be
// traced to the level that actually lost it.
function probeChain(root) {
  const wanted = ["body", "sidebar", "detail", "workers", "artifacts", "header", "row", "cap", "info", "name"];
  const found = {};
  (function walk(n) {
    if (wanted.indexOf(n.name) >= 0 && found[n.name] == null) {
      found[n.name] = Math.round(n.width * 10) / 10 +
        (n.layoutMode && n.layoutMode !== "NONE"
          ? "(pad" + n.paddingLeft + "/" + n.paddingRight +
            " mode " + n.primaryAxisSizingMode.charAt(0) + n.counterAxisSizingMode.charAt(0) +
            (n.layoutAlign === "STRETCH" ? " STRETCH" : "") +
            (n.layoutGrow ? " grow" : "") + ")"
          : "");
    }
    if ("children" in n) n.children.forEach(walk);
  })(root);
  return "chain " + wanted
    .filter(function (k) { return found[k] != null; })
    .map(function (k) { return k + "=" + found[k]; })
    .join(" ");
}

// Audits every page that renders product UI, not only the screens: the flows,
// menu and archive frames have to hold the same bar or "all clean" stops meaning
// anything.
function auditFrames(pageNames) {
  const lines = [];
  let samplesShown = false;
  const seen = [];
  pageNames.forEach(function (pageName) {
    const page = P[pageName];
    if (!page || seen.indexOf(page) >= 0) return;
    seen.push(page);
    page.children.forEach(function (frameNode) {
      if (frameNode.type !== "FRAME") return;
      const unbound = auditUnboundGray(frameNode);
      const overflow = auditOverflow(frameNode);
      const bindings = auditBindings(frameNode);
      const inner = auditInnerOverflow(frameNode);
      const chain = probeChain(frameNode);
      // 计数按帧累加，报告里以 key=value 行输出：冒烟门禁（smoke.js）与交接包读的是
      // 这几行，人读的是下面逐帧的那一段。
      AUDIT_TOTALS.frames++;
      AUDIT_TOTALS.gray += unbound;
      AUDIT_TOTALS.root += overflow.length;
      AUDIT_TOTALS.inner += inner.length;
      const showSamples = !samplesShown && frameNode.name.indexOf("· Dark") >= 0;
      if (showSamples) samplesShown = true;
      lines.push(
        frameNode.name + " · " + Math.round(frameNode.width) + "×" + Math.round(frameNode.height) +
        " " + samplePaint(frameNode) + " · " + bindings.dark + "/" + bindings.light + "bound · gray " + unbound +
        // 不截断到 2 处：截断只在读数前就丢证据，实跑一次很贵，一次读全。
        " · overflow " + (overflow.length ? overflow.length + ": " + overflow.join(", ") : "ok") +
        " · inner " + (inner.length ? inner.length + ": " + inner.join(", ") : "ok") +
        (inner.length ? "\n      " + chain : "") +
        (showSamples ? "\n      samples " + bindings.samples.slice(0, 5).join("  ") : "")
      );
    });
  });
  return lines;
}

async function gotoPage(page) {
  if (figma.setCurrentPageAsync) await figma.setCurrentPageAsync(page);
  else figma.currentPage = page;
}

async function main() {
  const t0 = Date.now();
  const report = [];
  const errors = [];
  let info = { modes: ["?"], darkModeId: null };
  let windows = [];
  let darkWindows = [];
  let sessionWindows = [];
  let sessionDarkWindows = [];
  let floatWindows = [];
  let floatDarkWindows = [];
  let closureWindows = [];
  let closureDarkWindows = [];
  let overviewBoards = [];
  let wiring = { wired: 0, attempts: 0 };

  async function step(name, fn) {
    try {
      await fn();
      report.push("ok    " + name);
    } catch (e) {
      const stack = e && e.stack ? "\n    " + String(e.stack).split("\n").slice(0, 2).join("\n    ") : "";
      errors.push(name + "  ->  " + (e && e.message ? e.message : String(e)) + stack);
    }
  }

  await figma.loadAllPagesAsync();
  await loadFonts();
  await loadCjkFont();
  await step("pages", function () { return buildPages(); });
  // Every builder writes its frames onto a shared real page, so each step's
  // output is picked up by diffing the page before and after it runs.
  const groupNodes = {};
  const pageSnapshots = {};
  REAL_PAGES.forEach(function (name) {
    const page = figma.root.children.find(function (p) { return p.name === name; });
    pageSnapshots[name] = {
      page: page,
      ids: page ? page.children.map(function (c) { return c.id; }) : []
    };
  });
  function takeGroup(logical) {
    const page = P[logical];
    if (!page) return;
    const snapshot = pageSnapshots[page.name];
    if (!snapshot) return;
    // Accumulate: one logical group can be built in more than one step (the
    // dark screen variants land after the light ones), and replacing the list
    // would tile only the later batch — straight on top of the earlier one.
    groupNodes[logical] = (groupNodes[logical] || []).concat(page.children.filter(function (c) {
      return snapshot.ids.indexOf(c.id) === -1;
    }));
    snapshot.ids = page.children.map(function (c) { return c.id; });
  }
  await step("variables", function () { info = buildVariables(); });
  await step("text styles", function () { buildTextStyles(); });
  // 范围开关只决定走哪一支，两支各自的行为都不受影响：闭环稿不是全量稿的裁剪，
  // 全量稿也不会因为闭环稿存在而多画或少画一块画板。
  if (CLOSURE_SCOPE) {
    await step("closure overview", async function () {
      await gotoPage(P[CLOSURE_GROUPS[0]]);
      overviewBoards = [buildClosureOverview()];
      takeGroup(CLOSURE_GROUPS[0]);
    });
    await step("closure screens", async function () {
      await gotoPage(P[CLOSURE_GROUPS[1]]);
      closureWindows = buildClosureScreens();
      takeGroup(CLOSURE_GROUPS[1]);
    });
    await step("closure dark", function () {
      closureDarkWindows = closureDarkVariants(closureWindows, info.collection.id, info.darkModeId);
      takeGroup(CLOSURE_GROUPS[1]);
    });
    await step("closure overlays", async function () {
      await gotoPage(P[CLOSURE_GROUPS[2]]);
      floatWindows = buildFloatBoards(CLOSURE_GROUPS[2]);
      takeGroup(CLOSURE_GROUPS[2]);
    });
    await step("overlay dark", function () {
      floatDarkWindows = buildFloatDarkVariants(
        floatWindows, info.collection.id, info.darkModeId, CLOSURE_GROUPS[2]
      );
      takeGroup(CLOSURE_GROUPS[2]);
    });
  } else {
    await step("foundations", async function () {
      await gotoPage(P["01 Foundations"]); buildFoundations(); takeGroup("01 Foundations");
    });
    await step("components", async function () {
      await gotoPage(P["02 Components"]); buildComponents(); takeGroup("02 Components");
    });
    await step("screens", async function () {
      await gotoPage(P["04 Screens"]); windows = buildScreens(); takeGroup("04 Screens");
    });
    await step("dark variants", function () {
      darkWindows = info.darkModeId
        ? buildDarkVariants(windows, info.collection.id, info.darkModeId)
        : buildDarkReferenceVariants(windows);
      takeGroup("04 Screens");
    });
    await step("session screens", async function () {
      await gotoPage(P["07 会话"]); sessionWindows = buildSessionScreens(); takeGroup("07 会话");
    });
    await step("session dark", function () {
      sessionDarkWindows = buildSessionDarkVariants(sessionWindows, info.collection.id, info.darkModeId);
      takeGroup("07 会话");
    });
    await step("session overlays", async function () {
      await gotoPage(P["08 会话浮层"]); floatWindows = buildFloatBoards(); takeGroup("08 会话浮层");
    });
    await step("overlay dark", function () {
      floatDarkWindows = buildFloatDarkVariants(floatWindows, info.collection.id, info.darkModeId);
      takeGroup("08 会话浮层");
    });
    await step("flows", async function () {
      await gotoPage(P["03 Flows"]); buildFlows(); takeGroup("03 Flows");
    });
    await step("menu & settings", async function () {
      await gotoPage(P["05 Menu & Settings"]); buildMenuAndSettings(); takeGroup("05 Menu & Settings");
    });
    await step("archive", async function () {
      await gotoPage(P["06 Archive"]); buildArchive(); takeGroup("06 Archive");
    });
  }
  const screensForWiring = CLOSURE_SCOPE
    ? closureWindows.concat(closureDarkWindows, floatWindows, floatDarkWindows)
    : windows.concat(darkWindows, sessionWindows, sessionDarkWindows);
  await step("prototype wiring", function () {
    wiring = wirePrototype(screensForWiring, overviewBoards[0] || null);
  });
  if (!CLOSURE_SCOPE) {
    await step("cover", async function () {
      await gotoPage(P["00 Cover"]); buildCover(); takeGroup("00 Cover");
    });
  }
  await step("layout", function () {
    tileGroups(groupNodes);
  });
  let audit = [];
  let counts = [];
  let stray = [];
  await step("audit", async function () {
    // Real pages, not logical ones: several logical groups share a page now, and
    // auditing per logical name would report the same page three times.
    REAL_PAGES.forEach(function (name) {
      const page = figma.root.children.find(function (p) { return p.name === name; });
      if (!page) return;
      const frames = page.children.filter(function (c) { return c.type === "FRAME"; });
      if (frames.length) counts.push(name.replace(/^[0-9]+ /, "") + " " + frames.length);
      // A builder that forgets to append a node leaves it on the page instead of
      // inside the frame: it renders as a float in the corner and no other check
      // notices it.
      const expected = allowedFrameName(name);
      frames.forEach(function (f) {
        if (!expected(f.name)) stray.push(name + " → " + f.name);
      });
    });
    audit = auditFrames(PAGE_NAMES);
  });

  try {
    // 落点：闭环稿停在总览（它是这套稿的入口），全量稿停在 04 Screens。
    const home = CLOSURE_SCOPE ? P[CLOSURE_GROUPS[0]] : P["04 Screens"];
    await gotoPage(home);
    const focus = CLOSURE_SCOPE ? overviewBoards : windows;
    if (focus.length) figma.viewport.scrollAndZoomIntoView(focus.slice(0, 1));
  } catch (e) {}

  const seconds = ((Date.now() - t0) / 1000).toFixed(1);
  const bindErrors = BIND_ERRORS.slice(0, 4);
  // The report panel clips its tail, so the verdict goes first and the per-frame
  // detail follows only for the frames that actually failed a check.
  // 结论区：**一处一行**。面板里的文本在无障碍层是按行截断的（实测约 85–90 字符），
  // 一行里塞两处问题就会丢掉后面那一处——2026-09-17 修稿时正是因此只看到 8 处里的前两处。
  // 每行 ≤ 名字 + 55 字符的结论；面板裁尾，所以结论仍然排在最前面。
  const problemFrames = [];
  const problems = [];
  audit.forEach(function (line) {
    const broken = line.indexOf("overflow ok") < 0 || line.indexOf("inner ok") < 0 ||
      line.indexOf("gray 0") < 0 || line.indexOf(" 0bound") >= 0;
    if (!broken) return;
    // 板名里本来就有「 · 」（`▸ 会议助手 · 会议页 · 空态`），所以不能按第一个「 · 」截；
    // 按「尺寸」那一段回退，才是完整的板名。
    const nameMatch = line.match(/^(.*) · \d+×\d+ /);
    const name = nameMatch ? nameMatch[1] : line.slice(0, 24);
    problemFrames.push(name);
    const found = [];
    // 结论行本身是「N: 甲, 乙」——**一处一行**地摊开。挤在一行里的代价是实测过的：
    // 2026-09-18 那一次，6 块板各有 2 处溢出，面板只给出一处 + 下一处的开头 11 个字符，
    // 于是「还有一处是什么」只能靠再跑一轮。摊开之后一处也不会丢。
    const spread = function (re, prefix) {
      const m = line.match(re);
      if (!m) return;
      m[1].split(", ").forEach(function (one) { found.push(prefix + one.trim()); });
    };
    spread(/overflow \d+: ([^\n]+)/, "overflow → ");
    spread(/inner \d+: ([^\n]+)/, "inner → ");
    const gray = line.match(/gray (\d+)/);
    if (gray && gray[1] !== "0") found.push("unbound-gray " + gray[1]);
    if (line.indexOf(" 0bound") >= 0) found.push("no dark binding");
    // 板名一行、每处结论一行：一行一处。上限 150——面板 820px、10px 等宽，一行约 130 字符，
    // 实测 div 的文本在无障碍层不会被截断（被截断的是那个装计数行的 <pre>，约 250 字符），
    // 所以带完整「路径 + 每层定位模式」的结论也读得全。
    if (found.length) problems.push(name);
    found.forEach(function (finding) { problems.push("    " + finding.slice(0, 150)); });
  });
  // Optional review PNGs, exported through the plugin UI so the frames reach the
  // download folder without a per-file trip through the Export dialog.
  let exported = [];
  if (EXPORT_PNGS) {
    await step("export png", async function () {
      for (const pageName of EXPORT_PAGES) {
        const page = P[pageName];
        if (!page) continue;
        for (const node of page.children) {
          if (node.type !== "FRAME") continue;
          const bytes = await node.exportAsync({
            format: "PNG",
            constraint: { type: "SCALE", value: 0.5 }
          });
          exported.push({ name: node.name + ".png", bytes: bytes });
        }
      }
    });
  }

  const boards = REAL_PAGES.reduce(function (n, name) {
    const page = figma.root.children.find(function (p) { return p.name === name; });
    if (!page) return n;
    return n + page.children.filter(function (c) { return c.type === "FRAME"; }).length;
  }, 0);
  const darkBoards = REAL_PAGES.reduce(function (n, name) {
    const page = figma.root.children.find(function (p) { return p.name === name; });
    if (!page) return n;
    return n + page.children.filter(function (c) {
      return c.type === "FRAME" && / · Dark$/.test(c.name);
    }).length;
  }, 0);
  // 可机读的计数行：冒烟门禁按 key=value 读它们，交接包登记它们，人先看结论行。
  const counters = [
    "boards=" + boards,
    "dark boards=" + darkBoards,
    "frames audited=" + AUDIT_TOTALS.frames,
    "bind errors=" + BIND_ERRORS.length,
    "export errors=" + EXPORT_ERRORS.length,
    "stray top-level=" + stray.length,
    "root overflow=" + AUDIT_TOTALS.root,
    "inner overflow=" + AUDIT_TOTALS.inner,
    "placeholder fill=" + AUDIT_TOTALS.gray,
    "prototype links=" + wiring.wired + "/" + wiring.attempts,
    "cjk runs=" + (CJK_FONT ? CJK_FONT.family : "none")
  ].join("\n");

  const verdict = "AUDIT VERDICT · " + audit.length + " frames · " +
    (problems.length || stray.length
      ? problemFrames.length + " frames need attention (" +
        (problems.length + stray.length) + " findings):\n" +
        problems.concat(stray.map(function (s) { return "stray top-level node: " + s; })).join("\n")
      : "all clean (overflow / inner / unbound-gray / dark-binding / stray)");
  const screenCount = CLOSURE_SCOPE
    ? closureWindows.length
    : windows.length + sessionWindows.length;
  const summary =
    "SpeechRail design kit " + (CLOSURE_SCOPE ? "closures" : "full") + " · " + seconds + "s · " +
    screenCount + " screens + " + floatWindows.length + " overlays · " +
    audit.length + " frames (" + counts.join(" · ") + ") · modes: " + info.modes.join(" / ") +
    // Verdict first, counters after: the panel clips its tail（实测面板高度只够前 ~30 行），
    // 而「哪一块坏了」是每次运行都要读的那一段。计数行是给 smoke.js 与交接包机读的，
    // 排在结论之后不影响它们（按行前缀匹配，与顺序无关）。
    "\n\n" + verdict +
    "\n\n" + counters +
    "\n\nprototype links: " + wiring.wired + "/" + wiring.attempts +
    (WIRE_ERRORS.length ? "\n" + WIRE_ERRORS.slice(0, 8).join("\n") : "") +
    "\nbind errors: " + BIND_ERRORS.length +
    "\nCJK runs: " + (CJK_FONT ? CJK_FONT.family : "none available — export may drop them") +
    (bindErrors.length ? "\n" + bindErrors.join("\n") : "") +
    (EXPORT_ERRORS.length ? "\nexport settings: " + EXPORT_ERRORS.length + " failed\n" +
      EXPORT_ERRORS.slice(0, 4).join("\n") : "") +
    "\n\n" + report.join("\n") +
    (audit.length ? "\n\nAUDIT\n" + audit.join("\n") : "") +
    (info.modeError ? "\n\nmodes: " + info.modeError : "") +
    (exported.length ? "\n\nexported: " + exported.length + " png → " +
      exported.map(function (f) { return f.name; }).join(", ") : "") +
    (errors.length ? "\n\nERRORS\n" + errors.join("\n") : "\n\nno errors");
  // 结论区**一行一个元素**，不是一个大 <pre>：无障碍层对单个文本节点会截断（实测 ~400 字符），
  // 一个 <pre> 装 30 行结论时，读屏与脚本化读回都只拿得到前 4 行——2026-09-18 在 Figma 桌面版
  // 实跑时正是因此只看到 10 块待修里的前 4 块。逐行拆开后每行都是一个短节点，读全没有问题。
  const esc = function (s) {
    return String(s).replace(/[<>&]/g, function (c) {
      return { "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c];
    });
  };
  const headLines = [verdict].concat(
    problems.length || stray.length
      ? problems.concat(stray.map(function (s) { return "stray top-level node: " + s; }))
      : []
  );
  const rest = summary.slice(summary.indexOf(verdict) + verdict.length).trim();
  figma.showUI(
    "<div style=\"font:10px/1.45 ui-monospace,Menlo,monospace;white-space:pre-wrap;padding:10px;margin:0\">" +
    headLines.map(function (l) { return "<div>" + esc(l) + "</div>"; }).join("") +
    "</div><pre style=\"font:10px/1.45 ui-monospace,Menlo,monospace;white-space:pre-wrap;padding:0 10px 10px;margin:0\">" +
    esc(rest) +
    "</pre>" +
    "<script>window.onmessage=function(e){var m=e.data.pluginMessage;" +
    "if(!m||m.type!=='export')return;m.files.forEach(function(f){" +
    "var b=new Blob([f.bytes],{type:'image/png'}),u=URL.createObjectURL(b)," +
    "a=document.createElement('a');a.href=u;a.download=f.name;" +
    "document.body.appendChild(a);a.click();" +
    "setTimeout(function(){URL.revokeObjectURL(u);a.remove();},10000);});};</script>",
    { width: 820, height: 760, title: "SpeechRail design kit · " + SCOPE }
  );
  if (exported.length) figma.ui.postMessage({ type: "export", files: exported });
}

main().catch(function (err) {
  figma.notify("SpeechRail kit failed: " + (err && err.message ? err.message : String(err)), {
    error: true,
    timeout: 10000
  });
  figma.closePlugin();
});
