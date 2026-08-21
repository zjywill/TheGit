<div align="center">

<img src="docs/icon.png" width="128" alt="TheGit">

# TheGit

**A native Git client for macOS that doesn't ship a browser.**

29 MB. One process. ~160 MB of RAM with three repositories open.<br>
No account, no telemetry, no sign-in wall.

[![Release](https://img.shields.io/github/v/release/zjywill/TheGit?color=blue)](https://github.com/zjywill/TheGit/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/zjywill/TheGit/total?color=blue)](https://github.com/zjywill/TheGit/releases)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/SwiftUI-native-orange?logo=swift&logoColor=white)](Sources/TheGit)
[![License](https://img.shields.io/github/license/zjywill/TheGit?color=green)](LICENSE)

</div>

<img src="docs/screenshot.png" alt="TheGit showing its own repository: branch sidebar, commit graph, staging panel">

## Get it

[**Download the DMG**](https://github.com/zjywill/TheGit/releases/latest) —
universal, under 10 MB, no toolchain needed. Open it, drag TheGit to
Applications, launch. It's signed with an Apple Developer ID and notarised by
Apple, so Gatekeeper lets it straight through.

Prefer Homebrew? The same signed app is also available as a cask:

```bash
brew install --cask zjywill/tap/thegit
```

Needs **macOS 14 Sonoma or later**. [Details](#requirements) below.

---

## Why it's 20× smaller

The mainstream desktop clients ship a browser to draw a commit graph.
GitKraken is an Electron app: Chromium, Node, and a fleet of helper processes,
all resident before it has read a single commit.

TheGit is a single native SwiftUI process that shells out to `git`. That's the
whole architecture, and it's the whole performance story.

| | TheGit | GitKraken |
|---|---:|---:|
| Application bundle | **29 MB** (universal) | 626 MB |
| Release DMG | **9.6 MB** | — |
| Processes | **1** | 9 |
| Resident memory | **~160 MB**, three repos open | ~1.3 GB, one repo open |
| Chromium bundled | none | 261 MB |

Where that shows up in use:

- **Launch is instant** — no Chromium bootstrap, no splash screen, and the
  last session's state is drawn from a cache before `git` is asked anything.
- **Nothing indexes in the background** — an FSEvents watcher decides when
  state actually changed, instead of a timer polling every repo you ever opened.
- **The graph is laid out in Swift, not in a DOM** — one pass over the commit
  list ([`Core/GraphLayout.swift`](Sources/TheGit/Core/GraphLayout.swift)),
  drawn with SwiftUI shapes.
- **Scrolling and zoom are AppKit's** — five zoom levels relayout natively
  instead of scaling a web view.

It drives the `git` binary you already have. No embedded Git engine, no daemon,
no service in the middle: your credential helper, SSH keys and hooks work
exactly as they do in the terminal.

The trade is deliberate — TheGit is macOS-only and does exactly what `git`
does. It won't grow a cross-platform UI toolkit or a built-in issue tracker.

> Measured on macOS 26.6 / Apple M4 Pro, TheGit 0.11.2 after two hours of use
> against GitKraken 12.4 freshly launched; GitKraken's figures are summed
> across all its processes. Measure your own with Activity Monitor.

---

## What you get

🌳 **A commit graph you can read.** Branch lines carry their own color rather
than inheriting a lane's, so a branch stays one color for its whole life even
when lanes get reused. Uncommitted work shows up as a dashed WIP node at the
top, connected to HEAD. Select a commit and its lineage lights up; hover a row
and a card shows the full message, author and refs.

🪟 **Three panes, one screen.** Branches left, graph middle, staging right.
Click a file and the diff overlays the graph instead of shoving the panes
around; <kbd>Esc</kbd> goes back. Arrow keys step through files, and image
diffs render side by side.

📚 **Everything in the sidebar.** Local and remote branches in a foldable tree
with the current branch pinned on top, a commit-activity heatmap, plus Tags,
Stashes, Worktrees, Submodules, Git LFS, and — if `gh` or `glab` is logged
in — your open Pull Requests and Issues, readable in full without leaving the
app: rendered description, timeline, and the PR's whole diff.

✅ **Staging that matches how you work.** Stage or unstage per file, in a
multi-selection, or all at once; discard, ignore (repo-wide or
`.git/info/exclude`, including files already tracked), stash just the staged
or just the unstaged, create a patch from a file's changes, amend. When `git`
refuses an operation over uncommitted changes, TheGit offers to stash and
restore around it.

🔀 **Branch operations without the man page.** Merge, rebase, cherry-pick,
revert, reset, fast-forward, tag, push/pull/fetch, set upstream, create a
worktree — from the context menus. When a merge or rebase stops on a conflict,
you get Continue and Abort, "take ours / take theirs" per file, and a built-in
conflict editor for the rest.

🧹 **Cleanup.** Finds branches whose PR is merged, branches squash-merged into
the default branch, branches whose upstream is gone, merged remote branches,
and stale worktrees — counts the commits that would be lost, lets you filter
by kind and by risk, and deletes nothing until you tick the rows and click.

🤖 **AI commit messages and pull requests** *(optional, off by default)*.
Point it at any OpenAI- or Anthropic-compatible provider and **Generate**
turns your staged diff into a commit message — Conventional Commits or a plain
summary, in English, Chinese, or whatever the repo already uses — or drafts
the title and body of a pull request and submits it through `gh`/`glab`. The
API key goes in the login keychain, never UserDefaults.

👀 **It notices changes made elsewhere.** Commit, checkout or edit from a
terminal and the view refreshes itself.

🗂️ **Multiple repositories in tabs**, with a Dashboard tab that keeps a card
per repository — open PRs, issues, a year of activity — and five UI zoom
levels (<kbd>⌘=</kbd> / <kbd>⌘-</kbd> / <kbd>⌘0</kbd>).

---

## Privacy

TheGit talks to exactly two things by default: the `git` binary and your
filesystem. Three features can reach the network, and you control all three:

| Feature | Reaches | Default |
|---|---|---|
| Author avatars | Gravatar, GitHub, GitLab | **Off** — View menu |
| AI commit messages / PRs | the provider you configured | **Off** — Settings |
| Update check | `api.github.com`, once per launch | On — one request, no identifiers |

Pull request and issue listing uses the `gh` / `glab` CLI you already
authenticated; TheGit never handles those tokens itself.

---

## Install

### DMG

Every release ships a universal `.dmg` on the
[Releases page](https://github.com/zjywill/TheGit/releases/latest). Open it,
drag TheGit to Applications, launch it.

The image and the app inside it are signed with an Apple Developer ID and
notarised by Apple, with the ticket stapled to both — so there's no Gatekeeper
detour, not even on a Mac that's offline. That's checked before every release
is tagged.

### Upgrade

TheGit tells you when a new release exists: it asks GitHub at launch (at most
every six hours) and shows a one-line banner if there's a newer version. It
never downloads or installs anything by itself — the banner links to the
release page, and dismissing it silences that version for good.
**Check for Updates…** in the TheGit menu asks on demand.

To upgrade, quit TheGit, open the new DMG and drag it over the old copy. Your
settings and the API key in the keychain carry over; the signature is stable
across releases, so nothing asks for the key again.

### Uninstall

Drag `/Applications/TheGit.app` to the Trash. Settings live in the
`com.zjywill.TheGit` `defaults` domain and the saved window state; the AI API
key is an item in the login keychain — delete it in Keychain Access for a
genuinely clean slate.

<details>
<summary><b>Homebrew (alternative)</b></summary>

```bash
brew install --cask zjywill/tap/thegit
```

Installs the same signed `.app` the DMG carries into `/Applications`.
Requires macOS 14 Sonoma or later and Homebrew 4.0+.

Upgrade (quit TheGit first):

```bash
brew update && brew upgrade --cask thegit
```

If an install or upgrade fails, uninstall and install again:

```bash
brew uninstall --cask thegit; brew untap zjywill/tap
brew install --cask --force zjywill/tap/thegit
```

</details>

---

## Requirements

- **macOS 14 (Sonoma) or later.** TheGit is built on SwiftUI APIs that
  shipped with Sonoma, so it doesn't run on Ventura or earlier — neither the
  DMG nor the cask. Apple supports Sonoma on every Mac from 2018 on.
- `git` on your `PATH`
- Optional: `git-lfs`, and `gh` or `glab` for pull requests and issues
- Xcode 15+ / Swift 5.9 toolchain **to build** (not needed for the DMG)

<details>
<summary><b>Build it yourself</b></summary>

```bash
scripts/bundle.sh     # universal dist/TheGit.app + dist/TheGit-<version>.dmg
swift run             # run from source
swift test            # tests
```

Useful knobs: `UNIVERSAL=0` builds for this Mac only, `DMG=0` assembles the
`.app` and stops, `DEST=…` picks the output directory. The bundle is **ad-hoc
signed** — enough to run on your own Mac and on any Mac you copy it to by
hand, not enough for network distribution, where Gatekeeper wants a Developer
ID and notarisation.

**Project layout**

```
Sources/TheGit/
  Core/        git invocation, parsers, graph layout, LFS, forge CLIs, AI
  State/       AppState (open repos) and RepoState (one repository)
  UI/          sidebar, graph, diffs, commit panel, settings
Tests/         parser, graph, cleanup and repo integration tests
scripts/       bundle.sh (app + DMG), release.sh (tag + release + tap),
               make-icon.py, sync-providers.py
```

The AI provider catalog in `Sources/TheGit/Resources/providers.json` is
generated and committed; `scripts/sync-providers.py` regenerates it and is only
run to refresh the list.

</details>

---

## License

[MIT](LICENSE) © 2026 Junyi Zhang
