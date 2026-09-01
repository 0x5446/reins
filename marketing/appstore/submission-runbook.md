# Submission Runbook — zero to "Waiting for Review"

Ordered. Steps marked **[Account Holder]** can only be done by the account
holder (this is a personal developer account, so that is you — but they
cannot be delegated to an API key or a future team member). Everything else
needs Admin or App Manager.

Facts assumed (verified in repo): bundle id `ai.novabox.rowel`, team
`AVKUVD4FPN`, version 1.0 (`ios/project.yml: MARKETING_VERSION`), iPhone-only,
iOS 17+, upload path `ios/release.sh` (archive → export → altool with ASC API
key), `ios/ExportOptions.plist` method `app-store-connect`.

---

## Phase 0 — prerequisites (one-time, ~15 min)

1. **[Account Holder]** appleid/developer.apple.com: membership active
   (activated 2026-08-19), latest **Apple Developer Program License
   Agreement accepted** — ASC banners block submissions until agreed. Free
   app → no Paid Applications agreement, no banking/tax forms needed.
2. Local toolchain: Xcode 26+ with iOS 26 SDK (26.4 verified on this
   machine — meets the "built with Xcode 26" upload requirement),
   `brew install xcodegen`.
3. Site URLs live — verified 2026-09-01: `https://rowel.novabox.ai/` ,
   `/help`, `/privacy` all HTTP 200. (**Use extensionless paths everywhere;
   `.html` variants 404.**)
4. Repo public at `github.com/0x5446/rowel` (the description and review
   notes point reviewers at it).

## Phase 1 — App Store Connect API key (one-time, ~10 min)

1. **[Account Holder]** ASC → Users and Access → **Integrations** →
   App Store Connect API → **Request Access** (first time only) → agree →
   Submit. Usually instant.
2. Team Keys tab → **Generate API Key**:
   - Name: `rowel-release` (reference only)
   - Access: **App Manager** (enough for upload + submit; don't mint Admin)
3. Record three things:
   - **Issuer ID** (UUID at the top of the Keys page)
   - **Key ID** (10 chars, on the key's row)
   - **AuthKey_<KEYID>.p8** — downloadable **exactly once**; Apple keeps no
     copy. Store at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`,
     never in the repo. Name/role are immutable after creation; revocation is
     permanent.

## Phase 2 — create the app record (~15 min)

1. Confirm the App ID exists: developer.apple.com → Identifiers →
   `ai.novabox.rowel` with **Push Notifications** capability. (It exists if
   the app has ever been signed for a device on this team; `release.sh`'s
   `-allowProvisioningUpdates` maintains it. If missing, register it there
   first — the ASC dropdown only lists registered IDs.)
2. ASC → My Apps → **+** → **New App**:
   | Field | Value |
   |---|---|
   | Platforms | iOS |
   | Name | `Rowel` (fallbacks in `metadata.md` if taken) |
   | Primary Language | English (U.S.) |
   | Bundle ID | `ai.novabox.rowel` (from dropdown — not a wildcard) |
   | SKU | `rowel-ios` (internal, immutable, never shown) |
   | User Access | Full Access |

## Phase 3 — app-level settings (~30 min, all from the prepared files)

1. **App Information**: Subtitle; Category **Developer Tools** (primary) +
   **Utilities** (secondary); Content Rights: does not contain third-party
   content; Age Rating questionnaire → answers table in `metadata.md`
   (expect 4+).
2. **App Privacy**: privacy policy URL `https://rowel.novabox.ai/privacy`;
   questionnaire → **Data Not Collected** per `privacy-questionnaire.md`;
   publish the responses.
3. **Pricing and Availability**:
   - Price: **Free** (USD 0).
   - Availability: choose specific territories → select all → deselect
     **China mainland, Russia, Belarus** → tick automatic availability for
     future territories.
   - **Untick** "iPhone and iPad Apps on Apple Silicon Macs".
   - **Untick** Apple Vision Pro availability.
4. **[Account Holder]** Business/Compliance → **EU Digital Services Act
   trader status: declare non-trader** (free, non-commercial). Apps without
   a declaration get removed from EU storefronts.

## Phase 4 — build and upload (~20 min machine time)

```sh
export ROWEL_TEAM_ID=AVKUVD4FPN
export ASC_KEY_ID=<Key ID>
export ASC_ISSUER_ID=<Issuer ID>
export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_<Key ID>.p8

# Dry run first: archive + export only, catches signing issues locally.
# NOTE: first run auto-creates an Apple Distribution certificate on the
# account (via -allowProvisioningUpdates) — expected, one-time.
./ios/release.sh --no-upload

# Real thing: archive → export → altool validate → altool upload.
./ios/release.sh
```

- Build number defaults to the git commit count (`ROWEL_BUILD` overrides) —
  monotonic, no bookkeeping.
- The script validates before uploading (server-parity checks, ~20 s,
  reported inline instead of by queue email).
- After upload: ASC → TestFlight shows the build "Processing" for a few
  minutes to an hour. First build triggers the **export compliance
  question** if the Info.plist answer needs supplementing — ours ships
  `ITSAppUsesNonExemptEncryption = true`, so answer the questionnaire once
  in ASC (answers in `metadata.md`; France declaration consequence in
  `APPSTORE.md` §2.5).

## Phase 5 — TestFlight internal smoke test (strongly recommended, zero review)

You (Account Holder) are automatically an eligible internal tester. Install
via TestFlight and verify on a physical phone the three things that once
crashed in this exact codebase (fixed in `project.yml`, but TCC only proves
itself on-device):
- [ ] Scan-pairing opens the camera **with a permission prompt, no crash**.
- [ ] App lock triggers Face ID without a crash.
- [ ] LAN direct connection shows the Local Network permission prompt and
      connects.
- [ ] A push arrives with the app killed; tapping it opens the session.

## Phase 6 — version page + submit (~30 min)

1. App Store tab → iOS App 1.0 → paste from `metadata.md`: Description,
   Keywords, Promotional Text, Support URL (`https://rowel.novabox.ai/help`),
   Marketing URL (`https://rowel.novabox.ai`), Copyright `2026 <name>`,
   What's New (`First release.`).
2. Upload the six 6.9" screenshots (`screenshots-spec.md`).
3. **App Review Information**: paste notes from `review-notes.md` §2 (with
   the real `<VIDEO URL>`); attach the demo video file; sign-in required:
   **No** (no accounts exist); contact phone + email that get answered.
4. Select the processed build.
5. Version Release: choose **Manually release this version** (you control
   launch timing for the X/PH push; you can flip to automatic later).
6. **Submit for Review.** (App Manager can do this; no Account Holder step.)

## Phase 7 — after submission

- Typical first response inside 24–48 h. If rejected → Resolution Center
  playbook in `review-notes.md` §5 (reply first, escalate rungs B→D only as
  forced).
- On approval with manual release: release when the launch posts are ready
  to go out (`marketing/launch/`).
- Post-release, non-Apple obligations (own deadlines, from `APPSTORE.md`
  §2): one-time BIS/NSA open-source notification email; one-time
  self-classification CSV before 2027-02-01; France declaration if the
  conservative export answers were used; keep the compliance rationale
  archived 5 years.

## Field-to-file map (copy sources)

| ASC field | Source |
|---|---|
| Name / Subtitle / Promo / Description / Keywords / URLs / Copyright | `marketing/appstore/metadata.md` |
| Age rating answers | `metadata.md` (table) |
| App Privacy answers | `marketing/appstore/privacy-questionnaire.md` |
| Export compliance answers | `metadata.md` (table) + `APPSTORE.md` §2.7 |
| Review notes + video | `marketing/appstore/review-notes.md` |
| Screenshots | `marketing/appstore/screenshots-spec.md` |


## Where this actually stands — 2026-09-01

**Done without the account holder** (driven through the App Store Connect and
developer-portal web sessions):

- App ID `ai.novabox.rowel`, with Push Notifications and Time Sensitive
  Notifications. Both are needed: the app sets
  `interruptionLevel = .timeSensitive` and the relay sends
  `interruption-level: time-sensitive`.
- App record **6807263060** — `Rowel: DeepSeek Harness Remote`, English (U.S.),
  SKU `rowel-ios`, Full Access, iOS only.
- Screenshots: the six 6.9" shots (1320×2868) from `marketing/shots` uploaded to
  the 1.0 page. Apple reuses them for 6.5" automatically.
- Pricing: free, in all 175 countries and regions, confirmed.
- Availability: all 175 countries and regions.
- Version 1.0 fields typed: promotional text, description, keywords, support and
  marketing URLs, copyright, review notes, contact first/last name and email,
  and "sign-in required" cleared — there are no accounts to give a reviewer.

**Blocked on the account holder — one field.** App Review Information wants a
**phone number**, with a `+` and a country code. Apple uses it to reach a human
during review, so nobody else can supply it, and the version page will not save
without it. Everything in the list above that says "typed" is typed but not yet
persisted for that reason; the copy all lives in `metadata.md` and
`review-notes.md`, so refilling it is mechanical.

**Also needs the account holder, but not yet blocking:**

- **EU trader status**, in the Business section. Without it the app cannot be
  submitted for the European Union at all, and the account has been showing the
  banner. It asks for a legal identity — individual or company — which is a
  disclosure only the holder can make.
- **An App Store Connect API key.** The account currently has none (the `.p8`
  at `~/.rowel/secrets/AuthKey_3M4859Q6U7.p8` does not correspond to any live
  key), so `ios/release.sh` has nothing to authenticate with. Generate one under
  Users and Access → Integrations; the issuer id is shown once, above the key
  list, and the `.p8` downloads exactly once.

**Then, in order:**

1. Save the version page.
2. App Privacy questionnaire — answers and their source-code evidence are in
   `privacy-questionnaire.md`.
3. Build and upload with `ios/release.sh` (`ASC_KEY_ID`, `ASC_ISSUER_ID`,
   `ASC_KEY_PATH`, `ROWEL_TEAM_ID=AVKUVD4FPN`).
4. Attach the build to 1.0, then Add for Review.

**Left at Apple's defaults, worth a glance before submitting:** the app is set
to appear on Apple silicon Macs and on Apple Vision Pro. Both are Apple's
default for an iOS app. Vision Pro is inert — 1.0 is marked not compatible —
but the Mac one puts an iPhone client for a Mac-side agent on the Mac App
Store, which may be more confusing than useful.
