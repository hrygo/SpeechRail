import test from "node:test";
import assert from "node:assert/strict";

import { mouthLevel, renderMouth } from "../static/avatar.mjs";

test("silence closes the mouth and loud input stays bounded", () => {
  assert.equal(mouthLevel(new Float32Array(1024), 0, 16), 0);
  const loud = mouthLevel(new Float32Array(1024).fill(2), 0, 1000);
  assert.ok(loud > 0.9 && loud <= 1);
});

test("non-finite and empty samples are safe", () => {
  assert.equal(mouthLevel(new Float32Array(), 0.5, 16), 0);
  assert.equal(mouthLevel(new Float32Array([Number.NaN]), 0.5, 16), 0);
  assert.equal(mouthLevel(new Float32Array([Number.POSITIVE_INFINITY]), 0.5, 16), 0);
  assert.equal(mouthLevel(new Float32Array([1]), Number.NaN, Number.NaN), 0);
});

test("time-based smoothing is close across 30 and 60 fps", () => {
  const loud = new Float32Array(1024).fill(0.12);
  let at30 = 0;
  let at60 = 0;
  for (let index = 0; index < 30; index += 1) {
    at30 = mouthLevel(loud, at30, 1000 / 30);
  }
  for (let index = 0; index < 60; index += 1) {
    at60 = mouthLevel(loud, at60, 1000 / 60);
  }
  assert.ok(Math.abs(at30 - at60) < 0.02);
});

test("renderMouth clamps the SVG ellipse dimensions", () => {
  const attributes = new Map();
  const mouth = {
    setAttribute(name, value) {
      attributes.set(name, value);
    },
  };
  renderMouth(mouth, 2);
  assert.equal(attributes.get("ry"), "16");
  assert.equal(attributes.get("rx"), "14");
  renderMouth(mouth, Number.NaN);
  assert.equal(attributes.get("ry"), "2");
  assert.equal(attributes.get("rx"), "10");
});
