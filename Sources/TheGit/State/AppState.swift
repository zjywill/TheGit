import AppKit
import SwiftUI

/// Top-level state: the set of open repositories (tabs).
@MainActor
final class AppState: ObservableObject {
    @Published var repos: [RepoState] = []
    @Published var activeRepoID: String?
    /// A folder the user tried to open that isn't a git repository.
    @Published var nonGitPath: String?

    private static let recentKey = "TheGit.openRepos"

    /// True while the pointer is over a repo tab or the + button, so the
    /// title-bar double-click monitor leaves those clicks alone.
    static var pointerOverTopControl = false

    /// Hidden-title-bar windows have a dead zone at the top: clicks land in
    /// the hosting view, so neither SwiftUI gestures nor AppKit's native
    /// title-bar zoom ever see a double-click. Handle it at the event level.
    private func installTitleBarDoubleClick() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            guard event.clickCount == 2,
                  let window = event.window,
                  window.styleMask.contains(.titled),
                  let content = window.contentView
            else { return event }

            // Title bar + toolbar + tab bar ≈ top 92 pt.
            let yFromTop = content.bounds.height - event.locationInWindow.y
            guard yFromTop >= 0, yFromTop <= 92 else { return event }
            guard !Self.pointerOverTopControl else { return event }
            if let hit = content.superview?.hitTest(event.locationInWindow),
               hit is NSControl {
                return event // toolbar button etc.
            }

            let pref = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            if pref == "Minimize" {
                window.performMiniaturize(nil)
            } else if pref != "None" {
                window.performZoom(nil)
            }
            return nil
        }
    }

    var activeRepo: RepoState? {
        repos.first { $0.id == activeRepoID }
    }

    init() {
        installTitleBarDoubleClick()
        let saved = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        for path in saved where FileManager.default.fileExists(atPath: path + "/.git") {
            repos.append(RepoState(path: path))
        }
        activeRepoID = repos.first?.id
    }

    func openRepoPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(path: url.path)
    }

    func open(path: String) {
        var isDir: ObjCBool = false
        let gitPath = path + "/.git"
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) else {
            // Never auto-init: a novice picking their home folder would
            // turn it into a repo. Tell them how to do it themselves.
            nonGitPath = path
            return
        }
        if let existing = repos.first(where: { $0.path == path }) {
            activeRepoID = existing.id
            return
        }
        let repo = RepoState(path: path)
        repos.append(repo)
        activeRepoID = repo.id
        persist()
        Task { await repo.refresh() }
    }

    func close(repo: RepoState) {
        repos.removeAll { $0.id == repo.id }
        if activeRepoID == repo.id {
            activeRepoID = repos.first?.id
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(repos.map(\.path), forKey: Self.recentKey)
    }
}
