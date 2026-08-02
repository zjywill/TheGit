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

    func testCommandSelectionAddsAndRemovesIndividualFiles() {
        let repo = makeRepo()
        let files = makeFiles()
        repo.snapshot.unstaged = files

        repo.selectFile(files[0], in: files)
        repo.selectFile(files[2], in: files, toggling: true)
        XCTAssertEqual(
            repo.selectedWorkingTreeFileIDs,
            Set([files[0].id, files[2].id])
        )
        XCTAssertEqual(repo.selectedFile?.id, files[2].id)

        repo.selectFile(files[2], in: files, toggling: true)
        XCTAssertEqual(repo.selectedWorkingTreeFileIDs, [files[0].id])
        XCTAssertEqual(repo.selectedFile?.id, files[0].id)
        repo.closeDiff()
    }

    func testShiftSelectionBuildsAContiguousRangeFromTheAnchor() {
        let repo = makeRepo()
        let files = makeFiles()
        repo.snapshot.unstaged = files

        repo.selectFile(files[1], in: files)
        repo.selectFile(files[3], in: files, extending: true)
        XCTAssertEqual(
            repo.selectedWorkingTreeFileIDs,
            Set(files[1...3].map(\.id))
        )

        repo.selectFile(files[0], in: files, extending: true)
        XCTAssertEqual(
            repo.selectedWorkingTreeFileIDs,
            Set(files[0...1].map(\.id))
        )
        repo.closeDiff()
    }

    func testSelectAllAndClearAreScopedToOneSection() {
        let repo = makeRepo()
        let unstaged = makeFiles()
        let staged = [
            FileChange(path: "staged-one.txt", status: "M", area: .staged),
            FileChange(path: "staged-two.txt", status: "A", area: .staged),
        ]
        repo.snapshot.unstaged = unstaged
        repo.snapshot.staged = staged

        repo.selectFile(staged[0], in: staged)
        repo.selectAllFiles(in: unstaged)
        XCTAssertEqual(
            repo.selectedWorkingTreeFileIDs,
            Set(unstaged.map(\.id))
        )
        XCTAssertEqual(repo.selectedFile?.id, unstaged[0].id)

        repo.clearFileSelection(in: unstaged)
        XCTAssertTrue(repo.selectedWorkingTreeFileIDs.isEmpty)
        XCTAssertNil(repo.selectedFile)
    }

    func testShiftArrowExtendsAndPlainArrowCollapsesSelection() {
        let repo = makeRepo()
        let files = makeFiles()
        repo.snapshot.unstaged = files

        repo.selectFile(files[0], in: files)
        XCTAssertEqual(
            repo.moveFileSelection(.next, extendingSelection: true)?.id,
            files[1].id
        )
        XCTAssertEqual(
            repo.selectedWorkingTreeFileIDs,
            Set(files[0...1].map(\.id))
        )

        XCTAssertEqual(repo.moveFileSelection(.next)?.id, files[2].id)
        XCTAssertEqual(repo.selectedWorkingTreeFileIDs, [files[2].id])
        repo.closeDiff()
    }

    private func makeFiles() -> [FileChange] {
        [
            FileChange(path: "one.txt", status: "M", area: .unstaged),
            FileChange(path: "two.txt", status: "M", area: .unstaged),
            FileChange(path: "three.txt", status: "?", area: .unstaged),
            FileChange(path: "four.txt", status: "A", area: .unstaged),
        ]
    }

    private func makeRepo() -> RepoState {
        RepoState(path: "/tmp/thegit-file-selection-tests")
    }
}
