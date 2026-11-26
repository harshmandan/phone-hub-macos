#!/bin/bash
# Phone Hub over Nearby Connections, from YOUR OWN Terminal (the Claude sandbox
# blocks Bluetooth). macOS prompts for Bluetooth the first time — allow it.
#
# The phone only arms its Nearby "secure_channel" listener while a Better Together
# BLE weave channel is live, so this holds a `bleweave` connection open in the
# background, waits for it to authenticate, then opens the Phone Hub NC channel.
#
# Usage: phonehub.sh <phone-bt-mac> [seconds=90] [action]
#   action: photos | ring | dismiss | reply:<text>  (acted on the first snapshot)
#     photos  — fetch recent camera-roll items; thumbnails saved (owner-only) to
#               ~/Library/Application Support/PhoneHub/photos
# Example: phonehub.sh 00:00:00:00:00:00 90 reply:on my way
set -e
cd "$(dirname "$0")/.."
PLIST="$PWD/Info.plist"
# Build ONLY the CLI target — the SwiftUI app target needs Xcode's toolchain, so a
# bare `swift build` under Command Line Tools fails on the SwiftUI macro plugin.
swift build --target phonehubkit-selftest \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" || exit 1
BIN=.build/debug/phonehubkit-selftest

MAC="${1:?usage: phonehub.sh <phone-bt-mac> [seconds] [action]}"
SECS="${2:-90}"
ACTION="${3:-}"
ID="../../probe/phone_identity.json"

# Hold a BLE weave channel open the whole time (arms the phone's NC listener).
# Arm only — do NOT let the arming weave channel turn on the phone's hotspot
# (it reconfigures Wi-Fi and drops Wi-Fi adb / links mid-session).
PHONEHUB_ARM_ONLY=1 "$BIN" bleweave "$((SECS + 25))" "$ID" > /tmp/phonehub-bleweave.log 2>&1 &
BLE_PID=$!
trap 'kill $BLE_PID 2>/dev/null' EXIT

echo "[phonehub.sh] bleweave arming the phone (pid $BLE_PID, log /tmp/phonehub-bleweave.log) …"
# Wait until it authenticates (phone then starts Nearby Phone Hub advertising).
for i in $(seq 1 30); do
  if grep -q "secure channel established" /tmp/phonehub-bleweave.log 2>/dev/null; then break; fi
  sleep 1
done
sleep 10   # let the phone bring up its Nearby secure_channel listener

# The RFCOMM accept depends on a live BR/EDR link + the phone's arming window, so
# retry a few times until a status snapshot comes back.
echo "[phonehub.sh] opening Phone Hub over Nearby Connections …"
for try in 1 2 3; do
  "$BIN" phonehub "$MAC" 30 "$ID" "$ACTION" | tee /tmp/phonehub-run.log
  if grep -q "PHONE HUB over Nearby" /tmp/phonehub-run.log; then exit 0; fi
  echo "[phonehub.sh] no snapshot yet (try $try/3) — settling before retry …"
  sleep 8   # reconnecting too fast makes GMS Nearby throttle us
done
echo "[phonehub.sh] gave up after 3 tries (phone's NC listener may not be armed)."
