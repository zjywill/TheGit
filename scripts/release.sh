#!/bin/bash
# Cut a release: tag the repo, publish a GitHub Release with the DMG, then
# point the Homebrew tap at the new tag.
#
#   scripts/release.sh 0.2.0
#   scripts/release.sh 0.2.0 --dry-run
#
# The tap formula's `url` and `sha256` have to move together, and the sha256
# can only be computed after the tag exists on GitHub — that ordering is the
# whole reason this is a script and not a note in the README. Doing it by
# hand means either a stale sha (brew refuses to install) or a sha computed
# from a local tarball that isn't byte-identical to GitHub's (same failure,
# but it looks like a Homebrew bug).
#
# The DMG is ad-hoc signed, not notarised, so macOS quarantines it on
# download and the first launch needs a trip through System Settings. The
# release notes say so, in the download's own words. Homebrew stays the
# recommended channel precisely because building from source sidesteps
# that; the DMG is for people who won't install a toolchain. When a
# Developer ID shows up, sign in bundle.sh and delete the warning below —
# nothing else here changes.
set -euo pipefail

TAP_REPO="zjywill/homebrew-tap"
FORMULA="Formula/thegit.rb"
SOURCE_REPO="zjywill/TheGit"

die() { echo "error: $*" >&2; exit 1; }

VERSION="${1:-}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1
[ -n "$VERSION" ] || die "usage: $(basename "$0") <version> [--dry-run]"
# Homebrew parses the version out of the tag; anything it can't parse becomes
# a formula that installs under a name nobody expects.
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "version must be MAJOR.MINOR.PATCH, got '$VERSION'"

cd "$(dirname "$0")/.."
TAG="v$VERSION"

echo "==> Checking the working tree"
command -v gh >/dev/null || die "gh is not installed — 'brew install gh' (the release upload needs it)"
gh auth status >/dev/null 2>&1 || die "gh is not logged in — run 'gh auth login'"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "on branch '$BRANCH', expected main"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "$TAG already exists locally"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "main and origin/main differ — push or pull first"

echo "==> Running the test suite"
swift test 2>&1 | tail -3

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "Dry run — would have:"
    echo "  1. built the universal DMG for $VERSION"
    echo "  2. tagged $TAG and pushed it to $SOURCE_REPO"
    echo "  3. published the GitHub Release with the DMG attached"
    echo "  4. computed the sha256 of the $TAG tarball"
    echo "  5. pointed $TAP_REPO's $FORMULA at it and pushed"
    exit 0
fi

# Before the tag, not after: a build that fails here costs nothing, whereas
# a failure after the push leaves a tag the tap and the release both need
# cleaning up around. The version is passed explicitly because bundle.sh
# would otherwise derive it from `git describe`, which can't see a tag that
# doesn't exist yet.
echo "==> Building the DMG"
DMG="$PWD/dist/TheGit-$VERSION.dmg"
VERSION="$VERSION" scripts/bundle.sh >/dev/null
[ -f "$DMG" ] || die "bundle.sh finished but $DMG isn't there"
echo "    $(du -h "$DMG" | awk '{print $1}')  $DMG"

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "TheGit $VERSION"
git push -q origin "$TAG"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The notes are what the in-app update banner sends people to, so they carry
# the first-launch instructions as well as the changelog. Commit subjects
# rather than a hand-written summary: the repo writes conventional commits,
# and a changelog nobody has to write is a changelog that doesn't get
# skipped. `git describe` on the tag's parent finds the previous tag.
echo "==> Publishing the GitHub Release"
PREV="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
if [ -n "$PREV" ]; then
    RANGE="$PREV..$TAG"
else
    RANGE="$TAG"
fi
{
    echo "## Changes"
    echo
    git log --no-merges --pretty='- %s' "$RANGE"
    cat <<'NOTES'

## Install

**Homebrew (recommended)** — builds from source, no Gatekeeper prompt:

```
brew install zjywill/tap/thegit
rm -rf /Applications/TheGit.app && cp -R "$(brew --prefix thegit)/TheGit.app" /Applications/
```

**DMG** — no toolchain needed. TheGit isn't signed with an Apple Developer
ID yet, so macOS blocks the first launch with "TheGit can't be opened".
It only happens once:

1. Open the DMG and drag TheGit to Applications.
2. Try to open it; macOS refuses.
3. System Settings → Privacy & Security → scroll down → **Open Anyway**.

Or, in Terminal, skip the dialog entirely:

```
xattr -dr com.apple.quarantine /Applications/TheGit.app
```
NOTES
} > "$WORK/notes.md"

gh release create "$TAG" "$DMG" \
    --repo "$SOURCE_REPO" \
    --title "TheGit $VERSION" \
    --notes-file "$WORK/notes.md"

# GitHub generates the tarball on demand; the first request right after a tag
# push occasionally 404s while the ref propagates.
echo "==> Fetching the tarball GitHub generates for $TAG"
URL="https://github.com/$SOURCE_REPO/archive/refs/tags/$TAG.tar.gz"
for attempt in 1 2 3 4 5; do
    if curl -fsSL -o "$WORK/src.tar.gz" "$URL"; then break; fi
    [ "$attempt" = 5 ] && die "could not download $URL"
    echo "    not there yet, retrying ($attempt/5)"
    sleep 3
done
SHA="$(shasum -a 256 "$WORK/src.tar.gz" | awk '{print $1}')"
echo "    sha256 $SHA"

echo "==> Updating $TAP_REPO"
# A fresh clone, not the local tap checkout: `brew tap` leaves that at
# whatever state the last install put it in, and pushing from a stale or
# dirty copy is how a tap ends up disagreeing with itself.
# SSH, not https: this machine authenticates to GitHub over SSH only, and
# an https push either prompts for a token or dies — which is exactly how
# a release once shipped its tag but not the tap update (v0.3.0).
git clone -q "git@github.com:$TAP_REPO.git" "$WORK/tap"
cd "$WORK/tap"
[ -f "$FORMULA" ] || die "$FORMULA not found in $TAP_REPO"
/usr/bin/sed -i '' \
    -e "s|^  url \".*\"|  url \"$URL\"|" \
    -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
    "$FORMULA"
# --no-pager: in a small terminal git hands even a two-line stat to less,
# and the whole release sits at "(END)" waiting for a keypress.
git --no-pager diff --stat -- "$FORMULA"
[ -n "$(git status --porcelain)" ] || die "formula already points at $TAG, nothing to do"
git add "$FORMULA"
git commit -q -m "thegit $VERSION"
git push -q origin HEAD

cat <<EOF

Released $VERSION.

  release https://github.com/$SOURCE_REPO/releases/tag/$TAG
  tap     https://github.com/$TAP_REPO/blob/main/$FORMULA
  dmg     $DMG

Users get it with:
  brew update && brew upgrade thegit

Verify it yourself from a clean slate:
  brew uninstall thegit && brew untap zjywill/tap
  brew install zjywill/tap/thegit
EOF
