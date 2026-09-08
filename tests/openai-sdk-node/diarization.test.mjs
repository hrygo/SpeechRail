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
