#!/bin/zsh
# Build MacPulse Shots.app - screenshot organizer menu bar app
set -e
cd "$(dirname "$0")"

APP="MacPulse Shots.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacPulseShots</string>
    <key>CFBundleIdentifier</key><string>local.macpulse.shots</string>
    <key>CFBundleName</key><string>MacPulse Shots</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Moves new screenshots from the Desktop into organized folders.</string>
</dict>
</plist>
EOF

swiftc -O -parse-as-library ShotsApp.swift -o "$APP/Contents/MacOS/MacPulseShots"
codesign --force --sign - "$APP"
echo "built: $APP"
