/**
 * When things happened in the footage.
 *
 * Written by the recording, not by hand: `Demo.swift` marks the moment it saw
 * the card and the moment it answered, `demo.sh` knows when the camera started,
 * and `beats.py` subtracts one from the other. Every caption below is placed
 * against those numbers, so a re-record moves the captions with it instead of
 * leaving them describing a frame that has moved on.
 */

import beats from '../raw/beats.json'

/** Seconds of footage to drop off the front: launching, and finding the list. */
const LEAD_IN = 1.6

/** Where the useful footage starts — a moment before the conversation opens. */
export const start = Math.max(0, beats.opened - LEAD_IN)

/**
 * Convert a beat into a frame of the edit.
 * @param {string} name - which beat.
 * @param {number} fps - frames per second of the composition.
 * @param {number} [offset] - seconds to shift by.
 * @returns {number} the frame, relative to the trimmed start.
 */
export function at(name, fps, offset = 0) {
  return Math.round((beats[name] - start + offset) * fps)
}

/** How long the edit runs, in seconds. */
export const duration = beats.ended - start

export { beats }
