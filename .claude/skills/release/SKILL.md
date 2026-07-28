---
name: release
description: >-
  Cut a TheGit release end to end: pick the next version, run the tests, tag,
  push, and move the Homebrew tap — then verify users can actually upgrade.
  Use this whenever the user says 发版, 发布, 升级版本号, release, bump the
  version, cut a release, 打 tag, or update the tap — and also when they
  report that `brew upgrade thegit` still shows an old version, that a tag
  exists but brew doesn't see it, or that release.sh failed partway. Any
  release-shaped request in this repo goes through this skill, not through
  hand-run git tag / formula edits.
---

# Releasing TheGit

One command does the whole release:

```bash
scripts/release.sh <MAJOR.MINOR.PATCH>
```

It checks the tree, runs the tests, tags `v<version>`, pushes the tag,
computes the sha256 of GitHub's tarball, and points the tap
(`zjywill/homebrew-tap`, `Formula/thegit.rb`) at it. **Never replay these
steps by hand** — the formula's `url` and `sha256` must move together, and
the sha can only be computed after the tag exists on GitHub. That ordering
is the reason the script exists; hand-running the steps is how half-releases
happen. `--dry-run` as the second argument previews without touching
anything.

## Version number

There is **no version file in the repo** — the version *is* the git tag
(`bundle.sh` derives it via `git describe`, the formula gets it passed in).
So "升级版本号" means nothing more than choosing the next tag:

- current version: `git describe --tags --abbrev=0`
- new features → bump MINOR; fixes only → bump PATCH; breaking → MAJOR
- when the session's changes make the choice obvious, propose it and go;
  otherwise ask

## Before running

The script refuses a dirty tree, a branch other than main, or a main that
differs from origin/main. So the order is: commit everything (feature and
docs as separate commits, matching the repo's conventional-commit style),
push main, then release. If a push is blocked by the permission layer, hand
the exact commands to the user instead of stopping the whole release.

## Verifying it landed

"Released X.Y.Z" printed at the end is necessary but not sufficient — the
run in July 2026 shipped its tag and then died, and nobody noticed until
`brew upgrade` kept saying the old version. Check both halves:

```bash
git ls-remote --tags origin | grep vX.Y.Z
curl -fsSL https://raw.githubusercontent.com/zjywill/homebrew-tap/main/Formula/thegit.rb | grep -E '  url |  sha256'
```

The formula must name the new tag. Then the user upgrades with:

```bash
brew update && brew upgrade thegit
```

`brew update` must report "Updated 1 tap" — "Already up-to-date" means the
tap never moved. After the build, the app in `/Applications` is a **real
copy** the user refreshes by hand (a symlink is invisible to Spotlight):

```bash
rm -rf /Applications/TheGit.app && cp -R /opt/homebrew/opt/thegit/TheGit.app /Applications/
```

Remind them to quit TheGit first — a running app keeps its old bundle.

## Failure modes (all seen in the wild)

**Half-release — "vX.Y.Z already exists locally" but the tap still points
at the old version.** A previous run tagged and pushed, then died before
updating the tap. Cleanest recovery: delete the tag and rerun, which
revalidates everything:

```bash
git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z
scripts/release.sh X.Y.Z
```

Safe because nothing has consumed the tag yet — brew never saw it.
Diagnose before recovering: check remote tags and the raw formula (commands
above) so you know which half is missing.

**Stalled at `(END)` in the terminal.** git handed output to `less` and the
script is waiting on a keypress, not dead — press `q` and it continues.
The known spot is fixed with `--no-pager`; if it recurs anywhere else in
the script, the fix is the same flag, not a bigger terminal.

**Auth failure pushing the tap.** This machine authenticates to GitHub over
SSH only; an https remote prompts for a token and dies — which is exactly
how the half-release above happened. The script clones the tap via
`git@github.com:`; keep it that way, and suspect this first if the tap push
fails silently.

**Tarball 404 right after tagging.** GitHub generates tag tarballs on
demand; the script already retries 5×. Only investigate if all retries
fail.

**No DMG, no bottle — on purpose.** The app is ad-hoc signed; downloaded
over the network it would be quarantined and refused by Gatekeeper. The
formula builds from source on the user's machine instead. Don't "improve"
the release by publishing binaries unless a Developer ID + notarisation
exists.

## Clean-slate check (optional)

```bash
brew uninstall thegit && brew untap zjywill/tap
brew install zjywill/tap/thegit
```

Homebrew 6 tap trust: installing by full name records trust; if brew says
the tap is ignored, `brew trust --formula zjywill/tap/thegit`.
