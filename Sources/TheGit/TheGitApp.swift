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
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage("uiZoomLevel") private var zoomLevel = UIZoom.defaultLevel

    private var zoom: CGFloat {
        UIZoom.levels[max(0, min(zoomLevel, UIZoom.levels.count - 1))]
    }

    /// The smallest content the window is laid out for: a sidebar, a graph
    /// with room for lanes, and a commit panel beside it. Declared once and
    /// used twice — as the root view's frame, which is what stops the content
    /// from being laid out any smaller, and as the window's own floor, which
    /// is what stops the window from being dragged under it.
    private static let minContent = CGSize(width: 1000, height: 620)

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
                .frame(minWidth: Self.minContent.width, minHeight: Self.minContent.height)
                // The frame alone is not enough — see WindowFloor.
                .background(WindowFloor(size: Self.minContent))
        }
        .commands {
            // Directly under "About TheGit", where every Mac app puts it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkNow() }
                    .disabled(updates.isChecking)
            }
            CommandGroup(after: .newItem) {
                Button("Open Repository…") { appState.openRepoPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                // Off by default and opt-in from here: avatars are the one
                // feature that reaches a server the user didn't configure.
                //
                // A title that swaps, not a Toggle: a Toggle draws its
                // checkmark inside the label, which pushes the title left of
                // every other item in a menu that reserves an icon column —
                // and "Show / Hide" is what the View menu does elsewhere on
                // this Mac anyway.
                Button(avatars.isEnabled ? "Hide Author Avatars" : "Show Author Avatars") {
                    avatars.isEnabled.toggle()
                }
                .help("Look up author avatars on GitLab, Gravatar, and GitHub")
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
                // ⌥⌘0, not the browsers' ⌘0: the tab strip owns ⌘0 for the
                // Dashboard (the zero of its ⌘1…⌘9 family), and two live
                // bindings on one chord fire nondeterministically.
                Button("Actual Size") { setZoom(UIZoom.defaultLevel) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
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
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The window's real toolbar. It is what the commands were always
    /// meant to be, and keeping it visible is also what gives the window
    /// macOS 26's toolbar-class corner radius — the app used to draw its own
    /// row in the title-bar band and buy that radius back by swizzling
    /// NSThemeFrame's private getters.
    ///
    /// Which commands appear follows the selected tab, so a screen switch
    /// changes the toolbar's contents and nothing else about the window.
    /// What a repository's command cluster puts between its buttons, so the
    /// home screens' row reads as the same row.
    private static let toolbarSpacing: CGFloat = 6

    /// A toolbar item that draws nothing of its own around its content.
    /// macOS 26 puts every custom item inside a glass capsule; the repo
    /// commands and the search field already carry their own surface (or
    /// deliberately carry none), so the system's capsule was a second
    /// background around both.
    @ToolbarContentBuilder
    private func bareItem<Content: View>(
        placement: ToolbarItemPlacement,
        @ViewBuilder content: () -> Content
    ) -> some ToolbarContent {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: placement, content: content)
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement, content: content)
        }
#else
        ToolbarItem(placement: placement, content: content)
#endif
    }

    @ToolbarContentBuilder
    private var toolbarCommands: some ToolbarContent {
        if let repo = appState.activeRepo {
            bareItem(placement: .navigation) {
                RepoCommandCluster(repo: repo)
            }
            bareItem(placement: .primaryAction) {
                HStack(spacing: Self.toolbarSpacing) {
                    RepoSearchField(repo: repo)
                    RepoBusySpinner(repo: repo)
                }
            }
        } else if appState.showingRepositories {
            // Same two slots as a repository's: commands leading, search
            // trailing. The home screens' buttons used to sit in a group of
            // their own, which macOS drew as a capsule beside the search
            // field — a different shape in a different place on every screen.
            bareItem(placement: .navigation) {
                HStack(spacing: Self.toolbarSpacing) {
                    TopBarIconButton(
                        systemImage: "folder.badge.plus",
                        help: "Add every Git repository inside a folder",
                        disabled: appState.scanning
                    ) { appState.scanFolderPanel() }
                    TopBarIconButton(
                        systemImage: "rectangle.stack.badge.plus",
                        help: "Group repositories under a heading of your own"
                    ) { appState.addCatalogSection() }
                    TopBarIconButton(
                        systemImage: "arrow.clockwise",
                        help: "Re-read every folder in the list (⌘R)",
                        spinning: appState.refreshingCatalog,
                        shortcut: "r"
                    ) { appState.refreshCatalog(userInitiated: true) }
                }
            }
            bareItem(placement: .primaryAction) {
                CatalogSearchField()
            }
        } else {
            bareItem(placement: .navigation) {
                HStack(spacing: Self.toolbarSpacing) {
                    TopBarIconButton(
                        systemImage: "folder.badge.plus",
                        help: "Open Repository (⌘O)"
                    ) { appState.openRepoPanel() }
                    TopBarIconButton(
                        systemImage: "arrow.clockwise",
                        help: "Re-read every repository (⌘R)",
                        spinning: appState.refreshingDashboard,
                        shortcut: "r"
                    ) { appState.refreshDashboard() }
                }
            }
        }
    }

    var body: some View {
        // One column on every screen: the window's real toolbar carries the
        // commands, the tab strip sits directly under it, and only the band
        // below that changes when a tab does. The strip is app navigation,
        // so it spans the full width — above the repository's sidebar, not
        // beside it.
        VStack(spacing: 0) {
            AppTopBar()
            // App-level status directly below the window navigation.
            if let update = updates.update {
                UpdateBanner(
                    update: update,
                    openReleasePage: { updates.openReleasePage() },
                    dismiss: { updates.skipCurrentUpdate() }
                )
                Divider()
            }
            if let repo = appState.activeRepo {
                RepoView(repo: repo)
            } else if appState.showingRepositories {
                RepositoriesView()
            } else {
                DashboardView()
            }
        }
        // Here rather than on the banner itself: showing the banner is this
        // stack's change, so this is the transaction its transition rides on.
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.2), value: updates.update)
        .toolbar { toolbarCommands }
        // Inside RootView, not on the WindowGroup root: SwiftUI quietly
        // reasserts title-bar properties when the screen below changes, and
        // only a view that re-renders on that change re-applies the chrome.
        .background(MainWindowChrome())
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
        // Only the result of a check the *user* asked for gets a dialog.
        .alert(
            updates.manualResult?.title ?? "",
            isPresented: Binding(
                get: { updates.manualResult != nil },
                set: { if !$0 { updates.manualResult = nil } }
            ),
            presenting: updates.manualResult
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result.message)
        }
        .onAppear {
            updates.checkInBackground()
            // Where `claude` and `codex` live is a question only the user's
            // own shell can answer — a bundled .app inherits launchd's bare
            // PATH, which has neither. The Hand Off menus appear as soon as
            // it has answered, which is long before anyone right-clicks.
            Task {
                await Shell.resolveLoginPath()
                AgentTools.shared.recheck()
            }
        }
    }

}

/// The tab strip's row, directly under the window's toolbar and above
/// everything a tab selects — including the repository sidebar. One row on
/// every screen, at the same x and the same height, so a switch changes
/// nothing above the content. The traffic lights are the toolbar's again;
/// this row no longer shares the title-bar band with them.
struct AppTopBar: View {
    /// Fixed, not zoomed: the row is chrome, and the toolbar above it is
    /// system-sized too.
    static let height: CGFloat = 40

    var body: some View {
        RepoTabsBar()
            .frame(height: Self.height)
            .background(.bar)
    }
}

/// One top-bar action: the same quiet icon-in-a-rounded-rect the pinned
/// tabs use, so the row reads as one family of controls.
private struct TopBarIconButton: View {
    let systemImage: String
    let help: String
    var disabled = false
    var spinning = false
    var shortcut: KeyEquivalent?
    let action: () -> Void

    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        // Sized, weighted and lit exactly like a repository's command
        // buttons — the two rows share the toolbar's leading slot, one
        // screen apart.
        Button(action: action) {
            Image(systemName: systemImage)
                .zoomFont(13, weight: .medium)
                .refreshSpin(spinning)
                .frame(width: 28 * zoom, height: 28 * zoom)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                        .animation(.easeOut(duration: 0.12), value: hovering)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.rowPressEffect)
        .disabled(disabled)
        .modifier(OptionalShortcut(key: shortcut))
        .help(help)
        .onHover {
            hovering = $0
            AppState.pointerOverTopControl = $0
        }
    }
}

/// `.keyboardShortcut` has no none-case; this applies one only when asked.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key)
        } else {
            content
        }
    }
}

/// One quiet line saying a newer release exists. It cannot install anything
/// — see UpdateChecker — so the only action it offers is the release page,
/// and dismissing it silences this version for good.
///
/// Takes the update rather than reading the singleton: the parent has
/// already unwrapped it, and a second optional here only creates a state
/// this can render but never actually reach.
struct UpdateBanner: View {
    let update: UpdateChecker.Update
    let openReleasePage: () -> Void
    let dismiss: () -> Void
    @Environment(\.uiZoom) private var zoom

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .zoomFont(12)
                .foregroundStyle(Color.accentColor)
            Text("TheGit \(update.version.description) is available.")
                .zoomFont(12, weight: .medium)
            // A shape, not a link: the surface behind it is chrome, and a
            // blue word on chrome is a control only to someone who can see
            // the blue. The arrow says the click leaves the app — this
            // banner cannot install anything, and a plain label implies it
            // can. Hand-built rather than .bordered so it scales with
            // Cmd+= like the rest of the window.
            Button(action: openReleasePage) {
                HStack(spacing: 4) {
                    Text("Open Release Notes")
                    Image(systemName: "arrow.up.right")
                }
                .zoomFont(11, weight: .medium)
                .padding(.horizontal, 8 * zoom)
                .padding(.vertical, 3 * zoom)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.pressEffect)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .zoomFont(9, weight: .bold)
                    .frame(width: 20 * zoom, height: 20 * zoom)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            // .help alone is a tooltip and an accessibility *hint*; with no
            // name, VoiceOver announces this as "button".
            .accessibilityLabel("Dismiss update notice")
            .help("Dismiss until the next release")
        }
        .padding(.horizontal, 10)
        .frame(height: 30 * zoom)
        // Neutral, not accent-tinted: accent means "current" everywhere else
        // in this window — the active tab, the checked-out branch, the
        // focused filter — and a full-width accent strip reads as a selected
        // row. The accent stays on the one icon.
        .background(Color.primary.opacity(0.05))
        // The matching .animation lives on RootView's stack, not here: this
        // view is inserted by the parent's `if`, and a modifier can't animate
        // an insertion it doesn't exist for yet.
        .transition(.move(edge: .top).combined(with: .opacity))
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                // An empty wall with a full catalog is the common case once
                // the user has scanned a folder: the repos exist, none of them
                // is on the Dashboard yet, and a file picker is the long way
                // round to a list the app already has.
                if !appState.catalog.isEmpty {
                    Button("Browse \(appState.catalog.count) Repositories") {
                        appState.showRepositories()
                    }
                    .buttonStyle(.link)
                }
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

/// How much tab strip lies beyond each edge of its viewport. Zero on an edge
/// means nothing is cut off there, which is what keeps the fade below from
/// dimming a strip that fits.
private struct TabScrollEdges: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

/// Top tab bar: one tab per open repository, like a browser. It lives in
/// AppTopBar's single row on every screen.
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
    /// The scrolling viewport, which the strip's own frame is read against to
    /// recover the scroll offset.
    private static let scrollSpace = "RepoTabsScroll"
    /// How far a tab dissolves at an edge it runs past. Long enough to read
    /// as a fade rather than a soft edge, short enough that the tab beside
    /// it stays fully legible.
    private static let fadeWidth: CGFloat = 24

    @State private var widths: [String: CGFloat] = [:]
    /// The tab under the pointer, its slot centre when the drag began, and
    /// how far the pointer has travelled since.
    @State private var draggingID: String?
    @State private var dragStartCenter: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var tabScrollID: String?
    /// The strip's frame in the viewport's space, and the viewport's width.
    /// Together they say how much strip lies past each edge.
    @State private var contentBounds: CGRect = .zero
    @State private var viewportWidth: CGFloat = 0

    private var scrollEdges: TabScrollEdges {
        // Before the first measurement there is no viewport to overflow.
        guard viewportWidth > 0 else { return TabScrollEdges() }
        return TabScrollEdges(
            leading: -contentBounds.minX,
            trailing: contentBounds.maxX - viewportWidth
        )
    }

    /// The fade ramps up over the first `fadeWidth` points that go past an
    /// edge, so a tab starting to leave dims gradually instead of the whole
    /// gradient switching on at the first scrolled pixel.
    private func fade(_ overflow: CGFloat) -> CGFloat {
        min(max(overflow, 0), Self.fadeWidth)
    }

    private var centers: [CGFloat] {
        TabStrip.centers(
            widths: appState.openRepos.map { widths[$0.id] ?? 0 },
            spacing: Self.spacing
        )
    }

    private func dragChanged(_ id: String, _ translation: CGFloat) {
        guard let current = appState.openTabIDs.firstIndex(of: id) else { return }
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
            RepositoriesTab()
            DashboardTab()
            // Pinned: they sit outside the reorderable ForEach below, so they
            // can't be dragged out of first place and the drag arithmetic
            // (which indexes appState.openTabIDs) never has to know about them.
            ScrollView(.horizontal) {
                HStack(spacing: Self.spacing) {
                    ForEach(appState.openRepos) { repo in
                        RepoTab(
                            repo: repo,
                            isActive: repo.id == appState.activeRepoID,
                            isDragging: draggingID == repo.id,
                            dragOffset: draggingID == repo.id ? dragTranslation : 0,
                            dragChanged: { dragChanged(repo.id, $0) },
                            dragEnded: dragEnded
                        )
                        .id(repo.id)
                    }
                    NewTabButton()
                }
                .coordinateSpace(name: Self.coordinateSpace)
                .scrollTargetLayout()
                // Where the strip sits inside its viewport, which is the only
                // way to tell a tab that is genuinely cut off from one that
                // simply ends near the edge. macOS 14 has no
                // onScrollGeometryChange, so this reads the offset off the
                // content's own frame in the viewport's coordinate space.
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .named(Self.scrollSpace))
                } action: { contentBounds = $0 }
            }
            // .never, not .hidden: .hidden still lets the system show the
            // scroller, so "Show scroll bars: Always" (and the legacy
            // non-overlay scrollers that come with it) draws a bar across
            // the tab strip and steals height from the tabs.
            .scrollIndicators(.never)
            .scrollPosition(id: $tabScrollID)
            .onAppear {
                tabScrollID = appState.activeRepoID
            }
            .onChange(of: appState.activeRepoID) { _, id in
                guard draggingID == nil else { return }
                tabScrollID = id
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                viewportWidth = width
                guard draggingID == nil else { return }
                // Keeping the selected id as the semantic scroll position
                // prevents a resize from leaving half of its tab clipped.
                tabScrollID = appState.activeRepoID
            }
            .coordinateSpace(name: Self.scrollSpace)
            // A tab that runs past an edge was being sliced flat — worst on
            // the selected one, whose fill ended in a hard vertical line
            // against the neighbouring control. Fading it out instead reads
            // as "there is more strip over here" rather than as damage.
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade(scrollEdges.leading))
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fade(scrollEdges.trailing))
                }
            )
        }
        .padding(.horizontal, 10 * zoom)
        // The bar fills AppTopBar's fixed row; the row owns the height and
        // the background.
        .frame(maxHeight: .infinity)
        .onPreferenceChange(TabWidthKey.self) { widths = $0 }
    }
}

/// The + at the end of the tab strip. Its own view, not four modifiers on a
/// Button inside `TabStrip`: hover is @State, and inside TabStrip every
/// pointer crossing would invalidate the whole strip — including the tabs
/// mid-drag.
struct NewTabButton: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        Button {
            appState.openRepoPanel()
        } label: {
            Image(systemName: "plus")
                .frame(width: 28 * zoom, height: 28 * zoom)
                // The same fill the tabs light up with, at the same corner:
                // it sits in their row, so it answers the pointer the way
                // they do. Without it the + was the one thing in the strip
                // that stayed dead under the cursor.
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering ? Color.primary.opacity(0.04) : .clear)
                        .animation(.easeOut(duration: 0.12), value: hovering)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressEffect)
        .foregroundStyle(hovering ? Color.primary.opacity(0.8) : .secondary)
        // The one ⌘O in the window: this bar is on every screen, so the
        // shortcut lives here rather than in a toolbar or empty state
        // that comes and goes with the screen.
        .keyboardShortcut("o")
        .help("Open Repository (⌘O)")
        .onHover {
            hovering = $0
            AppState.pointerOverTopControl = $0
        }
    }
}

/// Puts the root view's minimum size onto the window, because SwiftUI didn't.
///
/// `.frame(minWidth:minHeight:)` on a window's root view does not reliably
/// become the NSWindow's own floor after the repository switches into
/// full-size title-bar content. The window can otherwise drag smaller while
/// the content stays laid out at its minimum, clipping both outer columns.
///
/// The frame stays: it's what keeps the content from laying itself out any
/// smaller. This is only what stops the window from disagreeing with it.
private struct WindowFloor: NSViewRepresentable {
    let size: CGSize

    /// One window, one saved frame. The name is what AppKit keys the saved
    /// frame by in the preferences, so it must never change.
    static let autosaveName = "TheGitMainWindow"

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Deferred: on the first pass the view isn't in a window yet, and
        // setting a window's size from inside a layout pass it's running is
        // how you get "Unbalanced calls to begin/end appearance transition".
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // The only place in the app that holds an NSWindow, so it is
            // also where the frame gets a name to be saved under. AppKit
            // then restores size and position itself, which macOS's implicit
            // state restoration only does when it feels like it — a window
            // dragged to a second display and sized to fill it came back
            // 1100×760 in the middle of the laptop screen often enough to
            // be worth one line.
            if window.frameAutosaveName != Self.autosaveName {
                window.setFrameAutosaveName(Self.autosaveName)
            }
            guard window.contentMinSize != size else { return }
            window.contentMinSize = size
            // A window restored from a smaller saved frame keeps that frame
            // until something nudges it — the floor only applies to future
            // drags. Nudge it, or the content it was saved too small for is
            // clipped for the rest of the session.
            let frame = window.frame
            let content = window.contentRect(forFrameRect: frame)
            guard content.width < size.width || content.height < size.height else { return }
            let grown = window.frameRect(forContentRect: CGRect(
                origin: content.origin,
                size: CGSize(
                    width: max(content.width, size.width),
                    height: max(content.height, size.height)
                )
            ))
            // Anchored at the top-left, which is where the window's title bar
            // is: growing downwards from a window near the bottom of the
            // screen would walk it off the edge.
            window.setFrame(
                CGRect(
                    x: frame.minX,
                    y: frame.maxY - grown.height,
                    width: grown.width,
                    height: grown.height
                ),
                display: true
            )
        }
    }
}

/// The window's one chrome, applied once and never handed back mid-session:
/// no title, no title-bar separator, a toolbar that stays visible. Every
/// screen shares it, so switching tabs can't change the window's outline —
/// the old per-screen pair of chromes restored each other's settings on
/// every switch, flashing the "TheGit" title and swapping corner radii.
/// SwiftUI reasserts title-bar properties when windows change key state,
/// so this follows the same key/occlusion pattern as the Settings window.
private struct MainWindowChrome: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var propertyClamps: [NSKeyValueObservation] = []

        func attach(to window: NSWindow) {
            apply(to: window)
            guard self.window !== window else { return }
            self.window = window
            // Synchronous clamps, not another deferred re-apply: SwiftUI
            // re-shows the title inside its screen-switch commit, and any
            // notification-driven fix lands a frame later — the user sees
            // "TheGit" blink in the title bar on every switch. KVO fires
            // inside the setter, so the wrong value never reaches a frame.
            // The re-set from inside the handler recurses once and stops on
            // the equality guard.
            propertyClamps = [
                window.observe(\.titleVisibility) { window, _ in
                    if window.titleVisibility != .hidden {
                        window.titleVisibility = .hidden
                    }
                },
            ]
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                // The load-bearing one: SwiftUI re-shows the title and the
                // title-bar material somewhere in its own commit after a
                // screen switch, later than any deferred re-apply from this
                // side. didUpdate fires on every window display pass, so the
                // clamp lands the same frame as whatever undid it. apply()
                // writes only on an actual difference — steady state is a
                // few property reads.
                NSWindow.didUpdateNotification,
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] note in
                    guard let window = note.object as? NSWindow else { return }
                    self?.apply(to: window)
                }
            }
        }

        private func apply(to window: NSWindow) {
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }
            // Visible, and load-bearing: the commands live in it, and on
            // macOS 26 a visible toolbar is also what decides the window's
            // larger outer corner radius. Hiding it (which is what this app
            // did while it drew its own row in the title-bar band) dropped
            // the window to the small radius and left no public way back.
            if let toolbar = window.toolbar, !toolbar.isVisible {
                toolbar.isVisible = true
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            propertyClamps.forEach { $0.invalidate() }
        }
    }
}

/// The catalog, first in the strip — the one tab that's about the repos that
/// AREN'T open. Icon only, like the folder button GitKraken pins in the same
/// spot: it's a fixed landmark rather than a destination you read, and every
/// point it doesn't take is a repo name that stays legible in a full strip.
struct RepositoriesTab: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false

    private var isActive: Bool { appState.showingRepositories }

    var body: some View {
        Button {
            appState.showRepositories()
        } label: {
            Image(systemName: "folder")
                .zoomFont(12)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 30 * zoom, height: 28 * zoom)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive
                            ? Color.primary.opacity(0.08)
                            : hovering ? Color.primary.opacity(0.04) : .clear)
                        .animation(.easeOut(duration: 0.12), value: hovering)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.rowPressEffect)
        // ⌘0 is the Dashboard; the catalog beside it takes the shifted one.
        .keyboardShortcut("0", modifiers: [.command, .shift])
        .help("Repositories — every repo on this Mac (⇧⌘0)")
        .onHover {
            hovering = $0
            AppState.pointerOverTopControl = $0
        }
    }
}

/// The home tab, pinned at the head of the strip. Same shape as a repo tab
/// so the row reads as one row of tabs — but no close button, because it's
/// the one tab that can't be closed, and a disabled × on hover would be a
/// control that exists only to say no.
struct DashboardTab: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false

    private var isActive: Bool { appState.showingDashboard }

    var body: some View {
        Button {
            appState.showDashboard()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .zoomFont(10)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                StableTabTitle("Dashboard", isActive: isActive)
            }
            .padding(.horizontal, 10)
            .frame(height: 28 * zoom)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                        ? Color.primary.opacity(0.08)
                        : hovering ? Color.primary.opacity(0.04) : .clear)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPressEffect)
        // ⌘0 alongside the ⌘1…⌘9 a tab bar implies; zero is the one that
        // isn't a repo.
        .keyboardShortcut("0", modifiers: .command)
        .help("Dashboard — every open repository (⌘0)")
        .onHover {
            hovering = $0
            AppState.pointerOverTopControl = $0
        }
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
            StableTabTitle(repo.displayName, isActive: isActive)
            Button {
                appState.closeTab(repo: repo)
            } label: {
                Image(systemName: "xmark")
                    .zoomFont(8, weight: .bold)
            }
            .buttonStyle(.pressEffect)
            .foregroundStyle(.secondary)
            // Same omission as the update banner's dismiss: an SF Symbol
            // carries no name, so this announced as a bare "button".
            .accessibilityLabel("Close \(repo.displayName)")
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
        // A tab is a folder name, and a folder name is not an identity: two
        // clones of one repository make two tabs that read the same and sit
        // on different branches. The pointer is already here — say which one
        // this is, and what it's standing on.
        .help(helpText)
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
            Button("Close Tab") { appState.closeTab(repo: repo) }
            Button("Close Other Tabs") {
                for other in appState.openRepos where other.id != repo.id {
                    appState.closeTab(repo: other)
                }
            }
            Divider()
            // Closing a tab keeps the repo on the Dashboard, so the one action
            // that actually forgets it has to be sayable from here too.
            Button("Remove from TheGit") { appState.remove(repo: repo) }
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

    /// Path first: it's the answer to "which copy is this", and the branch
    /// under it is the other half of the same question. Detached HEAD has no
    /// branch to name, so the line is simply left off rather than made up.
    private var helpText: String {
        guard let branch = repo.snapshot.currentBranch else { return repo.displayPath }
        return repo.displayPath + "\n" + branch
    }
}

/// Reserves the semibold title width even while a tab is inactive. Changing
/// font weight otherwise changes the tab's measured width by a few points,
/// shifting every tab after it whenever selection moves.
private struct StableTabTitle: View {
    let title: String
    let isActive: Bool

    init(_ title: String, isActive: Bool) {
        self.title = title
        self.isActive = isActive
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(title)
                .zoomFont(12, weight: .semibold)
                .lineLimit(1)
                .hidden()
            Text(title)
                .zoomFont(12, weight: isActive ? .semibold : .regular)
                .lineLimit(1)
        }
    }
}
