import test from "node:test";
import assert from "node:assert/strict";

import { fetchAudio } from "../static/app.mjs";

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
