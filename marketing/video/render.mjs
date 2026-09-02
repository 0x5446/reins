#!/usr/bin/env node
/**
 * Cut the footage, then render the three shapes.
 *
 * Trimming happens here with ffmpeg rather than inside the composition. The
 * simulator records at whatever frame rate it manages, and asking the player
 * to skip N frames of an unknown rate is how an edit drifts a little further
 * out of sync with its captions on every take. Cutting on disk by seconds
 * makes the file itself the source of truth, and the beats are in seconds too.
 */

import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const raw = join(here, 'raw')
const beats = JSON.parse(readFileSync(join(raw, 'beats.json'), 'utf8'))

/** Seconds of launching and list-finding to drop off the front. */
const LEAD_IN = 1.6
const start = Math.max(0, beats.opened - LEAD_IN)

const run = (file, args) => execFileSync(file, args, { stdio: 'inherit', cwd: here })

mkdirSync(join(here, 'public'), { recursive: true })
rmSync(join(here, 'public/phone.mov'), { force: true })
run('ffmpeg', [
  '-y', '-loglevel', 'error',
  '-ss', String(start), '-i', join(raw, 'phone.mov'),
  '-t', String(beats.ended - start),
  // Re-encoded rather than stream-copied: a copy cuts at the nearest keyframe,
  // which can be a second away, and a second is the difference between opening
  // on the list and opening halfway into the conversation.
  '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-an',
  join(here, 'public/phone.mov'),
])

mkdirSync(join(here, 'out'), { recursive: true })
for (const id of ['Vertical', 'Square', 'Wide']) {
  run('npx', ['remotion', 'render', id, `out/rowel-${id.toLowerCase()}.mp4`])
}
