#!/bin/bash
# Build TheGit.app, ad-hoc sign it, and (by default) wrap it in a DMG.
#
# Ad-hoc (`-s -`) is enough to run the app on this machine and on any Mac
# you copy it to by hand. It is NOT enough for distribution: a DMG that
# travels over the network picks up a quarantine flag, and Gatekeeper will
# refuse an ad-hoc signature. That needs a Developer ID plus notarisation.
#
# Env:
#   VERSION, BUILD   what goes in Info.plist
#   DEST             output directory                       (default ./dist)
#   UNIVERSAL=0      build for this Mac only, not arm64+x86_64
#   DMG=0            assemble the .app and stop
#
# The Homebrew formula runs this with UNIVERSAL=0 DMG=0, so the bundle it
# installs and the bundle in the DMG are assembled by the same code. The
# Info.plist in particular has to stay in one place: a second copy in the
# formula is a second thing to forget when a UTI or a version key changes.
set -euo pipefail

BUILD="${BUILD:-1}"
APP_NAME="TheGit"
BUNDLE_ID="com.zjywill.TheGit"
UNIVERSAL="${UNIVERSAL:-1}"
DMG="${DMG:-1}"

cd "$(dirname "$0")/.."

# Default the version off the latest tag rather than a literal, which goes
# stale the moment it's bumped anywhere else and then silently stamps every
# later build with the wrong CFBundleShortVersionString. The Homebrew formula
# passes VERSION explicitly — it builds from a tarball that has no .git, so
# `git describe` there would find nothing.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
ROOT="$PWD"
DIST="${DEST:-$ROOT/dist}"
APP="$DIST/$APP_NAME.app"

# --disable-sandbox: Homebrew builds inside its own sandbox, which SwiftPM's
# nests badly within; the build only ever writes to .build here.
# Built as one flat list rather than by splicing a second array: /bin/bash on
# macOS is 3.2, where an empty array under `set -u` counts as unbound.
if [ "$UNIVERSAL" = "1" ]; then
    BUILD_ARGS=(-c release --disable-sandbox --arch arm64 --arch x86_64)
    echo "==> Building release binary (universal)"
else
    BUILD_ARGS=(-c release --disable-sandbox)
    echo "==> Building release binary (this Mac only)"
fi

swift build "${BUILD_ARGS[@]}"

BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"
[ -f "$BIN" ] || { echo "no binary at $BIN"; exit 1; }

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# The AI provider catalog. SwiftPM also emits it as a sibling .bundle, but
# that only belongs next to a bare binary — inside an .app the resource
# goes in Contents/Resources, which is where AIProviderCatalog looks first.
cp "$ROOT/Sources/TheGit/Resources/providers.json" "$APP/Contents/Resources/"

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

if [ "$DMG" != "1" ]; then
    echo
    echo "Built:"
    echo "  $APP"
    lipo -archs "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/  archs: /'
    exit 0
fi

echo "==> Building DMG"
STAGE="$DIST/dmg"
rm -rf "$STAGE"
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
