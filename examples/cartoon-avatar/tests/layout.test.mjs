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

test("mobile layout gives the stage and controls bounded grid rows", () => {
  assert.match(styles, /grid-template-rows:\s*minmax\(0, 1fr\) auto;/);
  assert.match(styles, /\.avatar-stage\s*\{[\s\S]*position:\s*relative;[\s\S]*flex:\s*1 1 auto;[\s\S]*min-height:\s*0;/);
  assert.match(styles, /#avatar\s*\{[\s\S]*position:\s*absolute;[\s\S]*inset:\s*0;[\s\S]*height:\s*100%;[\s\S]*max-width:\s*100%;/);
});

test("stage does not render the removed mouth-animation explanation", () => {
  assert.doesNotMatch(index, /嘴部会根据正在播放的声音幅值轻轻变化/);
  assert.doesNotMatch(index, /class=["']stage-note["']/);
});

test("stage mounts the extracted character asset and exposes an action state", () => {
  assert.match(index, /id=["']avatar["'][^>]*data-action=["']idle["']/);
  assert.match(index, /class=["']avatar-image["']/);
  assert.match(index, /src=["']\/static\/assets\/autobiography-character\.png["']/);
  assert.match(index, /alt=["']["']/);
});

test("action styles include reduced-motion fallback", () => {
  assert.match(styles, /\.avatar-action-speaking\s+\.avatar-image/);
  assert.match(styles, /\.avatar-action-thinking\s+\.avatar-image/);
  assert.match(styles, /\.avatar-action-emphasis\s+\.avatar-image/);
  assert.match(styles, /@media\s*\(prefers-reduced-motion:\s*reduce\)/);
  assert.match(styles, /\.avatar-image\s*\{[\s\S]*max-width:\s*100%;/);
});
