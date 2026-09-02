/**
 * Three shapes of one cut.
 *
 * A launch video that exists only in 16:9 gives up the feed on every platform
 * that is not YouTube, which for this audience is most of them. Same footage,
 * same beats, same words — the only thing that differs is whether the words sit
 * beside the phone or under it.
 */

import React from 'react'
import { Composition } from 'remotion'
import { Launch } from './Launch.jsx'
import { duration } from './beats.js'

const FPS = 30
const FRAMES = Math.round(duration * FPS)

export function RemotionRoot() {
  return (
    <>
      <Composition
        id="Vertical"
        component={Launch}
        durationInFrames={FRAMES}
        fps={FPS}
        width={1080}
        height={1920}
        defaultProps={{ wide: false }}
      />
      <Composition
        id="Square"
        component={Launch}
        durationInFrames={FRAMES}
        fps={FPS}
        width={1080}
        height={1080}
        defaultProps={{ wide: false }}
      />
      <Composition
        id="Wide"
        component={Launch}
        durationInFrames={FRAMES}
        fps={FPS}
        width={1920}
        height={1080}
        defaultProps={{ wide: true }}
      />
    </>
  )
}
