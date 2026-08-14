#!/bin/bash
# Cut a release: tag the repo, publish a GitHub Release with the DMG, then
# point the Homebrew tap at it.
#
#   scripts/release.sh 0.2.0
#   scripts/release.sh 0.2.0 --dry-run
#
# The tap ships a cask, not a formula, so `brew install` hands people the
# same notarised DMG the Releases page does. A formula built from source
# instead, which sounds tidier and isn't: Homebrew's build environment can't
# reach the login keychain, so bundle.sh found no certificate there and fell
# back to ad-hoc. An ad-hoc bundle gets a new identity on every rebuild, and
# the keychain items and permission grants keyed to the old one stop
# matching — so every `brew upgrade` asked for the AI key again.
#
# The cask's `version` and `sha256` have to move together, which is the whole
# reason this is a script and not a note in the README: a stale sha means
# brew refuses to install, and it looks like a Homebrew bug rather than a
# release mistake.
#
# The DMG goes out signed with a Developer ID and notarised, so it opens
# without a detour through System Settings. bundle.sh does that work and
# quietly falls back to an ad-hoc signature when the certificate or the
# notarytool credentials are missing — fine for a local build, not for a
# release, which is why the tickets are checked below before the tag is
# pushed. The release notes promise a clean first launch; a release that
# shipped an ad-hoc DMG under those notes would be worse than the old
# honest warning.
set -euo pipefail

TAP_REPO="zjywill/homebrew-tap"
TAP_NAME="zjywill/tap"
CASK="Casks/thegit.rb"
FORMULA="Formula/thegit.rb"
MIGRATIONS="tap_migrations.json"
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
. "$(dirname "$0")/release-lib.sh"
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
    echo "  4. computed the sha256 of the DMG"
    echo "  5. written $TAP_REPO's $CASK for $VERSION and pushed"
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
# Asked again here rather than taken on bundle.sh's word: this is the last
# point before a tag is pushed, and the tag is the part that can't be taken
# back. Both the image and the app inside it, because the image's ticket
# stops mattering the moment someone drags the app out and ejects it.
if verify_distribution "$DMG" open && verify_dmg_contents "$DMG"; then
    NOTARISED=1
    echo "    $(du -h "$DMG" | awk '{print $1}')  $DMG  (notarised)"
elif [ "${ALLOW_UNNOTARISED:-0}" = "1" ]; then
    # Apple's notary queue can sit on a submission for hours with no verdict
    # and no incident on the status page. Shipping through that is a choice,
    # not an accident, which is why it takes an explicit flag — and why the
    # install notes below switch back to the first-launch workaround. The
    # artefact and what the notes claim about it move together or not at all.
    NOTARISED=0
    echo "    $(du -h "$DMG" | awk '{print $1}')  $DMG"
    echo "    !! NOT notarised — shipping with the Gatekeeper workaround in the notes"
else
    die "$DMG has no stapled notarisation ticket. Check the Developer ID certificate and the '\$NOTARY_PROFILE' notarytool profile, or re-run with ALLOW_UNNOTARISED=1 to ship it anyway."
fi

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

**Homebrew (recommended)** — installs the same signed DMG straight into
/Applications:

```
brew install --cask zjywill/tap/thegit
```

Upgrading from the old build-from-source formula? Once:

```
brew uninstall thegit && brew install --cask zjywill/tap/thegit
```

Already dragged TheGit in from a DMG? A cask won't install over a copy
Homebrew didn't put there — add `--force` to take it over.

NOTES
    if [ "$NOTARISED" = "1" ]; then
        cat <<'NOTES'
**DMG** — no toolchain needed. Open it, drag TheGit to Applications, launch
it. Signed with an Apple Developer ID and notarised by Apple, so there's no
Gatekeeper detour.
NOTES
    else
        cat <<'NOTES'
**DMG** — no toolchain needed. Signed with an Apple Developer ID, but this
build is still waiting on Apple's notary service, so macOS blocks the first
launch with "TheGit can't be opened". It only happens once:

1. Open the DMG and drag TheGit to Applications.
2. Try to open it; macOS refuses.
3. System Settings → Privacy & Security → scroll down → **Open Anyway**.

Or, in Terminal, skip the dialog entirely:

```
xattr -dr com.apple.quarantine /Applications/TheGit.app
```
NOTES
    fi
} > "$WORK/notes.md"

gh release create "$TAG" "$DMG" \
    --repo "$SOURCE_REPO" \
    --title "TheGit $VERSION" \
    --notes-file "$WORK/notes.md"

# The sha of the local DMG, not of a re-download: `gh release create` just
# uploaded this exact file, and hashing what we shipped is one less thing
# that can be subtly different from what people fetch.
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
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

# Written whole rather than sed-patched. A cask is short enough that a
# template is easier to read than three substitutions, and it means the tap
# can't drift into a shape the next release's sed no longer matches.
mkdir -p "$(dirname "$CASK")"
cat > "$CASK" <<CASK
cask "thegit" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$SOURCE_REPO/releases/download/v#{version}/TheGit-#{version}.dmg"
  name "TheGit"
  desc "Lightweight native Git client for macOS"
  homepage "https://github.com/$SOURCE_REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Bare symbol, not ">= :sonoma": Homebrew 6 reads a symbol as a minimum and
  # deprecates the string form, which every brew command then warns about.
  depends_on macos: :sonoma

  app "TheGit.app"

  zap trash: [
    "~/Library/Preferences/com.zjywill.TheGit.plist",
    "~/Library/Saved Application State/com.zjywill.TheGit.savedState",
  ]
end
CASK

# The formula and the cask can't both answer to `thegit`, and leaving the
# formula would keep handing new installs the ad-hoc build this cask exists
# to replace. tap_migrations.json is what tells an existing `brew upgrade`
# where the name went instead of failing with "no available formula".
if [ -f "$FORMULA" ]; then
    git rm -q "$FORMULA"
fi
# The tap's brew name, not its repo name: brew resolves the value the same
# way it resolves `zjywill/tap/thegit`, and "homebrew-tap" is a GitHub
# spelling it never sees.
cat > "$MIGRATIONS" <<MIGRATIONS
{
  "thegit": "$TAP_NAME"
}
MIGRATIONS

git add -A
# --no-pager: in a small terminal git hands even a two-line stat to less,
# and the whole release sits at "(END)" waiting for a keypress.
git --no-pager diff --cached --stat
[ -n "$(git status --porcelain)" ] || die "tap already points at $TAG, nothing to do"
git commit -q -m "thegit $VERSION"
git push -q origin HEAD

cat <<EOF

Released $VERSION.

  release https://github.com/$SOURCE_REPO/releases/tag/$TAG
  tap     https://github.com/$TAP_REPO/blob/main/$CASK
  dmg     $DMG

Users get it with:
  brew update && brew upgrade --cask thegit

Verify it yourself from a clean slate:
  brew uninstall --cask thegit 2>/dev/null; brew untap zjywill/tap
  brew install --cask zjywill/tap/thegit
EOF
