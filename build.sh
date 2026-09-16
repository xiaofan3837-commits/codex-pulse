#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/Codex Pulse.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BUILD_CACHE="${TMPDIR:-/tmp}/codex-pulse-swift-cache"
mkdir -p "$BUILD_CACHE"
cp "Assets/CodexPulse.icns" "$APP/Contents/Resources/CodexPulseIcon.icns"
swiftc -O -module-cache-path "$BUILD_CACHE" -target arm64-apple-macosx14.0 -framework AppKit -framework SwiftUI -lsqlite3 Source/TaskStore.swift Source/CompletionTracker.swift Source/UsageStore.swift Source/main.swift -o "$APP/Contents/MacOS/CodexPulse"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexPulse</string>
<key>CFBundleIdentifier</key><string>local.codexpulse.widget</string>
<key>CFBundleName</key><string>Codex Pulse</string>
<key>CFBundleDisplayName</key><string>Codex Pulse</string>
<key>CFBundleIconFile</key><string>CodexPulseIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "已生成：$APP"
