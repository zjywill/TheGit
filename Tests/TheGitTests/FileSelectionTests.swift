import XCTest
@testable import TheGit

@MainActor
final class FileSelectionTests: XCTestCase {
    func testMovesWithinUnstagedFiles() {
        let repo = makeRepo()
        let files = [
            FileChange(path: "one.txt", status: "M", area: .unstaged),
            FileChange(path: "two.txt", status: "M", area: .unstaged),
            FileChange(path: "three.txt", status: "?", area: .unstaged),
        ]
        repo.snapshot.unstaged = files
        repo.selectedFile = files[1]

        XCTAssertEqual(repo.moveFileSelection(.previous)?.id, files[0].id)
        XCTAssertEqual(repo.selectedFile?.id, files[0].id)
        XCTAssertEqual(repo.moveFileSelection(.next)?.id, files[1].id)
        XCTAssertEqual(repo.selectedFile?.id, files[1].id)
        repo.closeDiff()
    }

    func testSelectionStaysAtSectionBoundaries() {
        let repo = makeRepo()
        let files = [
            FileChange(path: "one.txt", status: "M", area: .unstaged),
            FileChange(path: "two.txt", status: "M", area: .unstaged),
        ]
        repo.snapshot.unstaged = files

        repo.selectedFile = files[0]
        XCTAssertEqual(repo.moveFileSelection(.previous)?.id, files[0].id)
        XCTAssertEqual(repo.selectedFile?.id, files[0].id)

        repo.selectedFile = files[1]
        XCTAssertEqual(repo.moveFileSelection(.next)?.id, files[1].id)
        XCTAssertEqual(repo.selectedFile?.id, files[1].id)
        repo.closeDiff()
    }

    func testStagedSelectionDoesNotCrossIntoUnstagedFiles() {
        let repo = makeRepo()
        let staged = [
            FileChange(path: "staged-one.txt", status: "M", area: .staged),
            FileChange(path: "staged-two.txt", status: "A", area: .staged),
        ]
        repo.snapshot.staged = staged
        repo.snapshot.unstaged = [
            FileChange(path: "unstaged.txt", status: "M", area: .unstaged),
        ]
        repo.selectedFile = staged[0]

        XCTAssertEqual(repo.moveFileSelection(.next)?.id, staged[1].id)
        XCTAssertEqual(repo.selectedFile?.id, staged[1].id)
        XCTAssertEqual(repo.moveFileSelection(.next)?.id, staged[1].id)
        XCTAssertEqual(repo.selectedFile?.id, staged[1].id)
        repo.closeDiff()
    }

    func testConflictedSelectionStaysInConflictSection() {
        let repo = makeRepo()
        let conflicted = [
            FileChange(path: "conflict-one.txt", status: "U", area: .unstaged),
            FileChange(path: "conflict-two.txt", status: "U", area: .unstaged),
        ]
        repo.snapshot.conflicted = conflicted
        repo.snapshot.unstaged = [
            FileChange(path: "ordinary.txt", status: "M", area: .unstaged),
        ]
        repo.selectedFile = conflicted[0]

        XCTAssertEqual(repo.moveFileSelection(.next)?.id, conflicted[1].id)
        XCTAssertEqual(repo.selectedFile?.id, conflicted[1].id)
        repo.closeDiff()
    }

    private func makeRepo() -> RepoState {
        RepoState(path: "/tmp/thegit-file-selection-tests")
    }
}
