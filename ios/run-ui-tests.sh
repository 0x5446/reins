#!/usr/bin/env bash
#
# Drive the app against a real Bridle.
#
# Unlike run-tests.sh, this needs a machine to talk to. It starts one if there
# is not one already, mints a fresh pairing link, and hands it to the test
# runner. A pairing token is single-use, so the link has to be minted per run.
#
# Environment:
#   ROWEL_DEVICE   destination id. Defaults to a booted simulator; pass a real
#                  device's UDID (from `xcrun devicectl list devices`) to run on
#                  hardware.
#   ROWEL_TEAM_ID  signing team. Required for a device run.

set -euo pipefail

cd "$(dirname "$0")"
root="$(cd .. && pwd)"

if [ -t 1 ]; then bold=$(printf '\033[1m'); off=$(printf '\033[0m'); else bold=''; off=''; fi
say() { printf '%s==>%s %s\n' "$bold" "$off" "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is not installed. brew install xcodegen"
[ -f "$root/bridle/lib/cli.js" ] || fail "The Bridle is not built. Run: npm run build"

# --- A machine to talk to ---------------------------------------------------

started_bridle=""
bridle_pid=""
if ! pgrep -f "bridle/lib/cli.js" >/dev/null 2>&1; then
  say "Starting a Bridle"
  ( cd "$root" && exec node bridle/lib/cli.js --direct-port 61000 >/tmp/rowel-uitest-bridle.log 2>&1 ) &
  bridle_pid=$!
  started_bridle="yes"
  sleep 8
fi
# Only clean up a Bridle this script started, and only that one. `pkill` by
# pattern would take down a Bridle the developer is using for something else —
# which is exactly what happened once, silently, mid-session.
cleanup() {
  [ -n "$started_bridle" ] || return 0
  [ -n "$bridle_pid" ] || return 0
  kill "$bridle_pid" 2>/dev/null || true
}
trap cleanup EXIT

link=$(cd "$root" && node bridle/lib/cli.js pair --link 2>/dev/null | sed -n 's/^link: *//p')
[ -n "$link" ] || fail "Could not mint a pairing link. Check /tmp/rowel-uitest-bridle.log"

# --- Destination ------------------------------------------------------------

device="${ROWEL_DEVICE:-}"
if [ -z "$device" ]; then
  device=$(xcrun simctl list devices booted -j | python3 -c "
import json,sys
for runtime in json.load(sys.stdin)['devices'].values():
    for d in runtime:
        if d.get('state') == 'Booted':
            print(d['udid']); raise SystemExit
")
fi
[ -n "$device" ] || fail "No booted simulator and no ROWEL_DEVICE. Boot one, or pass a device UDID."

# A simulator id and a device id take the same -destination form here, so the
# only thing that changes between the two is whether signing is required.
say "Testing on $device"

ROWEL_TEAM_ID="${ROWEL_TEAM_ID:-}" xcodegen generate --quiet

# xcodebuild hands the test process only those variables prefixed TEST_RUNNER_,
# and strips the prefix on the way through.
export TEST_RUNNER_ROWEL_PAIR_LINK="$link"

args=(
  -project Rowel.xcodeproj
  -scheme RowelUI
  -configuration Debug
  -destination "id=$device"
  -derivedDataPath build/ui
  -resultBundlePath build/RowelUI.xcresult
  -allowProvisioningUpdates
)
[ -n "${ROWEL_TEAM_ID:-}" ] && args+=("DEVELOPMENT_TEAM=$ROWEL_TEAM_ID")

rm -rf build/RowelUI.xcresult
if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  xcodebuild "${args[@]}" test | xcbeautify
else
  xcodebuild "${args[@]}" test
fi
