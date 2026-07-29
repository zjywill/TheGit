# TheGit

A lightweight native Git client for macOS, written in SwiftUI.

TheGit gives you the things a desktop Git client is actually for — a readable
commit graph, a stage/diff/commit loop that stays out of your way, and one
place for branches, stashes, worktrees, submodules, tags and pull requests —
without the weight of a full IDE or an account to sign into.

It drives the `git` binary you already have. There is no embedded Git engine,
no daemon, and no service in the middle: your credential helper, SSH keys and
hooks work exactly as they do in the terminal.

---

## Why it's fast

The mainstream desktop clients ship a browser to draw a commit graph.
GitKraken is an Electron app: Chromium, Node, and a fleet of helper
processes, all resident before it has read a single commit. Sourcetree is
native, but it bundles its own Git and Git-LFS and keeps a background
scanning layer over every repository you've ever added.

TheGit is a single native SwiftUI process that shells out to `git`. That's
the whole architecture, and it's the whole performance story.

Measured on this machine — macOS 26.5, Apple M4 Pro:

| | TheGit | GitKraken |
|---|---:|---:|
| Application bundle | **11 MB** (universal) | 621 MB |
| Release DMG | **4.4 MB** | — |
| Processes at rest | **1** | 7+ (main, GPU, renderer, plugin, crashpad…) |
| Resident memory, repo open | **~95 MB** | ~1.6 GB |
| Chromium bundled | none | 261 MB Electron framework |

That's roughly **56× smaller on disk and 17× lighter in RAM** than GitKraken
for the same job — reading a repository and committing to it.

Where the difference shows up in use:

- **Launch is instant.** No Chromium bootstrap, no renderer handshake, no
  splash screen. The window is a native `WindowGroup`.
- **Nothing indexes in the background.** Repository state comes from `git`
  when something actually changes; an FSEvents watcher decides when that is,
  rather than a timer polling every repo you've ever opened.
- **The graph is laid out in Swift, not in a DOM.** Lane assignment is a
  single pass over the commit list (see `Core/GraphLayout.swift`), drawn with
  SwiftUI shapes — no virtual DOM diff between you and a scroll.
- **Scrolling and zoom are AppKit's.** Five UI zoom levels relayout natively
  instead of scaling a web view.
- **No account, no telemetry, no sign-in wall.** Nothing has to reach a
  server before you can look at your own repository.

The trade is deliberate: TheGit is macOS-only and does exactly what `git`
does. It won't grow a cross-platform UI toolkit, and it won't grow a
built-in issue tracker.

> Numbers above are from one machine with one mid-size repository open;
> measure your own with Activity Monitor. GitKraken's figures are from the
> installed 621 MB build, summed across all its processes.

---

## Highlights

**A commit graph you can read.** Branch lines carry their own color rather
than inheriting a lane's, so a branch stays the same color for its whole life
even when lanes get reused. Your uncommitted work shows up as a dashed WIP
node at the top, connected to HEAD.

**Three panes, one screen.** Branches on the left, graph in the middle,
staging area on the right. Click a file and the diff overlays the graph
instead of shoving the panes around; press <kbd>Esc</kbd> to go back.

**Everything in the sidebar.** Local and remote branches in a foldable tree
with the current branch pinned on top, plus Tags, Stashes, Worktrees,
Submodules, Git LFS, and — if `gh` or `glab` is installed and logged in —
your open Pull/Merge Requests.

**Staging that matches how you work.** Stage or unstage per file or all at
once, discard, ignore (repo-wide or `.git/info/exclude`), stash just the
staged or just the unstaged files, create a patch from a file's changes, and
amend the previous commit.

**Branch operations without the man page.** Merge, rebase, cherry-pick,
revert, reset, fast-forward, tag, push/pull/fetch, set or clear upstream,
create a worktree — from the branch and commit context menus. When a merge or
rebase stops on a conflict, the app shows the operation state with Continue
and Abort, and each conflicted file offers "take ours / take theirs".

**Cleanup.** Finds branches whose PR is merged, branches squash-merged into
the default branch, branches whose upstream is gone, and stale worktrees —
counts the commits that would be lost, and deletes nothing until you click.

**AI commit messages (optional, off by default).** Point it at any
OpenAI-compatible or Anthropic-compatible provider, and the **Generate**
button turns your staged diff into a commit message — Conventional Commits or
a plain summary, in English, Chinese, or matching whatever the repo already
uses. The API key goes in the login keychain, never UserDefaults.

**It notices changes made elsewhere.** An FSEvents watcher refreshes the view
when you commit, checkout, or edit files from a terminal.

**Multiple repositories** in tabs, and five UI zoom levels
(<kbd>⌘=</kbd> / <kbd>⌘-</kbd> / <kbd>⌘0</kbd>) for whatever display you're on.

---

## Privacy

TheGit talks to exactly two things by default: the `git` binary and your
filesystem.

Two features can reach the network, and both are opt-in:

- **Author avatars** (View menu) — fetches from Gravatar and GitHub.
- **AI commit messages** (Settings) — sends your staged diff to the provider
  you configured, under a size budget you choose.

Pull request listing uses the `gh` / `glab` CLI you already authenticated;
TheGit never handles those tokens itself.

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ / Swift 5.9 toolchain to build
- `git` on your `PATH`
- Optional: `git-lfs`, and `gh` or `glab` for pull requests

---

## Install

### Homebrew (recommended)

```bash
brew install zjywill/tap/thegit
```

The formula builds from source on your machine, which is deliberate: a build
you produced yourself is never quarantined, so nothing has to be talked past
Gatekeeper. A first build takes a minute or two and needs an Xcode 15+
toolchain.

Homebrew installs the bundle inside its own prefix and adds a `thegit` command
to your `PATH`. A formula can't write to `/Applications`, so copy it there
yourself:

```bash
cp -R /opt/homebrew/opt/thegit/TheGit.app /Applications/
```

(On an Intel Mac the prefix is `/usr/local` instead.)

A **copy**, not a symlink. Symlinking is the tidier-looking option and it does
give you a working Finder icon, but Spotlight indexes neither the Homebrew
prefix nor the target of a symlink in `/Applications` — the app then never
shows up in Spotlight or the Applications view. The cost of copying is one
command after each upgrade, below.

Homebrew 6 asks you to trust third-party taps. Installing the formula by its
full name as above records that trust for you; if a later command says the tap
is being ignored, this re-adds it:

```bash
brew trust --formula zjywill/tap/thegit
```

### DMG

Every release ships a universal `.dmg` on the
[Releases page](https://github.com/zjywill/TheGit/releases/latest) — no
toolchain, no Homebrew, 4.4 MB.

TheGit isn't signed with an Apple Developer ID yet, so macOS blocks the first
launch with "TheGit can't be opened". This is Gatekeeper refusing an
unnotarised download, not a problem with the app, and it only happens once:

1. Open the DMG and drag TheGit to Applications.
2. Try to open it; macOS refuses.
3. **System Settings → Privacy & Security**, scroll down, **Open Anyway**.

Or skip the dialog entirely:

```bash
xattr -dr com.apple.quarantine /Applications/TheGit.app
```

If that trade doesn't appeal, use Homebrew above — building from source never
hits this.

### Let an AI agent install it for you

Using Claude Code, Codex, or any agent with a terminal? Paste this prompt
and it will handle the whole thing — install, the `/Applications` copy, and
verification:

```text
Install TheGit (https://github.com/zjywill/TheGit), a native macOS Git
client, on this Mac via Homebrew:

1. brew install zjywill/tap/thegit
   — builds from source, needs an Xcode 15+ toolchain; if Homebrew says the
   tap is untrusted, run: brew trust --formula zjywill/tap/thegit
2. Copy the app where Finder and Spotlight can see it (a symlink is NOT
   enough — Spotlight won't index it):
   rm -rf /Applications/TheGit.app && cp -R "$(brew --prefix thegit)/TheGit.app" /Applications/
3. Verify: brew list --versions thegit, then open /Applications/TheGit.app

If it's already installed, upgrade instead: quit TheGit, run
brew update && brew upgrade thegit, then redo step 2.
```

### Upgrade

TheGit tells you when there's a new release: it asks GitHub once at launch
(at most every six hours) and shows a one-line banner above the tab bar if a
newer version exists. It never downloads or installs anything by itself —
the banner links to the release page, and dismissing it silences that version
for good. **Check for Updates…** in the TheGit menu asks on demand.

```bash
brew update && brew upgrade thegit
```

`brew update` refreshes the tap — without it, `brew upgrade` only ever sees
the formula version you already have. Quit TheGit first: a running app keeps
using its old bundle until you relaunch it.

Then refresh the copy in `/Applications`:

```bash
rm -rf /Applications/TheGit.app && cp -R /opt/homebrew/opt/thegit/TheGit.app /Applications/
```

`opt/thegit` always points at whichever version Homebrew currently has, so
that line is the same after every upgrade.

To see which version you're on:

```bash
brew list --versions thegit
```

### Uninstall

```bash
brew uninstall thegit && brew untap zjywill/tap
```

That doesn't touch the copy in `/Applications` — remove it with
`rm -rf /Applications/TheGit.app`. Your settings (the `com.zjywill.TheGit`
`defaults` domain) and the API key in the login keychain survive both an
upgrade and an uninstall; delete them by hand if you want a clean slate.

### Build the app yourself

```bash
scripts/bundle.sh
```

This produces a universal (arm64 + x86_64) `dist/TheGit.app` and a
`dist/TheGit-<version>.dmg`. Useful knobs: `UNIVERSAL=0` builds for this Mac
only, `DMG=0` assembles the `.app` and stops, `DEST=…` picks the output
directory. The bundle is **ad-hoc signed**, which is enough
to run on your own Mac and on any Mac you copy it to by hand — it is not
enough for network distribution, where Gatekeeper wants a Developer ID and
notarisation.

If you copy the DMG over the network and macOS refuses to open the app, clear
the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/TheGit.app
```

### Run from source

```bash
swift run
```

### Tests

```bash
swift test
```

---

## Project layout

```
Sources/TheGit/
  Core/        git invocation, parsers, graph layout, LFS, forge CLIs, AI
  State/       AppState (open repos) and RepoState (one repository)
  UI/          sidebar, graph, diffs, commit panel, settings
Tests/         parser, graph, cleanup and repo integration tests
scripts/       bundle.sh (app + DMG), release.sh (tag + tap), make-icon.py,
               sync-providers.py
```

The AI provider catalog in `Sources/TheGit/Resources/providers.json` is
generated and committed; `scripts/sync-providers.py` regenerates it and is
only run when someone wants to refresh the list.

---

## License

[MIT](LICENSE) © 2026 Junyi Zhang
