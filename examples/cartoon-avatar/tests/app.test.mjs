import test from "node:test";
import assert from "node:assert/strict";

import { chooseVoiceForProfile, fetchAudio, formatPlaybackTime } from "../static/app.mjs";
import { AVATAR_PROFILES } from "../static/avatar.mjs";

test("fetchAudio sends only the relative speech route and a stable payload", async () => {
  const originalFetch = globalThis.fetch;
  let request;
  const signal = new AbortController().signal;
  globalThis.fetch = async (url, options) => {
    request = { url, options };
    return new Response(new Uint8Array([82, 73, 70, 70]), {
      status: 200,
      headers: { "Content-Type": "audio/wav" },
    });
  };
  try {
    const bytes = await fetchAudio({ input: "你好", voice: "demo" }, signal);
    assert.equal(request.url, "/api/speech");
    assert.equal(request.options.method, "POST");
    assert.equal(request.options.headers["Content-Type"], "application/json");
    assert.deepEqual(JSON.parse(request.options.body), { input: "你好", voice: "demo" });
    assert.equal(request.options.signal, signal);
    assert.equal(bytes.byteLength, 4);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("fetchAudio keeps an upstream code and request id without exposing its message", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({
        error: {
          code: "backend_not_ready",
          message: "private upstream diagnostic",
          request_id: "req-503",
        },
      }),
      { status: 503, headers: { "Content-Type": "application/json" } },
    );
  try {
    await assert.rejects(
      fetchAudio({ input: "你好", voice: "demo" }, new AbortController().signal),
      (error) => {
        assert.equal(error.code, "backend_not_ready");
        assert.equal(error.request_id, "req-503");
        assert.equal(error.message, "backend_not_ready");
        return true;
      },
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("fetchAudio rejects a non-WAV success before reading audio bytes", async () => {
  const originalFetch = globalThis.fetch;
  let read = false;
  globalThis.fetch = async () => ({
    ok: true,
    headers: new Headers({ "Content-Type": "application/octet-stream" }),
    arrayBuffer: async () => {
      read = true;
      return new ArrayBuffer(1);
    },
  });
  try {
    await assert.rejects(
      fetchAudio({ input: "你好", voice: "demo" }, new AbortController().signal),
      (error) => error.code === "request_failed",
    );
    assert.equal(read, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("R1 exposes three distinct character presets with stable voice bindings", () => {
  assert.equal(AVATAR_PROFILES.length, 3);
  assert.equal(new Set(AVATAR_PROFILES.map((profile) => profile.id)).size, 3);
  assert.equal(new Set(AVATAR_PROFILES.map((profile) => profile.voiceId)).size, 3);
  for (const profile of AVATAR_PROFILES) {
    assert.ok(profile.name);
    assert.ok(profile.description);
    assert.ok(profile.colors.accent);
  }
});

test("unavailable profile binding is reported instead of silently replaced", () => {
  const profile = AVATAR_PROFILES[0];
  const result = chooseVoiceForProfile(
    [{ id: "replacement", name: "替代音色", available: true, is_default: true }],
    profile.id,
    "",
  );
  assert.equal(result.voiceId, "");
  assert.equal(result.bindingAvailable, false);
  assert.equal(result.boundVoiceId, profile.voiceId);
});

test("changing to a profile with an unavailable binding asks for a fresh replacement", () => {
  const profile = AVATAR_PROFILES[0];
  const result = chooseVoiceForProfile(
    [{ id: "replacement", name: "替代音色", available: true, is_default: true }],
    profile.id,
    "replacement",
    { preservePrevious: false },
  );
  assert.equal(result.voiceId, "");
  assert.equal(result.bindingAvailable, false);
});

test("playback time formatting stays compact and predictable", () => {
  assert.equal(formatPlaybackTime(0), "00:00");
  assert.equal(formatPlaybackTime(65.8), "01:05");
  assert.equal(formatPlaybackTime(Number.NaN), "00:00");
});
