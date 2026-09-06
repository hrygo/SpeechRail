const ATTACK_MS = 45;
const RELEASE_MS = 110;
const SILENCE_THRESHOLD = 0.015;
const MOUTH_GAIN = 7;
const SETTLE_MS = 620;
const EMPHASIS_MS = 260;
const EMPHASIS_COOLDOWN_MS = 520;
const EMPHASIS_THRESHOLD = 0.78;

export const AVATAR_ACTIONS = Object.freeze([
  "idle",
  "thinking",
  "speaking",
  "emphasis",
  "settle",
]);

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

  function setAction(nextAction) {
    const normalized = setAvatarAction(avatarElement, nextAction);
    action = normalized;
    if (normalized !== "settle") {
      clearSettle();
    }
    if (normalized !== "emphasis") {
      clearEmphasis();
    }
    return action;
  }

  function settle() {
    clearSettle();
    clearEmphasis();
    action = setAvatarAction(avatarElement, "settle");
    settleHandle = schedule(() => {
      settleHandle = null;
      if (action === "settle") {
        action = setAvatarAction(avatarElement, "idle");
      }
    }, SETTLE_MS);
    return action;
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
    avatarElement.style.setProperty("--speech-level", "0");
    avatarElement.style.setProperty("--speech-lift", "0px");
    action = setAvatarAction(avatarElement, "idle");
  }

  return {
    dispose,
    emphasize,
    setAction,
    setPlaybackState,
    setSpeechLevel,
  };
}
