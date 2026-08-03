import AppKit
import XCTest
@testable import TheGit

@MainActor
final class ImageDiffTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thegit-image-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImageMetadataRejectsInvalidDataAndReportsPixels() throws {
        XCTAssertTrue(ImageDiff.supports(path: "assets/icon.PNG"))
        XCTAssertTrue(ImageDiff.supports(path: "photo.webp"))
        XCTAssertFalse(ImageDiff.supports(path: "vector.svg"))
        XCTAssertNil(ImageDiffVersion(data: Data("<html>not an image</html>".utf8)))

        let data = png(width: 7, height: 5, seed: 31)
        let version = try XCTUnwrap(ImageDiffVersion(data: data))
        XCTAssertEqual(version.pixelWidth, 7)
        XCTAssertEqual(version.pixelHeight, 5)
        XCTAssertEqual(version.frameCount, 1)
        XCTAssertEqual(version.formattedDimensions, "7 x 5 px")
        XCTAssertFalse(version.formattedByteCount.isEmpty)
    }

    func testWorkingTreeImageDiffReadsIndexDiskAndHEAD() async throws {
        let path = try await makeRepo("working-tree")
        try writePNG(width: 3, height: 2, seed: 10, to: path + "/icon.png")
        try await git(path, ["add", "icon.png"])
        try await git(path, ["commit", "-qm", "add icon"])

        try writePNG(width: 8, height: 5, seed: 70, to: path + "/icon.png")
        let client = GitClient(repoPath: path)
        let unstagedValue = try await client.workingTreeImageDiff(
            FileChange(path: "icon.png", status: "M", area: .unstaged)
        )
        let unstaged = try XCTUnwrap(unstagedValue)
        XCTAssertEqual(unstaged.old.map { [$0.pixelWidth, $0.pixelHeight] }, [3, 2])
        XCTAssertEqual(unstaged.new.map { [$0.pixelWidth, $0.pixelHeight] }, [8, 5])

        try await git(path, ["add", "icon.png"])
        let stagedValue = try await client.workingTreeImageDiff(
            FileChange(path: "icon.png", status: "M", area: .staged)
        )
        let staged = try XCTUnwrap(stagedValue)
        XCTAssertEqual(staged.old.map { [$0.pixelWidth, $0.pixelHeight] }, [3, 2])
        XCTAssertEqual(staged.new.map { [$0.pixelWidth, $0.pixelHeight] }, [8, 5])
    }

    func testAddedDeletedAndRenamedImagesKeepTheCorrectSides() async throws {
        let path = try await makeRepo("file-shapes")
        let client = GitClient(repoPath: path)

        try writePNG(width: 4, height: 6, seed: 20, to: path + "/new.png")
        let addedValue = try await client.workingTreeImageDiff(
            FileChange(path: "new.png", status: "?", area: .unstaged)
        )
        let added = try XCTUnwrap(addedValue)
        XCTAssertNil(added.old)
        XCTAssertEqual(added.new.map { [$0.pixelWidth, $0.pixelHeight] }, [4, 6])

        try await git(path, ["add", "new.png"])
        try await git(path, ["commit", "-qm", "add new"])
        try await git(path, ["mv", "new.png", "renamed.png"])
        let status = try await client.status()
        let renamed = try XCTUnwrap(status.staged.first { $0.path == "renamed.png" })
        XCTAssertEqual(renamed.status, "R")
        XCTAssertEqual(renamed.oldPath, "new.png")
        let renamedValue = try await client.workingTreeImageDiff(renamed)
        let renamedDiff = try XCTUnwrap(renamedValue)
        XCTAssertEqual(renamedDiff.old?.pixelWidth, 4)
        XCTAssertEqual(renamedDiff.new?.pixelWidth, 4)

        try await git(path, ["reset", "-q", "HEAD"])
        try FileManager.default.moveItem(
            atPath: path + "/renamed.png", toPath: path + "/new.png"
        )
        try FileManager.default.removeItem(atPath: path + "/new.png")
        let deletedValue = try await client.workingTreeImageDiff(
            FileChange(path: "new.png", status: "D", area: .unstaged)
        )
        let deleted = try XCTUnwrap(deletedValue)
        XCTAssertEqual(deleted.old.map { [$0.pixelWidth, $0.pixelHeight] }, [4, 6])
        XCTAssertNil(deleted.new)
    }

    func testCommitAndReviewImageDiffUseTheHistoricalVersions() async throws {
        let path = try await makeRepo("history")
        try writePNG(width: 2, height: 3, seed: 12, to: path + "/banner.png")
        try await git(path, ["add", "banner.png"])
        try await git(path, ["commit", "-qm", "small banner"])
        let base = trimmed(try await git(path, ["rev-parse", "HEAD"]))

        try await git(path, ["checkout", "-qb", "feature"])
        try writePNG(width: 9, height: 4, seed: 90, to: path + "/banner.png")
        try await git(path, ["add", "banner.png"])
        try await git(path, ["commit", "-qm", "wide banner"])
        let head = trimmed(try await git(path, ["rev-parse", "HEAD"]))

        let client = GitClient(repoPath: path)
        let commitValue = try await client.commitImageDiff(
            head,
            file: FileChange(path: "banner.png", status: "M", area: .unstaged)
        )
        let commit = try XCTUnwrap(commitValue)
        XCTAssertEqual(commit.old.map { [$0.pixelWidth, $0.pixelHeight] }, [2, 3])
        XCTAssertEqual(commit.new.map { [$0.pixelWidth, $0.pixelHeight] }, [9, 4])

        let reviewValue = try await client.reviewFileImageDiff(
            range: "\(base)...\(head)",
            file: ReviewFile(path: "banner.png", status: "M", isBinary: true)
        )
        let review = try XCTUnwrap(reviewValue)
        XCTAssertEqual(review.old.map { [$0.pixelWidth, $0.pixelHeight] }, [2, 3])
        XCTAssertEqual(review.new.map { [$0.pixelWidth, $0.pixelHeight] }, [9, 4])
    }

    func testRepoStatePublishesAndClearsAnImageDiff() async throws {
        let path = try await makeRepo("repo-state")
        try writePNG(width: 3, height: 3, seed: 8, to: path + "/tile.png")
        try await git(path, ["add", "tile.png"])
        try await git(path, ["commit", "-qm", "tile"])
        try writePNG(width: 6, height: 4, seed: 80, to: path + "/tile.png")

        let repo = RepoState(path: path)
        await repo.refresh()
        let file = try XCTUnwrap(repo.snapshot.unstaged.first { $0.path == "tile.png" })
        repo.selectFile(file)
        try await waitUntil("image diff to load") { repo.imageDiff != nil }
        XCTAssertEqual(repo.imageDiff?.old?.pixelWidth, 3)
        XCTAssertEqual(repo.imageDiff?.new?.pixelWidth, 6)
        XCTAssertTrue(repo.diffLines.isEmpty)

        repo.closeDiff()
        XCTAssertNil(repo.imageDiff)
    }

    @discardableResult
    private func git(_ dir: String, _ args: [String]) async throws -> String {
        try await Shell.run(
            "/usr/bin/env",
            ["git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=Test"] + args,
            env: ["GIT_TERMINAL_PROMPT": "0"]
        )
    }

    private func makeRepo(_ name: String) async throws -> String {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try await git(path, ["init", "-q", "-b", "main", "."])
        try "seed\n".write(toFile: path + "/seed.txt", atomically: true, encoding: .utf8)
        try await git(path, ["add", "-A"])
        try await git(path, ["commit", "-qm", "init"])
        return path
    }

    private func writePNG(
        width: Int, height: Int, seed: UInt8, to path: String
    ) throws {
        try png(width: width, height: height, seed: seed).write(
            to: URL(fileURLWithPath: path), options: .atomic
        )
    }

    private func png(width: Int, height: Int, seed: UInt8) -> Data {
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        )!
        let bytes = image.bitmapData!
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * image.bytesPerRow + x * 4
                bytes[offset] = seed &+ UInt8((x * 17) % 127)
                bytes[offset + 1] = seed &+ UInt8((y * 23) % 127)
                bytes[offset + 2] = seed
                bytes[offset + 3] = 255
            }
        }
        return image.representation(using: .png, properties: [:])!
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
