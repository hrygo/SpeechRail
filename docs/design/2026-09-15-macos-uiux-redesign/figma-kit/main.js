// =============================================================================
// SpeechRail macOS 26 · UI/UX Redesign — Figma design kit builder
// Generates variables, text styles, foundations, components and all 8 screens.
// Idempotent: pages it owns are removed and rebuilt on each run.
// =============================================================================

const PAGE_NAMES = [
  "00 Cover", "01 Foundations", "02 Components", "03 Flows",
  "04 Screens", "05 Menu & Settings", "06 Archive"
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
const PAGE_LAYOUT = [
  { page: "01 Kit", groups: ["00 Cover", "01 Foundations", "02 Components"] },
  { page: "02 Screens", groups: ["04 Screens", "03 Flows", "05 Menu & Settings", "06 Archive"] }
];
const REAL_PAGES = PAGE_LAYOUT.map(function (spec) { return spec.page; });
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
  ["Caption / Medium", 10, "Medium", 135]
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
      { format: "SVG" }
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
    if (logical === "04 Screens") screens = true;
    else if (CANVAS_NAMES[logical]) exact.push(CANVAS_NAMES[logical]);
  });
  return function (name) {
    return (screens && name.indexOf("▸ ") === 0) || exact.indexOf(name) >= 0;
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
  { key: "overview", group: "引擎", label: "服务状态", icon: "server" },
  { key: "monitoring", group: "引擎", label: "运行监控", icon: "activity" },
  { key: "models", group: "引擎", label: "模型", icon: "package" },
  { key: "diagnostics", group: "引擎", label: "诊断", icon: "stethoscope" },
  { key: "developerDocs", group: "引擎", label: "开发者文档", icon: "book-open" }
];

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

function segmented(parent, items, activeIndex) {
  const seg = frame("segmented", {
    layout: "HORIZONTAL", gap: 1, pad: 1, radius: 7,
    fill: V["surface/window"], stroke: V["border/separator"], strokeWeight: 1
  });
  items.forEach(function (item, i) {
    const cell = frame("cell", {
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

function buildShell(routeKey, title, iconName, contentFn) {
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
  ["创作", "引擎"].forEach(function (groupName) {
    const group = frame("group/" + groupName, { layout: "VERTICAL", gap: 1 });
    const label = frame("groupLabel", { layout: "HORIZONTAL", padX: 8, padY: 2 });
    add(label, text("label", groupName, "Caption / Medium", V["text/tertiary"]));
    add(group, stretch(label));
    ROUTES.filter(function (r) { return r.group === groupName; }).forEach(function (r) {
      navItemRow(group, r, r.key === routeKey);
    });
    add(sidebar, stretch(group));
  });
  spacer(sidebar);

  const statusWrap = frame("sidebarStatusWrap", { layout: "VERTICAL", gap: 10 });
  const hairline = rect(statusWrap, "hairline", 220, 1, V["border/separator"]);
  const status = frame("sidebarStatus", {
    layout: "HORIZONTAL", gap: 8, align: "CENTER", padX: 8, padY: 7
  });
  size(status, 220, 30);
  dot(status, 8, V["status/ready"]);
  add(status, text("label", "服务已就绪 · Quality", "Callout", V["text/secondary"]));
  add(statusWrap, status);
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
  size(side, 300, null);
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
  add(sideBody, stretch(text("desc", "温暖、清晰、亲近，像一位深夜电台耐心的播客主持人。",
    "Callout", V["text/secondary"], { w: 268 })));
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
  spacer(table);
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
  size(topics, 272, null);
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

function buildScreens(colorModeId) {
  const page = P["04 Screens"];
  const built = [];
  SCREEN_DEFS.forEach(function (def, i) {
    const win = buildShell(def[0], def[1], def[2], def[3]);
    win.x = 0;
    win.y = i * 1020;
    // Export settings come from add() — every page-level frame gets the same
    // PNG @4x + SVG pair.
    add(page, win);
    built.push(win);
  });
  return built;
}

function buildDarkVariants(windows, collection, modeId) {
  const page = P["04 Screens"];
  return windows.map(function (win, i) {
    const clone = win.clone();
    clone.name = "▸ " + win.name.replace("▸ ", "") + " · Dark";
    try {
      clone.setExplicitVariableModeForCollection(collection, modeId);
    } catch (e) {
      try { clone.setExplicitVariableModeForCollection(collection.id, modeId); } catch (e2) {}
    }
    clone.x = 1560;
    clone.y = i * 1020;
    add(page, clone);
    return clone;
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
  size(canvas, 1600, 900);
  add(page, canvas);
  add(canvas, text("kicker", "SPEECHRAIL · macOS 26", "Caption / Medium", V["accent/rail"]));
  add(canvas, text("h1", "SpeechRail 管理控制台", "Title / Large", V["text/primary"]));
  add(canvas, text("h2", "UI/UX 重设计 · 提案 v1.0.0", "Title / Page", V["text/primary"]));
  add(canvas, text("lead",
    "让 App 同时符合两件事：产品定位（本机语音引擎的唯一产品化入口）与 macOS 26 最佳实践" +
    "（材质、层级、圆角、工具栏与键盘路径交还给系统）。",
    "Body", V["text/secondary"], { w: 820 }));
  add(canvas, text("date", "2026-09-15 · Status: Proposed", "Callout", V["text/tertiary"]));
  const list = frame("contents", { layout: "VERTICAL", gap: 6 });
  [
    "01 Foundations — 颜色、字体层级、间距、圆角、图标（全部为 Variables）",
    "02 Components — 状态胶囊、导航项、按钮、卡片、列表行、候选卡、空状态",
    "03 Flows — 四条主流程连线，并注明跨页连线需在 Prototype 面板手动接入",
    "04 Screens — 10 个页面 × Light / Dark 两种外观",
    "05 Menu & Settings — 菜单栏面板（默认 / 控制受限 / 深色）与设置窗口三个分组",
    "06 Archive — 迁移前的机架视觉对照，只作历史记录",
    "设计依据：docs/design/2026-09-15-macos-uiux-redesign/REDESIGN-SPEC.md"
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
  "06 Archive": "Archive"
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
  size(canvas, 1680, null);
  add(page, canvas);
  boardHead(canvas, "四条主流程",
    "产品只有四条主路径，其余界面都是它们的入口或解释。每个节点都可点击，" +
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
  if (o.busy) dot(item, 6, V["accent/voice"]);
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
    "两个不在主窗口里的界面。菜单栏面板承担「一句话状态 + 常用动作」，" +
    "设置只保留会影响默认行为的几项；模型管理仍然属于控制台。", 1180);

  const menuBox = frame("menus", { layout: "HORIZONTAL", gap: 48 });
  add(canvas, stretch(menuBox));
  const labels = ["菜单栏面板 · 默认", "菜单栏面板 · 控制受限", "菜单栏面板 · 深色"];
  const panels = [
    menuPanel("panel · 默认", {}),
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
  darkReference(panels[2]);

  const stripBox = frame("menuBarRow", { layout: "VERTICAL", gap: 20 });
  add(canvas, stretch(stripBox));
  add(stripBox, text("title", "菜单栏状态项", "Heading / Section", V["text/primary"]));
  [
    ["常态 · 服务就绪且空闲", { label: false, busy: false }, "只有图标：菜单栏属于系统，不属于产品。"],
    ["展开态 · 操作进行中", { label: true, busy: true }, "悬停或操作进行中才出现文字与琥珀色状态点。"]
  ].forEach(function (def) {
    const col = frame("state", { layout: "VERTICAL", gap: 8 });
    add(col, text("caption", def[0], "Callout", V["text/secondary"]));
    menuBarStrip(col, def[1]);
    add(col, text("note", def[2], "Caption", V["text/tertiary"], { w: 900 }));
    add(stripBox, stretch(col));
  });

  const settingsBox = frame("settings", { layout: "HORIZONTAL", gap: 40 });
  add(canvas, stretch(settingsBox));
  const windows = SETTINGS_TABS.map(function (t, i) {
    const col = frame("column/" + t.key, { layout: "VERTICAL", gap: 8 });
    add(col, text("caption", "设置 · " + t.title, "Callout", V["text/secondary"]));
    const win = settingsWindow(i);
    add(col, win);
    add(settingsBox, col);
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

function wirePrototype(light, dark) {
  const keys = SCREEN_DEFS.map(function (d) { return d[0]; });
  const total = { wired: 0, attempts: 0 };
  function wireGroup(group) {
    group.forEach(function (win, i) {
      keys.forEach(function (key, j) {
        // The row for the page you are already on is the selected row, not a
        // link: pointing a frame at itself is rejected and means nothing.
        if (!group[j] || group[j] === win) return;
        const row = findByName(win, "nav/" + key);
        if (!row) return;
        total.attempts++;
        if (wireClick(row, group[j], win.name)) total.wired++;
      });
      const status = findByName(win, "sidebarStatus");
      const overview = group[keys.indexOf("overview")];
      if (status && overview && overview !== win) {
        total.attempts++;
        if (wireClick(status, overview, win.name)) total.wired++;
      }
    });
  }
  wireGroup(light);
  wireGroup(dark);
  return total;
}

// =============================================================================
// Entry point
// =============================================================================

// --- Self-audit --------------------------------------------------------------
// Runs on the built document so the run report can distinguish "generated" from
// "generated and actually looks right".

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
function auditInnerOverflow(root) {
  const out = [];
  // `branch` is the top-level child of the audited frame the node sits in. A
  // board holds several windows, and "content ▸ group +8B" does not say which.
  function walk(node, branch) {
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
          out.push((branch ? branch + " ▸ " : "") + node.name + " ▸ " + child.name +
            " +" + Math.round(worst) + dir +
            " [" + Math.round(child.width) + " in " + Math.round(node.width) + "]");
        }
      });
    }
    if ("children" in node) {
      node.children.forEach(function (c) {
        walk(c, node.parent === root ? c.name : branch);
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
      const showSamples = !samplesShown && frameNode.name.indexOf("· Dark") >= 0;
      if (showSamples) samplesShown = true;
      lines.push(
        frameNode.name + " · " + Math.round(frameNode.width) + "×" + Math.round(frameNode.height) +
        " " + samplePaint(frameNode) + " · " + bindings.dark + "/" + bindings.light + "bound · gray " + unbound +
        " · overflow " + (overflow.length ? overflow.length + ": " + overflow.slice(0, 2).join(", ") : "ok") +
        " · inner " + (inner.length ? inner.length + ": " + inner.slice(0, 2).join(", ") : "ok") +
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
  await step("flows", async function () {
    await gotoPage(P["03 Flows"]); buildFlows(); takeGroup("03 Flows");
  });
  await step("menu & settings", async function () {
    await gotoPage(P["05 Menu & Settings"]); buildMenuAndSettings(); takeGroup("05 Menu & Settings");
  });
  await step("archive", async function () {
    await gotoPage(P["06 Archive"]); buildArchive(); takeGroup("06 Archive");
  });
  await step("prototype wiring", function () {
    wiring = wirePrototype(windows, darkWindows);
  });
  await step("cover", async function () {
    await gotoPage(P["00 Cover"]); buildCover(); takeGroup("00 Cover");
  });
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
    await gotoPage(P["04 Screens"]);
    if (windows.length) figma.viewport.scrollAndZoomIntoView(windows.slice(0, 1));
  } catch (e) {}

  const seconds = ((Date.now() - t0) / 1000).toFixed(1);
  const bindErrors = BIND_ERRORS.slice(0, 4);
  // The report panel clips its tail, so the verdict goes first and the per-frame
  // detail follows only for the frames that actually failed a check.
  const problems = audit.filter(function (line) {
    return line.indexOf("overflow ok") < 0 || line.indexOf("inner ok") < 0 ||
      line.indexOf("gray 0") < 0 || line.indexOf(" 0bound") >= 0;
  }).map(function (line) {
    // Keep the verdict one short line per problem: the panel clips its tail and
    // the first thing that has to survive the clip is the list of what broke.
    const name = line.slice(0, line.indexOf(" · "));
    const found = [];
    const over = line.match(/overflow \d+: ([^\n]+)/);
    const inner = line.match(/inner \d+: ([^\n]+)/);
    const gray = line.match(/gray (\d+)/);
    if (over) found.push("overflow → " + over[1].trim().slice(0, 60));
    if (inner) found.push("inner → " + inner[1].trim().slice(0, 60));
    if (gray && gray[1] !== "0") found.push("unbound-gray " + gray[1]);
    if (line.indexOf(" 0bound") >= 0) found.push("no dark binding");
    return name + ": " + found.join(" ; ");
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

  const verdict = "AUDIT VERDICT · " + audit.length + " frames · " +
    (problems.length || stray.length
      ? (problems.length + stray.length) + " need attention:\n" +
        problems.concat(stray.map(function (s) { return "stray top-level node: " + s; })).join("\n")
      : "all clean (overflow / inner / unbound-gray / dark-binding / stray)");
  const summary =
    "SpeechRail design kit · " + seconds + "s · " + windows.length + " screens · " +
    audit.length + " frames (" + counts.join(" · ") + ") · modes: " + info.modes.join(" / ") +
    // Verdict first: the panel clips its tail, and "did anything break" is the
    // question every run is read for.
    "\n\n" + verdict +
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
  figma.showUI(
    "<pre style=\"font:10px/1.45 ui-monospace,Menlo,monospace;white-space:pre-wrap;padding:10px;margin:0\">" +
    summary.replace(/[<>&]/g, function (c) { return { "<": "&lt;", ">": "&gt;", "&": "&amp;" }[c]; }) +
    "</pre>" +
    "<script>window.onmessage=function(e){var m=e.data.pluginMessage;" +
    "if(!m||m.type!=='export')return;m.files.forEach(function(f){" +
    "var b=new Blob([f.bytes],{type:'image/png'}),u=URL.createObjectURL(b)," +
    "a=document.createElement('a');a.href=u;a.download=f.name;" +
    "document.body.appendChild(a);a.click();" +
    "setTimeout(function(){URL.revokeObjectURL(u);a.remove();},10000);});};</script>",
    { width: 820, height: 760, title: "SpeechRail design kit" }
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
