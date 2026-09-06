import test from "node:test";
import assert from "node:assert/strict";

import { createPlayer } from "../static/player.mjs";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

class FakeSource {
  constructor(context) {
    this.context = context;
    this.buffer = null;
    this.onended = null;
    this.started = 0;
    this.stopped = 0;
    this.disconnected = 0;
    this.connections = [];
  }

  connect(node) {
    this.connections.push(node);
  }

  start() {
    this.started += 1;
  }

  stop() {
    this.stopped += 1;
  }

  disconnect() {
    this.disconnected += 1;
  }
}

class FakeAnalyser {
  constructor() {
    this.fftSize = 0;
    this.disconnected = 0;
    this.connections = [];
  }

  connect(node) {
    this.connections.push(node);
  }

  disconnect() {
    this.disconnected += 1;
  }

  getFloatTimeDomainData(samples) {
    samples.fill(0);
  }
}

class FakeContext {
  constructor({ resume, decodeAudioData } = {}) {
    this.state = "suspended";
    this.currentTime = 0;
    this.destination = { kind: "destination" };
    this.sources = [];
    this.analysers = [];
    this.closed = 0;
    this.resumeBehavior = resume;
    this.decodeBehavior = decodeAudioData;
  }

  async resume() {
    if (this.resumeBehavior) {
      await this.resumeBehavior(this);
      return;
    }
    this.state = "running";
  }

  async decodeAudioData(bytes) {
    if (this.decodeBehavior) {
      return this.decodeBehavior(bytes, this);
    }
    return { duration: 0.01 };
  }

  createBufferSource() {
    const source = new FakeSource(this);
    this.sources.push(source);
    return source;
  }

  createAnalyser() {
    const analyser = new FakeAnalyser();
    this.analysers.push(analyser);
    return analyser;
  }

  async close() {
    this.closed += 1;
    this.state = "closed";
  }
}

function makeHarness(options = {}) {
  const context = options.context ?? new FakeContext(options);
  const audio = deferred();
  const fetchStarted = deferred();
  const states = [];
  const levels = [];
  const progress = [];
  const frames = [];
  const cancelledFrames = [];
  const fetchImplementation = options.fetchAudio ?? (() => audio.promise);
  const player = createPlayer({
    fetchAudio: async (...args) => {
      fetchStarted.resolve(args);
      return fetchImplementation(...args);
    },
    makeContext: () => context,
    onState: (state, error) => states.push({ state, error }),
    onLevel: (samples, deltaMs) => levels.push({ samples, deltaMs }),
    onProgress: (elapsed, duration) => progress.push({ elapsed, duration }),
    scheduleFrame: (callback) => {
      frames.push(callback);
      return callback;
    },
    cancelFrame: (frame) => cancelledFrames.push(frame),
  });
  return {
    player,
    context,
    fetchStarted: fetchStarted.promise,
    resolveAudio: audio.resolve,
    get starts() {
      return context.sources.reduce((total, source) => total + source.started, 0);
    },
    states,
    levels,
    progress,
    frames,
    cancelledFrames,
    runFrame(timestamp = 16) {
      const frame = frames.at(-1);
      assert.ok(frame);
      frame(timestamp);
    },
  };
}

test("stopped request cannot start a late audio response", async () => {
  const h = makeHarness();
  const pending = h.player.speak({ input: "你好", voice: "demo" });
  await h.fetchStarted;
  h.player.stop();
  h.resolveAudio(new ArrayBuffer(48));
  await pending;
  assert.equal(h.starts, 0);
  assert.equal(h.states.at(-1).state, "idle");
});

test("stopped decode cannot create a source", async () => {
  const decoded = deferred();
  const h = makeHarness({ decodeAudioData: () => decoded.promise });
  const pending = h.player.speak({ input: "你好", voice: "demo" });
  await h.fetchStarted;
  h.resolveAudio(new ArrayBuffer(48));
  await Promise.resolve();
  h.player.stop();
  decoded.resolve({ duration: 0.01 });
  await pending;
  assert.equal(h.starts, 0);
  assert.equal(h.states.at(-1).state, "idle");
});

test("a late error from an old request cannot replace the new speaking state", async () => {
  const firstFetch = deferred();
  const secondFetch = deferred();
  let calls = 0;
  const h = makeHarness({
    fetchAudio: () => {
      calls += 1;
      return calls === 1 ? firstFetch.promise : secondFetch.promise;
    },
  });
  const first = h.player.speak({ input: "第一段", voice: "demo" });
  await h.fetchStarted;
  const second = h.player.speak({ input: "第二段", voice: "demo" });
  await new Promise((resolve) => setImmediate(resolve));
  secondFetch.resolve(new ArrayBuffer(48));
  await second;
  assert.equal(h.states.at(-1).state, "speaking");
  firstFetch.reject(new Error("late network failure"));
  await first;
  assert.equal(h.states.at(-1).state, "speaking");
  h.player.stop();
});

test("source connects through the analyser and samples only while speaking", async () => {
  const h = makeHarness();
  const pending = h.player.speak({ input: "你好", voice: "demo" });
  await h.fetchStarted;
  h.resolveAudio(new ArrayBuffer(48));
  await pending;

  const source = h.context.sources[0];
  const analyser = h.context.analysers[0];
  assert.equal(source.connections[0], analyser);
  assert.equal(analyser.connections[0], h.context.destination);
  assert.equal(analyser.fftSize, 1024);
  assert.equal(h.states.at(-1).state, "speaking");
  h.runFrame(100);
  assert.equal(h.levels.at(-1).samples.length, 1024);
  assert.equal(h.levels.at(-1).deltaMs, 16);
  h.player.stop();
  assert.equal(h.levels.at(-1).samples.length, 0);
  assert.ok(h.cancelledFrames.length >= 1);
  assert.equal(source.disconnected, 1);
  assert.equal(analyser.disconnected, 1);
});

test("natural end cleans the source and leaves the mouth closed", async () => {
  const h = makeHarness();
  const pending = h.player.speak({ input: "你好", voice: "demo" });
  await h.fetchStarted;
  h.resolveAudio(new ArrayBuffer(48));
  await pending;
  const source = h.context.sources[0];
  source.onended();
  assert.equal(h.states.at(-1).state, "idle");
  assert.equal(h.levels.at(-1).samples.length, 0);
  assert.equal(source.stopped, 0);
  assert.equal(source.disconnected, 1);
});

test("reports playback progress from the decoded buffer and closes at its duration", async () => {
  const h = makeHarness();
  const pending = h.player.speak({ input: "你好", voice: "demo" });
  await h.fetchStarted;
  h.resolveAudio(new ArrayBuffer(48));
  await pending;

  assert.deepEqual(h.progress.at(-1), { elapsed: 0, duration: 0.01 });
  h.context.currentTime = 0.006;
  h.runFrame(100);
  assert.ok(h.progress.at(-1).elapsed > 0);
  assert.equal(h.progress.at(-1).duration, 0.01);

  h.context.sources[0].onended();
  assert.deepEqual(h.progress.at(-1), { elapsed: 0.01, duration: 0.01 });
});

test("a late old onended callback cannot stop a newer source", async () => {
  const h = makeHarness();
  const first = h.player.speak({ input: "第一段", voice: "demo" });
  await h.fetchStarted;
  h.resolveAudio(new ArrayBuffer(48));
  await first;
  const oldSource = h.context.sources[0];
  const oldEnded = oldSource.onended;

  const second = h.player.speak({ input: "第二段", voice: "demo" });
  await new Promise((resolve) => setImmediate(resolve));
  h.resolveAudio(new ArrayBuffer(48));
  await second;
  const newSource = h.context.sources[1];
  oldEnded();
  assert.equal(h.states.at(-1).state, "speaking");
  assert.equal(newSource.stopped, 0);
});

test("stop is idempotent and dispose closes the context", async () => {
  const h = makeHarness();
  const pending = h.player.speak({ input: "你好", voice: "demo" });
  await h.fetchStarted;
  h.resolveAudio(new ArrayBuffer(48));
  await pending;
  const source = h.context.sources[0];
  h.player.stop();
  h.player.stop();
  await h.player.dispose();
  await h.player.dispose();
  assert.equal(source.stopped, 1);
  assert.equal(h.context.closed, 1);
  assert.equal(h.states.at(-1).state, "idle");
});

test("resume failure reports audio unavailable without fetching", async () => {
  let fetches = 0;
  const context = new FakeContext({
    resume: async () => {
      throw new Error("gesture required");
    },
  });
  const h = makeHarness({
    context,
    fetchAudio: async () => {
      fetches += 1;
      return new ArrayBuffer(48);
    },
  });
  await h.player.speak({ input: "你好", voice: "demo" });
  assert.equal(fetches, 0);
  assert.equal(h.starts, 0);
  assert.equal(h.states.at(-1).state, "error");
  assert.equal(h.states.at(-1).error.code, "audio_unavailable");
});

test("a suspended context after decode does not show speaking", async () => {
  const context = new FakeContext({
    resume: async (current) => {
      current.state = "running";
    },
    decodeAudioData: async (_, current) => {
      current.state = "interrupted";
      return { duration: 0.01 };
    },
  });
  const h = makeHarness({ context });
  const pending = h.player.speak({ input: "你好", voice: "demo" });
  await h.fetchStarted;
  h.resolveAudio(new ArrayBuffer(48));
  await pending;
  assert.equal(h.starts, 0);
  assert.equal(h.states.at(-1).state, "error");
  assert.equal(h.states.at(-1).error.code, "audio_unavailable");
});
