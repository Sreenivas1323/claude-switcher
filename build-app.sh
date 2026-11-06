#!/bin/bash
# Builds ClaudeSwitcher.app (release, universal) into ./build and optionally installs it.
#   ./build-app.sh            -> build/ClaudeSwitcher.app
#   ./build-app.sh --install  -> also copies to ~/Applications and launches it
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClaudeSwitcher.app
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ClaudeSwitcher

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitcher"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Switcher</string>
  <key>CFBundleDisplayName</key><string>Claude Switcher</string>
  <key>CFBundleIdentifier</key><string>in.ssaisreenivas.ClaudeSwitcher</string>
  <key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Opens Terminal to run "claude auth login" when you add an account.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x ClaudeSwitcher 2>/dev/null || true
  rm -rf ~/Applications/ClaudeSwitcher.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/ClaudeSwitcher.app
  echo "Installed to ~/Applications/ClaudeSwitcher.app"
fi
