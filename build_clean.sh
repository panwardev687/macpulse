#!/bin/zsh
# Build MacPulse Clean.app - safe storage cleaner
set -e
cd "$(dirname "$0")"

APP="MacPulse Clean.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacPulseClean</string>
    <key>CFBundleIdentifier</key><string>local.macpulse.clean</string>
    <key>CFBundleName</key><string>MacPulse Clean</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

swiftc -O -parse-as-library CleanApp.swift -o "$APP/Contents/MacOS/MacPulseClean"
codesign --force --sign - "$APP"
echo "built: $APP"
echo "run:   open '$PWD/$APP'"
