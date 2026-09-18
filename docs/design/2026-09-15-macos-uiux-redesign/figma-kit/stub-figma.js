// 离屏冒烟用的最小 Figma API 替身（配合 smoke.js，不需要打开 Figma）。
//
// 只实现这个 kit 用到的那部分 API，**不模拟布局引擎**：尺寸只在 resize() / 显式赋值时
// 变化，auto-layout 不会重算几何。所以它能抓的是拼装层面的错误——未定义引用、调用顺序、
// 页面预算、导出设置、深色改绑，以及「漏 add() 导致节点游离」。摆位、换行、字体渲染都
// 不在这里，也不能据此判断稿对不对。

let idSeq = 0;
const nextId = () => `node:${(idSeq += 1)}`;

class Node {
  constructor(type) {
    this.id = nextId();
    this.type = type;
    this.name = "";
    this.children = [];
    this.parent = null;
    this.x = 0;
    this.y = 0;
    this.width = 100;
    this.height = 100;
    this.fills = [];
    this.strokes = [];
    this.strokeWeight = 1;
    this.strokeAlign = "NONE";
    this.layoutMode = "NONE";
    this.layoutWrap = "NO_WRAP";
    this.layoutAlign = "INHERIT";
    this.layoutGrow = 0;
    this.layoutPositioning = "AUTO";
    this.itemSpacing = 0;
    this.paddingLeft = 0;
    this.paddingRight = 0;
    this.paddingTop = 0;
    this.paddingBottom = 0;
    this.primaryAxisSizingMode = "AUTO";
    this.counterAxisSizingMode = "AUTO";
    this.primaryAxisAlignItems = "MIN";
    this.counterAxisAlignItems = "MIN";
    this.cornerRadius = 0;
    this.clipsContent = false;
    this.exportSettings = [];
    this.reactions = [];
    this.opacity = 1;
    this.visible = true;
    this.scalarBound = {};
    this.explicitModes = {};
  }

  get removed() {
    return this.parent === null && this.type !== "PAGE";
  }

  // 真 API 返回渲染后的矩形；替身只回报显式尺寸，所以在替身上算出的 overflow 没有意义。
  get absoluteBoundingBox() {
    return { x: this.x, y: this.y, width: this.width, height: this.height };
  }

  resize(w, h) {
    if (typeof w === "number") this.width = w;
    if (typeof h === "number") this.height = h;
  }

  appendChild(node) {
    if (node.parent) node.parent.children.splice(node.parent.children.indexOf(node), 1);
    node.parent = this;
    this.children.push(node);
    return node;
  }

  insertChild(index, node) {
    if (node.parent) node.parent.children.splice(node.parent.children.indexOf(node), 1);
    node.parent = this;
    this.children.splice(index, 0, node);
    return node;
  }

  remove() {
    if (this.parent) this.parent.children.splice(this.parent.children.indexOf(this), 1);
    this.parent = null;
  }

  setBoundVariable(field, variable) {
    this.scalarBound[field] = variable;
  }

  setExplicitVariableModeForCollection(collection, modeId) {
    const id = typeof collection === "string" ? collection : collection.id;
    this.explicitModes[id] = modeId;
  }

  clone() {
    const copy = new Node(this.type);
    copy.name = this.name;
    copy.x = this.x;
    copy.y = this.y;
    copy.width = this.width;
    copy.height = this.height;
    copy.fills = this.fills.map((p) => ({ ...p, boundVariables: p.boundVariables ? { ...p.boundVariables } : undefined }));
    copy.strokes = this.strokes.map((p) => ({ ...p, boundVariables: p.boundVariables ? { ...p.boundVariables } : undefined }));
    copy.strokeWeight = this.strokeWeight;
    copy.layoutMode = this.layoutMode;
    copy.itemSpacing = this.itemSpacing;
    copy.exportSettings = [];
    for (const child of this.children) copy.appendChild(child.clone());
    return copy;
  }
}

// 真 Figma 只在节点已经有 auto-layout 父级时才接受 layoutPositioning = "ABSOLUTE"，
// 在游离节点上赋值会直接抛出（实测 2026-09-17：整块「会话占用」画板因此在真机上
// 丢失，而替身照单全收）。这个 setter 把那条限制搬到离屏，让同一类错误在 smoke.js
// 就红，而不是等客户端跑到一半。
Object.defineProperty(Node.prototype, "layoutPositioning", {
  get() {
    return this._layoutPositioning || "AUTO";
  },
  set(value) {
    if (value === "ABSOLUTE" && !(this.parent && this.parent.layoutMode && this.parent.layoutMode !== "NONE")) {
      throw new Error(
        "Can only set layoutPositioning = ABSOLUTE if the parent node has auto layout " +
        `(node "${this.name || this.type}" has ${this.parent ? "a '" + this.parent.layoutMode + "' parent" : "no parent"})`
      );
    }
    this._layoutPositioning = value;
  },
  configurable: true
});

class TextNode extends Node {
  constructor() {
    super("TEXT");
    this.characters = "";
    this.textStyleId = "";
    this.textAutoResize = "NONE";
    this.textAlignHorizontal = "LEFT";
    this.fontRanges = [];
  }

  setRangeFontName(start, end, font) {
    if (start < 0 || end > this.characters.length || start >= end) {
      throw new Error(`bad range ${start}-${end} of ${this.characters.length}`);
    }
    this.fontRanges.push({ start, end, font });
  }
}

class Variable {
  constructor(name, collection, resolvedType) {
    this.id = `var:${(idSeq += 1)}`;
    this.name = name;
    this.resolvedType = resolvedType;
    this.variableCollectionId = collection.id;
    this.valuesByMode = {};
  }

  setValueForMode(modeId, value) {
    this.valuesByMode[modeId] = value;
  }
}

class VariableCollection {
  constructor(name) {
    this.id = `coll:${(idSeq += 1)}`;
    this.name = name;
    this.modes = [{ modeId: "mode:1", name: "Mode 1" }];
    this.variableIds = [];
  }

  // 真运行时里这个属性是 undefined（2026-09-16 在 Figma 桌面版实测）：集合内的变量只能
  // 靠 variableIds + getLocalVariablesAsync() 取。替身照真机返回 undefined，否则「读了
  // coll.variables」这类 bug 在冒烟里看不见。
  get variables() {
    return undefined;
  }

  addMode(name) {
    const mode = { modeId: `mode:${(idSeq += 1)}`, name };
    this.modes.push(mode);
    return mode.modeId;
  }

  renameMode(modeId, name) {
    const mode = this.modes.find((m) => m.modeId === modeId);
    if (!mode) throw new Error(`no mode ${modeId}`);
    mode.name = name;
  }
}

function createFigmaStub() {
  const pages = [];
  const collections = [];
  const variables = [];
  const textStyles = [];
  // this kit 把报告渲染在插件面板里（不是 closePlugin(report)），所以面板内容、通知与
  // 「插件是否结束」是三条独立的记录：冒烟要按它实际的形状读，不能假装是骨架那一种。
  const log = { notify: [], panels: [], closed: null, pluginClosed: false, ui: [], zoomed: 0 };

  const root = new Node("DOCUMENT");
  root.type = "DOCUMENT";

  const createPage = () => {
    const page = new Node("PAGE");
    page.type = "PAGE";
    page.parent = root;
    pages.push(page);
    root.children.push(page);
    return page;
  };

  const page1 = createPage();
  page1.name = "Page 1"; // 新文件自带的空页，用来验证「收养空页」这条路径

  const figma = {
    root,
    currentPage: page1,
    createFrame: () => new Node("FRAME"),
    createComponent: () => new Node("COMPONENT"),
    createRectangle: () => new Node("RECTANGLE"),
    createEllipse: () => new Node("ELLIPSE"),
    createVector: () => new Node("VECTOR"),
    createText: () => new TextNode(),
    createNodeFromSvg(svg) {
      const node = new Node("VECTOR");
      // 图标是描边路径：替身必须给一个非空 strokes，否则 recolor() 会静默跳过绑定，
      // 「图标没绑上颜色」这条缺陷在冒烟里就消失了。
      node.strokes = [{ type: "SOLID", color: { r: 0, g: 0, b: 0 } }];
      node.fills = [];
      node.svgSource = svg;
      return node;
    },
    createPage,
    async setCurrentPageAsync(page) {
      figma.currentPage = page;
    },
    async loadAllPagesAsync() {},
    combineAsVariants(nodes, parent) {
      const set = new Node("COMPONENT_SET");
      set.layoutMode = "NONE";
      parent.appendChild(set);
      for (const n of nodes) set.appendChild(n);
      return set;
    },
    variables: {
      getLocalVariableCollections: () => collections,
      getLocalVariables(type) {
        return variables.filter((v) => !type || v.resolvedType === type);
      },
      async getLocalVariablesAsync() {
        return variables.slice();
      },
      createVariableCollection(name) {
        const coll = new VariableCollection(name);
        collections.push(coll);
        return coll;
      },
      createVariable(name, collection, type) {
        const v = new Variable(name, collection, type);
        variables.push(v);
        collection.variableIds.push(v.id);
        return v;
      },
      getVariableById(id) {
        return variables.find((v) => v.id === id) || null;
      },
      // 真 API 返回带绑定信息的新 paint；这里照做，深色改绑才可验证。
      setBoundVariableForPaint(paint, field, variable) {
        return { ...paint, boundVariables: { ...(paint.boundVariables || {}), [field]: variable } };
      }
    },
    getLocalTextStyles: () => textStyles,
    createTextStyle() {
      const style = { id: `style:${(idSeq += 1)}`, name: "" };
      textStyles.push(style);
      return style;
    },
    async loadFontAsync() {},
    async listAvailableFontsAsync() {
      return [
        { fontName: { family: "Inter", style: "Regular" } },
        { fontName: { family: "Inter", style: "Medium" } },
        { fontName: { family: "Inter", style: "Semi Bold" } },
        { fontName: { family: "Inter", style: "Bold" } },
        { fontName: { family: "PingFang SC", style: "Regular" } },
        { fontName: { family: "PingFang SC", style: "Medium" } },
        { fontName: { family: "PingFang SC", style: "Semibold" } }
      ];
    },
    viewport: {
      scrollAndZoomIntoView() {
        log.zoomed += 1;
      }
    },
    showUI(html, options) {
      log.panels.push({ html, options });
    },
    ui: {
      postMessage(message) {
        log.ui.push(message);
      }
    },
    notify(message, options) {
      log.notify.push({ message, options });
    },
    closePlugin(message) {
      log.closed = message;
    }
  };

  return { figma, log, collections, variables, textStyles, pages };
}

module.exports = { createFigmaStub, Node };
