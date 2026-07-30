import XCTest
@testable import TheGit

/// The library's whole claim is that three folders are one project, and it
/// makes that claim from a remote URL written four different ways. Both
/// halves are checked here rather than by looking at a grouped list and
/// believing it.
final class RepoCatalogTests: XCTestCase {
    // MARK: - Identity

    func testSpellingsOfOneRemoteAgree() {
        let expected = "github.com/nextim/dim-agent"
        for url in [
            "git@github.com:nextim/dim-agent.git",
            "git@github.com:nextim/dim-agent",
            "https://github.com/nextim/dim-agent.git",
            "https://github.com/nextim/dim-agent/",
            "https://Someone@GitHub.com/NexTim/Dim-Agent.git",
            "ssh://git@github.com/nextim/dim-agent.git",
            "ssh://git@github.com:22/nextim/dim-agent.git",
        ] {
            XCTAssertEqual(RepoCatalog.identity(remoteURL: url), expected, url)
        }
    }

    func testDifferentProjectsStayApart() {
        let a = RepoCatalog.identity(remoteURL: "git@github.com:nextim/dim-agent.git")
        let b = RepoCatalog.identity(remoteURL: "git@github.com:zjywill/dim-agent.git")
        let c = RepoCatalog.identity(remoteURL: "git@gitlab.com:nextim/dim-agent.git")
        XCTAssertNotEqual(a, b, "same name, different owner")
        XCTAssertNotEqual(a, c, "same slug, different host")
    }

    func testNestedGitLabGroupsKeepTheirFullPath() {
        XCTAssertEqual(
            RepoCatalog.identity(remoteURL: "git@gitlab.com:team/sub/app.git"),
            "gitlab.com/team/sub/app"
        )
    }

    func testLocalAndUnparseableRemotes() {
        XCTAssertEqual(
            RepoCatalog.identity(remoteURL: "/Users/x/mirrors/app.git"),
            "file:/users/x/mirrors/app"
        )
        XCTAssertNil(RepoCatalog.identity(remoteURL: ""))
        XCTAssertNil(RepoCatalog.identity(remoteURL: "github.com"))
    }

    // MARK: - Config parsing

    func testRemotesOutOfConfig() {
        let config = """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = git@github.com:nextim/dim-agent.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"]
        \turl = https://github.com/upstream/dim-agent.git
        [branch "main"]
        \tremote = origin
        """
        let remotes = RepoCatalog.remotes(inConfig: config)
        XCTAssertEqual(remotes["origin"], "git@github.com:nextim/dim-agent.git")
        XCTAssertEqual(remotes["upstream"], "https://github.com/upstream/dim-agent.git")
        XCTAssertEqual(remotes.count, 2, "branch.remote = origin is not a remote URL")
    }

    /// A fork has two remotes and the fork is what it was cloned from, so
    /// origin decides — not whichever section came first in the file.
    func testOriginWinsOverOtherRemotes() {
        var facts = RepoCatalog.Facts()
        facts.remotes = ["upstream": "git@github.com:a/x.git", "origin": "git@github.com:b/x.git"]
        XCTAssertEqual(facts.originURL, "git@github.com:b/x.git")
        facts.remotes = ["fork": "git@github.com:c/x.git"]
        XCTAssertEqual(facts.originURL, "git@github.com:c/x.git", "no origin: the only one left")
    }

    // MARK: - Grouping

    private func entry(_ path: String, daysAgo: Double) -> RepoCatalog.Entry {
        let when = Date(timeIntervalSince1970: 1_000_000 - daysAgo)
        return RepoCatalog.Entry(path: path, addedAt: when, lastOpened: when)
    }

    private func facts(_ remote: String?, branch: String) -> RepoCatalog.Facts {
        var facts = RepoCatalog.Facts()
        facts.exists = true
        facts.branch = branch
        if let remote { facts.remotes = ["origin": remote] }
        return facts
    }

    func testThreeClonesBecomeOneProject() {
        let entries = [
            entry("/Git/dim-agent", daysAgo: 1),
            entry("/Git/dim-agent-second", daysAgo: 3),
            entry("/Git/dim-agent-thrid", daysAgo: 2),
        ]
        let byPath: [String: RepoCatalog.Facts] = [
            "/Git/dim-agent": facts("git@github.com:nextim/dim-agent.git", branch: "main"),
            // Same project, different spelling of the same remote.
            "/Git/dim-agent-second": facts(
                "https://github.com/nextim/dim-agent", branch: "feat/agent-v3"
            ),
            "/Git/dim-agent-thrid": facts(
                "git@github.com:nextim/dim-agent", branch: "feature/popover-fix"
            ),
        ]
        let projects = RepoCatalog.group(entries) { byPath[$0] ?? RepoCatalog.Facts() }

        XCTAssertEqual(projects.count, 1)
        let project = try? XCTUnwrap(projects.first)
        XCTAssertEqual(project?.name, "dim-agent", "named for the remote, not for a folder")
        XCTAssertEqual(project?.owner, "nextim")
        XCTAssertEqual(project?.host, "github.com")
        XCTAssertEqual(project?.clones.count, 3)
        // Most recently opened first, inside the project as well as between.
        XCTAssertEqual(
            project?.clones.map(\.name),
            ["dim-agent", "dim-agent-thrid", "dim-agent-second"]
        )
        XCTAssertEqual(project?.clones.first?.branch, "main")
    }

    func testFolderNameNeverGroups() {
        // Same folder name, unrelated projects: the directory says they match
        // and the remote says they don't. The remote is right.
        let entries = [entry("/work/app", daysAgo: 1), entry("/side/app", daysAgo: 2)]
        let byPath: [String: RepoCatalog.Facts] = [
            "/work/app": facts("git@github.com:work/app.git", branch: "main"),
            "/side/app": facts("git@github.com:side/app.git", branch: "main"),
        ]
        let projects = RepoCatalog.group(entries) { byPath[$0] ?? RepoCatalog.Facts() }
        XCTAssertEqual(projects.count, 2)
        // Both are called "app", so the tie falls to the key — which is
        // total, so the order can't wobble between refreshes.
        XCTAssertEqual(projects.map(\.owner), ["side", "work"])
    }

    /// The key is lowercased so that four spellings of one URL group; the name
    /// on the row must not be, or "TheGit" shows up as "thegit".
    func testProjectNameKeepsTheRemotesOwnSpelling() {
        let projects = RepoCatalog.group([entry("/Git/TheGit", daysAgo: 1)]) { _ in
            self.facts("git@github.com:zjywill/TheGit.git", branch: "main")
        }
        XCTAssertEqual(projects.first?.name, "TheGit")
        XCTAssertEqual(projects.first?.id, "github.com/zjywill/thegit")
    }

    func testRemotelessReposStandAlone() {
        let entries = [entry("/scratch/a", daysAgo: 1), entry("/scratch/b", daysAgo: 2)]
        let byPath: [String: RepoCatalog.Facts] = [
            "/scratch/a": facts(nil, branch: "main"),
            "/scratch/b": facts(nil, branch: "main"),
        ]
        let projects = RepoCatalog.group(entries) { byPath[$0] ?? RepoCatalog.Facts() }
        XCTAssertEqual(projects.count, 2, "no remote to share, so no group to share")
        XCTAssertEqual(projects.map(\.name), ["a", "b"], "falls back to the folder name")
        XCTAssertNil(projects.first?.owner)
    }

    /// Alphabetical, case-folded — a forty-row list you can aim at. Recency
    /// orders the clones INSIDE a project, where the question is which copy
    /// you touched last.
    func testProjectsAreAlphabeticalAndClonesAreRecent() {
        let entries = [
            entry("/Git/old", daysAgo: 90),
            entry("/Git/Zebra", daysAgo: 30),
            entry("/Git/apple", daysAgo: 5),
            entry("/Git/old-second", daysAgo: 1),
        ]
        let byPath: [String: RepoCatalog.Facts] = [
            "/Git/old": facts("git@github.com:o/old.git", branch: "main"),
            "/Git/old-second": facts("git@github.com:o/old.git", branch: "dev"),
            "/Git/Zebra": facts("git@github.com:o/Zebra.git", branch: "main"),
            "/Git/apple": facts("git@github.com:o/apple.git", branch: "main"),
        ]
        let projects = RepoCatalog.group(entries) { byPath[$0] ?? RepoCatalog.Facts() }
        XCTAssertEqual(projects.map(\.name), ["apple", "old", "Zebra"])
        XCTAssertEqual(
            projects.first { $0.name == "old" }?.clones.map(\.name),
            ["old-second", "old"],
            "inside a project, the copy touched last comes first"
        )
    }

    /// A scanned-in folder has never been opened. It still belongs in the
    /// list, and it must not sort as if it were opened at the epoch.
    func testNeverOpenedFoldersSortLastInsideAProject() {
        let opened = RepoCatalog.Entry(
            path: "/Git/app-second",
            addedAt: Date(timeIntervalSince1970: 10),
            lastOpened: Date(timeIntervalSince1970: 20)
        )
        let scanned = RepoCatalog.Entry(
            path: "/Git/app",
            addedAt: Date(timeIntervalSince1970: 30)
        )
        let projects = RepoCatalog.group([scanned, opened]) { _ in
            self.facts("git@github.com:o/app.git", branch: "main")
        }
        XCTAssertEqual(projects.first?.clones.map(\.name), ["app-second", "app"])
        XCTAssertNil(projects.first?.clones.last?.lastOpened)
    }

    /// The list survived a format change: entries written before scanning
    /// existed have no `addedAt` and a non-optional `lastOpened`. Failing to
    /// decode them would silently empty the whole library on upgrade.
    func testOldEntriesStillDecode() throws {
        let json = Data("""
        [{"path":"/Git/app","lastOpened":740000000}]
        """.utf8)
        let entries = try JSONDecoder().decode([RepoCatalog.Entry].self, from: json)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.path, "/Git/app")
        XCTAssertNotNil(entries.first?.lastOpened)
        XCTAssertEqual(entries.first?.addedAt, entries.first?.lastOpened)
    }

    /// A folder that was moved or deleted stays in the list and says so —
    /// dropping it silently loses the one record of where the thing was.
    func testMissingFolderIsKeptAndMarked() {
        let projects = RepoCatalog.group([entry("/gone/app", daysAgo: 1)]) { _ in
            RepoCatalog.Facts()
        }
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.clones.first?.exists, false)
        XCTAssertNil(projects.first?.clones.first?.branch)
    }

    // MARK: - Reading a real repository

    func testFactsReadFromDiskWithoutGit() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = try await Shell.run("/usr/bin/env", ["git", "-C", path, "init", "-q", "-b", "main", "."])
        _ = try await Shell.run(
            "/usr/bin/env",
            ["git", "-C", path, "remote", "add", "origin", "git@github.com:nextim/dim-agent.git"]
        )

        let facts = RepoCatalog.facts(ofRepoAt: path)
        XCTAssertTrue(facts.exists)
        XCTAssertEqual(facts.branch, "main")
        XCTAssertFalse(facts.detached)
        XCTAssertEqual(
            facts.originURL.flatMap(RepoCatalog.identity(remoteURL:)),
            "github.com/nextim/dim-agent"
        )

        XCTAssertFalse(RepoCatalog.facts(ofRepoAt: root.path).exists, "a plain folder is not a repo")
    }

    // MARK: - Sections

    private func project(_ name: String) -> RepoCatalog.Project {
        RepoCatalog.Project(
            id: "github.com/o/" + name.lowercased(),
            name: name,
            owner: "o",
            host: "github.com",
            clones: [],
            lastOpened: nil
        )
    }

    func testSectionsPartitionTheListAndKeepTheirOrder() {
        let all = [project("alpha"), project("beta"), project("gamma")]
        let work = RepoCatalog.Section(id: "s1", name: "Work", projectIDs: [all[1].id])
        let side = RepoCatalog.Section(id: "s2", name: "Side", projectIDs: [all[2].id])
        let shelves = RepoCatalog.arrange(all, sections: [work, side])

        XCTAssertEqual(shelves.map(\.name), ["Work", "Side", nil], "sections first, in their order")
        XCTAssertEqual(shelves[0].projects.map(\.name), ["beta"])
        XCTAssertEqual(shelves[1].projects.map(\.name), ["gamma"])
        XCTAssertEqual(shelves[2].projects.map(\.name), ["alpha"], "the rest fall through")
    }

    /// Two sections claiming one project must not show it twice — dragging one
    /// copy would appear to move the other.
    func testAProjectLandsInExactlyOneSection() {
        let all = [project("alpha")]
        let first = RepoCatalog.Section(id: "s1", name: "First", projectIDs: [all[0].id])
        let second = RepoCatalog.Section(id: "s2", name: "Second", projectIDs: [all[0].id])
        let shelves = RepoCatalog.arrange(all, sections: [first, second])
        XCTAssertEqual(shelves.flatMap(\.projects).count, 1)
        XCTAssertEqual(shelves[0].projects.count, 1)
        XCTAssertTrue(shelves[1].projects.isEmpty)
    }

    func testEmptySectionSurvivesAndNoSectionsMeansNoBands() {
        let empty = RepoCatalog.Section(id: "s1", name: "Empty", projectIDs: [])
        let withSection = RepoCatalog.arrange([project("alpha")], sections: [empty])
        XCTAssertEqual(withSection.count, 2, "the band you just made is still there to drop into")

        let plain = RepoCatalog.arrange([project("alpha")], sections: [])
        XCTAssertEqual(plain.count, 1)
        XCTAssertNil(plain.first?.name, "no sections, no headings")
    }

    /// A section that names a project no longer in the library (removed, or a
    /// remote that changed) must not resurrect it as an empty row.
    func testSectionsIgnoreProjectsThatAreGone() {
        let section = RepoCatalog.Section(id: "s1", name: "Work", projectIDs: ["github.com/o/ghost"])
        let shelves = RepoCatalog.arrange([project("alpha")], sections: [section])
        XCTAssertTrue(shelves[0].projects.isEmpty)
        XCTAssertEqual(shelves[1].projects.map(\.name), ["alpha"])
    }

    // MARK: - Scanning

    func testScanFindsReposAndStopsAtEachOne() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-scan-" + UUID().uuidString)
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }

        func makeRepo(_ relative: String) async throws -> String {
            let path = root.appendingPathComponent(relative).path
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            _ = try await Shell.run("/usr/bin/env", ["git", "-C", path, "init", "-q", "."])
            return path
        }

        let top = try await makeRepo("app")
        let nested = try await makeRepo("clients/acme")
        // Inside a repository: a submodule or a vendored checkout is that
        // repo's business, not a row of its own in the list.
        _ = try await makeRepo("app/vendor/lib")
        // Under a folder the walk refuses to enter.
        _ = try await makeRepo("node_modules/thing")
        // A plain folder with nothing in it.
        try manager.createDirectory(
            atPath: root.appendingPathComponent("notes").path,
            withIntermediateDirectories: true
        )

        let found = Set(RepoCatalog.scan(root: root.path))
        XCTAssertEqual(found, [top, nested])
    }

    func testScanDepthIsBounded() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-deep-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let deep = root.appendingPathComponent("a/b/c/d/e").path
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        _ = try await Shell.run("/usr/bin/env", ["git", "-C", deep, "init", "-q", "."])

        XCTAssertTrue(RepoCatalog.scan(root: root.path, maxDepth: 3).isEmpty)
        XCTAssertEqual(RepoCatalog.scan(root: root.path, maxDepth: 5), [deep])
    }

    // MARK: - Which screen a launch comes back to

    @MainActor
    func testSessionRestoreOpensTheScreenThatWasShowing() {
        // Quit while looking at the repository list. The remembered tab is
        // still remembered — it just isn't what was on screen.
        XCTAssertEqual(
            AppState.restoredScreen(home: "repositories", active: "/Git/app", tabs: ["/Git/app"]),
            .home(.repositories)
        )
        XCTAssertEqual(
            AppState.restoredScreen(home: "dashboard", active: "/Git/app", tabs: ["/Git/app"]),
            .home(.dashboard)
        )
        // Quit inside a repo.
        XCTAssertEqual(
            AppState.restoredScreen(home: nil, active: "/Git/b", tabs: ["/Git/a", "/Git/b"]),
            .tab("/Git/b")
        )
        // The remembered tab was closed since: the leftmost one, not nothing.
        XCTAssertEqual(
            AppState.restoredScreen(home: nil, active: "/Git/gone", tabs: ["/Git/a"]),
            .tab("/Git/a")
        )
        // Upgrade from the build that saved neither.
        XCTAssertEqual(
            AppState.restoredScreen(home: nil, active: nil, tabs: ["/Git/a"]),
            .tab("/Git/a")
        )
        // Nothing open at all.
        XCTAssertEqual(
            AppState.restoredScreen(home: nil, active: "/Git/gone", tabs: []),
            .home(.dashboard)
        )
        // A key written by a later build that knows a screen this one doesn't.
        XCTAssertEqual(
            AppState.restoredScreen(home: "timeline", active: nil, tabs: ["/Git/a"]),
            .tab("/Git/a")
        )
    }
}
