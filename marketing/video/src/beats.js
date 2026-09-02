/**
 * When things happen in the cut.
 *
 * Written by `render.mjs`, not by hand and not by the recording either: the
 * recording's own beats live in `raw/beats.json` and describe the take, which
 * has ten seconds in the middle where a test runner is installing an app. What
 * this file describes is the joined timeline the captions are placed against.
 */

import timeline from '../public/beats.json'

/**
 * Convert a beat into a frame of the edit.
 * @param {string} name - which beat.
 * @param {number} fps - frames per second of the composition.
 * @param {number} [offset] - seconds to shift by.
 * @returns {number} the frame.
 */
export function at(name, fps, offset = 0) {
  return Math.round(((timeline[name] ?? 0) + offset) * fps)
}

/** Whether a beat is in this cut at all. */
export function has(name) {
  return typeof timeline[name] === 'number'
}

/** How long the edit runs, in seconds. */
export const duration = timeline.duration

export { timeline }
