#!/bin/bash
# Build TheGit.app, sign it, and (by default) wrap it in a DMG.
#
# Signing has two tiers and the script picks whichever the machine can do:
#
#   Developer ID  a "Developer ID Application" certificate in the keychain.
#                 Signed with the hardened runtime and a secure timestamp,
#                 then — if notarytool credentials are stored — submitted to
#                 Apple and stapled. That is the combination Gatekeeper wants
#                 from a DMG that travelled over the network.
#   ad-hoc        no such certificate. Runs on this machine and on any Mac
#                 you copy it to by hand, but a downloaded DMG picks up a
#                 quarantine flag and Gatekeeper refuses it.
#
# Env:
#   VERSION, BUILD   what goes in Info.plist
#   DEST             output directory                       (default ./dist)
#   UNIVERSAL=0      build for this Mac only, not arm64+x86_64
#   DMG=0            assemble the .app and stop
#   SIGN_ID          codesign identity      (default: the Developer ID
#                    Application certificate found in the keychain)
#   SIGN_ID=-        force ad-hoc even when a certificate is present
#   NOTARY_PROFILE   notarytool keychain profile           (default thegit)
#   NOTARIZE=0       Developer ID sign, but skip Apple's notary service
#   NOTARY_TIMEOUT   how long to wait for one verdict         (default 20m)
#   NOTARY_RETRIES   fresh submissions before giving up        (default 3)
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
NOTARIZE="${NOTARIZE:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-thegit}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-20m}"
NOTARY_RETRIES="${NOTARY_RETRIES:-3}"

# Matched by name rather than hash so the script keeps working when the
# certificate is renewed — Developer ID certs expire every five years and
# the replacement has a different hash but the same subject.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
SIGN_ID="${SIGN_ID:--}"

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

# --options runtime is what makes the signature notarisable, and it is also
# the reason this can't be bolted on at release time: the hardened runtime
# changes how the app behaves at launch, so the build that gets tested has
# to be the build that gets signed this way.
if [ "$SIGN_ID" = "-" ]; then
    echo "==> Ad-hoc signing (no Developer ID certificate in the keychain)"
    codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
    echo "==> Signing with $SIGN_ID"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP" && echo "    signature verifies"

# Notarise the .app before it goes in the DMG, not just the DMG afterwards.
# A ticket stapled to the DMG only covers the DMG: drag the app to
# /Applications, throw the DMG away, and the first launch on a Mac that is
# offline has nothing local to check. Stapling both costs one extra
# round-trip and makes the app self-contained.
# The verdict is read out of the output rather than the exit status on
# purpose: `notarytool submit --wait` exits 0 when the wait times out, so a
# script that trusts the exit code ships an unnotarised build believing it
# succeeded. "status: Accepted" is the only thing that means accepted.
notarise() { # <path to submit> <path to staple>
    local log="$DIST/.notarytool.log" attempt=1 id
    while :; do
        echo "==> Notarising $(basename "$1") (attempt $attempt of $NOTARY_RETRIES)"
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
            --wait --timeout "$NOTARY_TIMEOUT" 2>&1 | tee "$log" || true
        id="$(sed -n 's/^ *id: \(.*\)/\1/p' "$log" | head -1)"

        if grep -q "status: Accepted" "$log"; then
            rm -f "$log"
            xcrun stapler staple "$2"
            return 0
        fi

        # Apple saying no is not Apple saying nothing. A rejected build fails
        # identically on every retry, so stop and point at the log that says
        # which check it tripped.
        if grep -q "status: Invalid" "$log"; then
            echo "    Apple rejected this build. Why:"
            echo "      xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE"
            rm -f "$log"
            return 1
        fi

        # Anything else is the queue swallowing the submission — it happens,
        # and the cure is a fresh submission rather than a longer wait.
        if [ "$attempt" -ge "$NOTARY_RETRIES" ]; then
            echo "    no verdict after $NOTARY_RETRIES attempts of $NOTARY_TIMEOUT each."
            echo "    The submissions are not lost; check them later with:"
            echo "      xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
            rm -f "$log"
            return 1
        fi
        echo "    no verdict within $NOTARY_TIMEOUT (submission $id) — resubmitting"
        attempt=$((attempt + 1))
    done
}

CAN_NOTARISE=0
if [ "$SIGN_ID" != "-" ] && [ "$NOTARIZE" = "1" ]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        CAN_NOTARISE=1
    else
        echo "    (no notarytool profile '$NOTARY_PROFILE' — skipping notarisation)"
    fi
fi

if [ "$CAN_NOTARISE" = "1" ]; then
    # notarytool takes a zip, a DMG or a pkg — never a bare .app — so the
    # bundle goes up zipped and the ticket comes back onto the .app itself.
    ZIP="$DIST/$APP_NAME-notarise.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    if ! notarise "$ZIP" "$APP"; then rm -f "$ZIP"; exit 1; fi
    rm -f "$ZIP"
fi

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

if [ "$SIGN_ID" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DIST/$APP_NAME-$VERSION.dmg"
fi
if [ "$CAN_NOTARISE" = "1" ]; then
    notarise "$DIST/$APP_NAME-$VERSION.dmg" "$DIST/$APP_NAME-$VERSION.dmg"
fi

echo
echo "Built:"
echo "  $APP"
echo "  $DIST/$APP_NAME-$VERSION.dmg"
lipo -archs "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/  archs: /'
