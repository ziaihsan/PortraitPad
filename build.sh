#!/bin/bash
# Build PortraitPad.app (ad-hoc signed) into ./build
set -euo pipefail
cd "$(dirname "$0")"
APP=build/PortraitPad.app
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 \
  -import-objc-header Sources/CGVirtualDisplay.h \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia \
  Sources/main.swift -o "$APP/Contents/MacOS/PortraitPad"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.z.PortraitPad</string>
  <key>CFBundleName</key><string>PortraitPad</string>
  <key>CFBundleExecutable</key><string>PortraitPad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# A stable local identity keeps macOS privacy permissions (Screen Recording, Accessibility) across
# rebuilds; ad-hoc signatures change every build, so permissions would have to be granted again.
IDENTITY="PortraitPad Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "warning: '$IDENTITY' not in keychain, signing ad-hoc (permissions reset on every rebuild)"
  codesign --force --sign - "$APP"
fi
echo "built $APP"
