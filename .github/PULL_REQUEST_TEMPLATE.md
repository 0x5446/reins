<!--
Delete whatever does not apply. This is a prompt, not a form to fill in.
-->

## What changes

<!-- What is different after this, in behaviour terms. -->

## Why

<!-- What was wrong before, or what could not be done. -->

## What you verified, and on what

<!--
"Unit tests pass" and "I paired a real phone over the relay and approved a tool
call" are different claims. Make the strongest one that is true.
-->

- [ ] `npm test`
- [ ] `npm run test:e2e` — say whether a harness was running; without one, most
      of it skips
- [ ] `npm run test:ios`

## Documentation

- [ ] Touched `bridle/src`, `ios/Reins/Store`, a protocol frame, or a harness
      method — and either updated the matching document, or said here why it
      does not need one
- [ ] Changed the wire format — regenerated `npm run vectors`, and said what an
      older peer does when it meets this

<!--
No Co-Authored-By trailers, please. GitHub counts every co-author as a
contributor to this repository, and taking one back means rewriting history.
-->
