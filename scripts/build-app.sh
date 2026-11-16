#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) "build/Disk Cleaner.app" and, with --zip, the release
# archive build/DiskCleaner-<version>.zip plus its .sha256.
# Works with the Command Line Tools alone; Xcode is not needed.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Disk Cleaner.app"
# --tags: tags made on the GitHub release page are lightweight. Strip the "v" for the plist.
# VERSION=0.0.9 overrides it, for example to test the update banner against a real release.
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
fi
VERSION="${VERSION#v}"
# Monotonic along main, as macOS expects CFBundleVersion to grow.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# One build per architecture: a single multi-arch build needs Xcode's build system.
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" --product DiskCleaner
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/DiskCleaner .build/x86_64-apple-macosx/release/DiskCleaner \
  -output "$APP/Contents/MacOS/DiskCleaner"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Disk Cleaner</string>
    <key>CFBundleDisplayName</key><string>Disk Cleaner</string>
    <key>CFBundleIdentifier</key><string>local.disk-cleaner</string>
    <key>CFBundleExecutable</key><string>DiskCleaner</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: Apple silicon will not run unsigned code, and TCC treats rebuilds as
# the same local app. It is not a Developer ID signature, so downloads are quarantined.
codesign --force --sign - "$APP"
echo "Built $APP $VERSION ($BUILD): $(lipo -archs "$APP/Contents/MacOS/DiskCleaner")"

if [[ "${1:-}" == "--zip" ]]; then
  ZIP="build/DiskCleaner-${VERSION}.zip"
  rm -f "$ZIP"
  # ditto keeps the bundle's symlinks, permissions and signature intact.
  ditto -c -k --keepParent "$APP" "$ZIP"
  (cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
  echo "Packed $ZIP"
fi
