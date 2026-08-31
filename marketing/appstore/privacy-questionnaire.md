# App Privacy Questionnaire — Answers and Evidence

App Store Connect → App Privacy. The questionnaire asks whether you or your
third-party partners "collect" data from the app. Apple's definition of
collect: *transmitting data off the device in a way that allows you and/or
your third-party partners to access it for a period longer than what is
necessary to service the transmitted request in real time.*

## The answer

**"Do you or your third-party partners collect data from this app?" → No, we
do not collect data from this app.**

Resulting label: **Data Not Collected**. Tracking: **No** (no ATT prompt
needed).

This matches the shipped privacy manifest exactly —
`ios/Reins/PrivacyInfo.xcprivacy` declares `NSPrivacyCollectedDataTypes = []`
and `NSPrivacyTracking = false`. The label and the manifest must agree, and
they do. If you ever decide to declare anything on the label, update the
manifest in the same release.

## Source-level verification (performed 2026-09-01)

1. **No analytics / crash / tracking SDK.** Grep over `ios/Reins`,
   `ios/ReinsTests`, `ios/project.yml` for
   `analytics|firebase|sentry|crashlytics|amplitude|mixpanel|segment|appsflyer|adjust|bugsnag|datadog|posthog|telemetry|tracking|advertis`
   (case-insensitive). Every hit is benign: the `PrivacyInfo.xcprivacy`
   comment *stating* there is no analytics, the `NSPrivacyTracking(Domains)`
   keys themselves (false/empty), and UI vocabulary (`pickerStyle(.segmented)`,
   "advertised addresses" in networking code, `square.and.pencil` icons).
   Zero SDK references.

2. **Zero third-party dependencies of any kind.** No `Package.swift`, no
   `Podfile`, no `Cartfile`; no `packages:` section in `ios/project.yml`. The
   42 Swift files import exactly 11 frameworks, all Apple's: SwiftUI,
   Foundation, UIKit, UserNotifications, Observation, CryptoKit, Security,
   PhotosUI, Network, LocalAuthentication, AVFoundation. There is no code in
   the binary we did not write except the OS.

3. **No accounts, no server-side user identity.** Pairing is a QR code
   (`OnboardingView.swift`); the device identity key lives in the iOS
   Keychain; the app stores locally only the paired-machine list, the phone's
   display name, the last machine used, and the default model
   (per `site/public/privacy.html`, confirmed against `AppModel`/`Models`).
   Conversations are never persisted on the phone — fetched from the Mac,
   held in memory.

4. **Required-reason APIs:** only `UserDefaults` (reason CA92.1), declared in
   the manifest. Verified no file-timestamp, boot-time, disk-space, or
   keyboard APIs (`APPSTORE.md` §3.2).

## Why each transmitted item is still "not collected"

| Data in motion | Path | Retained by us? | Verdict |
|---|---|---|---|
| Prompts, replies, code, diffs, photos | Phone ↔ Mac inside the Noise channel; relay forwards ciphertext only, no key material | Never readable by us; nothing stored | Not collected |
| **APNs push token** | iOS → app → sealed channel → **the user's own Mac** (stored there, on the user's device); the Mac hands it to the relay **one wake at a time, at the moment a push is sent**, and the relay does not store it (`Push.swift` doc comment; `privacy.html` "Notifications": "handed over one wake at a time … is not stored") | No — transits the relay only to service that single push, then gone | **Not collected.** Servicing the request in real time is Apple's own carve-out. |
| Machine ID / display name / Bridle version | Held by the relay **only while that Mac is online**; the row is deleted on disconnect (`privacy.html`, `relay/src/registry.ts`) | Session-scoped, machine-scoped (random ID, not derived from hardware, not linked to a person — there are no accounts to link to) | Not collected |
| Pairing bundle | Held by relay only while a pairing code is outstanding (≤ 10–15 min), deleted on claim or expiry | Transient by design | Not collected |
| IP address, traffic timing/volume | Seen by the relay/Cloudflare as by any server; no log file, no analytics pipeline (`privacy.html`) | Not retained by us | Not collected |

**On the push token specifically** — the precise conclusion, since this is
the item most likely to be second-guessed: in Apple's taxonomy a push token
would fall under **Identifiers → Device ID**. It does not need to be declared
here because (a) the party that *keeps* it is the user's own Mac, not our
server; (b) the relay touches it only to sign and send one push and does not
persist it; (c) it is not linked to any user identity (there are none) and
not used for tracking. If you ever change the relay to *store* tokens (e.g.
for retry queues), that day the label changes to: Identifiers → Device ID →
App Functionality → Not Linked to You → Not Used for Tracking — and the
privacy manifest must be updated to match.

**Photos:** attached via the out-of-process `PhotosPicker` (no library
permission, no library access beyond the user's explicit picks); the image
goes only to the user's Mac through the encrypted channel. User content sent
to the user's own device is not collection.

**Cloudflare:** runs the relay Worker and terminates TLS, so it observes the
same connection metadata, under its own policy. It cannot read content
(ciphertext only) and is not a "partner collecting data" in the label's sense
— we neither share user data with it for its purposes nor receive analytics
from it.

## Questionnaire, category by category

| ASC category | Answer | Basis |
|---|---|---|
| Contact Info (name, email, phone, address, other) | Not collected | No accounts, nothing asked, nowhere to send it |
| Health & Fitness | Not collected | N/A |
| Financial Info | Not collected | Free app, no payments |
| Location (precise/coarse) | Not collected | No location APIs in the binary |
| Sensitive Info | Not collected | N/A |
| Contacts | Not collected | No Contacts framework |
| User Content (emails/messages, photos, audio, gameplay, customer support, other) | Not collected | Content moves phone↔Mac E2E-encrypted; we cannot read it and store nothing |
| Browsing History | Not collected | No browser in the app |
| Search History | Not collected | Search queries are answered by the user's own Mac over the sealed channel |
| Identifiers (User ID / Device ID) | Not collected | No user IDs exist; push token transits only (see above) |
| Purchases | Not collected | None |
| Usage Data | Not collected | No analytics of any kind |
| Diagnostics (crash, performance) | Not collected | No crash reporter; `uploadSymbols` in ExportOptions only uploads dSYMs to Apple for Apple's crash service — that is Apple-collected opt-in user data, not developer collection to declare |
| Other Data | Not collected | — |

Tracking section: **No** — nothing is used for tracking, no data broker
contact, `NSPrivacyTracking = false`, no tracking domains.

## Consistency checklist before submitting

- [ ] Label says Data Not Collected ↔ `PrivacyInfo.xcprivacy` has empty
      `NSPrivacyCollectedDataTypes`. (True today.)
- [ ] Privacy policy URL (`https://reins.novabox.ai/privacy`) reachable —
      verified HTTP 200 on 2026-09-01. **Do not use `/privacy.html` — it
      404s** (the Worker only routes the extensionless path).
- [ ] The privacy policy already discloses relay metadata, the push-token
      path, Cloudflare, and Apple's role — it does, in more detail than the
      label requires.
- [ ] 5.1.2(i) note: the policy should also state plainly that prompts are
      ultimately sent to whatever model provider **the user configured on
      their own Mac** — Reins neither chooses nor touches that provider.
      `privacy.html` covers the relay side thoroughly; this one sentence
      about the user's own model provider is worth adding to the site
      (suggestion only, tracked in review-notes.md).
