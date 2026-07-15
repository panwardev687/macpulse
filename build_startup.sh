#!/bin/zsh
# Build MacPulse Startup.app - login items & background process auditor
set -e
cd "$(dirname "$0")"

APP="MacPulse Startup.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacPulseStartup</string>
    <key>CFBundleIdentifier</key><string>local.macpulse.startup</string>
    <key>CFBundleName</key><string>MacPulse Startup</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Lists and removes login items via System Events.</string>
</dict>
</plist>
EOF

swiftc -O -parse-as-library StartupApp.swift -o "$APP/Contents/MacOS/MacPulseStartup"
codesign --force --sign - "$APP"
echo "built: $APP"
