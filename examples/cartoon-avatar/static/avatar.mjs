const ATTACK_MS = 45;
const RELEASE_MS = 110;
const SILENCE_THRESHOLD = 0.015;
const MOUTH_GAIN = 7;

function clamp(value, lower, upper) {
  return Math.max(lower, Math.min(upper, value));
}

/**
 * Convert analyser samples into a frame-rate-independent mouth opening level.
 * Non-finite samples close the mouth instead of allowing an invalid value to
 * reach the SVG attributes.
 */
export function mouthLevel(samples, previous, deltaMs) {
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

export function renderMouth(mouthElement, level) {
  const value = Number.isFinite(level) ? clamp(level, 0, 1) : 0;
  mouthElement.setAttribute("ry", String(2 + 14 * value));
  mouthElement.setAttribute("rx", String(10 + 4 * value));
}
