import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const stylesPath = fileURLToPath(new URL("../static/styles.css", import.meta.url));
const indexPath = fileURLToPath(new URL("../static/index.html", import.meta.url));
const styles = await readFile(stylesPath, "utf8");
const index = await readFile(indexPath, "utf8");

test("page layout is bounded to the viewport without page overflow", () => {
  assert.match(styles, /html,\s*body\s*\{[\s\S]*height:\s*100%;[\s\S]*overflow:\s*hidden;/);
  assert.match(styles, /\.app-shell\s*\{[\s\S]*height:\s*100dvh;[\s\S]*min-height:\s*0;/);
});

test("control panel scrolls instead of clipping R1 feedback", () => {
  assert.match(
    styles,
    /\.control-panel\s*\{\s*max-height:\s*100%;\s*overflow-x:\s*hidden;\s*overflow-y:\s*auto;/,
  );
});

test("mobile layout gives the stage and controls bounded grid rows", () => {
  assert.match(styles, /grid-template-rows:\s*clamp\(220px,\s*42dvh,\s*360px\)\s+minmax\(0, 1fr\);/);
  assert.match(styles, /\.avatar-stage\s*\{[\s\S]*position:\s*relative;[\s\S]*flex:\s*1 1 auto;[\s\S]*min-height:\s*0;/);
  assert.match(styles, /#avatar\s*\{[\s\S]*position:\s*absolute;[\s\S]*inset:\s*0;[\s\S]*height:\s*100%;[\s\S]*max-width:\s*100%;/);
});

test("mobile controls scroll inside their row instead of hiding the character stage", () => {
  assert.match(
    styles,
    /@media\s*\(max-width:\s*760px\)[\s\S]*?\.control-panel\s*\{[\s\S]*?overflow-y:\s*auto;/,
  );
});

test("medium desktop layout keeps the R1 panel compact", () => {
  assert.match(
    styles,
    /@media\s*\(min-width:\s*761px\)\s*and\s*\(max-width:\s*1000px\)[\s\S]*?\.transcript\s*\{[\s\S]*?max-height:\s*4\.4rem;/,
  );
});

test("stage does not render the removed mouth-animation explanation", () => {
  assert.doesNotMatch(index, /嘴部会根据正在播放的声音幅值轻轻变化/);
  assert.doesNotMatch(index, /class=["']stage-note["']/);
});

test("stage mounts an inline character scene and exposes an action state", () => {
  assert.match(index, /id=["']avatar["'][^>]*data-action=["']idle["']/);
  assert.match(index, /id=["']avatar-svg["']/);
  assert.match(index, /id=["']avatar-body["']/);
  assert.match(index, /id=["']mouth["']/);
  assert.doesNotMatch(index, /autobiography-character\.png/);
});

test("R1 controls expose character selection, full text and playback progress", () => {
  assert.match(index, /id=["']character["']/);
  assert.match(index, /id=["']transcript["']/);
  assert.match(index, /id=["']playback-progress["']/);
  assert.match(index, /role=["']progressbar["']/);
});

test("action styles include reduced-motion fallback", () => {
  assert.match(styles, /\.avatar-action-speaking\s+\.avatar-svg/);
  assert.match(styles, /\.avatar-action-thinking\s+\.avatar-svg/);
  assert.match(styles, /\.avatar-action-emphasis\s+\.avatar-svg/);
  assert.match(styles, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
  assert.match(styles, /\.avatar-svg\s*\{[\s\S]*max-width:\s*100%;/);
});
