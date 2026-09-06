const ZERO_SAMPLES = new Float32Array(0);
const ERROR_MESSAGES = Object.freeze({
  audio_unavailable: "浏览器当前无法播放音频，请检查音频权限后重试。",
  audio_decode_failed: "音频格式无法解码，请再次点击播报。",
  request_failed: "语音请求失败，请检查 SpeechRail 后重试。",
});

function defaultMakeContext() {
  const Context = globalThis.AudioContext ?? globalThis.webkitAudioContext;
  if (typeof Context !== "function") {
    throw new Error("AudioContext is unavailable");
  }
  return new Context();
}

function defaultScheduleFrame(callback) {
  if (typeof globalThis.requestAnimationFrame === "function") {
    return globalThis.requestAnimationFrame(callback);
  }
  return globalThis.setTimeout(() => callback(globalThis.performance?.now?.() ?? Date.now()), 16);
}

function defaultCancelFrame(frame) {
  if (typeof globalThis.cancelAnimationFrame === "function") {
    globalThis.cancelAnimationFrame(frame);
  } else {
    globalThis.clearTimeout(frame);
  }
}

function isCurrent(token, source, activeSource) {
  return token === activeSource.generation && source === activeSource.source;
}

function errorWithCode(code, requestError) {
  const requestId =
    requestError && typeof requestError.request_id === "string"
      ? requestError.request_id
      : undefined;
  const upstreamCode =
    requestError && typeof requestError.code === "string" && requestError.code !== code
      ? requestError.code
      : undefined;
  return {
    code,
    message: ERROR_MESSAGES[code] ?? ERROR_MESSAGES.request_failed,
    ...(requestId ? { request_id: requestId } : {}),
    ...(upstreamCode ? { upstream_code: upstreamCode } : {}),
  };
}

/**
 * Create a browser-independent controller for fetching, decoding and playing
 * one complete WAV response at a time.
 */
export function createPlayer({
  fetchAudio,
  makeContext = defaultMakeContext,
  onState = () => {},
  onLevel = () => {},
  scheduleFrame = defaultScheduleFrame,
  cancelFrame = defaultCancelFrame,
}) {
  let context = null;
  let currentController = null;
  let activeSource = null;
  let activeAnalyser = null;
  let activeFrame = null;
  let activeSamples = null;
  let lastFrameTime = null;
  let generation = 0;
  let disposed = false;

  function emitLevelZero() {
    onLevel(ZERO_SAMPLES, 0);
  }

  function cancelMeter() {
    if (activeFrame !== null) {
      cancelFrame(activeFrame);
      activeFrame = null;
    }
    lastFrameTime = null;
  }

  function cleanupAudio({ stopSource = true, notifyZero = true } = {}) {
    const source = activeSource;
    const analyser = activeAnalyser;
    activeSource = null;
    activeAnalyser = null;
    activeSamples = null;
    cancelMeter();

    if (source) {
      if (stopSource) {
        try {
          source.stop();
        } catch {
          // Stopping an already-ended source is harmless for this controller.
        }
      }
      try {
        source.disconnect();
      } catch {
        // Some test doubles and browsers can already have disconnected nodes.
      }
      source.onended = null;
    }
    if (analyser) {
      try {
        analyser.disconnect();
      } catch {
        // The node may have been disconnected by the browser during teardown.
      }
    }
    if (notifyZero) {
      emitLevelZero();
    }
  }

  function failCurrent(token, code, cause) {
    if (token !== generation) {
      return;
    }
    cleanupAudio();
    onState("error", errorWithCode(code, cause));
  }

  function startMeter(token, source, analyser) {
    const active = { generation: token, source };
    const frame = (timestamp) => {
      if (!isCurrent(token, source, active) || analyser !== activeAnalyser || !activeSamples) {
        return;
      }
      const now = Number.isFinite(timestamp) ? timestamp : Date.now();
      const deltaMs = lastFrameTime === null ? 16 : Math.max(0, Math.min(1000, now - lastFrameTime));
      lastFrameTime = now;
      try {
        analyser.getFloatTimeDomainData(activeSamples);
        onLevel(activeSamples, deltaMs);
      } catch (error) {
        failCurrent(token, "audio_unavailable", error);
        return;
      }
      if (isCurrent(token, source, active)) {
        activeFrame = scheduleFrame(frame);
      }
    };
    activeFrame = scheduleFrame(frame);
  }

  function finishNaturally(token, source) {
    if (token !== generation || source !== activeSource) {
      return;
    }
    cleanupAudio({ stopSource: false });
    onState("idle");
  }

  async function speak({ input, voice }) {
    const token = ++generation;
    if (currentController) {
      currentController.abort();
      currentController = null;
    }
    cleanupAudio();

    if (disposed) {
      onState("error", errorWithCode("audio_unavailable"));
      return;
    }
    if (typeof input !== "string" || typeof voice !== "string") {
      onState("error", errorWithCode("request_failed"));
      return;
    }

    const controller = new AbortController();
    currentController = controller;
    onState("generating");
    let stage = "resume";
    try {
      if (!context || context.state === "closed") {
        context = makeContext();
      }
      await context.resume();
      if (token !== generation) {
        return;
      }
      if (context.state !== undefined && context.state !== "running") {
        failCurrent(token, "audio_unavailable");
        return;
      }

      stage = "fetch";
      const bytes = await fetchAudio({ input, voice }, controller.signal);
      if (token !== generation) {
        return;
      }

      stage = "decode";
      const buffer = await context.decodeAudioData(bytes);
      if (token !== generation) {
        return;
      }
      if (context.state !== undefined && context.state !== "running") {
        failCurrent(token, "audio_unavailable");
        return;
      }

      stage = "connect";
      const source = context.createBufferSource();
      let analyser;
      try {
        analyser = context.createAnalyser();
      } catch (error) {
        try {
          source.disconnect();
        } catch {
          // The source may not have been connected yet.
        }
        throw error;
      }
      activeSource = source;
      activeAnalyser = analyser;
      analyser.fftSize = 1024;
      activeSamples = new Float32Array(analyser.fftSize);
      source.buffer = buffer;
      source.connect(analyser);
      analyser.connect(context.destination);
      source.onended = () => finishNaturally(token, source);

      stage = "start";
      source.start();
      if (token !== generation) {
        cleanupAudio();
        return;
      }
      onState("speaking");
      startMeter(token, source, analyser);
    } catch (error) {
      if (token !== generation) {
        return;
      }
      const code =
        stage === "resume" || stage === "connect" || stage === "start"
          ? "audio_unavailable"
          : stage === "decode"
            ? "audio_decode_failed"
            : "request_failed";
      failCurrent(token, code, error);
    } finally {
      if (currentController === controller) {
        currentController = null;
      }
    }
  }

  function stop() {
    generation += 1;
    if (currentController) {
      currentController.abort();
      currentController = null;
    }
    cleanupAudio();
    onState("idle");
  }

  async function dispose() {
    if (disposed) {
      return;
    }
    disposed = true;
    generation += 1;
    if (currentController) {
      currentController.abort();
      currentController = null;
    }
    cleanupAudio();
    onState("idle");
    const oldContext = context;
    context = null;
    if (oldContext) {
      try {
        await oldContext.close();
      } catch {
        // Closing is best-effort when a page is already being torn down.
      }
    }
  }

  return { speak, stop, dispose };
}
