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

    var activeRepo: RepoState? {
        repos.first { $0.id == activeRepoID }
    }

    init() {
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
