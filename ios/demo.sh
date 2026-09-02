#!/usr/bin/env bash
#
# Record the launch demo: an agent stopped on a permission request, and a
# person unblocking it from a phone.
#
# Two screens, both on this Mac, neither of them a camera. The "phone" is the
# simulator, which `simctl` records directly; the Mac side is the harness's own
# web UI showing the same session, which resumes when the tap lands. Nothing
# here is staged — the approval is a real one, provoked by running the session
# under a `read-only` sandbox so the agent's first write is refused and it has
# to ask.
#
# Usage:
#   ios/demo.sh              set up an approval, record both screens
#   ios/demo.sh --arm        set up the approval and stop, to record by hand
#
# Output: marketing/video/raw/{phone,mac}.mov, ready for the Remotion edit.
#
# Requires the screenshot harness (ios/screenshots.sh) to be up: this borrows
# its dsh, its Bridle and its sample repository rather than standing up a
# second one.

set -euo pipefail

cd "$(dirname "$0")"
root="$(cd .. && pwd)"
home="${ROWEL_SHOTS_HOME:-$HOME/rowel-shots}"
port="${ROWEL_SHOTS_PORT:-3082}"
device="${ROWEL_SHOTS_DEVICE:-iPhone 17 Pro Max}"
sample="$HOME/code/checkout-api"
out="$root/marketing/video/raw"

# Where the Mac half lives, in points, and the same rectangle in the form
# AppleScript wants (left, top, right, bottom). Fixed rather than measured:
# the edit crops and scales against these numbers, so a window that moved
# between takes would silently change the framing.
MAC_RECT="${ROWEL_DEMO_RECT:-0,60,1000,820}"
MAC_RECT_AS=$(printf '%s' "$MAC_RECT" | awk -F, '{print $1", "$2", "($1+$3)", "($2+$4)}')
# The same rectangle in pixels, for the crop: the display is 2x.
MAC_X=$(printf '%s' "$MAC_RECT" | cut -d, -f1 | awk '{print $1*2}')
MAC_Y=$(printf '%s' "$MAC_RECT" | cut -d, -f2 | awk '{print $1*2}')
MAC_W=$(printf '%s' "$MAC_RECT" | cut -d, -f3 | awk '{print $1*2}')
MAC_H=$(printf '%s' "$MAC_RECT" | cut -d, -f4 | awk '{print $1*2}')

if [ -t 1 ]; then bold=$(printf '\033[1m'); off=$(printf '\033[0m'); else bold=''; off=''; fi
say() { printf '%s==>%s %s\n' "$bold" "$off" "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

curl -s -o /dev/null -m 2 "http://127.0.0.1:$port/" \
  || fail "no harness on :$port — run ios/screenshots.sh first."

rpc() {
  printf '{"type":"client-request","rpcId":"d%s","method":"%s","payload":%s}' \
    "$RANDOM" "$1" "$2" \
    | curl -s -m 90 -X POST "http://127.0.0.1:$port/api/$1" \
        -H 'content-type: application/json' --data-binary @-
}

# Can anything on this machine record the Mac half?
#
# Checked before the expensive part rather than after. Screen recording is a
# permission macOS grants per binary through System Settings, and a process
# without it does not fail — `screencapture` hangs, and ffmpeg simply reports
# no screen among its capture devices. The first take of this ran the whole
# four-minute sequence and produced one recording and one missing file.
mac_recorder() {
  if ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -qi "capture screen"; then
    printf 'ffmpeg'
  else
    printf 'none'
  fi
}

zone() {
  local link
  link=$(readlink /etc/localtime 2>/dev/null)
  case "$link" in
    */zoneinfo/*) printf '%s' "${link#*/zoneinfo/}" ;;
    *) printf 'UTC' ;;
  esac
}

# --- An agent that is actually stuck -----------------------------------------

# Provoked by the sandbox, not by a prompt asking it to pause.
#
# Asking an agent to "stop and ask" produces a sentence; a permission request
# is a different thing — the run is suspended and the harness is holding the
# tool call. Only the second one is what the app is for, and the only reliable
# way to cause it is to deny the write: under `read-only` the first attempt is
# refused, and escalating needs consent.
arm() {
  say "arming an approval"
  # Take the file away first. The last take answered Allow, so the file it
  # asked to create exists — and an agent asked to create something that is
  # already there reads it and reports, which needs no permission and produces
  # no card. The approval has to be provoked by real work, so the work has to
  # be real.
  rm -f "$sample/CHANGELOG.md"
  python3 - "$port" "$(zone)" "$sample" <<'PY'
import json, sys, time, urllib.request

port, zone, sample = sys.argv[1], sys.argv[2], sys.argv[3]

def call(method, payload):
    body = json.dumps({"type": "client-request", "rpcId": "arm",
                       "method": method, "payload": payload}).encode()
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/{method}", data=body,
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(request, timeout=90) as answer:
        return json.load(answer)

def preset(value):
    described = call("settings.describe", {})
    namespaces = described["result"]["value"]["namespaces"]
    revision = next((n.get("revision") for n in namespaces if n.get("ns") == "permission"), None)
    call("settings.update", {"ns": "permission", "patch": {"defaultPreset": value},
                             "expectedRevision": revision})

# Retire any earlier take, so the list shows one of these and not four.
for session in call("session.list", {})["result"]["value"]["items"]:
    if session.get("projections", {}).get("values", {}).get("title") == "Ship the currency fix":
        call("workspace.archiveSession", {"sessionId": session["sessionId"]})

# The preset is read when the session is created, so it has to be set first and
# put back afterwards — it is machine-wide, and leaving a harness read-only
# would be a confusing thing to find later.
preset("read-only")
try:
    session = call("session.create", {"cwd": sample})["result"]["value"]["sessionId"]
    answer = call("session.prompt", {
        "sessionId": session, "mode": "queue", "clientTimeZone": zone,
        "content": [{"type": "text", "text":
            'Add a CHANGELOG.md to this repository with one entry: '
            '"Add CAD and AUD support". Write the file.'}],
    })
    if not answer["result"].get("value", {}).get("accepted"):
        raise SystemExit(f"the harness refused the prompt: {json.dumps(answer)[:300]}")
    time.sleep(1.5)
    call("session.rename", {"sessionId": session, "title": "Ship the currency fix"})
finally:
    preset("workspace-write")

# Wait for the agent to actually reach the question. Recording before it does
# would capture a spinner and call it a demo.
for _ in range(60):
    time.sleep(2)
    page = call("session.history", {"sessionId": session, "maxMessages": 8})
    events = page["result"]["value"]["events"]
    if any(e.get("event", {}).get("type") == "approval/asked" for e in events):
        print("approval pending")
        break
else:
    raise SystemExit("the agent never asked for permission")
PY
}

# --- Both screens ------------------------------------------------------------

record() {
  local udid
  udid=$(xcrun simctl list devices available | grep -m1 "$device (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [ -n "$udid" ] || fail "no simulator called '$device'."
  xcrun simctl boot "$udid" 2>/dev/null || true
  open -a Simulator
  # Regenerate first. The project file is not committed, so a driver added
  # since the last generate is not in the scheme — and `-only-testing` against
  # a test that does not exist fails in a way that still leaves two recordings
  # on disk, of a home screen.
  xcodegen generate --spec project.yml >/dev/null
  # A test runner left over from before the rename sits on the home screen and
  # ends up in the shot.
  xcrun simctl uninstall "$udid" ai.novabox.reins.uitests.xctrunner 2>/dev/null || true
  mkdir -p "$out"
  rm -f "$out/phone.mov" "$out/mac.mov"

  # The Mac half is the harness's own web UI on the same session. It is the
  # honest counterpart to the phone: the same conversation, seen from the
  # machine that is blocked, resuming when the answer arrives.
  open -a "Google Chrome" --args --new-window "http://127.0.0.1:$port/" >/dev/null 2>&1 || true
  sleep 4
  # Put it somewhere known and record that rectangle rather than the display.
  # The simulator is on the same screen, and a full-display capture would put
  # the phone inside the Mac half of the shot — the one thing the edit needs
  # kept apart, since the whole point is that these are two machines.
  osascript -e "tell application \"Google Chrome\" to set bounds of front window to {$MAC_RECT_AS}" \
    >/dev/null 2>&1 || say "could not place the Chrome window; recording the rect anyway"
  # And the simulator clear of it, or it sits on top of the rectangle being
  # recorded and the Mac half of the shot contains a phone.
  osascript -e 'tell application "System Events" to tell process "Simulator" to set position of front window to {1010, 60}' \
    >/dev/null 2>&1 || true
  sleep 1

  say "recording"
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$out/phone.mov" &
  local phone_pid=$!
  local mac_pid=""
  if [ "$(mac_recorder)" = ffmpeg ]; then
    local screen
    screen=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
      | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p' | head -1)
    ffmpeg -y -loglevel error -f avfoundation -capture_cursor 0 -framerate 30 \
      -i "${screen}:none" -vf "crop=${MAC_W}:${MAC_H}:${MAC_X}:${MAC_Y}" \
      -t 60 "$out/mac.mov" &
    mac_pid=$!
  else
    say "no screen-recording permission — the Mac half is being skipped."
    say "  grant it in System Settings › Privacy & Security › Screen Recording,"
    say "  to whichever program runs this, then run ios/demo.sh again."
  fi
  sleep 2

  local link
  link=$(ROWEL_HOME="$home/rowel-home" node "$root/bridle/lib/cli.js" pair --link 2>/dev/null \
    | sed -n 's/^link: *//p')
  [ -n "$link" ] || fail "could not mint a pairing invitation"

  # `pipefail` so a build that never ran the test is not reported as success
  # by the grep at the end of the pipe. That is how the first take produced
  # eighteen seconds of a home screen and said nothing was wrong.
  set +e
  set -o pipefail
  TEST_RUNNER_ROWEL_PAIR_LINK="$link" xcodebuild test \
    -project Rowel.xcodeproj -scheme RowelUI -destination "id=$udid" \
    -only-testing:RowelUITests/Demo 2>&1 | grep -E "Test Case|error:"
  local status=$?
  set +o pipefail
  set -e

  # SIGINT rather than SIGTERM: both writers finalise the container on
  # interrupt and truncate on terminate, and a truncated .mov is unplayable
  # rather than short.
  kill -INT "$phone_pid" 2>/dev/null || true
  [ -n "$mac_pid" ] && kill -INT "$mac_pid" 2>/dev/null
  wait "$phone_pid" 2>/dev/null || true
  [ -n "$mac_pid" ] && { wait "$mac_pid" 2>/dev/null || true; }

  [ -s "$out/phone.mov" ] || fail "the simulator recording is empty"
  say "raw footage in marketing/video/raw"
  for f in "$out"/*.mov; do
    [ -e "$f" ] || continue
    printf '    %-10s %s  %ss\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" \
      "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)"
  done
  return $status
}

case "${1:-}" in
  --arm) arm ;;
  *) arm; record ;;
esac
