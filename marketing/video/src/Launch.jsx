/**
 * The edit.
 *
 * One shot, three shapes. The footage is a real recording of the app answering
 * a real permission request; everything added here is framing and words, and
 * the words are placed against the beats the recording wrote down rather than
 * against timings typed in by hand.
 *
 * The captions say what is happening rather than what to think about it. The
 * one claim the video makes — the agent was stopped, and a tap on a phone
 * started it again — is carried by the footage, so the text only has to keep
 * out of its way and name the moment.
 */

import React from 'react'
import {
  AbsoluteFill, OffthreadVideo, interpolate, staticFile,
  useCurrentFrame, useVideoConfig,
} from 'remotion'
import { at, start } from './beats.js'

const INK = '#101114'
const PAPER = '#f7f7f5'
const ACCENT = '#2f6bff'

/**
 * The captions, each pinned to the beat it belongs to.
 *
 * Only a start. Each line runs until the next one begins, and the last runs to
 * the end — because a `hold` per line is a set of numbers that have to be kept
 * consistent with each other by hand, and the first attempt at that put two
 * captions on screen at once.
 */
const LINES = [
  { beat: 'opened', offset: 0.2, text: 'Your agent stopped to ask.' },
  { beat: 'asked', offset: 1.2, text: 'The whole command. Not a summary.' },
  { beat: 'allowed', offset: 0.1, text: 'One tap, from wherever you are.' },
  { beat: 'allowed', offset: 3.4, text: 'The Mac carries on.' },
]

/**
 * Fade a value in and out around a window.
 * @param {number} frame - current frame.
 * @param {number} from - first frame of the window.
 * @param {number} to - last frame of the window.
 * @param {number} fade - frames of fade at each end.
 * @returns {number} opacity between 0 and 1.
 */
function around(frame, from, to, fade) {
  return interpolate(frame, [from, from + fade, to - fade, to], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp',
  })
}

/** The recording, in a frame that reads as a phone without pretending to be one. */
function Phone({ height }) {
  const radius = height * 0.055
  return (
    <div style={{
      height,
      aspectRatio: '1320 / 2868',
      borderRadius: radius,
      overflow: 'hidden',
      background: '#000',
      boxShadow: '0 30px 90px rgba(0,0,0,0.28), 0 0 0 1px rgba(0,0,0,0.06)',
    }}>
      {/* Already trimmed on disk. `render.mjs` cuts the lead-in with ffmpeg
          rather than asking the player to skip it: the recording's frame rate
          is whatever the simulator felt like, and trimming by frame against an
          unknown rate is how an edit drifts a few frames every take. */}
      <OffthreadVideo
        src={staticFile('phone.mov')}
        style={{ width: '100%', height: '100%', objectFit: 'cover' }}
      />
    </div>
  )
}

/** One caption, on screen until the next one takes over. */
function Caption({ line, next, fps, width, wide, total }) {
  const frame = useCurrentFrame()
  const from = at(line.beat, fps, line.offset)
  const to = next === undefined ? total : at(next.beat, fps, next.offset)
  const opacity = around(frame, from, to, Math.round(0.28 * fps))
  if (opacity <= 0.001) return null
  const rise = interpolate(frame, [from, from + Math.round(0.4 * fps)], [10, 0], {
    extrapolateLeft: 'clamp', extrapolateRight: 'clamp',
  })
  return (
    <div style={{
      opacity,
      transform: `translateY(${rise}px)`,
      color: INK,
      fontFamily: 'ui-sans-serif, -apple-system, "Segoe UI", system-ui, sans-serif',
      fontWeight: 600,
      fontSize: wide ? width * 0.026 : width * 0.052,
      lineHeight: 1.25,
      letterSpacing: '-0.01em',
      textAlign: wide ? 'left' : 'center',
      maxWidth: wide ? '100%' : '86%',
    }}>
      {line.text}
    </div>
  )
}

/** The last two seconds: what it is, and where to get it. */
function Endplate({ fps, width, total }) {
  const frame = useCurrentFrame()
  const from = total - Math.round(2.2 * fps)
  const opacity = around(frame, from, total, Math.round(0.3 * fps))
  if (opacity <= 0.001) return null
  return (
    <AbsoluteFill style={{
      opacity,
      background: PAPER,
      alignItems: 'center',
      justifyContent: 'center',
      flexDirection: 'column',
      gap: width * 0.018,
      fontFamily: 'ui-sans-serif, -apple-system, "Segoe UI", system-ui, sans-serif',
    }}>
      <div style={{ fontSize: width * 0.075, fontWeight: 700, color: INK, letterSpacing: '-0.03em' }}>
        Rowel
      </div>
      <div style={{ fontSize: width * 0.027, color: '#5d6069', fontWeight: 500 }}>
        Your Mac’s coding agent, on your phone
      </div>
      <div style={{ fontSize: width * 0.024, color: ACCENT, fontWeight: 600, marginTop: width * 0.01 }}>
        rowel.novabox.ai
      </div>
    </AbsoluteFill>
  )
}

/**
 * @param {{wide?: boolean}} props - `wide` puts the words beside the phone
 *   rather than under it, which is the only thing that changes between the
 *   landscape cut and the other two.
 */
export function Launch({ wide = false }) {
  const { fps, width, height, durationInFrames } = useVideoConfig()
  // In landscape the phone is taller than the frame on purpose. Fitted whole
  // into 1080 lines it is about 430 pixels wide, and at that size the command
  // the video is asking you to read is unreadable — which loses the shot to
  // keep a device outline. Overscaled and anchored low, the part on screen is
  // the part that matters: the card, and the answer.
  const phoneHeight = wide ? height * 1.34 : height * 0.76
  return (
    <AbsoluteFill style={{ background: PAPER }}>
      <AbsoluteFill style={{
        flexDirection: wide ? 'row' : 'column',
        alignItems: wide ? 'flex-end' : 'center',
        justifyContent: 'center',
        gap: wide ? width * 0.05 : height * 0.035,
        padding: wide ? width * 0.04 : width * 0.03,
        overflow: 'hidden',
      }}>
        <Phone height={phoneHeight} />
        <div style={{
          width: wide ? '38%' : '100%',
          display: 'flex',
          flexDirection: 'column',
          alignItems: wide ? 'flex-start' : 'center',
          justifyContent: 'center',
          minHeight: wide ? undefined : height * 0.12,
          alignSelf: wide ? 'center' : undefined,
        }}>
          {LINES.map((line, index) => (
            <Caption
              key={index}
              line={line}
              next={LINES[index + 1]}
              total={durationInFrames}
              fps={fps}
              width={width}
              wide={wide}
            />
          ))}
        </div>
      </AbsoluteFill>
      <Endplate fps={fps} width={width} total={durationInFrames} />
    </AbsoluteFill>
  )
}

export { start }
