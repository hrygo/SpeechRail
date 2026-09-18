// Builds the session-closure plugin (the second design file):
//   SPEECHRAIL_SCOPE = "closures"  +  icons.js + main.js  ->  code.js
// and stages code.js + manifest.json into the user's Downloads folder so the
// Figma desktop file picker can reach them.
//
// Same sources as build.js, one scope declaration in front: the closure draft is
// not a fork of the generator, it is the same generator told to build only the
// three features' closed loops. Both plugins therefore stay in step — a screen
// fixed in one is fixed in the other.
//
// Nothing generated is written back into this folder: code.js only ever lands in
// the staging directory, so the repository holds sources and nothing else.
//
// Usage: node build-closures.js

const fs = require("fs");
const os = require("os");
const path = require("path");

const SRC_DIR = __dirname;
const STAGE_DIR = path.join(os.homedir(), "Downloads", "SpeechRail-closure-kit");

// Separate plugin id and name: two development plugins with the same name are
// indistinguishable in Plugins ▸ Development, and picking the wrong one builds
// the wrong draft.
const MANIFEST = {
  name: "SpeechRail Closure Kit",
  id: "speechrail-closure-kit-local-0001",
  api: "1.0.0",
  main: "code.js",
  editorType: ["figma"],
  networkAccess: { allowedDomains: ["none"] }
};

const code = [
  'var SPEECHRAIL_SCOPE = "closures";',
  fs.readFileSync(path.join(SRC_DIR, "icons.js"), "utf8"),
  fs.readFileSync(path.join(SRC_DIR, "main.js"), "utf8")
].join("\n");

fs.mkdirSync(STAGE_DIR, { recursive: true });
fs.writeFileSync(path.join(STAGE_DIR, "code.js"), code);
fs.writeFileSync(path.join(STAGE_DIR, "manifest.json"), JSON.stringify(MANIFEST, null, 2) + "\n");

console.log("code.js " + code.length + " bytes");
console.log("staged  " + STAGE_DIR);
