# Submission Runbook — zero to "Waiting for Review"

Ordered. Steps marked **[Account Holder]** can only be done by the account
holder (this is a personal developer account, so that is you — but they
cannot be delegated to an API key or a future team member). Everything else
needs Admin or App Manager.

Facts assumed (verified in repo): bundle id `ai.novabox.reins`, team
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
3. Site URLs live — verified 2026-09-01: `https://reins.novabox.ai/` ,
   `/help`, `/privacy` all HTTP 200. (**Use extensionless paths everywhere;
   `.html` variants 404.**)
4. Repo public at `github.com/0x5446/reins` (the description and review
   notes point reviewers at it).

## Phase 1 — App Store Connect API key (one-time, ~10 min)

1. **[Account Holder]** ASC → Users and Access → **Integrations** →
   App Store Connect API → **Request Access** (first time only) → agree →
   Submit. Usually instant.
2. Team Keys tab → **Generate API Key**:
   - Name: `reins-release` (reference only)
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
   `ai.novabox.reins` with **Push Notifications** capability. (It exists if
   the app has ever been signed for a device on this team; `release.sh`'s
   `-allowProvisioningUpdates` maintains it. If missing, register it there
   first — the ASC dropdown only lists registered IDs.)
2. ASC → My Apps → **+** → **New App**:
   | Field | Value |
   |---|---|
   | Platforms | iOS |
   | Name | `Reins` (fallbacks in `metadata.md` if taken) |
   | Primary Language | English (U.S.) |
   | Bundle ID | `ai.novabox.reins` (from dropdown — not a wildcard) |
   | SKU | `reins-ios` (internal, immutable, never shown) |
   | User Access | Full Access |

## Phase 3 — app-level settings (~30 min, all from the prepared files)

1. **App Information**: Subtitle; Category **Developer Tools** (primary) +
   **Utilities** (secondary); Content Rights: does not contain third-party
   content; Age Rating questionnaire → answers table in `metadata.md`
   (expect 4+).
2. **App Privacy**: privacy policy URL `https://reins.novabox.ai/privacy`;
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
export REINS_TEAM_ID=AVKUVD4FPN
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

- Build number defaults to the git commit count (`REINS_BUILD` overrides) —
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
   Keywords, Promotional Text, Support URL (`https://reins.novabox.ai/help`),
   Marketing URL (`https://reins.novabox.ai`), Copyright `2026 <name>`,
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
