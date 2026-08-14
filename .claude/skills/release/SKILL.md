---
name: release
description: >-
  Cut a TheGit release end to end: pick the next version, run the tests, build
  and publish the DMG on GitHub Releases, tag, push, and move the Homebrew tap
  — then verify users can actually upgrade. Use this whenever the user says
  发版, 发布, 升级版本号, 打包, 出个 DMG, release, bump the version, cut a
  release, 打 tag, publish a release, upload the DMG, or update the tap — and
  also when they report that `brew upgrade thegit` still shows an old version,
  that a tag exists but brew doesn't see it, that a Release is missing its
  DMG, that the in-app update banner isn't showing a version they just cut, or
  that release.sh failed partway, or that a shipped DMG or app has no stapled
  notarisation ticket. Any release-shaped request in this repo goes through
  this skill, not through hand-run git tag / gh release / cask edits.
---

# Releasing TheGit

One command does the whole release:

```bash
scripts/release.sh <MAJOR.MINOR.PATCH>
```

> **Read this before running it.** That command waits for Apple to notarise,
> twice, and verdicts for this Developer ID currently take hours — it will
> sit there most of a working day. Until that changes, use the two-step flow
> under "The flow that doesn't require sitting in front of a terminal" below.
> Don't discover this by starting the blocking one and waiting.

It checks the tree, runs the tests, builds the universal DMG, signs and
notarises it, **verifies the notarisation tickets actually landed**, tags
`v<version>`, pushes the tag, publishes the GitHub Release with the DMG
attached and generated notes, and writes the tap's cask
(`zjywill/homebrew-tap`, `Casks/thegit.rb`) pointing at that DMG. It needs
`gh` installed and logged in; it checks for that before touching anything.

**Never replay these steps by hand** — the cask's `version` and `sha256` must
move together, and the sha is of the DMG that was actually uploaded. That
coupling is the reason the script exists; hand-running the steps is how
half-releases happen. `--dry-run` as the second argument previews without
touching anything.

The tap ships a **cask**, not a formula. A formula built from source, and
Homebrew's build environment can't reach the login keychain — so `bundle.sh`
found no Developer ID there and fell back to ad-hoc, giving the bundle a new
identity on every rebuild and re-prompting for the keychain on every upgrade.
Don't reintroduce a source-built formula to "avoid Gatekeeper"; the cask's
DMG is notarised, so there is no Gatekeeper prompt to avoid.

## Version number

There is **no version file in the repo** — the version *is* the git tag
(`bundle.sh` derives it via `git describe`, the cask is written from it).
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
gh release view vX.Y.Z --repo zjywill/TheGit --json tagName,assets
curl -fsSL https://raw.githubusercontent.com/zjywill/homebrew-tap/main/Casks/thegit.rb | grep -E '  version |  sha256'
```

The release must list a `TheGit-X.Y.Z.dmg` asset with a non-zero size — a
release with an empty `assets` array is the half-release the in-app update
banner would send people to. The cask must name the new version. Then the
user upgrades with:

```bash
brew update && brew upgrade --cask thegit
```

`brew update` must report "Updated 1 tap" — "Already up-to-date" means the
tap never moved. A cask installs into `/Applications` itself, so there is no
copy step to remind anyone about — but do remind them to quit TheGit first,
since a running app keeps its old bundle.

Someone still on the old build-from-source formula migrates once:

```bash
brew uninstall thegit && brew install --cask zjywill/tap/thegit
```

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
Diagnose before recovering: check remote tags and the raw cask (commands
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

**Script exits silently right after the test lines — no tag created.**
The integration tests (merge/stash) have a history of timing flakes, and
the script's `swift test | tail -3` can crop the actual failure while
still showing a "passed" trailer from the swift-testing runner. Run the
full `swift test` to see what failed; if it passes clean, the release run
just hit a flake — rerun release.sh.

**Verification shows the OLD version even though the script said
"Released".** raw.githubusercontent.com caches for ~5 minutes. Before
diagnosing a half-release, confirm via the API, which is not cached:

```bash
curl -fsSL https://api.github.com/repos/zjywill/homebrew-tap/contents/Casks/thegit.rb | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['content']).decode())" | grep -E '  version |  sha256'
```

**Release created but the DMG isn't attached.** `gh release create` uploads
the asset in the same call, so a release with no asset means the upload was
rejected after the release existed. Don't rerun the script — the tag is
already there. Attach it on its own:

```bash
gh release upload vX.Y.Z dist/TheGit-X.Y.Z.dmg --clobber
```

**Notarisation sits at "In Progress" for hours.** Expected, for this team.
Measured on 2026-08-12, its first day of notarising anything: a submission at
08:42Z was accepted around 11:20Z, and four others sat unanswered for eight
hours. Neither Apple nor the build was at fault — an account problem fails at
submission, and a content problem comes back `Invalid`, not `In Progress`.
This is what a Developer ID new to the notary service looks like until it
builds some history. Full write-up in `docs/notarisation.md`.

So **do not shorten `NOTARY_TIMEOUT` or raise `NOTARY_RETRIES`** to "get
past it". A resubmission doesn't jump the queue, it adds one more item to a
slow one — and the submission it walked away from gets accepted anyway with
nobody waiting to staple it. The defaults are deliberately 2h and 1.

**The flow that doesn't require sitting in front of a terminal.** Until this
team's verdicts get faster, cut releases in two steps rather than waiting out
`release.sh`:

```bash
NOTARIZE=0 ALLOW_UNNOTARISED=1 scripts/release.sh X.Y.Z   # minutes; ships with the workaround notes
scripts/notarise-release.sh X.Y.Z                          # run again whenever; no waiting
```

The second command never blocks. It advances one leg, records the submission
id under `dist/.notary-X.Y.Z/`, and exits telling you to come back —
typically three runs (submit app / staple app + submit image / staple image +
upload + rewrite notes), with any gap you like between them. A leg already
done takes about a second, and a leg already queued is **not** resubmitted.

Don't offer to "just wait" instead, and don't hand-run `notarytool submit` to
hurry it along — a second submission for the same artefact is strictly worse
than the one already queued.

Ctrl-C is safe throughout: the submission survives and Apple keeps the ticket.
The exception is `release.sh` itself, whose `bundle.sh` leg rebuilds from
source — a rebuild is a new binary with a new cdhash, so the ticket waiting
for the old one no longer applies. That's the whole reason for the two-step
flow above.

**A ticket you already have.** Notarising a container issues tickets for the
code inside it, so the app in an accepted DMG is notarised too — `stapler
staple` fetches it in under a second, no submission. v0.10.7 needed no
notarisation at all by the time anyone looked; both tickets had been sitting
on Apple's servers for hours while the release shipped unstapled. Always let
`notarise()` try the staple before assuming a wait is needed.

**"no notarisation ticket is stapled to it" from the release gate.** This is
the trap the gate exists for, and v0.10.7 fell into it: Apple accepted the
DMG twice, but the ticket never got stapled to the local file, so the
download only passed Gatekeeper while online. Do **not** work around it by
checking `spctl` instead — `spctl` asks Apple over the network and reports
"accepted / Notarized Developer ID" for a bundle with no local ticket at
all. `xcrun stapler validate` and `syspolicy_check distribution` are the two
that read the ticket inside the bundle, and both the image *and* the app
inside it need one: the image's ticket stops mattering the moment someone
drags the app out and ejects it.

## Clean-slate check (optional)

```bash
brew uninstall --cask thegit 2>/dev/null; brew untap zjywill/tap
brew install --cask zjywill/tap/thegit
```

Homebrew 6 tap trust: installing by full name records trust; if brew says
the tap is ignored, `brew trust --cask zjywill/tap/thegit`. If the install
stops at "there is already an App at '/Applications/TheGit.app'", that is a
copy Homebrew does not track (someone dragged it out of a DMG) — rerun with
`--force`, which is also what a user in that state needs to be told.
