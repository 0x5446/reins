# The launch video

One thing happens in it: an agent is stopped, waiting on a person, and the
person says yes from a phone. That is the product, and it is the only part
that a screenshot cannot carry — a still shows the card, but not that the Mac
was blocked before the tap and working after it.

## Why it is recorded rather than generated

The 2026 house style for this category is real product UI, and the reason is
not taste: a generated approximation of a screen cannot be evidence, and
evidence is the entire job here. What generative video is good for — a
cinematic establishing shot — is the part this video does not need.

What is worth borrowing from that world is the *assembly*: the edit is code
(Remotion), so when the interface moves the video is re-rendered rather than
re-shot. That is the same bargain `ios/screenshots.sh` already makes for the
stills, and the reason neither is kept as a hand-made artifact.

## Producing it

```sh
ios/screenshots.sh --seed   # a harness with a sample repository, once
ios/demo.sh                 # arm a real approval, record both screens
```

`demo.sh` provokes a genuine permission request — the session runs under a
`read-only` sandbox, so the agent's first write is refused and escalating
needs consent — then drives the tap and records:

| | source | how |
|---|---|---|
| phone | the simulator | `xcrun simctl io recordVideo` |
| Mac | the harness's own web UI | `ffmpeg -f avfoundation`, cropped to the window |

Neither is a camera and neither is a physical device, so a take is repeatable.

**The Mac half needs a permission.** Screen recording is granted per binary in
System Settings › Privacy & Security › Screen Recording, and a process without
it does not fail cleanly — `screencapture` hangs and ffmpeg reports no screen
among its devices. `demo.sh` checks first and records the phone alone rather
than spending four minutes to produce half a set.

## Raw footage

`raw/` is not committed. It is large, it is regenerable, and it is a recording
of a real machine — the same reason `marketing/shots` is generated from a
throwaway harness rather than from anybody's own.
