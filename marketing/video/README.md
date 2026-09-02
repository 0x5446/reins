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
ios/screenshots.sh --seed          # a harness with a sample repository, once
ios/demo.sh                        # arm a real approval, record the tap
cd marketing/video && npm install  # once
node render.mjs                    # trim, then render all three shapes
```

Out come `out/rowel-{vertical,square,wide}.mp4` — 9:16, 1:1 and 16:9 of the
same cut. Three rather than one because a launch video that exists only in
16:9 gives up the feed everywhere that is not YouTube.

The captions are placed against `raw/beats.json`, which the recording writes:
`Demo.swift` marks when it saw the card and when it answered, `demo.sh` knows
when the camera started, `beats.py` subtracts. Re-record and the words move
with the footage instead of describing a frame that has shifted. Each caption
runs until the next one starts, so there is no per-line duration to keep in
step — the first attempt had those, and put two captions on screen at once.

In the landscape cut the phone is deliberately taller than the frame. Fitted
whole into 1080 lines it is about 430 pixels wide, and the command the video is
asking you to read is then unreadable; overscaled and anchored low, what is on
screen is the card and the answer.

`demo.sh` provokes a genuine permission request — the session runs under a
`read-only` sandbox, so the agent's first write is refused and escalating
needs consent — then drives the tap and records:

The phone is the simulator, recorded with `xcrun simctl io recordVideo` — no
camera and no physical device, so a take is repeatable.

## There is no Mac half, and why

The shot would be better with one: the same session on the machine that is
blocked, resuming when the tap lands. It was built and then removed.

Capturing it meant recording a rectangle of the display, and a rectangle of the
display holds whatever is in front of it. Two takes came back containing
windows belonging to the person running it — the second was a private
conversation — and the only reason neither reached a video is that both were
looked at first. Targeting by window title or URL does not fix it: AppleScript
will tell you a window exists and where it was moved to, not that it is the
thing actually visible at those coordinates. Another app on top, and the
recording is of that app.

A Mac half needs a recorder that captures a *window* rather than a region —
ScreenCaptureKit's window capture, or a browser recording its own page. Until
there is one, the phone alone carries the shot: it shows the agent blocked, the
card, the tap, and the work continuing, which is the whole claim.

Two smaller things that cost a take each, in case they come up again. The Xcode
project is generated and not committed, so a driver added since the last
`xcodegen` is not in the scheme, and `-only-testing` against a test that does
not exist still leaves a recording on disk — of a home screen. And while
`simctl` is recording it holds the capture system, so anything asking "can I
record the screen?" after that point is told no on a machine where the answer
is yes.

## Raw footage

`raw/` is not committed. It is large, it is regenerable, and it is a recording
of a real machine — the same reason `marketing/shots` is generated from a
throwaway harness rather than from anybody's own.
