import AppKit
import SwiftUI

/// Five UI zoom levels. Zoom multiplies font sizes and the key layout
/// metrics through the `\.uiZoom` environment value — plain state-driven
/// relayout, no scale transforms and no nested hosting views. Every
/// transform-based approach that was tried (SwiftUI scaleEffect, an AppKit
/// bounds transform, a wrapped NSHostingView with scene bridging off)
/// tripped macOS 26's reentrant-layout assert in the window's toolbar
/// bridge when zoom changed while a layout pass was in flight.
enum UIZoom {
    static let levels: [CGFloat] = [0.85, 0.95, 1.0, 1.15, 1.3]
    static let defaultLevel = 2
}

private struct UIZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Current UI zoom factor; font sizes and layout metrics multiply by it.
    var uiZoom: CGFloat {
        get { self[UIZoomKey.self] }
        set { self[UIZoomKey.self] = newValue }
    }
}

@main
struct TheGitApp: App {
    @StateObject private var appState = AppState()
    @ObservedObject private var avatars = AvatarStore.shared
    @AppStorage("uiZoomLevel") private var zoomLevel = UIZoom.defaultLevel

    private var zoom: CGFloat {
        UIZoom.levels[max(0, min(zoomLevel, UIZoom.levels.count - 1))]
    }

    private func setZoom(_ level: Int) {
        DispatchQueue.main.async {
            zoomLevel = max(0, min(level, UIZoom.levels.count - 1))
        }
    }

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
                .environment(\.uiZoom, zoom)
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
                Divider()
                // ⌘= rather than ⌘⇧= : matches what browsers actually bind.
                // The level change is deferred out of the key-event cycle
                // so the whole-window relayout starts from a clean turn.
                Button("Zoom In") { setZoom(zoomLevel + 1) }
                    .keyboardShortcut("=")
                    .disabled(zoomLevel >= UIZoom.levels.count - 1)
                Button("Zoom Out") { setZoom(zoomLevel - 1) }
                    .keyboardShortcut("-")
                    .disabled(zoomLevel <= 0)
                Button("Actual Size") { setZoom(UIZoom.defaultLevel) }
                    .keyboardShortcut("0")
                    .disabled(zoomLevel == UIZoom.defaultLevel)
            }
        }

        // Its own window, inheriting nothing from the one above — zoom has
        // to be handed to it separately.
        Settings {
            SettingsRootView()
                .environment(\.uiZoom, zoom)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var appState: AppState
    /// Lives here, not in RepoToolbar: @AppStorage inside a ToolbarContent
    /// struct is never installed on the view graph on macOS — writes were
    /// silently dropped and the pull-mode picker's check never moved.
    @AppStorage("pullMode") private var pullModeRaw = RepoState.PullMode.ff.rawValue

    var body: some View {
        VStack(spacing: 0) {
            // With no repo open the bar holds one lone + against an empty
            // strip, and the empty state below already offers the same
            // action in a form that reads as the thing to do. A tab bar
            // with no tabs is chrome describing nothing.
            if !appState.repos.isEmpty {
                RepoTabsBar()
                Divider()
            }
            if let repo = appState.activeRepo {
                RepoView(repo: repo)
            } else {
                EmptyStateView()
            }
        }
        // Anchored to the window, not to the repo. Hanging it off RepoView
        // meant every tab switch tore the NSToolbar down and rebuilt each
        // item viewer as a fresh subview — the single largest cost of a
        // switch (1542 samples in -[NSToolbarView layout] plus 745 in
        // ToolbarBridge.makeStorage, ~27% of the main thread). Up here the
        // items keep their identity across repos and only rebind.
        .toolbar {
            if let repo = appState.activeRepo {
                RepoToolbar(repo: repo, pullModeRaw: $pullModeRaw)
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
            // A box with no git is the first-launch-on-a-fresh-Mac case:
            // every repo would error, so "open a repository" is the wrong
            // pitch. Say what's missing and offer Apple's own installer —
            // one click, no password, no Homebrew. The card dismisses
            // itself: AppState polls for git and flips the flag.
            if appState.gitMissing {
                Image(systemName: "wrench.and.screwdriver")
                    .zoomFont(48)
                    .foregroundStyle(.secondary)
                Text("Git isn't installed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("TheGit works through Apple's command-line git.\nInstalling the Command Line Tools takes a few minutes and needs nothing else.")
                    .zoomFont(12)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // The screen's one action gets the one prominent button.
                Button("Install Command Line Tools…") {
                    appState.installCommandLineTools()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Opens Apple's installer. This screen moves on by itself once git is ready.")
                    .zoomFont(10)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .zoomFont(48)
                    .foregroundStyle(.secondary)
                Text("No repository open")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button("Open Repository…") { appState.openRepoPanel() }
                    .keyboardShortcut("o")
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Each tab's laid-out width, keyed by repo id. Widths don't change while a
/// tab is dragged (`.offset` moves it without resizing it), so the bar can
/// work out every slot's position from these alone.
private struct TabWidthKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Top tab bar: one tab per open repository, like a browser.
///
/// Reordering is a plain drag gesture, not a pasteboard drag. Two reasons,
/// both learned the hard way: `.draggable` in this strip never started a
/// session at all — the window's `.bar` background claims the drag first —
/// and even where it works it can only ever drag a *picture* of the tab to
/// a drop target, which is not what a browser does. Here the tab itself is
/// what moves, and the others shuffle out of its way as it passes them.
struct RepoTabsBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom

    private static let spacing: CGFloat = 2
    /// The drag gesture measures in this space — the strip itself, which
    /// never moves. Measuring in the tab's own space feeds back: every slot
    /// change moves the tab, which moves the coordinate space, which skews
    /// the next translation, which moves the tab again.
    static let coordinateSpace = "RepoTabsBar"

    @State private var widths: [String: CGFloat] = [:]
    /// The tab under the pointer, its slot centre when the drag began, and
    /// how far the pointer has travelled since.
    @State private var draggingID: String?
    @State private var dragStartCenter: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0

    private var centers: [CGFloat] {
        TabStrip.centers(
            widths: appState.repos.map { widths[$0.id] ?? 0 },
            spacing: Self.spacing
        )
    }

    private func dragChanged(_ id: String, _ translation: CGFloat) {
        guard let current = appState.repos.firstIndex(where: { $0.id == id }) else { return }
        if draggingID != id {
            draggingID = id
            dragStartCenter = centers[current]
            // Pressing a tab selects it, then drags it — same as a browser.
            appState.activeRepoID = id
        }
        // Where the tab is being held, in bar coordinates. Anchored to the
        // centre it had when the drag began, so it stays correct however
        // many times the tab changes slots on the way.
        let held = dragStartCenter + translation
        let target = TabStrip.slot(holding: held, current: current, centers: centers)
        if target != current {
            // Animated: this is the other tabs sliding aside.
            withAnimation(.easeOut(duration: 0.18)) {
                appState.moveTab(from: current, to: target)
            }
        }
        // Not animated, and computed after the move: the offset is whatever
        // it takes to keep the tab under the pointer now that its slot has
        // moved out from under it.
        dragTranslation = held - centers[target]
    }

    private func dragEnded() {
        // The tab is already in its slot; this is only the last few points
        // between the pointer and the slot's centre closing up.
        withAnimation(.easeOut(duration: 0.18)) {
            draggingID = nil
            dragTranslation = 0
        }
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(appState.repos) { repo in
                RepoTab(
                    repo: repo,
                    isActive: repo.id == appState.activeRepoID,
                    isDragging: draggingID == repo.id,
                    dragOffset: draggingID == repo.id ? dragTranslation : 0,
                    dragChanged: { dragChanged(repo.id, $0) },
                    dragEnded: dragEnded
                )
            }
            Button {
                appState.openRepoPanel()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28 * zoom, height: 28 * zoom)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            .help("Open Repository (⌘O)")
            .onHover { AppState.pointerOverTopControl = $0 }
            Spacer()
        }
        .coordinateSpace(name: Self.coordinateSpace)
        // The traffic lights live in the toolbar row above, not in this one,
        // so nothing here has to dodge them. 10 pt is the sidebar's own
        // inset: the first tab's edge lines up with the filter field and
        // the branch pill directly below it.
        .padding(.horizontal, 10)
        .frame(height: 38 * zoom)
        .background(.bar)
        .onPreferenceChange(TabWidthKey.self) { widths = $0 }
    }
}

struct RepoTab: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var repo: RepoState
    let isActive: Bool
    let isDragging: Bool
    let dragOffset: CGFloat
    let dragChanged: (CGFloat) -> Void
    let dragEnded: () -> Void
    @State private var hovering = false
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .zoomFont(10)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            Text(repo.displayName)
                .zoomFont(12, weight: isActive ? .semibold : .regular)
                .lineLimit(1)
            Button {
                appState.close(repo: repo)
            } label: {
                Image(systemName: "xmark")
                    .zoomFont(8, weight: .bold)
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.horizontal, 10)
        .frame(height: 28 * zoom)
        .background(
            ZStack {
                // Opaque only while in flight: the tab passes over its
                // neighbours, and without a solid base their titles show
                // through this one — and the shadow, with nothing solid to
                // fall from, outlines every glyph instead of the tab.
                if isDragging {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .windowBackgroundColor))
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.primary.opacity(0.08) : hovering ? Color.primary.opacity(0.04) : .clear)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
        )
        // Measured before the offset below, so a tab in flight still reports
        // the width of the slot it came out of.
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TabWidthKey.self,
                    value: [repo.id: geometry.size.width]
                )
            }
        )
        // Picked up off the strip: it rides above its neighbours and casts a
        // shadow, so it reads as the thing being moved rather than as a tab
        // that has come loose.
        .shadow(
            color: .black.opacity(isDragging ? 0.25 : 0),
            radius: isDragging ? 6 : 0,
            y: isDragging ? 2 : 0
        )
        .offset(x: dragOffset)
        .zIndex(isDragging ? 1 : 0)
        // The reorder's withAnimation must not reach the held tab: its slot
        // position and the offset that cancels it have to land in the same
        // frame, or their sum drifts and the tab slides out from under the
        // pointer. Only its neighbours animate. On release isDragging is
        // already false, so the settle back to the slot still animates.
        .transaction { transaction in
            if isDragging { transaction.animation = nil }
        }
        .contentShape(Rectangle())
        // Tab switching is a many-times-a-day action: no animation, instant.
        .onTapGesture { appState.activeRepoID = repo.id }
        // 3pt of slack so a click that shifts by a pixel still selects the
        // tab instead of nudging the whole bar.
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named(RepoTabsBar.coordinateSpace))
                .onChanged { dragChanged($0.translation.width) }
                .onEnded { _ in dragEnded() }
        )
        .contextTarget("tab:" + repo.id, repo)
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
