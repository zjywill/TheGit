import XCTest
@testable import TheGit

@MainActor
final class MenuActionsTests: XCTestCase {

    /// A RepoState with a hand-built snapshot — none of the logic under
    /// test touches git, it all reads the snapshot.
    private func repo(
        local: [Branch] = [],
        remote: [Branch] = [],
        current: String? = nil
    ) -> RepoState {
        let state = RepoState(path: "/tmp/does-not-matter")
        var snapshot = RepoSnapshot()
        snapshot.localBranches = local
        snapshot.remoteBranches = remote
        snapshot.currentBranch = current
        state.snapshot = snapshot
        return state
    }

    private func remoteBranch(_ name: String) -> Branch {
        let remote = name.split(separator: "/").first.map(String.init) ?? "origin"
        return Branch(name: name, kind: .remote(remote), isCurrent: false)
    }

    // MARK: - Set Upstream submenu

    /// The same-named remote branch is the answer nine times out of ten,
    /// so it sorts first regardless of which remote it lives on.
    func testUpstreamChoicesPutSameNameFirst() {
        let state = repo(remote: [
            remoteBranch("upstream/main"),
            remoteBranch("origin/zzz"),
            remoteBranch("origin/feature"),
            remoteBranch("origin/main"),
        ])
        let feature = Branch(name: "feature", kind: .local, isCurrent: false)
        XCTAssertEqual(
            state.upstreamChoices(for: feature).map(\.name),
            ["origin/feature", "origin/main", "origin/zzz", "upstream/main"]
        )
    }

    /// Same branch name on two remotes: both float to the top.
    func testUpstreamChoicesWithNameOnTwoRemotes() {
        let state = repo(remote: [
            remoteBranch("origin/aaa"),
            remoteBranch("upstream/main"),
            remoteBranch("origin/main"),
        ])
        let main = Branch(name: "main", kind: .local, isCurrent: true)
        XCTAssertEqual(
            state.upstreamChoices(for: main).map(\.name),
            ["origin/main", "upstream/main", "origin/aaa"]
        )
    }

    /// origin/HEAD is a symbolic ref, never a legal upstream.
    func testUpstreamChoicesDropRemoteHEAD() {
        let state = repo(remote: [remoteBranch("origin/HEAD"), remoteBranch("origin/main")])
        let main = Branch(name: "main", kind: .local, isCurrent: true)
        XCTAssertEqual(state.upstreamChoices(for: main).map(\.name), ["origin/main"])
    }

    // MARK: - Which remote a branch belongs to

    func testRemoteForBranchComesFromItsUpstream() {
        let state = repo(remote: [remoteBranch("origin/main")])
        var branch = Branch(name: "feature", kind: .local, isCurrent: false)
        branch.upstream = "upstream/feature"
        XCTAssertEqual(state.remote(for: branch), "upstream")
    }

    /// Nested branch names must not confuse the remote/name split.
    func testRemoteForNestedBranchName() {
        let state = repo(remote: [remoteBranch("origin/main")])
        var branch = Branch(name: "feature/a/b", kind: .local, isCurrent: false)
        branch.upstream = "origin/feature/a/b"
        XCTAssertEqual(state.remote(for: branch), "origin")
    }

    func testRemoteForBranchWithoutUpstreamFallsBackToDefault() {
        let state = repo(remote: [remoteBranch("upstream/main")])
        let branch = Branch(name: "feature", kind: .local, isCurrent: false)
        // No origin in this repo, so defaultRemote is the only remote.
        XCTAssertEqual(state.remote(for: branch), "upstream")
    }

    // MARK: - Delete confirmation payload

    /// The two delete flavours must be distinct values, or the alert can't
    /// tell which one the user picked.
    func testPendingDeleteIdentityDistinguishesRemoteVariant() {
        let branch = Branch(name: "feature", kind: .local, isCurrent: false)
        let localOnly = PendingBranchDelete(branch: branch)
        let both = PendingBranchDelete(branch: branch, includeRemote: true)
        XCTAssertFalse(localOnly.includeRemote)
        XCTAssertNotEqual(localOnly.id, both.id)
    }

    // MARK: - Drop intents

    func testDropIntentNeedsCheckoutOnlyWhenTargetIsNotCurrent() {
        let state = repo(current: "main")
        XCTAssertFalse(state.needsCheckout(.branchOnBranch(source: "feature", target: "main")))
        XCTAssertTrue(state.needsCheckout(.branchOnBranch(source: "main", target: "feature")))
    }

    func testDropIntentTitles() {
        XCTAssertEqual(
            DropIntent.branchOnBranch(source: "feature", target: "main").title,
            "feature → main"
        )
        let commit = DraggedCommit(hash: "abc1234def5678", subject: "fix things")
        XCTAssertEqual(DropIntent.commitOnBranch(commit: commit, target: "main").title, "abc1234 → main")
        XCTAssertEqual(commit.shortHash, "abc1234")
    }

    /// Ids must separate a branch drop from a commit drop onto the same
    /// target, so a second drop replaces the dialog rather than merging.
    func testDropIntentIdsAreDistinct() {
        let commit = DraggedCommit(hash: "abc1234", subject: "s")
        XCTAssertNotEqual(
            DropIntent.branchOnBranch(source: "abc1234", target: "main").id,
            DropIntent.commitOnBranch(commit: commit, target: "main").id
        )
    }

    // MARK: - Ref badges

    /// A local branch with slashes in its name (fundive/mcp-apps-host) must
    /// not be mistaken for a remote ref — that misread collapsed the badge
    /// to the wrong label and cost the context menu its Checkout entry.
    func testSlashedLocalBranchStaysLocalInBadges() {
        let infos = RefBadge.infos(
            for: ["origin/fundive/mcp-apps-host", "fundive/mcp-apps-host"],
            remotes: ["origin"]
        )
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos.first?.label, "fundive/mcp-apps-host")
        XCTAssertEqual(infos.first?.hasLocal, true)
        XCTAssertEqual(infos.first?.hasRemote, true)
    }

    /// Same collapse with the refs in the other order (%D puts HEAD's
    /// branch first when it's checked out).
    func testSlashedLocalBranchCollapsesInEitherOrder() {
        let infos = RefBadge.infos(
            for: ["HEAD -> fundive/mcp-apps-host", "origin/fundive/mcp-apps-host"],
            remotes: ["origin"]
        )
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos.first?.label, "fundive/mcp-apps-host")
        XCTAssertEqual(infos.first?.isHead, true)
        XCTAssertEqual(infos.first?.hasLocal, true)
        XCTAssertEqual(infos.first?.hasRemote, true)
    }

    /// The plain case keeps working: origin/main + main = one badge.
    func testLocalAndRemoteOfSameBranchCollapse() {
        let infos = RefBadge.infos(for: ["main", "origin/main"], remotes: ["origin"])
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos.first?.label, "main")
        XCTAssertEqual(infos.first?.hasLocal, true)
        XCTAssertEqual(infos.first?.hasRemote, true)
    }

    /// A remote-only ref keeps its full origin-qualified label, and a
    /// same-named branch on another remote is a separate badge, not a
    /// collapse target.
    func testRemoteOnlyRefKeepsFullLabel() {
        let infos = RefBadge.infos(
            for: ["origin/codex/builtin-browser", "upstream/codex/builtin-browser"],
            remotes: ["origin", "upstream"]
        )
        XCTAssertEqual(infos.map(\.label), ["origin/codex/builtin-browser", "upstream/codex/builtin-browser"])
        XCTAssertEqual(infos.map(\.hasLocal), [false, false])
    }

    // MARK: - Checking out a pull request you're already on

    private func pullRequest(_ number: Int, branch: String) -> PullRequest {
        PullRequest(
            number: number, title: "t", branch: branch,
            author: "a", isDraft: false, url: ""
        )
    }

    /// The one case worth blocking: HEAD already is the request's source
    /// branch, so a checkout has nothing to offer and can still fast-forward
    /// the branch under you.
    func testCheckoutIsOffWhenAlreadyOnTheRequestsBranch() {
        XCTAssertTrue(RepoState.isCheckedOut(
            pullRequest(372, branch: "dev"), detail: nil, currentBranch: "dev"
        ))
        XCTAssertFalse(RepoState.isCheckedOut(
            pullRequest(372, branch: "release"), detail: nil, currentBranch: "dev"
        ))
    }

    /// A detached HEAD is on no branch, and a request whose branch the CLI
    /// didn't report is unknowable — neither may read as "already there".
    func testCheckoutStaysOnWithoutABranchToCompare() {
        XCTAssertFalse(RepoState.isCheckedOut(
            pullRequest(1, branch: "dev"), detail: nil, currentBranch: nil
        ))
        XCTAssertFalse(RepoState.isCheckedOut(
            pullRequest(1, branch: ""), detail: nil, currentBranch: "dev"
        ))
    }

    /// The fetched page's branch name wins over the listing's — but only for
    /// the request it belongs to. Another request's page must not decide
    /// this row's answer.
    func testCheckoutPrefersTheFetchedPagesBranchForItsOwnRequest() {
        let page = PullRequestDetail(
            number: 372, title: "t", body: "", author: "a",
            baseBranch: "release", headBranch: "fork-side",
            state: .open, isDraft: false
        )
        // The listing said "dev", the page says "fork-side" — and HEAD is
        // the latter.
        XCTAssertTrue(RepoState.isCheckedOut(
            pullRequest(372, branch: "dev"), detail: page, currentBranch: "fork-side"
        ))
        // Same branch names, different request: the page doesn't apply.
        XCTAssertFalse(RepoState.isCheckedOut(
            pullRequest(999, branch: "dev"), detail: page, currentBranch: "fork-side"
        ))
        // An empty branch on the page falls back to the listing's.
        var blank = page
        blank.headBranch = ""
        XCTAssertTrue(RepoState.isCheckedOut(
            pullRequest(372, branch: "dev"), detail: blank, currentBranch: "dev"
        ))
    }
}
