#!/bin/bash
# Run in YOUR OWN Terminal (the Claude sandbox blocks Bluetooth). Serves Nearby
# Connections over Bluetooth Classic (RFCOMM) — the medium Quick Start actually
# bootstraps on (GMS decompile: source discovers {BLE,BT-Classic}, connects over
# BT-Classic). Publishes an SDP service under the Nearby service UUID and accepts
# an RFCOMM channel, then runs the UKEY2/D2D state machine on it.
#
# It prints this Mac's Bluetooth MAC — use that as the injected
# D2DDevice.bluetoothMacAddr so the phone dials us directly (no discovery).
# Allow Bluetooth if macOS prompts the first time.
cd "$(dirname "$0")/.."
PLIST="$PWD/Info.plist"
swift build -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" || exit 1
exec .build/debug/phonehubkit-selftest btserve "${1:-180}"
