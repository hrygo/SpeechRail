import assert from "node:assert/strict";
import test from "node:test";

import OpenAI, { toFile } from "openai";

test("official OpenAI Node SDK encodes native diarization multipart fields", async () => {
  let multipart;
  const client = new OpenAI({
    apiKey: "local",
    baseURL: "http://speechrail.test/v1",
    fetch: async (_input, init) => {
      multipart = await new Response(init.body).formData();
      return Response.json({
        task: "transcribe",
        duration: 1,
        text: "hello",
        segments: [],
      });
    },
  });

  const result = await client.audio.transcriptions.create({
    model: "gpt-4o-transcribe-diarize",
    file: await toFile(Buffer.from([0, 1]), "clip.wav"),
    response_format: "diarized_json",
    chunking_strategy: { type: "server_vad" },
  });

  assert.equal(multipart.get("model"), "gpt-4o-transcribe-diarize");
  assert.equal(multipart.get("response_format"), "diarized_json");
  assert.equal(multipart.get("chunking_strategy[type]"), "server_vad");
  assert.equal(multipart.get("file").name, "clip.wav");
  assert.equal(result.text, "hello");
});

// The event field names are the SDK's own contract, not this server's naming:
// `segment_id` on a delta, `id` on a segment.  The Python SDK test proves the
// server emits them; this one proves the official Node SDK reads the association
// a diarized consumer needs to reassemble the transcript by speaker.
test("official OpenAI Node SDK reads the diarized delta/segment association", async () => {
  const frames = [
    { type: "transcript.text.delta", delta: "\u4f60\u597d", segment_id: "seg_0" },
    {
      type: "transcript.text.segment",
      id: "seg_0",
      start: 0,
      end: 500,
      text: "\u4f60\u597d",
      speaker: "A",
    },
    { type: "transcript.text.delta", delta: "\u4e16\u754c", segment_id: "seg_1" },
    {
      type: "transcript.text.segment",
      id: "seg_1",
      start: 500,
      end: 1000,
      text: "\u4e16\u754c",
      speaker: "B",
    },
    { type: "transcript.text.done", text: "\u4f60\u597d \u4e16\u754c" },
  ];
  const body = frames.map((frame) => `data: ${JSON.stringify(frame)}\n\n`).join("");

  const client = new OpenAI({
    apiKey: "local",
    baseURL: "http://speechrail.test/v1",
    fetch: async () =>
      new Response(body, { headers: { "content-type": "text/event-stream" } }),
  });

  const stream = await client.audio.transcriptions.create({
    model: "gpt-4o-transcribe-diarize",
    file: await toFile(Buffer.from([0, 1]), "clip.wav"),
    response_format: "diarized_json",
    stream: true,
  });

  const events = [];
  for await (const event of stream) {
    events.push(event);
  }

  const deltas = events.filter((event) => event.type === "transcript.text.delta");
  const segments = events.filter((event) => event.type === "transcript.text.segment");
  assert.deepEqual(
    deltas.map((event) => event.segment_id),
    segments.map((event) => event.id),
  );
  assert.equal(new Set(deltas.map((event) => event.segment_id)).size, 2);
  assert.equal(segments.map((event) => event.speaker).join(""), "AB");
});
