# App Review Strategy and Notes — Rowel v1.0

The structural problem: the reviewer does not have a Mac running dsh, and
pairing tokens are single-use with a ~10-minute TTL
(`protocol/src/pairing.ts: PAIRING_TTL_MS = 10 * 60 * 1000`), so no code
pasted into Review Notes can ever work. Everything below is built around that
fact.

## 1. What we are, in App Review's vocabulary

Frame the app as a **companion client for self-hosted software the user
already runs** — a category with long-standing precedent on the store:

- **SSH/terminal clients** (Termius, Blink Shell, Prompt): connect to the
  user's own machine, over the public internet, full shell authority, no
  demo account possible. Closest analogue.
- **Home Assistant, Plex, Nextcloud**: useless until pointed at a server the
  user self-hosts; first launch is a connect screen. All approved, all
  category leaders.

Rowel is that shape: the agent runs on the user's Mac with the user's API
keys; the app reads results and sends approvals over an end-to-end encrypted
channel. It is *not* a chatbot service, *not* a remote desktop, and *not* an
app that executes code.

## 2. Paste-ready Review Notes (App Review Information → Notes)

Fill `<VIDEO URL>` with the demo video (unlisted YouTube/Vimeo link) before
submitting. ~3.3 KB, under the 4000-byte limit.

```
WHAT THIS APP IS

Rowel is a companion client for a coding agent that runs on the user's own
Mac — the same shape as an SSH client or the Home Assistant app: it is
useless until the user pairs it with software they already run themselves.
It renders its own native SwiftUI interface from structured JSON received
over an end-to-end encrypted WebSocket. No screen content, framebuffers, or
pixels are transmitted, and no code is downloaded or executed on the phone.

WHY THERE IS NO DEMO ACCOUNT

There are no accounts anywhere in the product. The app pairs directly with a
small companion program ("Bridle") that the user installs on their own Mac
with one command; pairing is a QR code that program prints. There is no
server to sign in to and no credentials we could give you.

WHY WE CANNOT PUT A PAIRING CODE IN THESE NOTES

Pairing tokens are single-use and expire after about ten minutes by design
(they hand the phone shell-level authority over that Mac, so they must not
live long). Any code written here would be dead before you read it.

Instead, here is a complete walkthrough recorded on physical devices — the
Mac-side install, pairing by QR, a live agent session with streaming output,
an approval with its full command and diff, the photo attachment flow, and
the lock-screen notification path:

  <VIDEO URL>

If you would like live access, we will gladly stand up a dedicated Mac and
provide a fresh pairing code at a scheduled time — reply here and we will
arrange it within 24 hours.

WHAT YOU CAN VERIFY WITHOUT A MAC

Launch → the pairing screen states what the app is and what it needs. "Connect
a Mac" shows the install command and the scanner; "Enter a code instead"
shows the manual path. The camera permission prompt appears at the scanner.
Everything past pairing requires the user's own machine, which the video
covers end to end.

THREE THINGS WE WANT TO BE EXPLICIT ABOUT

1. Guideline 2.5.2 — no code is downloaded, executed, compiled, previewed,
   or installed by this app. The agent runs entirely on the user's Mac with
   the user's own API keys. The app displays results and sends approvals.

2. Guideline 4.2.7 — this is not a remote desktop client. There is no screen
   mirroring and no pixel transport; the app speaks a JSON protocol and draws
   its own native UI. It is the same class of product as an SSH client.

3. Guideline 1.2 / 4.7 — there is no user-to-user content and no chatbot
   service provided by us. No accounts, no social features, no distribution.
   Output is generated on the user's own machine, by the model provider the
   user configured there, and returns only to that user.

PERMISSIONS

• Camera — scan the pairing QR code shown by the Mac.
• Local Network — connect directly to the Mac on the same Wi-Fi (skips the
  relay entirely).
• Face ID — optional app lock, because a paired phone can approve commands.
• Notifications — the push carries no content; the phone reconnects over its
  encrypted tunnel and writes the real notification locally.

The full source of the app, the Mac companion, and the relay is public:
https://github.com/0x5446/rowel — including an end-to-end test asserting the
relay only ever sees ciphertext.
```

## 3. Demo video (the `<VIDEO URL>` placeholder)

To be recorded by the main session. Requirements that make it land:

- **One continuous take, physical devices, Mac screen and iPhone both in
  frame** (Apple's "Tips from App Review" prefers real-device footage for
  hardware-companion apps; the "hardware" here is the Mac). 2–4 minutes,
  captions not narration.
- Shot list: ① `curl … | sh` install on the Mac → `bridle pair` prints QR;
  ② iPhone: launch, Connect a Mac, scan, paired; ③ session list appears,
  grouped by workspace; ④ send a prompt, streaming reply + reasoning +
  tool cards; ⑤ an approval arrives — show full command + diff — approve it,
  Mac side visibly continues; ⑥ background the app, trigger a question,
  lock-screen notification arrives, tap through, answer it; ⑦ attach a photo
  of a hand-drawn sketch, agent starts building; ⑧ model picker; ⑨ Trace and
  cost panel, 5 seconds each.
- Hygiene: neutral machine name (edit `machineName` in `~/.rowel/bridle.json`),
  throwaway demo repo, no API keys or real paths on screen.
- Host as **unlisted YouTube or Vimeo**; also attach the file itself in App
  Review Information → Attachment if under the size limit (belt and braces —
  reviewers sometimes won't follow links).

## 4. First-launch-without-a-Mac audit (is this an "empty app"?)

Verified against `ios/Rowel/Views/RootView.swift` (the `model.isNew` branch)
and `OnboardingView.swift`. What a reviewer actually sees:

1. Brand screen: icon, "Rowel", tagline "Your coding agent, in your pocket.",
   three promise rows (E2E encryption / no account / LAN direct), one primary
   button "Connect a Mac" + "Takes about a minute."
2. Tapping it: a two-step pairing sheet — install command with copy button,
   `bridle pair` command, then "I've run it — scan the code" (camera
   permission prompt → scanner) and "Enter a code instead" (short-code
   entry, validates input, shows errors).

So it is **not** a blank screen — it is a coherent, self-explanatory gate.
But every path dead-ends without a Mac, which is exactly the 4.2/2.1 profile
of "reviewer cannot exercise the app". Risk is real; the notes + video above
are the mitigation.

**Copy-level suggestions (suggestions only — no app code changed):**

- The onboarding tagline row could carry one expectation-setting line, e.g.
  "Works with the free dsh coding agent on your Mac" — so a reviewer
  immediately classifies it as a companion app rather than a thin client to
  a missing service.
- The pairing sheet's install step already says what Bridle is; one extra
  sentence — "Nothing to sign up for: Rowel only talks to your own Mac" —
  would preempt the "where is the login" reaction.
- Both are `Text()` string changes in `OnboardingView.swift` if ever wanted;
  neither is required for submission, and the Review Notes carry the same
  information regardless.

## 5. Rejection playbook (Guidelines 2.1 / 4.2 minimal functionality)

Escalation ladder — spend nothing until a rejection forces the next rung:

| Rung | What | Cost | When |
|---|---|---|---|
| A | Notes + demo video (above) | done | First submission |
| B | Reply offering a **scheduled live pairing**: we keep a dedicated Mac awake, generate a fresh QR/short code at an agreed time, post the short code in Resolution Center | ops only | First 2.1/4.2 rejection — always reply in Resolution Center before resubmitting; many 2.1s dissolve on explanation |
| C | Bridle change: a long-lived, multi-use demo pairing offer (e.g. `bridle pair --demo`) + a 24/7 demo Mac with a scoped throwaway workspace | ~1 day + standing ops | If B stalls or reviews recur every update |
| D | Built-in demo mode (fake transport + scripted signal stream through `MachineSession`) | 400–700 lines of shipping code | Last resort; note 2.1(a) requires *prior approval by Apple* for demo-mode-in-lieu-of-account, and it must show full functionality |

Arguments to reuse verbatim in Resolution Center if 4.2 ("minimal
functionality") is cited: the app ships a full native client — transcript
renderer, diff viewer, trace, approvals, search, multi-machine session
management (13k lines of Swift, zero web views); the *service* it connects
to is the user's own computer, the same dependency shape as every SSH client
on the store. If 4.2.3(i) ("should work on its own") is cited: the companion
is desktop software, not another iOS app; Home Assistant / Plex / Nextcloud
are the precedent.

Also pre-loaded in the notes: the 2.5.2 "vibe-coding" sweep (we download and
execute nothing), 4.2.7 remote-desktop (no mirroring; and its LAN-only clause
therefore does not apply), 1.2/4.7 (no UGC, no chatbot service). Details and
sources in `APPSTORE.md` §4.

## 6. Submission-day checklist for this file

- [ ] Record and upload demo video; replace `<VIDEO URL>`.
- [ ] Paste §2 into App Review Information → Notes.
- [ ] Attach the video file in the Attachment field too, if it fits.
- [ ] Contact info in App Review Information: a phone number and email that
      are actually answered — B-rung scheduling depends on it.
- [ ] Keep the demo Mac's Bridle updated to the tagged release the video
      shows.
