import XCTest

@testable import TheGit

final class ToolchainTests: XCTestCase {
    func testHintPrefersBrewWhenInstalled() {
        XCTAssertEqual(
            InstallHint.hint(for: .gh, brewInstalled: true),
            .command("brew install gh")
        )
        XCTAssertEqual(
            InstallHint.hint(for: .glab, brewInstalled: true),
            .command("brew install glab")
        )
        XCTAssertEqual(
            InstallHint.hint(for: .gitLFS, brewInstalled: true),
            .command("brew install git-lfs")
        )
    }

    func testHintFallsBackToWebsiteWithoutBrew() {
        for tool in DevTool.allCases {
            let hint = InstallHint.hint(for: tool, brewInstalled: false)
            XCTAssertEqual(hint, .website(tool.website))
            XCTAssertFalse(hint.isCommand)
            XCTAssertTrue(hint.display.hasPrefix("https://"), "\(tool) website should be a URL")
        }
    }

    func testForgeMapsToItsCLITool() {
        XCTAssertEqual(Forge.github.cliTool, .gh)
        XCTAssertEqual(Forge.gitlab.cliTool, .glab)
        // The hint command must install the binary the forge shells out to.
        for forge in [Forge.github, .gitlab] {
            XCTAssertEqual(forge.cliTool.binary, forge.binary)
        }
    }

    func testEveryToolHasSettingsCopy() {
        for tool in DevTool.allCases {
            XCTAssertFalse(tool.title.isEmpty)
            XCTAssertFalse(tool.purpose.isEmpty)
        }
    }
}
