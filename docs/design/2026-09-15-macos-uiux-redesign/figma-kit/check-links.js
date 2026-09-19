#!/usr/bin/env node
// 连线源核对：闭环稿的连线是「按文案找回那个控件」的（`closureLinkSource`），文案一改，
// 找不到源就**静默**少一条连线——报告里只体现为 attempts 变小，不报错
// （实测 2026-09-17：改名后 smoke 只报 205/205 而不是失败）。
//
// 所以改稿里任何按钮或菜单行文案之后，跑这个脚本：它把 CLOSURE_BOARDS / CLOSURE_BAND_LINKS
// 里每一条声明的连线源在替身上重新解析一次，解析不到就列出「画板 + 文案」并非 0 退出。
//
// 用法： node check-links.js [closures]     默认 closures
// 全量稿的连线不走这套「按文案找回源控件」的机制，所以只支持闭环稿。
// 它同样不需要 Figma，也不检查几何。

const fs = require("fs");
const path = require("path");
const { createFigmaStub } = require("./stub-figma");

const scope = process.argv[2] || "closures";
if (scope !== "closures") {
  console.error(`CHECK FAIL: 只支持 closures（全量稿的连线不按文案解析），收到 "${scope}"`);
  process.exit(2);
}
const here = __dirname;
const prelude = scope === "closures" ? 'var SPEECHRAIL_SCOPE = "closures";' : "";
const source = [prelude]
  .concat(["icons.js", "main.js"].map((f) => fs.readFileSync(path.join(here, f), "utf8")))
  .join("\n\n");

// 生成器自己在末尾跑 main()；这里在同一个函数体里追加一段核对，
// 用到的都是生成器内部的名字（同一作用域），所以不需要导出任何东西。
const probe = `
(async function () {
  // 生成器在末尾自跑 main()，画板是异步铺上去的（smoke.js 等的是「面板出现了」）。
  // 所以这里等到页面上真的有画板再核对，不然看到的是空树。
  const collect = function () {
    const out = [];
    figma.root.children.forEach(function (page) {
      (page.children || []).forEach(function (n) { if (n.type === "FRAME") out.push(n); });
    });
    return out;
  };
  const deadline = Date.now() + 60000;
  while (collect().length === 0 && Date.now() < deadline) {
    await new Promise(function (r) { setTimeout(r, 10); });
  }
  checkDeclaredLinks();
})();

function checkDeclaredLinks() {
  const boards = CLOSURE_BOARDS;
  const frames = [];
  figma.root.children.forEach(function (page) {
    (page.children || []).forEach(function (n) { if (n.type === "FRAME") frames.push(n); });
  });
  const missing = [];
  let checked = 0;
  if (process.env.SPEECHRAIL_CHECK_NAMES === "1") {
    frames.forEach(function (f) { console.log("FRAME  " + f.name); });
  }
  boards.forEach(function (def) {
    (def.links || []).forEach(function (l) {
      const win = frames.find(function (f) { return f.name === "▸ " + def.title; });
      if (!win) { missing.push([def.title, "(画板不存在)", l[0]]); return; }
      checked += 1;
      if (!closureLinkSource(win, l[0])) missing.push([def.title, l[0], l[1]]);
    });
  });
  CLOSURE_BAND_LINKS.forEach(function (l) {
    const win = frames.find(function (f) { return f.name.replace(/^▸ /, "") === l[0]; });
    if (!win) { missing.push([l[0], "(画板不存在)", l[1]]); return; }
    checked += 1;
    if (!findIconButton(win, l[1])) missing.push([l[0], "icon/" + l[1], l[2]]);
  });
  console.log("scope=closures  声明连线源=" + checked + "  解析不到=" + missing.length);
  missing.forEach(function (m) { console.log("MISSING  " + m[0] + "  ←  " + m[1] + "  →  " + m[2]); });
  console.log(missing.length ? "CHECK FAIL" : "CHECK OK: 每条声明连线都能在稿里找到源控件");
  if (missing.length) process.exitCode = 1;
}
`;

new Function("figma", "console", source + "\n" + probe)(createFigmaStub().figma, console);
