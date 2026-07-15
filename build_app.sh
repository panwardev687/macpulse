#!/bin/zsh
# Build MacPulse.app - the unified suite (sources in MacPulseApp/)
set -e
cd "$(dirname "$0")"

APP="MacPulse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# app icon (regenerate with: swift scripts/make_icon.swift && iconutil -c icns AppIcon.iconset)
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacPulse</string>
    <key>CFBundleIdentifier</key><string>local.macpulse.suite</string>
    <key>CFBundleName</key><string>MacPulse</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Lists and removes login items via System Events.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Finds large/duplicate files and organizes screenshots.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Finds large and duplicate files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Finds large and duplicate files.</string>
</dict>
</plist>
EOF

swiftc -O -parse-as-library MacPulseApp/*.swift -o "$APP/Contents/MacOS/MacPulse"
codesign --force --sign - "$APP"
echo "built: $APP"
echo "run:   open '$PWD/$APP'"
