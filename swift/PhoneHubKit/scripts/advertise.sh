#!/bin/bash
# Run from YOUR OWN Terminal (the Claude sandbox blocks Bluetooth). Advertises
# the Mac as a Chromebook near the phone. Allow Bluetooth if macOS prompts.
cd "$(dirname "$0")/.."
PLIST="$PWD/Info.plist"
swift build -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" || exit 1
exec .build/debug/phonehubkit-selftest advertise "${1:-60}"
