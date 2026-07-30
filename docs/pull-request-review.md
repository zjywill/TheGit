# Reviewing pull and merge requests

The plan is four phases. **P1 — the read-only review panel — is done**; this
file records what it ships, where its data actually lives, and what P2–P4
still have to do.

Written in English to match the rest of the repo, and kept next to the code
rather than in an issue because the decisions below are the kind that get
silently re-litigated six months later.

---

## P1 — what ships

Clicking a row in the sidebar's Pull Requests / Merge Requests section opens
a review panel over the graph, in the centre pane's single overlay slot
(same slot as a file diff, the file history and the issue viewer). It has
two tabs:

- **Overview** — title, state pill, `base ← head`, review decision, CI
  rollup, conflict flag, total ±, the description, and the forge's timeline.
- **Files (N)** — every file the request touches, with per-file ± counts and
  a viewed tick, beside that file's diff.

Nothing in it writes to the forge. `Checkout` is the only button that
touches the local repo, and it is disabled when HEAD already is the
request's source branch.

### The one decision worth not re-opening: the diff is local

The file list and every file diff come from `git`, not from the forge's API:
fetch the request's head ref, then diff from the merge base.

```
git fetch --force <remote> +refs/pull/<n>/head:refs/thegit/pr/<n>          # GitHub
git fetch --force <remote> +refs/merge-requests/<n>/head:refs/thegit/mr/<n> # GitLab
git diff --numstat --find-renames -z <base>...<head>
git diff --name-status --find-renames -z <base>...<head>
git diff -U3 --find-renames <base>...<head> -- <path> [<newpath>]
```

Why: no rate limit, no paging, no truncation on a big request, works
offline once fetched, and the diff renders through the same `DiffParser` /
`DiffLineRow` as every other diff in the app — line numbers, hunks and
binary detection all come for free.

`refs/pull/N/head` and `refs/merge-requests/N/head` exist on the remote
whatever repo the branch lives in, so a fork's request works the same as an
in-repo one.

Three dots, not two: `base...head` diffs from the merge base, so commits
that landed on the base meanwhile don't show up as this request's work —
the same asymmetry the AI PR description already uses.

**The refs namespace is deliberate.** `refs/thegit/pr|mr/<n>` is invisible
to the graph, which walks `--branches --remotes --tags HEAD` — a fetched
request adds no rows and draws no ref badges. Verified against a real
fetch. (`GitClient.activity`, the heatmap, does use `--all` and will count
a fetched request's commits. Known, listed under gaps.)

### Where the data lives, and how long

| What | Where | Lifetime |
|---|---|---|
| The request listing (number, title, branch, author, draft) | `RepoState.pullRequests`, persisted by `RepoCache` | Across relaunches, refetched past `prsFreshFor` |
| The request's page (state, decision, CI, conflicts, body) | `RepoState.prDetail`, memory | While the panel is open on it |
| The timeline | `RepoState.prThread`, memory | Same |
| The fetched head ref | `refs/thegit/pr|mr/<n>`, on disk | Forever, until pruned by hand |
| The file list + per-file ± | `RepoState.prFiles`, memory | While the panel is open |
| The open file's diff lines | `RepoState.prDiffLines`, memory | Until another file is picked |
| Viewed ticks | `RepoState.viewedByRequest`, memory | **Session only** — lost on quit, and never sent to the forge |
| The `base...head` range | `RepoState.prRange`, memory | While the panel is open |

So: reopening a request after a relaunch is fast (the ref is already local)
but starts with an empty page, an empty timeline and no ticks.

### Invariants the code relies on

- **One reading pane at a time.** Opening a review clears the diff, the file
  history and the issue viewer; every one of those clears `prToView` in
  turn. Two stacked doesn't mean both are open — the lower one is
  unreachable.
- **The reading pane is drawn over the panes, not swapped in for them.** A
  review covers the graph *and* the commit panel (nothing in a review has
  anything to do with staging), but the panes stay in the view tree
  underneath. Taking them out would reset the graph's scroll position, cost
  a subtree rebuild on every close, and bring the commit panel back at the
  width the app launched with. The reasoning is spelled out on
  `RepoView.workArea` — the file to read before "simplifying" this into an
  `if/else`.
- **A missing signal is not a good one.** `mergeable: "UNKNOWN"`,
  `reviewDecision: ""`, an empty `statusCheckRollup`, a `canceled` GitLab
  pipeline — all become `nil`, and a `nil` draws no chip. Nothing in the
  header may imply "green" from an absence.
- **Every task guards on `prToView?.number`.** The panel can be switched
  while a fetch is in flight; another request's page is not this one's.
- **Reviewing never moves HEAD or needs a clean tree.** The diff is read out
  of fetched refs.

### Where the code is

| Concern | Location |
|---|---|
| `PullRequestDetail`, `CheckRollup`, `ReviewDecision`, `ForgeItemKind` | `Core/ForgeClient.swift` |
| `gh pr view` / `glab mr view` parsing | `ForgeParsers.pullRequestDetail` |
| Timeline shared by issues and requests | `ForgeClient.thread(number:kind:forge:)` |
| `ReviewFile` | `Core/Models.swift` |
| `-z` numstat + name-status parsing | `GitParsers.reviewFiles` |
| Fetch, range, per-file diff | `GitClient.fetchReviewRefs` / `reviewFiles` / `reviewFileDiff` |
| Panel state and actions | `RepoState`, "Review a pull/merge request" section |
| The panel | `UI/PullRequestDetailView.swift` |
| Timeline rendering (shared with the issue viewer) | `UI/ForgeTimeline.swift` |
| Tests | `ForgeParsersTests`, `ReviewDiffTests`, `MenuActionsTests` |

### Known gaps left by P1

Small, deliberate, and each one is a real hole rather than a rough edge:

1. **The timeline skips PR-specific events.** `ForgeParsers.githubTimeline`
   renders the kinds it knows; `reviewed`, `line-commented`, `committed`,
   `head_ref_force_pushed`, `ready_for_review` and `review_requested` are
   all skipped. So a reviewer's verdict text and every inline comment are
   currently invisible in the Overview tab. This is the biggest hole in
   P1 and the first thing P2 should close.
2. **Viewed ticks don't survive a relaunch** and don't sync either way with
   the forge's own viewed state (GitHub `markFileAsViewed`, GitLab's
   per-file review state).
3. **Review refs accumulate.** Nothing prunes `refs/thegit/**`. A repo where
   many requests have been reviewed keeps them all.
4. **The heatmap counts them.** `GitClient.activity` walks `--all`, so a
   fetched request's commits land in the activity grid.
5. **GitLab has no review decision.** Approvals are a separate resource
   (`/merge_requests/:iid/approvals`), unfetched — so the header shows no
   decision chip on GitLab at all.
6. **The thread is capped** at 5 pages × 100 entries, and says so.
7. **No refresh on window focus.** The panel refetches only when its
   refresh button is pressed, unlike the rest of the app.
8. **No keyboard navigation** between files in the Files tab.

---

## P2 — being able to act

The line P2 crosses is that it writes to the forge. Everything below is a
side effect somebody else sees, which is why none of it is in P1.

### Verdicts

```
gh pr review <n> --approve | --request-changes | --comment --body <text>
glab mr approve <n>                    # approval
glab mr note <n> --message <text>      # a plain comment
```

- GitLab splits what GitHub joins: approval and comment are separate
  commands, and approval can fail on permissions (`403`) in a way a comment
  won't. Route both through `ForgeFailure.describe` so the message says
  which.
- Approving is not reversible in a way a user would recognise: `gh pr review`
  has no undo, while GitLab does (`glab mr revoke`, aliased `unapprove`).
  Confirm before sending either way.

### Inline comments

```
gh api repos/{owner}/{repo}/pulls/<n>/comments -f path=… -F line=… -f commit_id=… -f body=…
glab api projects/:id/merge_requests/<n>/discussions -f position[new_path]=… …
```

The hazard is line identity: a comment is anchored to a `commit_id` + path +
line, and a force-push after the panel fetched invalidates it. Bind every
draft to the head sha the diff was computed from, and refuse to post (with
a "the branch moved, refetch" message) when the request's head has changed
since.

GitLab's `position` object needs `base_sha`, `head_sha` and `start_sha` —
all three, and all from the MR's own diff refs, not from our local range.

### Merging

```
gh pr merge <n> --squash | --merge | --rebase [--delete-branch]
glab mr merge <n> [--squash] [--remove-source-branch]
```

Irreversible and visible to everyone. Needs a confirmation naming the
strategy and whether the branch is deleted, and should refuse outright when
`hasConflicts == true` or checks are failing (with an override, not a
silent one).

### Also in P2

- **Close the timeline gap** — parse `reviewed` and `line-commented` events
  so a review's body and its inline comments read as part of the
  conversation, and show inline comments on the diff lines they belong to.
- **Fetch GitLab approvals** so the decision chip works there too.
- **Persist viewed ticks** in `RepoCache` (local only — syncing them to the
  forge is a write, and belongs with the rest of P2's writes).
- **Prune `refs/thegit/**`** — either on cleanup, or when a request leaves
  the open list.
- **Refresh a request's head** and warn when it moved under an open review.

---

## P3 — AI-assisted review

Reuses what the commit-message and PR-description generators already use:
`AIClient.stream`, `AISettings`, and a prompt module beside
`PullRequestGenerator`.

- Input: the request's diff (through `CommitMessageGenerator.summarize`'s
  budget logic, which already handles big diffs) plus the description.
- Output: structured findings — `file`, `line`, severity, comment.
- Findings land as **draft comments the user accepts, edits or discards one
  by one**. Nothing is ever posted automatically. This is the line that
  decides whether the feature can be trusted at all.
- Drafts persist in `RepoCache`, bound to the head sha (see the line
  identity hazard above).

## P4 — review without a forge

The same panel and the same AI pass over any two refs (`feature` vs `main`),
with the verdict buttons absent. Works with no `gh`/`glab` installed and on
a self-hosted git with no forge at all. Most of the machinery already
allows it: `GitClient.reviewFiles` / `reviewFileDiff` take a range, not a
request number — only the fetch step and the panel's header assume a forge.
