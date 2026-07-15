#!/bin/zsh
# Build MacPulse Memory.app - memory pressure watchdog menu bar widget
set -e
cd "$(dirname "$0")"

APP="MacPulse Memory.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacPulseMemory</string>
    <key>CFBundleIdentifier</key><string>local.macpulse.memory</string>
    <key>CFBundleName</key><string>MacPulse Memory</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

swiftc -O MemoryWidget.swift -o "$APP/Contents/MacOS/MacPulseMemory"
codesign --force --sign - "$APP"
echo "built: $APP"
