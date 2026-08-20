# Contributing

Reins is maintained by one person in the open. That shapes what is useful to
send. A bug report with a reproduction is always welcome. A small fix is easy to
take. A large feature is worth asking about before you build it — `docs/architecture.md`
§17 lists the things that are deliberately *not* being built, and a pull request
that implements one of them is work nobody wanted.

Security problems do not go in the issue tracker. See [SECURITY.md](SECURITY.md).

## A note on language

The code, the comments, the commit messages, and the user-facing pages are in
English. The design documents under `docs/` are in Chinese, because they were
written for the person maintaining this. You do not need to read them to fix a
bug or add a test. You do need `docs/protocol.md` to touch the wire format, and
if that is a wall, open an issue and ask — an English section is cheaper to
write on demand than a translation of the whole thing is to keep current.

## What you need

| For | You need |
|---|---|
| Everything except the app | Node 22 or newer |
| The iOS app | macOS, Xcode with an iOS 17-or-newer simulator, and `brew install xcodegen` |
| Most of the end-to-end suite | a DeepSeek Harness (`dsh`) serving on this machine |
| The Cloudflare relay's own tests | `wrangler dev` |

The Xcode project is generated from `ios/project.yml` and is not committed, so
`xcodegen` is a hard requirement rather than a convenience. Committing a
3000-line `pbxproj` means every added file arrives as a merge conflict.

## Commands

```sh
npm ci                 # exact install from the lockfile
npm run build          # tsc -b across protocol, bridle, dsh-plugin, relay, e2e
npm test               # build + check:docs + the unit tests. Seconds.
npm run test:e2e       # the whole stack: real relay, real Bridle, scripted phone
npm run test:ios       # xcodegen + the app's unit tests. About half a minute.
npm run vectors        # regenerate the cross-language test vectors
npm run check:docs     # the mechanical half of "the docs still match the code"
```

This file does not tell you how many tests there are. The README used to, and it
was wrong by a factor of two inside a week. CI has the number.

## The four layers, and what each one proves

Losing any one of them loses something the others cannot cover.

**Vectors.** `protocol/scripts/emit-vectors.js` runs the handshake with fixed
keys and fixed ephemerals and writes `ios/ReinsTests/Fixtures/protocol-vectors.json`.
Swift compares byte for byte: handshake messages, the handshake hash, the
six-digit confirmation, transport ciphertext, the pairing link, frame encoding.
"My server talks to my client" proves nothing when both are mine. A failure here
is a protocol fork, not a flaky test.

**Unit.** `npm test`. Folding, parsing, rate limiting, address selection, plugin
lifecycle. No network. This is also where `check:docs` runs, so documentation
drift fails the unit suite.

**End to end.** `npm run test:e2e`. A real relay process, a real Bridle, and a
scripted phone. The security invariants live here because an assertion in prose
is not a fact — `the relay only ever sees ciphertext` has to be executable.

**UI.** `ios/run-ui-tests.sh`. Separate scheme, separate script, because it needs
a booted simulator and a paired Bridle and takes minutes. Between "it compiles"
and "it works" there is a whole gap.

## Green does not always mean covered

Tests that need something absent **skip** rather than fail. That is the right
behaviour and it is also a trap:

- Without a harness serving on this machine, `cli`, `direct`, `security`, and
  `tunnel` in `e2e/tests/` all skip. A green `npm run test:e2e` on a machine with
  no `dsh` has run a small fraction of it. Read the skip lines.
- `e2e/tests/deployed.test.js` skips unless `REINS_E2E_RELAY_URL` points at a
  relay. Against the deployed one it is the only thing that catches a tunnel
  refusing WebSocket upgrades or a proxy buffering the stream into uselessness.
- `relay-worker/tests/worker.test.js` skips unless `REINS_WORKER_URL` points at a
  running worker:

  ```sh
  npx wrangler dev --config relay-worker/wrangler.jsonc --var REINS_SWEEP_INTERVAL_MS:2000
  REINS_WORKER_URL=ws://127.0.0.1:8787 node --test relay-worker/tests/worker.test.js
  ```

  The sweep override is not optional. Without it the suite passes four times and
  fails the fifth, which is worse than failing every time.
- `e2e/tests/site.test.js` fetches the public site by default. Point
  `REINS_E2E_SITE_URL` somewhere else or expect it to need the network.

## Changing the wire format

The protocol is implemented twice, in TypeScript and in Swift, and nothing but
the vectors keeps the two honest.

1. Change both implementations.
2. `npm run vectors` and commit the regenerated fixture.
3. Run `npm run test:ios` — `ParityTests` is what fails if the two have drifted.
4. Update `docs/protocol.md`. `npm run check:docs` enforces the parts of it that
   have exactly one right answer: the prologue, the frame list, the constants a
   reimplementer would copy, and the two copies of the relay mux format.
5. Say in the commit message what an older peer will do when it meets the change.
   The protocol refuses across a version mismatch rather than negotiating down;
   `docs/architecture.md` §14 is the rule.

`relay-worker/src/wire.ts` is a hand-kept second copy of `protocol/src/mux.ts`,
because a Cloudflare Worker cannot import the Node package. `check:docs` compares
them in both directions — a value that drifts there does not crash, it silently
drops frames.

## Changing behaviour that the docs describe

The order of authority is fixed:

```
test vectors  >  tests  >  code  >  docs
```

`check:docs` only knows things with one right answer. Everything else is on
people. If you change `bridle/src`, `ios/Reins/Store`, a protocol frame, or a
harness method, either update the matching document or say in the commit message
why it does not need one.

When a document and the code disagree, work out which is wrong before you edit.
If the document describes what *should* happen and the code does not do it, the
code has the bug. If the document misremembers behaviour that has been stable,
the document has the bug. Both need fixing; making them merely agree is not one
of the options.

## Commits and pull requests

Commit subjects here describe a change in behaviour, in lower case, in one line —
`stop guessing which APNs host, and stop deleting good tokens`, not
`fix(push): update apns.ts`. Say what is different now. The body is for why, and
for what was wrong before.

**Do not add `Co-Authored-By` trailers.** GitHub counts every co-author as a
contributor to this repository, and removing one afterwards means rewriting
history.

One idea per pull request. Say what you verified and on what — "unit tests pass"
and "I paired a real phone over the relay and approved a tool call" are different
claims and the second one is worth making explicitly.

## Where things are

```
protocol/      Noise, frames, pairing payloads, relay wire format (TypeScript)
bridle/        the companion process and its CLI
dsh-plugin/    the same core, mounted inside a harness instead of beside it
relay/         the Node relay
relay-worker/  the same relay on Cloudflare Workers and Durable Objects
e2e/           tests that span all three
ios/           the app (Swift, SwiftUI, XcodeGen)
site/          the four pages the app links to
docs/          design, protocol, fold, deployment
```

`docs/README.md` says which document answers which question, and which sections
are specification-grade versus design-grade. Read that before trusting a section
to reimplement from.
