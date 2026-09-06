import { createAvatarController, speechLevel } from "./avatar.mjs";
import { createPlayer } from "./player.mjs";

const MAX_INPUT_LENGTH = 600;
const SAFE_CODE = /^[a-z][a-z0-9_.-]{0,63}$/;
const FRIENDLY_MESSAGES = Object.freeze({
  audio_unavailable: "浏览器暂停了音频，请再次点击播报。",
  audio_decode_failed: "音频格式无法解码，请再次点击播报。",
  auth_failed: "SpeechRail 鉴权失败，请检查 SPEECHRAIL_API_KEY。",
  invalid_api_key: "SpeechRail 鉴权失败，请检查 SPEECHRAIL_API_KEY。",
  authentication_error: "SpeechRail 鉴权失败，请检查 SPEECHRAIL_API_KEY。",
  backend_busy: "SpeechRail 当前繁忙，请稍后再试。",
  backend_not_ready: "SpeechRail 尚未就绪，请确认服务运行后刷新音色。",
  example_busy: "示例正在处理上一段语音，请稍后再试。",
  rate_limited: "SpeechRail 当前繁忙，请稍后再试。",
  unauthorized: "SpeechRail 鉴权失败，请检查 SPEECHRAIL_API_KEY。",
  upstream_invalid_audio: "SpeechRail 返回的音频无效，请再次尝试。",
  upstream_invalid_response: "音色目录无效，请刷新音色。",
  upstream_timeout: "SpeechRail 响应超时，请稍后再试。",
  upstream_unreachable: "无法连接 SpeechRail，请确认服务运行后刷新音色。",
  voice_not_available: "所选音色当前不可用，请刷新音色后再试。",
  request_failed: "语音请求失败，请检查 SpeechRail 后重试。",
});

function safeCode(value) {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim().toLowerCase();
  return SAFE_CODE.test(normalized) ? normalized : null;
}

function safeRequestId(value) {
  if (typeof value !== "string") {
    return undefined;
  }
  const normalized = value.trim();
  return normalized.length > 0 && normalized.length <= 128 ? normalized : undefined;
}

function clientError(code, requestId) {
  const error = new Error(code);
  error.code = code;
  const normalizedRequestId = safeRequestId(requestId);
  if (normalizedRequestId) {
    error.request_id = normalizedRequestId;
  }
  return error;
}

async function errorFromResponse(response) {
  let payload = null;
  try {
    payload = await response.json();
  } catch {
    // A non-JSON error still becomes a fixed client error below.
  }
  const upstreamError = payload && typeof payload === "object" ? payload.error : null;
  const code = upstreamError && typeof upstreamError === "object" ? safeCode(upstreamError.code) : null;
  const requestId =
    safeRequestId(response.headers.get("x-request-id")) ??
    (upstreamError && typeof upstreamError === "object"
      ? safeRequestId(upstreamError.request_id)
      : undefined);
  return clientError(code ?? "request_failed", requestId);
}

function isWavMime(value) {
  if (typeof value !== "string") {
    return false;
  }
  const mime = value.split(";", 1)[0].trim().toLowerCase();
  return mime === "audio/wav" || mime === "audio/x-wav" || mime === "audio/wave";
}

export async function fetchAudio({ input, voice }, signal) {
  let response;
  try {
    response = await fetch("/api/speech", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ input, voice }),
      signal,
    });
  } catch (error) {
    if (error && error.name === "AbortError") {
      throw error;
    }
    throw clientError("request_failed");
  }
  if (!response.ok) {
    throw await errorFromResponse(response);
  }
  const requestId = safeRequestId(response.headers.get("x-request-id"));
  if (!isWavMime(response.headers.get("content-type"))) {
    throw clientError("request_failed", requestId);
  }
  try {
    return await response.arrayBuffer();
  } catch {
    throw clientError("request_failed", requestId);
  }
}

function friendlyMessage(error) {
  const code =
    (error && safeCode(error.upstream_code)) ||
    (error && safeCode(error.code)) ||
    "request_failed";
  return FRIENDLY_MESSAGES[code] ?? FRIENDLY_MESSAGES.request_failed;
}

function createBrowserContext() {
  const Context = window.AudioContext ?? window.webkitAudioContext;
  if (typeof Context !== "function") {
    throw new Error("AudioContext is unavailable");
  }
  return new Context();
}

function initializePage() {
  const form = document.getElementById("controls");
  const input = document.getElementById("input");
  const voice = document.getElementById("voice");
  const speakButton = document.getElementById("speak");
  const stopButton = document.getElementById("stop");
  const refreshButton = document.getElementById("refresh-voices");
  const status = document.getElementById("status");
  const count = document.getElementById("char-count");
  const voiceHelp = document.getElementById("voice-help");
  const avatar = document.getElementById("avatar");
  if (
    !(form instanceof HTMLFormElement) ||
    !(input instanceof HTMLTextAreaElement) ||
    !(voice instanceof HTMLSelectElement) ||
    !(speakButton instanceof HTMLButtonElement) ||
    !(stopButton instanceof HTMLButtonElement) ||
    !(refreshButton instanceof HTMLButtonElement) ||
    !(status instanceof HTMLElement) ||
    !(count instanceof HTMLOutputElement) ||
    !(voiceHelp instanceof HTMLElement) ||
    !(avatar instanceof HTMLElement)
  ) {
    return null;
  }

  const state = {
    directory: "loading",
    voices: [],
    selectedVoice: "",
    playback: "idle",
    refreshing: false,
    voiceGeneration: 0,
    voiceAbortController: null,
    player: null,
    pageHidden: false,
    speechLevel: 0,
  };
  const avatarController = createAvatarController(avatar);

  function setStatus(message, isError = false, requestId) {
    status.replaceChildren();
    const messageNode = document.createElement("span");
    messageNode.textContent = message;
    status.append(messageNode);
    const normalizedRequestId = safeRequestId(requestId);
    if (normalizedRequestId) {
      const label = document.createElement("span");
      label.textContent = " 请求 ID：";
      const idNode = document.createElement("code");
      idNode.textContent = normalizedRequestId;
      status.append(label, idNode);
    }
    status.classList.toggle("is-error", isError);
  }

  function setSelectMessage(message) {
    voice.replaceChildren();
    const option = document.createElement("option");
    option.value = "";
    option.textContent = message;
    voice.append(option);
  }

  function updateControls() {
    const textLength = Array.from(input.value.trim()).length;
    count.textContent = `${textLength} / ${MAX_INPUT_LENGTH}`;
    input.setAttribute("aria-invalid", textLength > MAX_INPUT_LENGTH ? "true" : "false");
    const selectedVoiceIsAvailable = state.voices.some((item) => item.id === voice.value);
    const activePlayback = state.playback === "generating" || state.playback === "speaking";
    speakButton.disabled =
      state.directory !== "ready" ||
      state.refreshing ||
      activePlayback ||
      textLength < 1 ||
      textLength > MAX_INPUT_LENGTH ||
      !selectedVoiceIsAvailable;
    stopButton.disabled = !activePlayback;
    voice.disabled = state.directory !== "ready" || state.refreshing || activePlayback || !state.voices.length;
    refreshButton.disabled = state.refreshing || activePlayback;
  }

  function handlePlayerState(nextState, error) {
    state.playback = nextState;
    avatarController.setSpeechLevel(nextState === "speaking" ? state.speechLevel : 0);
    avatarController.setPlaybackState(nextState);
    if (nextState === "generating") {
      setStatus("正在生成语音");
    } else if (nextState === "speaking") {
      setStatus("正在播报");
    } else if (nextState === "error") {
      setStatus(friendlyMessage(error), true, error && error.request_id);
    } else if (nextState === "idle") {
      setStatus("已就绪，可以再次播报。");
    }
    updateControls();
  }

  function makePlayer() {
    state.speechLevel = 0;
    avatarController.setSpeechLevel(0);
    return createPlayer({
      fetchAudio,
      makeContext: createBrowserContext,
      onState: handlePlayerState,
      onLevel: (samples, deltaMs) => {
        state.speechLevel = speechLevel(samples, state.speechLevel, deltaMs);
        avatarController.setSpeechLevel(state.speechLevel);
      },
      scheduleFrame: (callback) => window.requestAnimationFrame(callback),
      cancelFrame: (frame) => window.cancelAnimationFrame(frame),
    });
  }

  function renderVoices(availableVoices, previousSelection) {
    voice.replaceChildren();
    for (const item of availableVoices) {
      const option = document.createElement("option");
      option.value = item.id;
      option.textContent = item.name;
      voice.append(option);
    }
    const preserved = availableVoices.find((item) => item.id === previousSelection);
    const defaultVoice = availableVoices.find((item) => item.is_default === true);
    state.selectedVoice = preserved?.id ?? defaultVoice?.id ?? availableVoices[0]?.id ?? "";
    voice.value = state.selectedVoice;
  }

  function normalizeVoiceList(payload) {
    if (!payload || typeof payload !== "object" || !Array.isArray(payload.data)) {
      throw clientError("upstream_invalid_response");
    }
    return payload.data
      .filter(
        (item) =>
          item &&
          typeof item === "object" &&
          item.available === true &&
          typeof item.id === "string" &&
          item.id.length > 0 &&
          item.id.length <= 200 &&
          typeof item.name === "string" &&
          item.name.length > 0 &&
          item.name.length <= 200,
      )
      .map((item) => ({
        id: item.id,
        name: item.name,
        is_default: item.is_default === true,
      }));
  }

  async function loadVoices() {
    state.voiceGeneration += 1;
    const generation = state.voiceGeneration;
    state.voiceAbortController?.abort();
    const controller = new AbortController();
    state.voiceAbortController = controller;
    const previousSelection = state.selectedVoice || voice.value;
    state.refreshing = true;
    state.directory = "loading";
    setSelectMessage("正在加载音色…");
    voiceHelp.textContent = "正在从本地 SpeechRail 读取音色目录。";
    setStatus("正在加载音色目录…");
    updateControls();

    try {
      const response = await fetch("/api/voices", {
        headers: { Accept: "application/json" },
        signal: controller.signal,
      });
      if (!response.ok) {
        throw await errorFromResponse(response);
      }
      const payload = await response.json();
      const availableVoices = normalizeVoiceList(payload);
      if (generation !== state.voiceGeneration) {
        return;
      }
      state.voices = availableVoices;
      state.directory = "ready";
      renderVoices(availableVoices, previousSelection);
      if (availableVoices.length === 0) {
        voiceHelp.textContent = "暂无可用音色，请检查 SpeechRail 后刷新。";
        setSelectMessage("暂无可用音色");
        setStatus("暂无可用音色，请检查 SpeechRail 后刷新。", true);
      } else {
        voiceHelp.textContent = "只显示当前 SpeechRail 权重实际可用的音色。";
        setStatus(`已加载 ${availableVoices.length} 个可用音色。`);
      }
    } catch (error) {
      if (generation !== state.voiceGeneration || (error && error.name === "AbortError")) {
        return;
      }
      state.voices = [];
      state.directory = "error";
      setSelectMessage("音色加载失败");
      voiceHelp.textContent = "无法加载音色目录，请确认 SpeechRail 正在运行后刷新。";
      setStatus(friendlyMessage(error), true, error && error.request_id);
    } finally {
      if (generation === state.voiceGeneration) {
        state.refreshing = false;
        state.voiceAbortController = null;
        updateControls();
      }
    }
  }

  input.addEventListener("input", updateControls);
  voice.addEventListener("change", () => {
    state.selectedVoice = voice.value;
    updateControls();
  });
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    const inputSnapshot = input.value.trim();
    const voiceSnapshot = voice.value;
    const inputLength = Array.from(inputSnapshot).length;
    if (
      speakButton.disabled ||
      inputLength < 1 ||
      inputLength > MAX_INPUT_LENGTH ||
      !state.voices.some((item) => item.id === voiceSnapshot)
    ) {
      updateControls();
      return;
    }
    void state.player.speak({ input: inputSnapshot, voice: voiceSnapshot });
  });
  stopButton.addEventListener("click", () => {
    state.player.stop();
    setStatus("已停止，可以重新播报。");
    updateControls();
  });
  refreshButton.addEventListener("click", () => {
    void loadVoices();
  });
  window.addEventListener("pagehide", () => {
    state.pageHidden = true;
    state.voiceGeneration += 1;
    state.voiceAbortController?.abort();
    state.voiceAbortController = null;
    void state.player?.dispose();
  });
  window.addEventListener("pageshow", () => {
    if (!state.pageHidden) {
      return;
    }
    state.pageHidden = false;
    state.player = makePlayer();
    setStatus("页面已恢复，请再次点击播报。");
    updateControls();
  });

  state.player = makePlayer();
  updateControls();
  void loadVoices();
  return { loadVoices, state };
}

if (typeof document !== "undefined") {
  initializePage();
}
