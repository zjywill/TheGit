#!/bin/bash
# Cut a release: tag the repo, then point the Homebrew tap at the new tag.
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
# Nothing here signs or notarises anything, so no DMG is published: an
# ad-hoc-signed DMG downloaded over the network is quarantined and Gatekeeper
# refuses it. The formula builds from source on the user's machine, which is
# what keeps that whole problem out of the picture. If you get a Developer ID
# later, that's when a GitHub Release with a DMG starts making sense.
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
    echo "  1. tagged $TAG and pushed it to $SOURCE_REPO"
    echo "  2. computed the sha256 of the $TAG tarball"
    echo "  3. pointed $TAP_REPO's $FORMULA at it and pushed"
    exit 0
fi

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "TheGit $VERSION"
git push -q origin "$TAG"

# GitHub generates the tarball on demand; the first request right after a tag
# push occasionally 404s while the ref propagates.
echo "==> Fetching the tarball GitHub generates for $TAG"
URL="https://github.com/$SOURCE_REPO/archive/refs/tags/$TAG.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
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
git diff --stat -- "$FORMULA"
[ -n "$(git status --porcelain)" ] || die "formula already points at $TAG, nothing to do"
git add "$FORMULA"
git commit -q -m "thegit $VERSION"
git push -q origin HEAD

cat <<EOF

Released $VERSION.

  source  https://github.com/$SOURCE_REPO/releases/tag/$TAG
  tap     https://github.com/$TAP_REPO/blob/main/$FORMULA

Users get it with:
  brew update && brew upgrade thegit

Verify it yourself from a clean slate:
  brew uninstall thegit && brew untap zjywill/tap
  brew install zjywill/tap/thegit
EOF
