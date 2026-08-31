# Launch Thread — X

Seven tweets. Rules baked in: no link until the last tweet (X suppresses
outbound links in the first post), no emoji, no "Introducing", each under
280 characters (counts verified). Tweet 1 carries the video — first two
seconds must show the lock-screen notification lighting up.

Every claim below is source-true: content-free push (`relay-worker` APNs
constant + `Push.swift`), ciphertext-only relay (e2e test name is literal),
LAN racing (`RelayDirectory`/`LocalNetwork`), photo attach up to 4 images
(`Composer.swift`), single-agent honesty (dsh only), revoke semantics
(README).

---

**1/** *(attach 20–30 s video: phone lights up with an approval → tap → full
command + diff → Approve → Mac terminal visibly resumes)*

```
Your coding agent hit a permission prompt 40 minutes ago.

You were on a train. It's still waiting.

Reins puts that approval on your iPhone — end-to-end encrypted to your own Mac, with the full command and the diff in front of you before you say yes.
```

**2/**

```
The ask reaches your lock screen, but the push carries no content. The alert text is a hardcoded constant in the relay's source. Your phone wakes, opens its own encrypted tunnel to your Mac, fetches what actually happened, and writes the real notification locally.
```

**3/**

```
Whiteboard sketch, napkin drawing, an error on someone else's screen — photograph it, attach it, say "build this."

The photo rides the same sealed channel as everything else. It reaches the agent on your Mac and nothing in between can open it.
```

**4/**

```
"The relay can't read your traffic" is a claim about structure, not conduct.

Noise IK, X25519, ChaCha20-Poly1305. Keys exist only on your phone and your Mac. And there's an e2e test literally named "the relay only ever sees ciphertext" — if it goes red, the build is broken.
```

**5/**

```
On the same Wi-Fi, the phone talks to your Mac directly — the relay never sees a packet. Elsewhere, both paths race and the fastest wins.

Through that one tunnel: streaming replies with reasoning, tool cards, approvals, forks, full-text search, model switching.
```

**6/** *(the honesty tweet — historically the most-shared one in dev threads)*

```
The edges, stated plainly: iPhone only. Works with DeepSeek Harness (dsh) only, for now. And a paired phone has the same authority over that Mac as your own terminal — `bridle revoke` on the Mac is what takes it back. Know that before you pair.
```

**7/**

```
Free. MIT. No accounts — pairing is a QR code your terminal prints. Don't trust our relay? Run your own; it's one Cloudflare Worker.

github.com/0x5446/reins
```

---

## Posting notes

- After tweet 7, reply to your own thread with the full 60-second demo video
  (raw, uncut) — threads with a follow-up video in replies get a second
  algorithmic wave.
- If the App Store link is live at posting time, reply once more with it;
  don't put two links in tweet 7.
- Do not schedule this the same hour as the Show HN — one channel at a time,
  X first or HN first per `GTM.md` §3.7 sequencing.
- Word to avoid on this platform for this product: "control your coding
  agent from your phone" as a standalone pitch — both Anthropic and OpenAI
  ship that sentence about their own products (`GTM.md` §2.5); tweet 1's
  scenario framing exists to dodge it.
