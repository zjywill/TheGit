import Foundation
import XCTest
@testable import TheGit

@MainActor
final class MergeEditorStateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-merge-editor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var conflictText: String {
        """
        top
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> topic
        bottom
        """ + "\n"
    }

    private func file() -> FileChange {
        FileChange(path: "conflict.txt", status: "U", area: .unstaged)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ args: [String]) async throws -> String {
        try await Shell.run(
            "/usr/bin/env",
            [
                "git", "-C", root.path,
                "-c", "user.email=test@example.com",
                "-c", "user.name=Test",
            ] + args,
            env: ["GIT_TERMINAL_PROMPT": "0"]
        )
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func openSession(in repo: RepoState, at fileURL: URL) throws -> MergeEditorSession {
        try write(conflictText, to: fileURL)
        var snapshot = repo.snapshot
        snapshot.conflicted = [file()]
        repo.snapshot = snapshot
        repo.openMergeEditor(file())
        return try XCTUnwrap(repo.mergeSession)
    }

    func testExternalEditIsNeverOverwrittenSilently() async throws {
        let fileURL = root.appendingPathComponent("conflict.txt")
        let repo = RepoState(path: root.path)
        let session = try openSession(in: repo, at: fileURL)
        XCTAssertEqual(session.originalData, try Data(contentsOf: fileURL))
        session.setSide(0, side: .ours, on: true)

        try write("changed by another editor\n", to: fileURL)
        repo.saveMergeResolution()

        try await waitUntil("external-change warning") {
            repo.mergeExternalChangePrompt != nil
        }
        XCTAssertTrue(repo.mergeSession === session)
        XCTAssertEqual(read(fileURL), "changed by another editor\n")
    }

    func testNavigationWaitsForExplicitDiscard() throws {
        let fileURL = root.appendingPathComponent("conflict.txt")
        let repo = RepoState(path: root.path)
        let session = try openSession(in: repo, at: fileURL)
        session.setSide(0, side: .ours, on: true)
        let next = FileChange(path: "next.txt", status: "?", area: .unstaged)

        repo.selectFile(next)
        XCTAssertTrue(repo.mergeSession === session)
        XCTAssertNil(repo.selectedFile)
        XCTAssertNotNil(repo.mergeDiscardPrompt)

        repo.confirmPendingMergeDiscard()
        XCTAssertNil(repo.mergeSession)
        XCTAssertEqual(repo.selectedFile?.id, next.id)
    }

    func testBatchSelectionWaitsForExplicitDiscard() throws {
        let fileURL = root.appendingPathComponent("conflict.txt")
        let repo = RepoState(path: root.path)
        let session = try openSession(in: repo, at: fileURL)
        session.setSide(0, side: .ours, on: true)
        let files = [
            FileChange(path: "one.txt", status: "?", area: .unstaged),
            FileChange(path: "two.txt", status: "?", area: .unstaged),
        ]

        XCTAssertNil(repo.selectFile(files[1], in: files))
        XCTAssertTrue(repo.mergeSession === session)
        XCTAssertTrue(repo.selectedWorkingTreeFileIDs.isEmpty)
        XCTAssertNotNil(repo.mergeDiscardPrompt)

        repo.confirmPendingMergeDiscard()
        XCTAssertNil(repo.mergeSession)
        XCTAssertEqual(repo.selectedFile?.id, files[1].id)
        XCTAssertEqual(repo.selectedWorkingTreeFileIDs, [files[1].id])
    }

    func testSymlinkConflictFallsBackWithoutReplacingTheLink() throws {
        let targetURL = root.appendingPathComponent("target.txt")
        let fileURL = root.appendingPathComponent("conflict.txt")
        try write(conflictText, to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: targetURL
        )
        let repo = RepoState(path: root.path)
        var snapshot = repo.snapshot
        snapshot.conflicted = [file()]
        repo.snapshot = snapshot

        repo.openMergeEditor(file())

        XCTAssertNil(repo.mergeSession)
        XCTAssertEqual(repo.selectedFile?.id, file().id)
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
        )
    }

    func testSaveRefusesAFileReplacedByASymbolicLink() async throws {
        let targetURL = root.appendingPathComponent("target.txt")
        let fileURL = root.appendingPathComponent("conflict.txt")
        let repo = RepoState(path: root.path)
        let session = try openSession(in: repo, at: fileURL)
        session.setSide(0, side: .ours, on: true)

        try FileManager.default.removeItem(at: fileURL)
        try write(conflictText, to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: targetURL
        )

        repo.saveMergeResolution()
        try await waitUntil("symbolic-link refusal") {
            repo.errorMessage?.contains("symbolic link") == true
        }

        XCTAssertTrue(repo.mergeSession === session)
        XCTAssertEqual(read(targetURL), conflictText)
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
        )
    }

    func testRebaseUsesOperationSpecificSideDescriptions() {
        let repo = RepoState(path: root.path)
        var snapshot = repo.snapshot
        snapshot.operation = .rebase
        repo.snapshot = snapshot

        XCTAssertEqual(repo.conflictSideDescription(.ours), "rebase destination")
        XCTAssertEqual(repo.conflictSideDescription(.theirs), "commit being replayed")
    }

    func testStageFailureKeepsSessionAndWrittenDraft() async throws {
        let fileURL = root.appendingPathComponent("conflict.txt")
        let repo = RepoState(path: root.path)
        let session = try openSession(in: repo, at: fileURL)
        session.setSide(0, side: .ours, on: true)

        repo.saveMergeResolution()

        try await waitUntil("stage failure") {
            repo.errorNotice != nil
        }
        XCTAssertTrue(repo.mergeSession === session)
        XCTAssertEqual(read(fileURL), "top\nours\nbottom\n")
        XCTAssertEqual(session.originalData, try Data(contentsOf: fileURL))
        XCTAssertTrue(repo.errorMessage?.contains("was saved") == true)
    }

    func testSuccessfulSaveWritesStagesAndOnlyThenCloses() async throws {
        let fileURL = root.appendingPathComponent("conflict.txt")
        try await git(["init", "-q", "-b", "main", "."])
        try write("base\n", to: fileURL)
        try await git(["add", "--", "conflict.txt"])
        try await git(["commit", "-qm", "base"])

        try await git(["checkout", "-qb", "topic"])
        try write("theirs\n", to: fileURL)
        try await git(["commit", "-qam", "theirs"])

        try await git(["checkout", "-q", "main"])
        try write("ours\n", to: fileURL)
        try await git(["commit", "-qam", "ours"])
        do {
            try await git(["merge", "topic"])
            XCTFail("expected a merge conflict")
        } catch {
            // The non-zero merge exit is the fixture reaching its target.
        }

        let repo = RepoState(path: root.path)
        await repo.refresh()
        let conflict = try XCTUnwrap(repo.snapshot.conflicted.first)
        repo.openMergeEditor(conflict)
        let session = try XCTUnwrap(repo.mergeSession)
        session.setSide(0, side: .ours, on: true)

        repo.saveMergeResolution()
        try await waitUntil("successful resolution") {
            repo.mergeSession == nil
        }

        XCTAssertEqual(read(fileURL), "ours\n")
        let unmergedEntries = try await git(["ls-files", "-u", "--", "conflict.txt"])
        XCTAssertEqual(unmergedEntries, "")
        XCTAssertNil(repo.errorMessage)
    }
}
