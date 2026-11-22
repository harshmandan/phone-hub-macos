#!/bin/bash
# Run in YOUR OWN Terminal. Advertises as a Quick START target + prints the QR.
# Scan the QR from the phone's Quick Start / "set up with Android phone" flow.
cd "$(dirname "$0")/.."
swift build >/dev/null 2>&1 || { swift build; exit 1; }
exec .build/debug/phonehubkit-selftest qsserve "${1:-180}"
