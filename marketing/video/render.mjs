#!/usr/bin/env node
/**
 * Cut the footage, then render the three shapes.
 *
 * Two segments joined, not one trim. The recording holds a notification at the
 * front and the conversation at the back, and between them ten seconds of a
 * test runner installing an app — real, and nothing anybody needs to watch. So
 * the cut is: how you found out, then what you did about it.
 *
 * Trimming happens here with ffmpeg rather than inside the composition. The
 * simulator records at whatever frame rate it manages, and asking the player to
 * skip N frames of an unknown rate drifts a little further out of sync with the
 * captions on every take. Cutting on disk by seconds makes the file the source
 * of truth, and the beats are in seconds too.
 *
 * What the edit reads is `public/beats.json`, written here: the same beats
 * moved onto the joined timeline. `raw/beats.json` stays as the recording said
 * it happened.
 */

import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const raw = join(here, 'raw')
const beats = JSON.parse(readFileSync(join(raw, 'beats.json'), 'utf8'))

/**
 * A constant-rate copy of the recording, made once before anything is cut.
 *
 * The simulator records at a variable rate — it emits a frame when something
 * changes and nothing when nothing does — and cutting that by time does not
 * give you the seconds you asked for. Asking for 4.6 seconds returned 1.5, and
 * asking for 19 returned 9.7, which is not even a constant error to correct
 * for. Normalised first, every `-t` below means what it says.
 */
const source = join(here, 'public/source.mp4')

/** Seconds of home screen before the notification lands. */
const BEFORE_NOTICE = 1.0
/** How long to stay on the banner before cutting away. */
const NOTICE_HELD = 3.6
/** Seconds of the list before the conversation opens. */
const LEAD_IN = 1.6

const run = (file, args) => execFileSync(file, args, { stdio: 'inherit', cwd: here })

/** One `-ss`/`-t` extraction, re-encoded so the cut lands where it was asked to. */
function cut(from, seconds, out) {
  run('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-ss', String(from), '-i', source,
    '-t', String(seconds),
    // Re-encoded rather than stream-copied: a copy cuts at the nearest
    // keyframe, which can be a second away, and a second is the difference
    // between opening on the banner and opening after it.
    '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-an',
    out,
  ])
}

mkdirSync(join(here, 'public'), { recursive: true })
run('ffmpeg', [
  '-y', '-loglevel', 'error', '-i', join(raw, 'phone.mov'),
  '-vf', 'fps=30', '-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast', '-an',
  source,
])

const parts = []
const timeline = {}
let played = 0

const hasNotice = typeof beats.notified === 'number'
if (hasNotice) {
  const from = Math.max(0, beats.notified - BEFORE_NOTICE)
  const length = beats.notified - from + NOTICE_HELD
  const part = join(here, 'public/part-notice.mp4')
  cut(from, length, part)
  parts.push(part)
  timeline.notified = beats.notified - from
  played += length
}

{
  const from = Math.max(0, beats.opened - LEAD_IN)
  const length = beats.ended - from
  const part = join(here, 'public/part-session.mp4')
  cut(from, length, part)
  parts.push(part)
  for (const name of ['opened', 'asked', 'allowed', 'ended']) {
    if (typeof beats[name] === 'number') timeline[name] = played + (beats[name] - from)
  }
  played += length
}

// Concatenated through a list file: the parts were encoded identically a moment
// ago, so there is nothing to reconcile and no reason to encode a third time.
const list = join(here, 'public/parts.txt')
writeFileSync(list, parts.map(p => `file '${p}'`).join('\n') + '\n')
rmSync(join(here, 'public/phone.mp4'), { force: true })
run('ffmpeg', [
  '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', list,
  '-c', 'copy', join(here, 'public/phone.mp4'),
])
for (const part of [...parts, list, source]) rmSync(part, { force: true })

timeline.duration = played
writeFileSync(join(here, 'public/beats.json'), `${JSON.stringify(timeline, null, 2)}\n`)

mkdirSync(join(here, 'out'), { recursive: true })
for (const id of ['Vertical', 'Square', 'Wide']) {
  run('npx', ['remotion', 'render', id, `out/rowel-${id.toLowerCase()}.mp4`])
}
