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
# A real identity keeps the signature stable across rebuilds, so the Keychain
# grant survives; ad-hoc changes every build and re-prompts for the password.
ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID/{print $2; exit}')
codesign --force --sign "${ID:--}" "$APP"

pkill -x ClaudeBattery 2>/dev/null || true
rm -rf /Applications/ClaudeBattery.app
cp -R "$APP" /Applications/
open /Applications/ClaudeBattery.app
echo "Installed and launched. Approve the Keychain prompt (Always Allow)."
