#!/usr/bin/env bash
#
# Build and test the iOS app.
#
# Picks a simulator rather than taking one as an argument: the destination has to
# name a device that exists on this machine, and that list differs between Xcode
# versions and between a laptop and CI. REINS_SIM overrides when a specific
# device matters.

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed. brew install xcodegen" >&2
  exit 1
fi

# The project file is generated, not committed, so a fresh clone has to make one
# before xcodebuild has anything to open.
xcodegen generate --quiet

sim="${REINS_SIM:-}"
if [ -z "$sim" ]; then
  # Newest available iPhone. `xcrun simctl` lists in model order within a runtime,
  # so the last available iPhone is the newest one installed.
  sim=$(xcrun simctl list devices available | grep -oE '^ +iPhone [^(]*' | sed 's/ *$//;s/^ *//' | tail -1)
fi
if [ -z "$sim" ]; then
  echo "No iPhone simulator is installed. Open Xcode > Settings > Components." >&2
  exit 1
fi

echo "Testing on $sim"

# xcbeautify is nice to have and not worth a hard dependency; without it the raw
# log is still readable, just long.
if command -v xcbeautify >/dev/null 2>&1; then
  set -o pipefail
  xcodebuild -project Reins.xcodeproj -scheme Reins \
    -destination "platform=iOS Simulator,name=$sim" \
    -resultBundlePath build/Reins.xcresult \
    test | xcbeautify
else
  xcodebuild -project Reins.xcodeproj -scheme Reins \
    -destination "platform=iOS Simulator,name=$sim" \
    -resultBundlePath build/Reins.xcresult \
    test
fi
