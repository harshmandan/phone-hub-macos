#!/bin/bash
# Run a BLE scan from YOUR OWN Terminal (not the Claude sandbox, which blocks
# Bluetooth). macOS will prompt to allow Bluetooth the first time — allow it.
# Lists what is advertising near the Mac, with service UUIDs + service data.
cd "$(dirname "$0")/.."
PLIST="$PWD/Info.plist"
swift build -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" || exit 1
exec .build/debug/phonehubkit-selftest bleweave "${1:-120}" "${2:-../../probe/phone_identity.json}"
