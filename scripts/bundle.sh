#!/bin/bash
# Build TheGit.app (universal), ad-hoc sign it, and wrap it in a DMG.
#
# Ad-hoc (`-s -`) is enough to run the app on this machine and on any Mac
# you copy it to by hand. It is NOT enough for distribution: a DMG that
# travels over the network picks up a quarantine flag, and Gatekeeper will
# refuse an ad-hoc signature. That needs a Developer ID plus notarisation.
set -euo pipefail

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
APP_NAME="TheGit"
BUNDLE_ID="com.zjywill.TheGit"

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building universal release binary"
swift build -c release --arch arm64 --arch x86_64

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
[ -f "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

echo "==> Assembling $APP_NAME.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "    (no Resources/AppIcon.icns — run scripts/make-icon.py first)"
fi

# The two drag types have to be declared here, or macOS logs "type was
# expected to be declared and exported in the Info.plist" on every drag.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.thegit.branch</string>
            <key>UTTypeDescription</key><string>Git Branch Reference</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>com.thegit.commit</string>
            <key>UTTypeDescription</key><string>Git Commit Reference</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "    signature verifies"

echo "==> Building DMG"
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO "$DIST/$APP_NAME-$VERSION.dmg"
rm -rf "$STAGE"

echo
echo "Built:"
echo "  $APP"
echo "  $DIST/$APP_NAME-$VERSION.dmg"
lipo -archs "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/  archs: /'
