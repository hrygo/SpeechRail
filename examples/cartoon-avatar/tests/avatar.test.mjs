import test from "node:test";
import assert from "node:assert/strict";

import {
  AVATAR_ACTIONS,
  createAvatarController,
  setAvatarAction,
  speechLevel,
} from "../static/avatar.mjs";

test("avatar action presets cover the common playback states", () => {
  assert.deepEqual(AVATAR_ACTIONS, ["idle", "thinking", "speaking", "emphasis", "settle"]);
});

test("avatar controller maps playback states and clamps speech level", () => {
  const classes = new Set();
  const styles = new Map();
  const avatar = {
    classList: {
      toggle(name, force) {
        if (force) {
          classes.add(name);
        } else {
          classes.delete(name);
        }
      },
    },
    dataset: {},
    style: {
      setProperty(name, value) {
        styles.set(name, value);
      },
    },
  };
  const scheduled = [];
  const controller = createAvatarController(avatar, {
    schedule: (callback) => {
      scheduled.push(callback);
      return scheduled.length - 1;
    },
    cancel: (handle) => {
      scheduled[handle] = null;
    },
  });

  assert.equal(controller.setPlaybackState("generating"), "thinking");
  assert.equal(avatar.dataset.action, "thinking");
  assert.ok(classes.has("avatar-action-thinking"));

  assert.equal(controller.setPlaybackState("speaking"), "speaking");
  controller.setSpeechLevel(2);
  assert.equal(styles.get("--speech-level"), "1");
  assert.equal(styles.get("--speech-lift"), "-4px");

  assert.equal(controller.setPlaybackState("idle"), "settle");
  assert.equal(avatar.dataset.action, "settle");
  scheduled.at(-1)();
  assert.equal(avatar.dataset.action, "idle");
});

test("loud speaking samples trigger a bounded emphasis beat", () => {
  const classes = new Set();
  const avatar = {
    classList: {
      toggle(name, force) {
        if (force) {
          classes.add(name);
        } else {
          classes.delete(name);
        }
      },
    },
    dataset: {},
    style: { setProperty() {} },
  };
  const scheduled = [];
  const controller = createAvatarController(avatar, {
    schedule: (callback) => {
      scheduled.push(callback);
      return scheduled.length - 1;
    },
    cancel: (handle) => {
      scheduled[handle] = null;
    },
  });

  controller.setPlaybackState("speaking");
  assert.equal(controller.setSpeechLevel(0.9), "emphasis");
  assert.equal(avatar.dataset.action, "emphasis");
  scheduled.at(-1)();
  assert.equal(avatar.dataset.action, "speaking");

  scheduled.at(-1)();
  assert.equal(controller.setSpeechLevel(0.9), "emphasis");
});

test("unknown avatar actions fall back to idle", () => {
  const classes = new Set();
  const avatar = {
    classList: {
      toggle(name, force) {
        if (force) {
          classes.add(name);
        } else {
          classes.delete(name);
        }
      },
    },
    dataset: {},
  };

  assert.equal(setAvatarAction(avatar, "surprise"), "idle");
  assert.equal(avatar.dataset.action, "idle");
  assert.ok(classes.has("avatar-action-idle"));
});

test("silence maps to zero and loud input stays bounded", () => {
  assert.equal(speechLevel(new Float32Array(1024), 0, 16), 0);
  const loud = speechLevel(new Float32Array(1024).fill(2), 0, 1000);
  assert.ok(loud > 0.9 && loud <= 1);
});

test("non-finite and empty samples are safe", () => {
  assert.equal(speechLevel(new Float32Array(), 0.5, 16), 0);
  assert.equal(speechLevel(new Float32Array([Number.NaN]), 0.5, 16), 0);
  assert.equal(speechLevel(new Float32Array([Number.POSITIVE_INFINITY]), 0.5, 16), 0);
  assert.equal(speechLevel(new Float32Array([1]), Number.NaN, Number.NaN), 0);
});

test("time-based smoothing is close across 30 and 60 fps", () => {
  const loud = new Float32Array(1024).fill(0.12);
  let at30 = 0;
  let at60 = 0;
  for (let index = 0; index < 30; index += 1) {
    at30 = speechLevel(loud, at30, 1000 / 30);
  }
  for (let index = 0; index < 60; index += 1) {
    at60 = speechLevel(loud, at60, 1000 / 60);
  }
  assert.ok(Math.abs(at30 - at60) < 0.02);
});
