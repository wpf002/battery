#!/bin/bash
# Builds ClaudeBattery.app into ./build, installs to /Applications, launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClaudeBattery.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O \
  -o "$APP/Contents/MacOS/ClaudeBattery" \
  Sources/main.swift \
  -framework AppKit -framework Security -framework ServiceManagement

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"   # ad-hoc signature so the Keychain grant sticks

pkill -x ClaudeBattery 2>/dev/null || true
rm -rf /Applications/ClaudeBattery.app
cp -R "$APP" /Applications/
open /Applications/ClaudeBattery.app
echo "Installed and launched. Approve the Keychain prompt (Always Allow)."
