#!/bin/bash
# Verify the `phonehub … json` event mode the menu-bar app consumes: arm with
# bleweave, then open the NC channel in json mode and show the EVENT lines.
cd "$(dirname "$0")/.."
BIN=.build/release/phonehubkit-selftest
ID=/Users/harsh/Developer/phone-hub-macos/probe/phone_identity.json
MAC="${1:-AA:BB:CC:DD:EE:FF}"
"$BIN" bleweave 120 "$ID" > /tmp/arm.log 2>&1 &
ARM=$!
trap 'kill $ARM 2>/dev/null' EXIT
echo "arming (bleweave)…"
for i in $(seq 1 40); do grep -q "secure channel established" /tmp/arm.log && break; sleep 1; done
grep -q "secure channel established" /tmp/arm.log || { echo "arm failed; tail:"; tail -3 /tmp/arm.log; exit 1; }
echo "armed; opening json NC in 8s…"; sleep 8
( sleep 22; echo "photos" ) | "$BIN" phonehub "$MAC" 45 "$ID" json 2>/dev/null \
  | grep --line-buffered -E "^EVENT|established over Nearby"
echo "done"
