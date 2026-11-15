#!/usr/bin/env bash
# Builds a release binary and wraps it in "build/Disk Cleaner.app".
# Works with the Command Line Tools alone; Xcode is not needed.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Disk Cleaner.app"
VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/DiskCleaner"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskCleaner"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Disk Cleaner</string>
    <key>CFBundleDisplayName</key><string>Disk Cleaner</string>
    <key>CFBundleIdentifier</key><string>local.disk-cleaner</string>
    <key>CFBundleExecutable</key><string>DiskCleaner</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper and TCC treat rebuilds as the same local app.
codesign --force --sign - "$APP"
echo "Built $APP"
