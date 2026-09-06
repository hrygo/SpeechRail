const ATTACK_MS = 45;
const RELEASE_MS = 110;
const SILENCE_THRESHOLD = 0.015;
const MOUTH_GAIN = 7;
const SETTLE_MS = 620;
const EMPHASIS_MS = 260;
const EMPHASIS_COOLDOWN_MS = 520;
const EMPHASIS_THRESHOLD = 0.78;
const WELCOME_MS = 1200;
const SMILE_MS = 900;

export const AVATAR_PROFILES = Object.freeze([
  Object.freeze({
    id: "midnight",
    name: "墨蓝讲述者",
    description: "沉稳、清晰的本地系统向导",
    voiceId: "uncle_fu",
    hair: "short",
    clothes: "blazer",
    accessory: "glasses",
    colors: Object.freeze({
      skin: "#f1c6a5",
      skinShadow: "#d89574",
      hair: "#23364d",
      hairHighlight: "#4c6d8f",
      clothes: "#18343a",
      clothesAccent: "#1e8f88",
      shirt: "#fff8ed",
      accessory: "#126c6a",
      accent: "#1e8f88",
    }),
  }),
  Object.freeze({
    id: "coral",
    name: "珊瑚向导",
    description: "明亮、亲切的日常播报员",
    voiceId: "vivian",
    hair: "bob",
    clothes: "hoodie",
    accessory: "star",
    colors: Object.freeze({
      skin: "#f4c4a8",
      skinShadow: "#d98e78",
      hair: "#6b3044",
      hairHighlight: "#c96875",
      clothes: "#b94d62",
      clothesAccent: "#f39b65",
      shirt: "#fff1e8",
      accessory: "#f39b65",
      accent: "#c6576f",
    }),
  }),
  Object.freeze({
    id: "mint",
    name: "薄荷向导",
    description: "轻快、友好的知识播报员",
    voiceId: "serena",
    hair: "wave",
    clothes: "sweater",
    accessory: "none",
    colors: Object.freeze({
      skin: "#dcae8f",
      skinShadow: "#bd785f",
      hair: "#274e4b",
      hairHighlight: "#5fa59a",
      clothes: "#3c8f83",
      clothesAccent: "#f2c35b",
      shirt: "#f5fff7",
      accessory: "#f2c35b",
      accent: "#2b8b7d",
    }),
  }),
]);

export const AVATAR_ACTIONS = Object.freeze([
  "idle",
  "welcome",
  "thinking",
  "speaking",
  "smile",
  "emphasis",
  "settle",
]);

export function getAvatarProfile(profileId) {
  return AVATAR_PROFILES.find((profile) => profile.id === profileId) ?? AVATAR_PROFILES[0];
}

function cssVariableName(name) {
  return `--avatar-${name.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`;
}

export function renderAvatarProfile(avatarElement, profileOrId) {
  const profile =
    typeof profileOrId === "string"
      ? getAvatarProfile(profileOrId)
      : getAvatarProfile(profileOrId?.id);
  avatarElement.dataset.profile = profile.id;
  avatarElement.dataset.hair = profile.hair;
  avatarElement.dataset.clothes = profile.clothes;
  avatarElement.dataset.accessory = profile.accessory;
  avatarElement.dataset.voiceId = profile.voiceId;
  for (const [name, value] of Object.entries(profile.colors)) {
    avatarElement.style.setProperty(cssVariableName(name), value);
  }
  return profile.id;
}

function clamp(value, lower, upper) {
  return Math.max(lower, Math.min(upper, value));
}

/**
 * Convert analyser samples into a frame-rate-independent speech intensity.
 * Non-finite samples return silence instead of allowing an invalid value to
 * reach the avatar animation CSS variables.
 */
export function speechLevel(samples, previous, deltaMs) {
  if (!(samples instanceof Float32Array) || samples.length === 0) {
    return 0;
  }
  let sumSquares = 0;
  for (const sample of samples) {
    if (!Number.isFinite(sample)) {
      return 0;
    }
    sumSquares += sample * sample;
  }
  const rms = Math.sqrt(sumSquares / samples.length);
  const target = clamp((rms - SILENCE_THRESHOLD) * MOUTH_GAIN, 0, 1);
  const prior = Number.isFinite(previous) ? clamp(previous, 0, 1) : 0;
  const elapsed = Number.isFinite(deltaMs) ? clamp(deltaMs, 0, 1000) : 0;
  const tau = target >= prior ? ATTACK_MS : RELEASE_MS;
  const alpha = 1 - Math.exp(-elapsed / tau);
  const value = prior + (target - prior) * alpha;
  return value < 0.01 ? 0 : clamp(value, 0, 1);
}

function normalizeAction(action) {
  return typeof action === "string" && AVATAR_ACTIONS.includes(action) ? action : "idle";
}

function formatPixels(value) {
  return `${Number.isInteger(value) ? value : value.toFixed(2)}px`;
}

export function setAvatarAction(avatarElement, action) {
  const nextAction = normalizeAction(action);
  for (const availableAction of AVATAR_ACTIONS) {
    avatarElement.classList.toggle(`avatar-action-${availableAction}`, availableAction === nextAction);
  }
  avatarElement.dataset.action = nextAction;
  return nextAction;
}

export function createAvatarController(
  avatarElement,
  { schedule = globalThis.setTimeout, cancel = globalThis.clearTimeout } = {},
) {
  let action = setAvatarAction(avatarElement, "idle");
  let settleHandle = null;
  let emphasisHandle = null;
  let emphasisCooldownHandle = null;
  let transientHandle = null;

  function cancelHandle(handle) {
    if (handle !== null) {
      cancel(handle);
    }
    return null;
  }

  function clearSettle() {
    settleHandle = cancelHandle(settleHandle);
  }

  function clearEmphasis() {
    emphasisHandle = cancelHandle(emphasisHandle);
    emphasisCooldownHandle = cancelHandle(emphasisCooldownHandle);
  }

  function clearTransient() {
    transientHandle = cancelHandle(transientHandle);
  }

  function setAction(nextAction) {
    const normalized = setAvatarAction(avatarElement, nextAction);
    action = normalized;
    if (normalized !== "settle") {
      clearSettle();
    }
    if (normalized !== "emphasis") {
      clearEmphasis();
    }
    if (normalized !== "welcome" && normalized !== "smile") {
      clearTransient();
    }
    return action;
  }

  function settle() {
    clearSettle();
    clearEmphasis();
    clearTransient();
    action = setAvatarAction(avatarElement, "settle");
    settleHandle = schedule(() => {
      settleHandle = null;
      if (action === "settle") {
        action = setAvatarAction(avatarElement, "idle");
      }
    }, SETTLE_MS);
    return action;
  }

  function showTransient(nextAction, duration) {
    clearSettle();
    clearEmphasis();
    clearTransient();
    action = setAvatarAction(avatarElement, nextAction);
    transientHandle = schedule(() => {
      transientHandle = null;
      if (action === nextAction) {
        settle();
      }
    }, duration);
    return action;
  }

  function welcome() {
    return showTransient("welcome", WELCOME_MS);
  }

  function smile() {
    return showTransient("smile", SMILE_MS);
  }

  function emphasize() {
    if (action !== "speaking" || emphasisHandle !== null || emphasisCooldownHandle !== null) {
      return action;
    }
    action = setAvatarAction(avatarElement, "emphasis");
    emphasisHandle = schedule(() => {
      emphasisHandle = null;
      if (action === "emphasis") {
        action = setAvatarAction(avatarElement, "speaking");
        emphasisCooldownHandle = schedule(() => {
          emphasisCooldownHandle = null;
        }, EMPHASIS_COOLDOWN_MS);
      }
    }, EMPHASIS_MS);
    return action;
  }

  function setPlaybackState(playbackState) {
    if (playbackState === "generating") {
      return setAction("thinking");
    }
    if (playbackState === "speaking") {
      return setAction("speaking");
    }
    if (playbackState === "idle" || playbackState === "error") {
      return settle();
    }
    return setAction("idle");
  }

  function setSpeechLevel(level) {
    const value = Number.isFinite(level) ? clamp(level, 0, 1) : 0;
    avatarElement.style.setProperty("--speech-level", String(value));
    avatarElement.style.setProperty("--speech-lift", formatPixels(-4 * value));
    return value >= EMPHASIS_THRESHOLD ? emphasize() : action;
  }

  function dispose() {
    clearSettle();
    clearEmphasis();
    clearTransient();
    avatarElement.style.setProperty("--speech-level", "0");
    avatarElement.style.setProperty("--speech-lift", "0px");
    action = setAvatarAction(avatarElement, "idle");
  }

  return {
    dispose,
    emphasize,
    smile,
    setAction,
    setPlaybackState,
    setSpeechLevel,
    welcome,
  };
}
