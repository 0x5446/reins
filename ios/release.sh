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
#   REINS_TEAM_ID        the paid team's 10-character id. NOT the Personal Team.
#   ASC_KEY_ID           the App Store Connect key id, from the key's row.
#   ASC_ISSUER_ID        the issuer id, shown once above the key list.
#   ASC_KEY_PATH         path to the AuthKey_<id>.p8. Downloadable exactly once.
#   REINS_BUILD          build number to stamp. Defaults to the commit count,
#                        which rises monotonically and needs no bookkeeping.
#
# The key file is a private key. Keep it out of the repo — .gitignore has the
# pattern, but the safer habit is to keep it in ~/.appstoreconnect/private_keys
# where Xcode and altool both look for it by default.

set -euo pipefail

cd "$(dirname "$0")/.."

UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

ARCHIVE="${TMPDIR:-/tmp}/Reins.xcarchive"
EXPORT="${TMPDIR:-/tmp}/ReinsExport"

missing() {
  echo "release: \$$1 is not set." >&2
  echo "  Create a key at App Store Connect → Users and Access → Integrations." >&2
  exit 1
}

: "${REINS_TEAM_ID:?release: \$REINS_TEAM_ID is not set. It is the paid team, not the Personal Team.}"
if [ "$UPLOAD" = 1 ]; then
  [ -n "${ASC_KEY_ID:-}" ]     || missing ASC_KEY_ID
  [ -n "${ASC_ISSUER_ID:-}" ]  || missing ASC_ISSUER_ID
  [ -n "${ASC_KEY_PATH:-}" ]   || missing ASC_KEY_PATH
  [ -f "$ASC_KEY_PATH" ]       || { echo "release: no key file at $ASC_KEY_PATH" >&2; exit 1; }
fi

# A build number App Store Connect will accept is one it has not seen. The
# commit count is the cheapest thing that is always larger than last time.
BUILD="${REINS_BUILD:-$(git rev-list --count HEAD)}"
echo "release: building $BUILD for team $REINS_TEAM_ID"

REINS_TEAM_ID="$REINS_TEAM_ID" xcodegen generate --spec ios/project.yml --quiet

rm -rf "$ARCHIVE" "$EXPORT"

xcodebuild archive \
  -project ios/Reins.xcodeproj \
  -scheme Reins \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$REINS_TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD"

# The export options name the team too, because the archive records the team it
# was signed by and the export can legitimately differ from it.
OPTIONS="${TMPDIR:-/tmp}/ReinsExportOptions.plist"
sed "s|<string>AVKUVD4FPN</string>|<string>$REINS_TEAM_ID</string>|" ios/ExportOptions.plist > "$OPTIONS"

EXPORT_AUTH=()
if [ "$UPLOAD" = 1 ]; then
  EXPORT_AUTH=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$OPTIONS" \
  -allowProvisioningUpdates \
  "${EXPORT_AUTH[@]}"

IPA="$(find "$EXPORT" -name '*.ipa' -print -quit)"
[ -n "$IPA" ] || { echo "release: export produced no .ipa" >&2; exit 1; }
echo "release: exported $IPA"

if [ "$UPLOAD" = 0 ]; then
  echo "release: --no-upload, stopping here"
  exit 0
fi

# Validate before upload. The same checks run server-side afterwards, but they
# run in a queue and report by email; here they report in twenty seconds.
xcrun altool --validate-app \
  --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

xcrun altool --upload-app \
  --type ios --file "$IPA" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "release: build $BUILD uploaded. Processing takes a few minutes before"
echo "         it appears in TestFlight."
