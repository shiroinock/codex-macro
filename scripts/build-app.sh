#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--skip-build" ]; then
  swift build -c release --disable-sandbox
fi
app_bundle=".build/C100 Companion.app"
mkdir -p "$app_bundle/Contents/MacOS"
cp .build/release/c100-status "$app_bundle/Contents/MacOS/c100-status"
cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>c100-status</string>
<key>CFBundleIdentifier</key><string>com.c100.companion</string>
<key>CFBundleName</key><string>C100 Companion</string>
<key>CFBundleDisplayName</key><string>C100 Companion</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>C100から選択したClaudeセッションをGhosttyで開きます。</string>
</dict></plist>
PLIST
codesign --force --sign - "$app_bundle"
printf '%s\n' "$(pwd)/$app_bundle"
