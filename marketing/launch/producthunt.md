# Product Hunt Launch — Reins

## Name

```
Reins
```

## Tagline (limit 60 chars)

```
Drive the coding agent on your Mac from your iPhone
```
(51 characters)

Fallback if a sharper edge is wanted (44 chars):

```
Your Mac runs the agent. Your phone answers.
```

## Description (limit 260 chars)

```
The agent runs on your Mac, with your code and your keys. Reins is the iPhone side: approve commands with the full diff, read streaming output, get woken only when it needs you. End-to-end encrypted — the relay only ever sees ciphertext. Free, open source.
```
(256 characters)

## Topics

Developer Tools, Artificial Intelligence, Open Source, iOS, Privacy

## Links

- App Store: `<APP STORE URL>` (fill after approval; launch PH only once the
  store link is live — a "build it with Xcode" CTA dies on PH)
- GitHub: https://github.com/0x5446/reins
- Website: https://reins.novabox.ai

## Gallery

Reuse the six App Store screenshots (they're full-bleed UI, they work here),
plus the 60-second demo video as the first slot. First image = the approval
card — it is the one screen that explains the product without words.

## First comment (maker comment — post immediately after launch goes live)

```
Hi PH — maker here.

Reins exists because of a specific, repeating moment: you leave your desk
while a coding agent is mid-task, and forty minutes later you discover it
stopped almost immediately — to ask permission to run a command. The work
didn't fail. It just waited, because you weren't there to say yes.

Reins is the iPhone side of the agent already running on your Mac (currently
DeepSeek Harness / dsh). The Mac keeps the code, the API keys, and the agent.
The phone gets the part that shouldn't require a desk:

- Approvals arrive with the full command and the diff — you see exactly what
  will run before it runs. Anything asked while you were away is pinned on
  top when you come back. Nothing gets auto-answered on your behalf.
- Streaming replies with the model's reasoning, tool-call cards, traces, and
  cost/context breakdowns, laid out for a phone instead of shrunk to fit one.
- Photograph a whiteboard sketch, attach it, say "build this."
- When the app is closed, a push wakes the phone — but the push carries no
  content. The alert text is a hardcoded constant in the relay's source; the
  phone reconnects over its own encrypted tunnel and writes the real
  notification locally.

The part I care most about: the relay cannot read any of this. Phone and Mac
run a Noise IK handshake with each other (X25519, ChaCha20-Poly1305, all
platform crypto — CryptoKit and node:crypto, zero third-party crypto deps),
and the relay just switches sealed frames it has no keys for. That's a
property of the structure, not a policy — there's an end-to-end test named
"the relay only ever sees ciphertext" that fails the build if it ever stops
being true. On the same Wi-Fi the relay isn't involved at all; the phone
connects to the Mac directly.

No accounts anywhere. Pairing is a QR code your terminal prints.

The honest edges: iPhone only, dsh only, for now. And a paired phone has the
same authority over that Mac as your own terminal — that's what makes it
useful, and it's why the app locks itself behind Face ID and why revoking a
phone happens on the Mac, where it can't be faked.

Everything is MIT and public — the app, the Mac companion, the relay (one
Cloudflare Worker; self-host it if you don't trust ours):
https://github.com/0x5446/reins

I'll be here all day — happy to answer anything, especially the skeptical
questions about the crypto and what the relay can still observe (metadata:
that's in the privacy page, stated plainly).
```

## Launch logistics

- Launch 00:01 PT; maker comment within the first 5 minutes.
- Don't launch the same day as Show HN; PH after HN reuses the HN discussion
  as social proof (or vice versa — just not simultaneously).
- Reply to every comment day one; the skeptical crypto questions are the
  conversion moments, not attacks — the e2e-test answer and the metadata
  honesty are the two prepared responses (`GTM.md` §四 has the full
  objection playbook).
- Do not mention future pricing anywhere (`GTM.md` §2.3-⑦: category price
  mode is zero; "free, open source" is the correct complete answer today).
