#!/usr/bin/env bash
#
# Archive the app and hand it to App Store Connect.
#
# Authentication is an App Store Connect API key rather than an Apple ID signed
# into Xcode, and that is the point: a key works without a person at the
# keyboard, survives a machine being reinstalled, and can be revoked on its own
# without touching the account. An Xcode sign-in works too, but only while
# someone is there to answer the two-factor prompt.
#
# Usage:
#   ios/release.sh                 archive, export, upload
#   ios/release.sh --no-upload     archive and export only, leave the .ipa
#
# Environment:
#   ROWEL_TEAM_ID        the paid team's 10-character id. NOT the Personal Team.
#   ASC_KEY_ID           the App Store Connect key id, from the key's row.
#   ASC_ISSUER_ID        the issuer id, shown once above the key list.
#   ASC_KEY_PATH         path to the AuthKey_<id>.p8. Downloadable exactly once.
#   ROWEL_BUILD          build number to stamp. Defaults to the commit count,
#                        which rises monotonically and needs no bookkeeping.
#
# The key file is a private key. Keep it out of the repo — .gitignore has the
# pattern, but the safer habit is to keep it in ~/.appstoreconnect/private_keys
# where Xcode and altool both look for it by default.

set -euo pipefail

cd "$(dirname "$0")/.."

UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

ARCHIVE="${TMPDIR:-/tmp}/Rowel.xcarchive"
EXPORT="${TMPDIR:-/tmp}/RowelExport"

missing() {
  echo "release: \$$1 is not set." >&2
  echo "  Create a key at App Store Connect → Users and Access → Integrations." >&2
  exit 1
}

: "${ROWEL_TEAM_ID:?release: \$ROWEL_TEAM_ID is not set. It is the paid team, not the Personal Team.}"
if [ "$UPLOAD" = 1 ]; then
  [ -n "${ASC_KEY_ID:-}" ]     || missing ASC_KEY_ID
  [ -n "${ASC_ISSUER_ID:-}" ]  || missing ASC_ISSUER_ID
  [ -n "${ASC_KEY_PATH:-}" ]   || missing ASC_KEY_PATH
  [ -f "$ASC_KEY_PATH" ]       || { echo "release: no key file at $ASC_KEY_PATH" >&2; exit 1; }
fi

# A build number App Store Connect will accept is one it has not seen. The
# commit count is the cheapest thing that is always larger than last time.
BUILD="${ROWEL_BUILD:-$(git rev-list --count HEAD)}"
echo "release: building $BUILD for team $ROWEL_TEAM_ID"

ROWEL_TEAM_ID="$ROWEL_TEAM_ID" xcodegen generate --spec ios/project.yml --quiet

rm -rf "$ARCHIVE" "$EXPORT"

# The same App Store Connect key that authorises the upload also authorises
# provisioning. Without it, `-allowProvisioningUpdates` needs an Apple ID
# signed into Xcode and fails with "No Accounts: Add a new account in Accounts
# settings" followed by "No profiles for <bundle id> were found" — which reads
# like a missing profile and is really a missing login. Passing the key here
# means a machine that has never opened Xcode can still archive.
AUTH=()
if [ "$UPLOAD" = 1 ]; then
  AUTH=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

xcodebuild archive \
  -project ios/Rowel.xcodeproj \
  -scheme Rowel \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$ROWEL_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD"

# The export options name the team too, because the archive records the team it
# was signed by and the export can legitimately differ from it.
OPTIONS="${TMPDIR:-/tmp}/RowelExportOptions.plist"
sed "s|<string>AVKUVD4FPN</string>|<string>$ROWEL_TEAM_ID</string>|" ios/ExportOptions.plist > "$OPTIONS"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$OPTIONS" \
  -allowProvisioningUpdates \
  "${AUTH[@]}"

IPA="$(find "$EXPORT" -name '*.ipa' -print -quit)"
[ -n "$IPA" ] || { echo "release: export produced no .ipa" >&2; exit 1; }
echo "release: exported $IPA"

if [ "$UPLOAD" = 0 ]; then
  echo "release: --no-upload, stopping here"
  exit 0
fi

# `--p8-file-path` rather than letting altool hunt for the key. Without it the
# only way altool finds an AuthKey_<id>.p8 is by scanning four fixed
# directories — ./private_keys, ~/private_keys, ~/.private_keys, and
# ~/.appstoreconnect/private_keys — so a $ASC_KEY_PATH pointing anywhere else
# passed the existence check above and then failed at upload with
# "Failed to load AuthKey file. (-43)", naming four paths the caller never
# mentioned. Xcode 26's altool takes the path directly; say it.
AUTH=(
  --api-key "$ASC_KEY_ID"
  --api-issuer "$ASC_ISSUER_ID"
  --p8-file-path "$ASC_KEY_PATH"
)

# Validate before upload. The same checks run server-side afterwards, but they
# run in a queue and report by email; here they report in twenty seconds.
xcrun altool --validate-app \
  --type ios --file "$IPA" \
  "${AUTH[@]}"

xcrun altool --upload-app \
  --type ios --file "$IPA" \
  "${AUTH[@]}"

echo "release: build $BUILD uploaded. Processing takes a few minutes before"
echo "         it appears in TestFlight."
