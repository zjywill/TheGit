import AppKit
import SwiftUI

@main
struct TheGitApp: App {
    @StateObject private var appState = AppState()
    @ObservedObject private var avatars = AvatarStore.shared

    init() {
        // Needed when launched via `swift run` (no app bundle).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // The app has its own repo tab bar. macOS's native window tabbing
        // would stack a second, unrelated tab bar above it — and its View
        // menu items sit right next to ours, one slip away. Off entirely.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Repository…") { appState.openRepoPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                // Off by default and opt-in from here: avatars are the one
                // feature that reaches a server the user didn't configure.
                Toggle("Author Avatars", isOn: $avatars.isEnabled)
                    .help("Fetch author avatars from Gravatar and GitHub")
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            RepoTabsBar()
            Divider()
            if let repo = appState.activeRepo {
                RepoView(repo: repo)
                    .id(repo.id)
            } else {
                EmptyStateView()
            }
        }
        .alert(
            "Not a Git repository",
            isPresented: Binding(
                get: { appState.nonGitPath != nil },
                set: { if !$0 { appState.nonGitPath = nil } }
            )
        ) {
            Button("Copy Command") {
                if let path = appState.nonGitPath {
                    RepoState.copyToPasteboard("cd \"\(path)\" && git init")
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("""
            "\((appState.nonGitPath as NSString?)?.lastPathComponent ?? "")" has no .git directory.

            To turn it into a repository, run this in Terminal, then open the folder again:

            cd "\(appState.nonGitPath ?? "")" && git init
            """)
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No repository open")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Open Repository…") { appState.openRepoPanel() }
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Top tab bar: one tab per open repository, like a browser.
struct RepoTabsBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(appState.repos) { repo in
                RepoTab(repo: repo, isActive: repo.id == appState.activeRepoID)
            }
            Button {
                appState.openRepoPanel()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            .help("Open Repository (⌘O)")
            .onHover { AppState.pointerOverTopControl = $0 }
            Spacer()
        }
        .padding(.horizontal, 80) // leave room for traffic lights
        .frame(height: 38)
        .background(.bar)
    }
}

struct RepoTab: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var repo: RepoState
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(repo.displayName)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            Button {
                appState.close(repo: repo)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.04) : .clear)
                .animation(.easeOut(duration: 0.12), value: hovering)
        )
        .contentShape(Rectangle())
        // Tab switching is a many-times-a-day action: no animation, instant.
        .onTapGesture { appState.activeRepoID = repo.id }
        .contextMenu {
            Button("Close Tab") { appState.close(repo: repo) }
            Button("Close Other Tabs") {
                for other in appState.repos where other.id != repo.id {
                    appState.close(repo: other)
                }
            }
            Divider()
            Button("Copy Repository Path") { RepoState.copyToPasteboard(repo.path) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            }
            Button("Open in Terminal") {
                let url = URL(fileURLWithPath: repo.path)
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        }
        .onHover {
            hovering = $0
            AppState.pointerOverTopControl = $0
        }
    }
}
