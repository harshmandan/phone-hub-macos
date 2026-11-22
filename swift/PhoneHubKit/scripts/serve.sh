#!/bin/bash
# Run from YOUR OWN Terminal (sandbox blocks the network/mDNS). Advertises the
# Mac as a Nearby endpoint. Then open Quick Share on the phone and look for it.
cd "$(dirname "$0")/.."
swift build >/dev/null 2>&1 || { swift build; exit 1; }
exec .build/debug/phonehubkit-selftest serve "${1:-120}"
