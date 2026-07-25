import SwiftUI

/// Three-pane layout for one repository:
/// sidebar (branches) | graph | commit panel.
struct RepoView: View {
    @ObservedObject var repo: RepoState

    var body: some View {
        HSplitView {
            SidebarView(repo: repo)
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
            GraphView(repo: repo)
                .frame(minWidth: 400)
                .layoutPriority(1)
            CommitPanelView(repo: repo)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
        }
        .toolbar { RepoToolbar(repo: repo) }
        .task { await repo.appeared() }
        .alert(
            "Git Error",
            isPresented: Binding(
                get: { repo.errorMessage != nil },
                set: { if !$0 { repo.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(repo.errorMessage ?? "")
        }
    }
}

struct RepoToolbar: ToolbarContent {
    @ObservedObject var repo: RepoState

    var body: some ToolbarContent {
        ToolbarItemGroup {
            // Fixed slot + opacity fade: the spinner must never push the
            // other toolbar buttons sideways when it appears.
            ProgressView()
                .controlSize(.small)
                .opacity(repo.isBusy ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: repo.isBusy)
                .frame(width: 20)
            Button {
                repo.fetch()
            } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Fetch all remotes")

            Button {
                repo.pull()
            } label: {
                Label("Pull", systemImage: "arrow.down")
            }
            .help("Pull")

            Button {
                repo.push()
            } label: {
                Label("Push", systemImage: "arrow.up")
            }
            .help("Push")

            Button {
                Task { await repo.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
        }
    }
}
