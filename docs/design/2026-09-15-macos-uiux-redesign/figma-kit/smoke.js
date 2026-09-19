#!/usr/bin/env node
// 离屏冒烟：在替身 API 上把生成器完整跑一遍，检查拼装层面的不变量（不需要打开 Figma）。
//
// 用法： node smoke.js [full|closures]
// 退出码非 0 = 有结构性问题。抓的是：跑不起来、页面超预算、画板不是页面顶层 FRAME、
// 导出设置缺失或被 Figma 拒绝的那种写法（SVG 带 constraint）、深色克隆缺失或没改绑、
// 游离节点、绑定与导出设置报错。
//
// **不检查几何**：替身没有布局引擎，报告里的 root/inner overflow 在它这里是假的，不要据此
// 判断稿对不对。与 audit.js 的分工：audit.js 静态看引用，smoke.js 动态看执行结果，两者都
// 不替代在 Figma 里跑一次（摆位、换行、字体只有真跑才看得见）。

const fs = require("fs");
const path = require("path");
const { createFigmaStub } = require("./stub-figma");

const here = __dirname;
// 范围：默认全量稿（48 板）；传 closures 时先声明 SPEECHRAIL_SCOPE，与 build-closures.js
// 拼出来的 code.js 是同一份源码——离屏门禁验的是将要跑进 Figma 的那一份。
const scope = process.argv[2] || "full";
if (["full", "closures"].indexOf(scope) < 0) {
  console.error(`SMOKE FAIL: 未知范围 "${scope}"（可用：full / closures）`);
  process.exit(2);
}
const prelude = scope === "closures" ? 'var SPEECHRAIL_SCOPE = "closures";' : "";
const source = [prelude]
  .concat(["icons.js", "main.js"].map((f) => fs.readFileSync(path.join(here, f), "utf8")))
  .join("\n\n");

// 每个范围自己声明的真实页面：页面名写死在一个地方，冒烟与生成器读的是同一张表。
const REAL_PAGES = {
  full: ["01 Kit", "02 Screens"],
  closures: ["01 闭环"]
}[scope];

const { figma, log, collections, pages } = createFigmaStub();
const problems = [];
const expect = (ok, label) => {
  console.log(`${ok ? "ok  " : "FAIL"} ${label}`);
  if (!ok) problems.push(label);
};

// 生成器在加载末尾自跑 main()（与 Figma 里的生命周期一致），所以这里只求值一次、等它结束，
// 不要再手动调一次 main()——两次并发会交叉，计数全乱。
new Function("figma", "console", source)(figma, console);

// 这个 kit 不把报告交给 closePlugin()，而是渲染在插件面板里（main.js 末尾的
// figma.showUI(html)），所以等待目标是「面板出现了」而不是「插件关闭了」。closePlugin 只在
// 生成器抛错时被调用，这里保持它未被调用反而是正常路径。
const waitForPanel = async (ms) => {
  const deadline = Date.now() + ms;
  while (log.panels.length === 0 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 10));
  return log.panels.length ? panelText(log.panels[0].html) : null;
};

// 面板是一段 HTML：报告正文被摆进 <pre>，其中 < > & 已被转义。按它实际的形状取回来。
const panelText = (html) => {
  const match = html.match(/<pre[^>]*>([\s\S]*?)<\/pre>/);
  const body = match ? match[1] : html;
  return body
    .replace(/&(amp|lt|gt);/g, (_, entity) => ({ amp: "&", lt: "<", gt: ">" }[entity]))
    .trim();
};

const valueOf = (report, prefix) => {
  const line = report.split("\n").find((l) => l.startsWith(prefix));
  return line == null ? null : Number(line.split("=")[1]);
};

const framesOf = (page) => page.children.filter((c) => c.type === "FRAME");

// 一块画板上的绑定分别落在哪个集合：深色克隆里不该还有浅色集合的绑定。
function bindingSplit(frame, darkCollectionId) {
  let dark = 0;
  let light = 0;
  const walk = (node) => {
    for (const field of ["fills", "strokes"]) {
      const paints = node[field];
      if (!Array.isArray(paints)) continue;
      for (const paint of paints) {
        const bound = paint && paint.boundVariables && paint.boundVariables.color;
        if (!bound) continue;
        if (bound.variableCollectionId === darkCollectionId) dark += 1;
        else light += 1;
      }
    }
    if (node.children) node.children.forEach(walk);
  };
  walk(frame);
  return { dark, light };
}

// 生成器要建上千个节点、再逐帧走三遍审计，替身没有布局引擎但仍有可观的纯 JS 开销：
// 实测约 20 秒。给到 120 秒是为了区分「卡住」和「慢」。
waitForPanel(120000).then((report) => {
  if (report === null) {
    console.error("SMOKE FAIL: 生成器 120 秒内没有把报告推进插件面板（可能卡在 await 上）");
    process.exit(1);
  }
  // 生成器只有抛错时才走 closePlugin，所以在这里出现非空值本身就是失败证据。
  if (log.closed !== null) console.error(`SMOKE FAIL: 生成器走了失败分支：${log.closed}`);

  const GEOMETRY_PREFIXES = ["AUDIT VERDICT:", "root overflow=", "inner overflow=", "AUDIT"];
  console.log("--- 生成器报告（`~` 行 = 替身无布局引擎，不可信）---");
  console.log(
    report
      .split("\n")
      .map((line) => (GEOMETRY_PREFIXES.some((p) => line.startsWith(p)) ? `~ ${line}（替身不可信）` : line))
      .join("\n")
  );
  console.log("--- 结构断言 ---");

  expect(log.panels.length === 1, "报告只推一次插件面板");
  expect(log.closed === null, "生成器没有走失败分支（closePlugin 未被调用）");
  expect(!/\nERRORS\n/.test(report), "生成器没有抛错的步骤（报告里没有 ERRORS 段）");
  expect(pages.length <= 3, `页数 ${pages.length} 不超过免费版上限 3`);
  expect(valueOf(report, "bind errors=") === 0, "没有 paint 绑定失败");
  expect(valueOf(report, "export errors=") === 0, "没有导出设置写入失败");
  expect(valueOf(report, "stray top-level=") === 0, "没有游离的顶层节点");
  expect(valueOf(report, "boards=") > 0 && valueOf(report, "boards=") === valueOf(report, "frames audited="),
    `boards 与逐帧审计数一致（${valueOf(report, "boards=")} 块画板）`);

  // 真实页面：只认 kit 自己声明的三张，且每张顶层只有 FRAME。
  expect(pages.every((p) => REAL_PAGES.includes(p.name)), `页面只有 kit 自己声明的：${pages.map((p) => p.name).join(", ")}`);
  const nonFrames = pages.flatMap((p) => p.children.filter((c) => c.type !== "FRAME"));
  expect(nonFrames.length === 0, "没有非 FRAME 节点留在页面层（组件集/组件/文字都必须在画板里）");

  // 导出设置：每块画板两条，PNG @4x 与不带 constraint 的 SVG。
  const badExport = [];
  pages.forEach((p) => framesOf(p).forEach((f) => {
    const s = f.exportSettings || [];
    const png = s.find((x) => x.format === "PNG");
    const svg = s.find((x) => x.format === "SVG");
    if (s.length !== 2 || !png || !svg) return badExport.push(`${f.name}: ${s.length} 条`);
    if (!png.constraint || png.constraint.type !== "SCALE") badExport.push(`${f.name}: PNG 没有 SCALE`);
    if (svg.constraint) badExport.push(`${f.name}: SVG 带了 constraint（Figma 会拒绝整组）`);
    // SVG 少了这一条，Figma 会把文字全部轮廓化：图和尺寸都正常，只有"稿能被搜索/被读"这件事没了。
    if (svg.svgOutlineText !== false) badExport.push(`${f.name}: SVG 没有写 svgOutlineText: false（文字会被转成路径）`);
  }));
  expect(badExport.length === 0, `每块画板都是 PNG@4x + 保留文字的 SVG 两条设置${badExport.length ? "：" + badExport.slice(0, 3).join(" / ") : ""}`);

  // 自连：真 Figma 拒绝「把画板连到它自己」（Reaction at index 0 was invalid），替身照收，
  // 于是留下一条点了没反应的死链。侧边栏里「你正在这一页」的那一行就是这种情况，所以
  // 在离屏也判一次：任何 reaction 的目的地都不能是源节点自己或它的祖先。
  const allFrames = pages.flatMap(framesOf);
  const byId = {};
  const index = (node) => {
    byId[node.id] = node;
    (node.children || []).forEach(index);
  };
  allFrames.forEach(index);
  const selfLinks = [];
  const linksSeen = { total: 0 };
  const checkLinks = (node) => {
    (node.reactions || []).forEach((reaction) => {
      (reaction.actions || []).forEach((action) => {
        if (action.type !== "NODE") return;
        linksSeen.total += 1;
        const target = byId[action.destinationId];
        for (let up = node; up; up = up.parent) {
          if (up === target) return selfLinks.push(`${node.name} → ${target.name}`);
        }
      });
    });
    (node.children || []).forEach(checkLinks);
  };
  allFrames.forEach(checkLinks);
  expect(selfLinks.length === 0,
    `${linksSeen.total} 条原型连线里没有自连${selfLinks.length ? "：源与目的地同一棵子树 " + selfLinks.slice(0, 3).join(", ") : ""}`);

  // 深色克隆：每块浅色屏幕/浮层都要有同名 ` · Dark` 孪生。文档类画板
  // （Cover / Foundations / Components / Flows / Menu & Settings / Archive）没有深色孪生，
  // 它们讲的是 token 与流程，不是一个界面的两种外观——所以这里按命名前缀划范围，
  // 而不是要求每块画板都成对。
  const lightBoards = allFrames.filter((f) => !/ · Dark$/.test(f.name));
  const pairedLightBoards = lightBoards.filter((f) => f.name.indexOf("▸ ") === 0 || f.name.indexOf("浮层 · ") === 0);
  const missingDark = pairedLightBoards.filter((f) => !allFrames.some((d) => d.name === f.name + " · Dark"));
  expect(missingDark.length === 0,
    `${pairedLightBoards.length} 块屏幕/浮层画板都有深色克隆${missingDark.length ? "：缺 " + missingDark.slice(0, 3).map((f) => f.name).join(", ") : ""}`);
  const darkFrames = allFrames.filter((f) => / · Dark$/.test(f.name));
  expect(darkFrames.length === pairedLightBoards.length,
    `深色画板数 ${darkFrames.length} 等于该成对的浅色画板数 ${pairedLightBoards.length}`);

  // 深色怎么实现取决于 Figma 是否允许给一个变量集合加第二个 mode：
  //   免费版：addMode 抛错 → 第二个集合 "SpeechRail (Dark reference)"，逐节点改绑；
  //   付费版 / 替身：addMode 成功 → 单集合双 mode，深色靠 setExplicitVariableModeForCollection。
  // 两条都要能被认出来：只认其中一条，另一条下的「深色其实是浅色」就静默通过。
  const mainCollection = collections.find((c) => c.name === "SpeechRail");
  const darkCollection = collections.find((c) => c.name === "SpeechRail (Dark reference)");
  const darkMismatch = [];
  let darkPath;
  if (darkCollection == null) {
    darkPath = "单集合双 mode（逐帧 explicit mode）";
    const darkModeId = mainCollection && mainCollection.modes.length > 1
      ? mainCollection.modes[1].modeId
      : null;
    darkFrames.forEach((f) => {
      if (!darkModeId || f.explicitModes[mainCollection.id] !== darkModeId) {
        darkMismatch.push(`${f.name}:${f.explicitModes[mainCollection.id] || "没有指到 Dark mode"}`);
      }
    });
    expect(darkModeId !== null, "主集合里确实有第二个 mode 可供深色画板指向");
  } else {
    darkPath = "独立深色参照集合（逐节点改绑）";
    darkFrames.forEach((f) => {
      const split = bindingSplit(f, darkCollection.id);
      if (split.dark === 0 || split.light > 0) darkMismatch.push(`${f.name}:${split.dark}dark/${split.light}light`);
    });
    expect(collections.length === 2 && mainCollection != null,
      "免费版路径下只有主集合与深色参照集合两个");
  }
  expect(darkMismatch.length === 0,
    `深色画板都真的指向深色（${darkPath}）${darkMismatch.length ? "：" + darkMismatch.slice(0, 3).join(", ") : ""}`);

  // 会话屏的交互规矩（2026-09-18 第七轮，双视角审查的结论）：
  //   **同一个动作在屏上只出现一次**——页头、结论条、状态带、右栏不能各给一个同名按钮；
  //   重复时用户与实现者都要猜哪个才是它。
  //
  // 唯一允许的重复：**同一个重复容器里的行**。断法表是「四种断法各自的出口」，第二行给
  // 的出口与第一行相同是有意的——判据是这些同名按钮的最近公共祖先底下有一组同名兄弟
  // （`closureCheckRow` 的行名都是 `checkRow`）。规则分不出「有意的逐行重复」和
  // 「两个地方各画了一遍」，所以用容器形状来分。
  //
  // 不查「一屏几个主按钮」：实测有两处是**正当的两个主按钮**（会议页 = 页级动作
  // `重新生成纪要` + 行内编辑器的 `保存`；对话页 = 页级 `结束对话` + 合成器的 `发送`），
  // 机器分不出它们和「两个相互竞争的主按钮」。有害的那种（同一个动作画两遍）由上一条拦住。
  // 只查闭环稿：全量稿的屏幕按页面组织，导航行与分组标题里有大量同名项，不适用这条。
  if (scope === "closures") {
    const violations = [];
    // 唯一一处有意的重复：会议中断页的「继续这一段」——页头是现在的入口，断法表的每一行
    // 给的是那种情况下的出口（表格在这里是文档）。除此之外不该再有第二处。
    const ALLOWED_REPEATS = ["▸ 会议助手 · 会议页 · 录制中断（服务或来源断了）:继续这一段"];
    const pathOf = (root, node) => {
      const chain = [];
      for (let up = node; up && up !== root; up = up.parent) chain.unshift(up);
      return chain;
    };
    const insideRepeatedRow = (root, hits) => {
      // 从每个命中点往上找，直到某个祖先在"它自己这一层有同名兄弟"——那就是重复容器。
      const chains = hits.map((h) => pathOf(root, h));
      for (let depth = 1; depth <= Math.min(...chains.map((c) => c.length)); depth += 1) {
        const nodes = chains.map((c) => c[c.length - depth]);
        if (nodes.some((n) => n !== nodes[0])) continue; // 还没合拢到公共祖先
        const parent = nodes[0].parent;
        if (!parent || !parent.children) return false;
        const same = parent.children.filter((c) => c.name === nodes[0].name);
        return same.length >= 2;
      }
      return false;
    };
    // 只比「按钮」的文案：胶囊、说话人徽标、列表标题也会用 `label` 这个名字，
    // 把它们算进来会得到一堆假阳性（第一版实测：`可选`、`夜航主持` 都被报成同名按钮）。
    const labelsOf = (node, out) => {
      if (node.type === "TEXT" && node.characters) {
        for (let up = node.parent; up; up = up.parent) {
          if (up.name && up.name.indexOf("Button /") === 0) {
            out.push([node.characters, up]);
            break;
          }
        }
      }
      (node.children || []).forEach((c) => labelsOf(c, out));
    };
    const screens = allFrames.filter((f) => f.name.indexOf("▸ ") === 0);
    screens.forEach((f) => {
      const labels = [];
      labelsOf(f, labels);
      const byLabel = new Map();
      labels.forEach((l) => {
        if (!byLabel.has(l[0])) byLabel.set(l[0], []);
        byLabel.get(l[0]).push(l[1]);
      });
      const bad = [];
      byLabel.forEach((nodes, label) => {
        if (nodes.length < 2) return;
        if (ALLOWED_REPEATS.indexOf(f.name + ":" + label) >= 0) return;
        if (insideRepeatedRow(f, nodes)) return;
        bad.push(`${label}×${nodes.length}`);
      });
      if (bad.length) violations.push(`${f.name}：同一个动作画了多遍 ${bad.slice(0, 3).join(" / ")}`);
    });
    expect(violations.length === 0,
      `${screens.length} 块闭环屏的动作没有重复${violations.length ? "：" + violations.slice(0, 4).join("；") : ""}`);
  }

  console.log("");
  if (problems.length) {
    console.error(`SMOKE FAIL: ${problems.length} 项不合格`);
    process.exit(1);
  }
  console.log("SMOKE OK: 结构不变量全部通过（几何未检查，需在 Figma 里实跑）");
});
