import XCTest
@testable import TheGit

/// GitKraken-style auto-stash: operations git refuses over uncommitted
/// changes (checkout, rebase, merge, cherry-pick, revert) stash them,
/// retry, and pop the stash back. Checked against a real repository —
/// git's refusal wording is the trigger, so the tests exercise git
/// itself, not our idea of it.
@MainActor
final class AutoStashTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-autostash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func git(_ dir: String, _ args: [String]) async throws -> String {
        try await Shell.run(
            "/usr/bin/env",
            ["git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=Test"] + args,
            env: ["GIT_TERMINAL_PROMPT": "0"]
        )
    }

    /// A repo with one commit (seed.txt) on main.
    private func makeRepo(_ name: String) async throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(path, ["init", "-q", "-b", "main", "."])
        try write("seed\n", to: path + "/seed.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "init"])
        return path
    }

    private func write(_ contents: String, to path: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// git refuses to rebase with unstaged changes to tracked files even
    /// when they can't conflict. Auto-stash makes it go through and puts
    /// the dirty file back, leaving no stash entry behind.
    func testRebaseWithUnstagedChangesAutoStashes() async throws {
        let path = try await makeRepo("rebase-dirty")
        try await git(path, ["checkout", "-q", "-b", "feature"])
        try write("feature\n", to: path + "/feature.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "feature work"])
        try await git(path, ["checkout", "-q", "main"])
        try write("upstream\n", to: path + "/upstream.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "upstream work"])
        try await git(path, ["checkout", "-q", "feature"])
        // Unstaged edit to a tracked file that no rebase step touches.
        try write("seed dirty\n", to: path + "/seed.txt")

        let client = GitClient(repoPath: path)
        try await client.rebase(onto: "main")

        // Rebased: upstream's commit is now an ancestor of feature.
        try await git(path, ["merge-base", "--is-ancestor", "main", "HEAD"])
        // The dirty edit survived, and nothing was left in the stash.
        XCTAssertEqual(read(path + "/seed.txt"), "seed dirty\n")
        let stashes = try await git(path, ["stash", "list"])
        XCTAssertEqual(stashes.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// Checkout refused because the dirty file differs on the target
    /// branch: the checkout itself must land, and when popping the stash
    /// back conflicts, the changes stay marked in the tree with the stash
    /// kept as backup — reported as an outcome, not a silent failure.
    func testCheckoutOverwriteConflictKeepsStashBackup() async throws {
        let path = try await makeRepo("checkout-conflict")
        try await git(path, ["checkout", "-q", "-b", "other"])
        try write("other\n", to: path + "/seed.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "other seed"])
        try await git(path, ["checkout", "-q", "main"])
        // Local edit that checkout would overwrite — git refuses.
        try write("local\n", to: path + "/seed.txt")

        let client = GitClient(repoPath: path)
        do {
            try await client.checkout(branch: "other")
            XCTFail("expected the conflicted stash pop to be reported")
        } catch {
            let message = (error as? GitError)?.message ?? ""
            XCTAssertTrue(message.contains("stash was kept"), "unexpected error: \(error)")
        }

        // The checkout landed despite the dirty tree...
        let branch = try await git(path, ["branch", "--show-current"])
        XCTAssertEqual(branch.trimmingCharacters(in: .whitespacesAndNewlines), "other")
        // ...and the local edit is conflict-marked, with the stash intact.
        XCTAssertTrue(read(path + "/seed.txt").contains("<<<<<<<"))
        let stashes = try await git(path, ["stash", "list"])
        XCTAssertFalse(stashes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// An error that isn't the dirty-tree refusal passes straight through
    /// without touching the stash.
    func testNonDirtyErrorDoesNotStash() async throws {
        let path = try await makeRepo("plain-error")
        try write("dirty\n", to: path + "/seed.txt")

        let client = GitClient(repoPath: path)
        do {
            try await client.checkout(branch: "no-such-branch")
            XCTFail("expected checkout of a missing branch to fail")
        } catch {
            // Expected. The dirty file must be untouched and unstashed.
        }
        XCTAssertEqual(read(path + "/seed.txt"), "dirty\n")
        let stashes = try await git(path, ["stash", "list"])
        XCTAssertEqual(stashes.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// The user-reported path: reset with unstaged files must not error —
    /// git itself allows it, and no app-level guard should refuse it.
    func testResetWithUnstagedFilesSucceeds() async throws {
        let path = try await makeRepo("reset-dirty")
        try write("second\n", to: path + "/second.txt")
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "second"])
        try write("dirty\n", to: path + "/seed.txt")
        try write("untracked\n", to: path + "/new.txt")

        let client = GitClient(repoPath: path)
        try await client.reset(to: "HEAD~1", mode: .mixed)

        let head = try await git(path, ["log", "--format=%s", "-n", "1"])
        XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), "init")
        XCTAssertEqual(read(path + "/seed.txt"), "dirty\n")
        XCTAssertEqual(read(path + "/new.txt"), "untracked\n")
    }
}
