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
const numberUses = collect(/N\["([^"]+)"\]/g);

// Icons are referenced four ways: icon(parent, "name", px, color),
// iconButton(parent, "name", side), the icon argument of
// primaryButton/secondaryButton(parent, "label", "name"), and object literals /
// table rows ({ icon: "check", … }).
const iconUses = new Map();
merge(iconUses, collect(/\bicon\([^,()]+,\s*"([^"]+)"/g));
merge(iconUses, collect(/\biconButton\([^,()]+,\s*"([^"]+)"/g));
merge(iconUses, collect(/\b(?:primary|secondary)Button\([^,()]+,\s*"[^"]*",\s*"([^"]+)"/g));
merge(iconUses, collect(/\bicon:\s*"([^"]+)"/g));

// text(name, chars, "Style / Name", colorVar, opts): the style is the third
// positional argument, and `chars` is either a literal (sometimes concatenated)
// or a variable.
const styleUses = new Map();
merge(styleUses, collect(/text\(\s*"[^"]*",\s*"(?:[^"\\]|\\.)*"(?:\s*\+\s*"[^"]*")*\s*,\s*"([^"]+)"/g));
merge(styleUses, collect(/text\(\s*"[^"]*",\s*[A-Za-z_$][A-Za-z0-9_$.]*\s*,\s*"([^"]+)"/g));

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

if (numberUses.size === 0) {
  console.log(
    `\n== number variables: ${numberTokens.size} defined, 0 referenced by name`
      + "\n   (spacing/radius/size values are written as literals at the call sites,"
      + " by design — nothing to resolve)"
  );
} else {
  bad += report("number variables", numberUses, numberTokens);
}

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
