import XCTest
@testable import TheGit

final class UpdateCheckTests: XCTestCase {
    func testParsesTagsWithAndWithoutPrefix() {
        XCTAssertEqual(SemanticVersion("v0.7.0")?.description, "0.7.0")
        XCTAssertEqual(SemanticVersion("0.7.0")?.description, "0.7.0")
        XCTAssertEqual(SemanticVersion(" v1.2.3\n")?.description, "1.2.3")
    }

    func testRejectsAnythingThatIsntThreeNumbers() {
        XCTAssertNil(SemanticVersion(nil))
        XCTAssertNil(SemanticVersion("0.7"))
        XCTAssertNil(SemanticVersion("0.7.0-beta"))
        XCTAssertNil(SemanticVersion("nightly"))
        XCTAssertNil(SemanticVersion(""))
    }

    /// The whole point of not comparing the tag strings directly.
    func testOrdersByNumberNotByString() {
        XCTAssertTrue(SemanticVersion("0.9.0")! < SemanticVersion("0.10.0")!)
        XCTAssertTrue(SemanticVersion("0.7.9")! < SemanticVersion("0.8.0")!)
        XCTAssertTrue(SemanticVersion("1.0.0")! > SemanticVersion("0.99.99")!)
        XCTAssertEqual(SemanticVersion("0.7.0")!, SemanticVersion("v0.7.0")!)
    }

    func testReadsTagAndPageFromGitHubsAnswer() {
        let json = """
        {"tag_name": "v0.8.0", "draft": false,
         "html_url": "https://github.com/zjywill/TheGit/releases/tag/v0.8.0"}
        """
        let update = UpdateChecker.parseLatest(Data(json.utf8))
        XCTAssertEqual(update?.version.description, "0.8.0")
        XCTAssertEqual(update?.page.lastPathComponent, "v0.8.0")
    }

    /// A draft is visible to the author's token and to nobody else — acting
    /// on one points every user at a page they'd get a 404 from.
    func testIgnoresDraftsAndUnparseableAnswers() {
        let draft = """
        {"tag_name": "v0.9.0", "draft": true,
         "html_url": "https://github.com/zjywill/TheGit/releases/tag/v0.9.0"}
        """
        XCTAssertNil(UpdateChecker.parseLatest(Data(draft.utf8)))
        XCTAssertNil(UpdateChecker.parseLatest(Data("{\"message\": \"Not Found\"}".utf8)))
        XCTAssertNil(UpdateChecker.parseLatest(Data("not json".utf8)))
    }
}
