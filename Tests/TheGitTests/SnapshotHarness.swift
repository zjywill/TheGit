import XCTest
import SwiftUI
import AppKit
@testable import TheGit

/// Not an assertion suite — an offscreen camera. Renders real views for a
/// real repo into PNGs so layout bugs can be inspected pixel by pixel
/// when the running app can't be screenshotted (unbundled debug builds
/// are invisible to the screen-capture allowlist).
///
/// An offscreen NSWindow + NSHostingView rather than ImageRenderer:
/// ImageRenderer never materialises a LazyVStack inside a ScrollView,
/// and the graph is exactly that. Deliberately NOT an async test — the
/// render pumps the main run loop, and doing that inside a Swift
/// concurrency job over-releases the job's autorelease pool (SIGSEGV).
///
/// Off by default: set SNAPSHOT_REPO (a repo path) and SNAPSHOT_OUT (a
/// directory) to produce images, e.g.
///   SNAPSHOT_REPO=~/Git/TheGit-handoff SNAPSHOT_OUT=/tmp/snaps \
///     swift test --filter SnapshotHarness
final class SnapshotHarness: XCTestCase {
    func testRenderGraphAtWidths() throws {
        guard let repoPath = ProcessInfo.processInfo.environment["SNAPSHOT_REPO"],
              let out = ProcessInfo.processInfo.environment["SNAPSHOT_OUT"]
        else { throw XCTSkip("diagnostic harness — set SNAPSHOT_REPO and SNAPSHOT_OUT to run") }

        try FileManager.default.createDirectory(
            atPath: out, withIntermediateDirectories: true)

        var repo: RepoState!
        let refreshed = expectation(description: "refresh")
        Task { @MainActor in
            repo = RepoState(path: (repoPath as NSString).expandingTildeInPath)
            await repo.refresh()
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 120)

        try MainActor.assumeIsolated {
            // Headless xctest has no app instance; AppKit windows crash
            // without one.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            print("snapshot: rows=\(repo.snapshot.graphRows.count) conflicted=\(repo.snapshot.conflicted.count)")

            for width in [520.0, 1200.0] {
                let view = GraphView(repo: repo)
                    .frame(width: width, height: 700)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                hosting.appearance = NSAppearance(named: .darkAqua)

                let window = NSWindow(
                    contentRect: hosting.frame,
                    styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.contentView = hosting
                window.colorSpace = .sRGB
                // ARC also releases the window; the AppKit default of
                // release-on-close makes that a double free.
                window.isReleasedWhenClosed = false
                // A few plain runloop turns (outside any concurrency job):
                // LazyVStack materialises its viewport one pass after the
                // scroll view learns its size.
                for _ in 0..<4 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    hosting.layoutSubtreeIfNeeded()
                }

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    XCTFail("no bitmap at width \(width)"); continue
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("no png at width \(width)"); continue
                }
                let file = out + "/graph-\(Int(width)).png"
                try png.write(to: URL(fileURLWithPath: file))
                print("snapshot: wrote \(file)")
                window.close()
            }
        }
    }

    func testRenderMergeEditorAtWidths() throws {
        guard let repoPath = ProcessInfo.processInfo.environment["SNAPSHOT_REPO"],
              let out = ProcessInfo.processInfo.environment["SNAPSHOT_OUT"]
        else { throw XCTSkip("diagnostic harness — set SNAPSHOT_REPO and SNAPSHOT_OUT to run") }

        try FileManager.default.createDirectory(
            atPath: out, withIntermediateDirectories: true)

        var repo: RepoState!
        var session: MergeEditorSession!
        let refreshed = expectation(description: "refresh")
        Task { @MainActor in
            repo = RepoState(path: (repoPath as NSString).expandingTildeInPath)
            await repo.refresh()
            if let conflict = repo.snapshot.conflicted.first {
                repo.openMergeEditor(conflict)
                session = repo.mergeSession
            }
            refreshed.fulfill()
        }
        wait(for: [refreshed], timeout: 120)
        guard session != nil else {
            return XCTFail("SNAPSHOT_REPO has no text conflict for the merge editor")
        }

        try MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)

            for width in [400.0, 700.0, 1100.0] {
                let view = MergeEditorView(repo: repo, session: session)
                    .frame(width: width, height: 700)
                let hosting = NSHostingView(rootView: view)
                hosting.frame = NSRect(x: 0, y: 0, width: width, height: 700)
                hosting.appearance = NSAppearance(named: .darkAqua)

                let window = NSWindow(
                    contentRect: hosting.frame,
                    styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.contentView = hosting
                window.colorSpace = .sRGB
                window.isReleasedWhenClosed = false
                for _ in 0..<4 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    hosting.layoutSubtreeIfNeeded()
                }

                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    XCTFail("no merge-editor bitmap at width \(width)"); continue
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("no merge-editor png at width \(width)"); continue
                }
                let file = out + "/merge-\(Int(width)).png"
                try png.write(to: URL(fileURLWithPath: file))
                print("snapshot: wrote \(file)")
                window.close()
            }
        }
    }
}
