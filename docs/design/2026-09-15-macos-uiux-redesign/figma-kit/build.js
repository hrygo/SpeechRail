// Builds the Figma development plugin:
//   icons.js + main.js  ->  code.js
// and stages code.js + manifest.json into the user's Downloads folder so the
// Figma desktop file picker can reach them.
//
// Nothing generated is written back into this folder: code.js only ever lands in
// the staging directory, so the repository holds sources and nothing else.
//
// Usage: node build.js

const fs = require("fs");
const os = require("os");
const path = require("path");

const SRC_DIR = __dirname;
const STAGE_DIR = path.join(os.homedir(), "Downloads", "SpeechRail-figma-kit");

const code = [path.join(SRC_DIR, "icons.js"), path.join(SRC_DIR, "main.js")]
  .map(function (file) { return fs.readFileSync(file, "utf8"); })
  .join("\n");

fs.mkdirSync(STAGE_DIR, { recursive: true });
fs.writeFileSync(path.join(STAGE_DIR, "code.js"), code);
fs.copyFileSync(path.join(SRC_DIR, "manifest.json"), path.join(STAGE_DIR, "manifest.json"));

console.log("code.js " + code.length + " bytes");
console.log("staged  " + STAGE_DIR);
