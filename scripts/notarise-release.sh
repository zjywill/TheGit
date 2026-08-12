#!/bin/bash
# Notarise a release that shipped without it, after Apple's notary queue
# comes back.
#
#   scripts/notarise-release.sh 0.10.7
#
# release.sh with ALLOW_UNNOTARISED=1 ships a Developer ID signed DMG whose
# notes carry the Gatekeeper workaround, because Apple's notary service can
# sit on a submission for hours with no verdict and no incident posted. This
# is the other half: submit the same DMG, staple the ticket, replace the
# asset on the existing Release, and strip the workaround from the notes.
#
# No new version number. The tag, the tarball and the tap all still point at
# the same source — only the DMG's ticket and the notes about it change.
#
# The notes edit is the reason this is a script. Re-uploading a notarised
# DMG under notes that still say "macOS blocks the first launch" leaves
# every reader following three steps they no longer need, and it is exactly
# the step a person doing this by hand forgets.
set -euo pipefail

REPO="zjywill/TheGit"

die() { echo "error: $*" >&2; exit 1; }

cd "$(dirname "$0")/.."
. "$(dirname "$0")/notarise-lib.sh"

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: $(basename "$0") <version>"
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "version must be MAJOR.MINOR.PATCH, got '$VERSION'"

TAG="v$VERSION"
DMG="$PWD/dist/TheGit-$VERSION.dmg"

command -v gh >/dev/null || die "gh is not installed — 'brew install gh'"
gh auth status >/dev/null 2>&1 || die "gh is not logged in — run 'gh auth login'"
[ -f "$DMG" ] || die "$DMG isn't there — rebuild it with 'VERSION=$VERSION scripts/bundle.sh'"
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
    || die "no GitHub Release for $TAG"

# An ad-hoc signature can't be notarised, and finding that out from Apple
# ten minutes later is a worse error message than this one.
codesign -dv --verbose=4 "$DMG" 2>&1 | grep -q "Authority=Developer ID Application" \
    || die "$DMG is not signed with a Developer ID — rebuild it before notarising"

if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "==> $DMG already carries a ticket, skipping the notary service"
else
    notarise "$DMG" "$DMG" || die "notarisation did not complete — try again later"
    xcrun stapler validate "$DMG" >/dev/null 2>&1 \
        || die "notarisation reported success but no ticket stapled"
fi

echo "==> Replacing the DMG on $TAG"
gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber

# The workaround block is matched on the sentence release.sh writes rather
# than on line numbers, so an edited changelog above it doesn't shift the
# target. Nothing found means the notes were already rewritten — say so and
# stop rather than leaving a half-updated release.
echo "==> Rewriting the release notes"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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

$TAG is notarised.

  release  https://github.com/$REPO/releases/tag/$TAG
  dmg      $DMG

Check it the way a downloader would:
  spctl -a -vvv -t open --context context:primary-signature "$DMG"
EOF
