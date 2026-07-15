#!/bin/zsh
# Build MacPulse Files.app - duplicate & large file finder
set -e
cd "$(dirname "$0")"

APP="MacPulse Files.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacPulseFiles</string>
    <key>CFBundleIdentifier</key><string>local.macpulse.files</string>
    <key>CFBundleName</key><string>MacPulse Files</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Scans for large and duplicate files.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Scans for large and duplicate files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Scans for large and duplicate files.</string>
</dict>
</plist>
EOF

swiftc -O -parse-as-library FilesApp.swift -o "$APP/Contents/MacOS/MacPulseFiles"
codesign --force --sign - "$APP"
echo "built: $APP"
