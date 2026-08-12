#!/bin/bash
# Notarise a release that shipped without it, after Apple's notary queue
# comes back.
#
#   scripts/notarise-release.sh 0.10.7
#
# release.sh with ALLOW_UNNOTARISED=1 ships a Developer ID signed DMG whose
# notes carry the Gatekeeper workaround, because a verdict from Apple can be
# hours away. This is the other half: get tickets onto that build, replace
# the asset on the existing Release, and strip the workaround from the notes.
#
# **Run it repeatedly.** It does not wait for Apple — it advances as far as
# it can, remembers the submission id, and exits telling you to come back.
# Three runs, typically:
#
#   1st  submits the app
#   2nd  staples the app, builds the image, submits the image
#   3rd  staples the image, verifies, uploads, rewrites the notes
#
# A run that has nothing to wait for does the whole thing at once. Nothing
# is resubmitted, and a leg that is already done takes about a second.
#
# Both tickets. A ticket on the DMG covers the DMG and nothing else — drag
# the app to /Applications, throw the image away, and the ticket Gatekeeper
# reads on a Mac that is offline is the one inside the bundle. A read-only
# image can't be stapled into after the fact, so the app comes out of the
# image, gets its own ticket, and the image is rebuilt around it. The binary
# is the one that shipped either way; only the tickets are new.
#
# No new version number. The tag, the tarball and the tap all still point at
# the same source.
#
# The notes edit is the reason this is a script. Re-uploading a notarised
# DMG under notes that still say "macOS blocks the first launch" leaves
# every reader following three steps they no longer need, and it is exactly
# the step a person doing this by hand forgets.
set -euo pipefail

REPO="zjywill/TheGit"
APP_NAME="TheGit"

die() { echo "error: $*" >&2; exit 1; }

cd "$(dirname "$0")/.."
. "$(dirname "$0")/release-lib.sh"

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: $(basename "$0") <version>"
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "version must be MAJOR.MINOR.PATCH, got '$VERSION'"

TAG="v$VERSION"
DMG="$PWD/dist/$APP_NAME-$VERSION.dmg"
# Submission ids, so a re-run resumes instead of queueing again. In dist/,
# which is gitignored — none of this is worth carrying to another machine,
# since the ticket is only useful next to the bytes it belongs to.
STATE="$PWD/dist/.notary-$VERSION"

come_back() {
    cat <<EOF

Nothing more to do until Apple answers. Run the same command again later:

  scripts/$(basename "$0") $VERSION

It picks up where this left off — no resubmission, and the leg that is
already done takes about a second. Watch the queue with:

  xcrun notarytool history --keychain-profile $NOTARY_PROFILE
EOF
}

command -v gh >/dev/null || die "gh is not installed — 'brew install gh'"
gh auth status >/dev/null 2>&1 || die "gh is not logged in — run 'gh auth login'"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
    || die "no GitHub Release for $TAG"

# The rebuilt image has to be signed again, so the certificate has to be here
# now rather than three notary round-trips from now.
SIGN_ID="${SIGN_ID:-$(find_sign_id)}"
[ -n "$SIGN_ID" ] || die "no Developer ID Application certificate in the keychain"

# The asset on the Release, not whatever dist/ happens to hold. A local
# rebuild is a different binary, and pushing that out under a version that
# is already published replaces people's build with one nobody tested. This
# also makes the script work on a machine that never built the release.
echo "==> Fetching the DMG attached to $TAG"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh release download "$TAG" --repo "$REPO" --pattern '*.dmg' --dir "$WORK/released" \
    || die "could not download the DMG attached to $TAG"
RELEASED="$WORK/released/$APP_NAME-$VERSION.dmg"
[ -f "$RELEASED" ] || die "$TAG has no $APP_NAME-$VERSION.dmg attached"

# An ad-hoc signature can't be notarised, and finding that out from Apple
# ten minutes later is a worse error message than this one.
#
# Captured rather than piped into `grep -q`. grep exits at the first match
# while codesign still has a dozen lines to write, codesign dies of SIGPIPE,
# and `set -o pipefail` hands that 141 to the pipeline — so the check
# rejected a correctly signed DMG every single time.
SIGNING="$(codesign -dv --verbose=4 "$RELEASED" 2>&1 || true)"
case "$SIGNING" in
    *"Authority=Developer ID Application"*) ;;
    *) die "the DMG on $TAG is not signed with a Developer ID — it needs a rebuild and a new version, not a ticket" ;;
esac

echo "==> Taking the app out of the image"
MNT="$WORK/mnt"
mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MNT" "$RELEASED" \
    || die "the DMG on $TAG will not mount"
[ -d "$MNT/$APP_NAME.app" ] || { hdiutil detach -quiet "$MNT"; die "no $APP_NAME.app inside the DMG on $TAG"; }
# ditto rather than cp: it is the copy that keeps a signed bundle intact,
# extended attributes and all.
ditto "$MNT/$APP_NAME.app" "$WORK/$APP_NAME.app"
hdiutil detach -quiet "$MNT"

APP="$WORK/$APP_NAME.app"

# Extracted fresh from the same read-only image on every run, so the bundle —
# and therefore the cdhash the ticket is keyed to — is identical each time.
# That is what makes coming back tomorrow work.
ZIP="$WORK/$APP_NAME-notarise.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> The app's ticket"
rc=0; notarise_async "$ZIP" "$APP" "$STATE/app" || rc=$?
[ "$rc" = 1 ] && die "the app cannot be notarised"
[ "$rc" = 2 ] && { come_back; exit 0; }
verify_distribution "$APP" execute || die "the app still would not pass Gatekeeper"

# Reuse the image an earlier run built rather than making a new one. hdiutil
# does not produce byte-identical images, so rebuilding every time would hand
# Apple a different hash on every run and the wait would never converge —
# which is exactly the trap on a team whose verdicts take hours and where
# "Ctrl-C and come back later" is the normal way to use this.
if [ -f "$DMG" ] && verify_dmg_contents "$DMG" >/dev/null 2>&1; then
    echo "==> Reusing the image an earlier run built around the stapled app"
else
    echo "==> Rebuilding the image around the stapled app"
    build_dmg "$APP" "$DMG" "$APP_NAME" "$SIGN_ID"
    # A new image is a new hash, so whatever the last one was queued as no
    # longer applies to this file.
    rm -f "$STATE/dmg"
fi

echo "==> The image's ticket"
rc=0; notarise_async "$DMG" "$DMG" "$STATE/dmg" || rc=$?
[ "$rc" = 1 ] && die "the image cannot be notarised"
[ "$rc" = 2 ] && { come_back; exit 0; }
verify_distribution "$DMG" open || die "the image still would not pass Gatekeeper"
verify_dmg_contents "$DMG" || die "the app inside the image lost its ticket"

echo "==> Replacing the DMG on $TAG"
gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber

# The workaround block is matched on the sentence release.sh writes rather
# than on line numbers, so an edited changelog above it doesn't shift the
# target. Nothing found means the notes were already rewritten — say so and
# stop rather than leaving a half-updated release.
echo "==> Rewriting the release notes"
gh release view "$TAG" --repo "$REPO" --json body -q .body > "$WORK/old.md"

python3 - "$WORK/old.md" "$WORK/new.md" <<'PY'
import re, sys

old = open(sys.argv[1]).read()
replacement = """**DMG** — no toolchain needed. Open it, drag TheGit to Applications, launch
it. Signed with an Apple Developer ID and notarised by Apple, so there's no
Gatekeeper detour.
"""
# From the DMG heading through the fenced xattr command that closes the
# workaround. Non-greedy so a later fenced block is not swallowed.
pattern = re.compile(
    r"\*\*DMG\*\* — no toolchain needed\..*?xattr -dr com\.apple\.quarantine[^\n]*\n```\n",
    re.S,
)
new, n = pattern.subn(replacement, old)
if n == 0:
    sys.exit("no Gatekeeper workaround found in the notes — already rewritten?")
open(sys.argv[2], "w").write(new)
PY

gh release edit "$TAG" --repo "$REPO" --notes-file "$WORK/new.md"

cat <<EOF

$TAG is notarised — the image and the app inside it both carry a ticket.

  release  https://github.com/$REPO/releases/tag/$TAG
  dmg      $DMG

Check it the way a downloader would:
  spctl -a -vvv -t open --context context:primary-signature "$DMG"
EOF
