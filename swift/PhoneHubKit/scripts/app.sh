#!/bin/bash
# Build the PhoneHub menu-bar app and bundle it into PhoneHub.app.
# The SwiftUI target needs Xcode's toolchain (CommandLineTools lacks the SwiftUI
# macro plugin); the CLI engine it spawns is embedded with its Bluetooth
# Info.plist so the child process can use CoreBluetooth.
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"
DEVDIR=/Applications/Xcode.app/Contents/Developer
PLIST="$ROOT/Info.plist"

echo "building app (Xcode toolchain)…"
DEVELOPER_DIR=$DEVDIR swift build -c release --target PhoneHubMenuBar
echo "building CLI engine (with Bluetooth Info.plist)…"
DEVELOPER_DIR=$DEVDIR swift build -c release --target phonehubkit-selftest \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST"

BIN="$ROOT/.build/release"
APP="$ROOT/.build/PhoneHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PhoneHubMenuBar" "$APP/Contents/MacOS/PhoneHubMenuBar"
cp "$BIN/phonehubkit-selftest" "$APP/Contents/MacOS/phonehubkit-selftest"

cat > "$APP/Contents/Info.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PhoneHub</string>
  <key>CFBundleDisplayName</key><string>Phone Hub</string>
  <key>CFBundleIdentifier</key><string>in.brewdex.phonehub</string>
  <key>CFBundleExecutable</key><string>PhoneHubMenuBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Phone Hub connects to your phone over Bluetooth.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Phone Hub connects to your phone over Bluetooth.</string>
</dict>
</plist>
PLISTEOF

echo "bundled: $APP"
# Ad-hoc sign the bundle (and the embedded CLI) so CoreBluetooth has a signed
# identity and the Bluetooth permission is tracked consistently.
echo "signing (ad-hoc)…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign failed — continuing unsigned)"
echo "launching…"
open "$APP"
