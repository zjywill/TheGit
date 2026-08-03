import SwiftUI

/// The Settings window's shell: a sidebar on the left, one pane on the
/// right.
///
/// The sidebar is a system `List(selection:)`, which is a deliberate
/// exception to the app-wide ban on table-backed views (macOS 26
/// reentrant-layout crash — see the zoom notes in TheGitApp). The ban still
/// holds everywhere it was written for: the repo sidebar and the graph put
/// thousands of rows through a zoom change. This list is four static rows,
/// and it was re-verified on macOS 26.5 — 1,500 zoom flips with selection
/// and window-resize churn on top, driven inline rather than deferred, with
/// no assert. What the system list buys back is exactly what this window
/// kept getting wrong by hand: the macOS 26 selection material (which
/// blends with the glass capsule instead of painting over it), arrow-key
/// navigation, a focus ring, and real list semantics for VoiceOver.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance
    case ai
    case handoff
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .ai: return "AI"
        case .handoff: return "Hand Off"
        case .tools: return "Tools"
        }
    }

    var icon: String {
        switch self {
        case .appearance: return "paintbrush"
        case .ai: return "sparkles"
        case .handoff: return "arrowshape.turn.up.right"
        case .tools: return "wrench.and.screwdriver"
        }
    }

    /// Sidebar group the pane sits under. Two groups for three items is
    /// deliberately a little roomy — it's the slot structure new panes
    /// (Git behavior, integrations, updates) drop into.
    var group: String {
        self == .appearance ? "General" : "Features"
    }
}

struct SettingsRootView: View {
    @Environment(\.uiZoom) private var zoom
    @State private var pane: SettingsPane = .appearance

    private var groups: [(name: String, panes: [SettingsPane])] {
        var seen: [String: [SettingsPane]] = [:]
        var order: [String] = []
        for pane in SettingsPane.allCases {
            if seen[pane.group] == nil { order.append(pane.group) }
            seen[pane.group, default: []].append(pane)
        }
        return order.map { ($0, seen[$0] ?? []) }
    }

    /// Height of the (unified-toolbar) title bar the window now draws its
    /// content under. Fixed, not zoomed: the traffic lights are AppKit's and
    /// stay the same size at every zoom level, so the room made for them has
    /// to as well.
    private static let titleBarHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        // The macOS 27 shape, matching the repository window: the sidebar
        // is one flat surface flush with the window's leading, top, and
        // bottom edges, with the traffic lights in its top band. The window
        // drops its title bar (SettingsWindowChrome) and the content stops
        // reserving the safe area that title bar used to occupy.
        .ignoresSafeArea(.container, edges: .top)
        .background(SettingsWindowChrome())
    }

    /// Never nil, though the list's binding is: clicking the empty space
    /// under the rows asks for "nothing selected", and a Settings window with
    /// no pane showing is a blank right half. Refusing the deselect keeps a
    /// pane on screen without giving up the system list.
    private var selection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { if let new = $0 { pane = new } })
    }

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(groups, id: \.name) { group in
                Section {
                    ForEach(group.panes) { item in
                        PaneRow(pane: item)
                            .tag(item)
                    }
                } header: {
                    Text(group.name)
                        .zoomFont(10, weight: .semibold)
                        .tracking(0.5)
                }
            }
        }
        .listStyle(.sidebar)
        // The capsule's glass is behind the list; the list's own backdrop
        // would sit between the two and flatten it.
        .scrollContentBackground(.hidden)
        // Room for the traffic lights, which sit in the sidebar's top band.
        // An inset rather than padding, so rows scroll under it.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: Self.titleBarHeight)
        }
        .frame(width: 168 * zoom)
        // The same glass recipe as the repository sidebar (Xcode-matched
        // 247 in light mode), flush to the window's edges — no capsule, no
        // clip, no border.
        .background(SidebarGlass())
    }

    private var detail: some View {
        VStack(spacing: 0) {
            // The pane's name, where the window title used to be — the title
            // bar is gone, and System Settings likewise titles the right half
            // rather than the window. Its baseline sits level with the
            // traffic lights on the capsule beside it.
            HStack {
                Text(pane.title)
                    .zoomFont(15, weight: .semibold)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20 * zoom)
            .frame(height: Self.titleBarHeight, alignment: .bottom)
            .padding(.bottom, 6 * zoom)
            Group {
                switch pane {
                case .appearance: AppearanceSettingsView()
                case .ai: AISettingsView()
                case .handoff: HandoffSettingsView()
                case .tools: ToolsSettingsView()
                }
            }
            // A floor, not a fixed size: the pane still asks for the same
            // room whichever one is showing — so switching panes doesn't move
            // the window — but it now stretches to whatever the window
            // actually is, instead of leaving a band of bare window under it.
            // The floor is only what the widest row (Appearance's zoom
            // picker) needs to not clip — every pane scrolls vertically, so
            // height can go well under content height.
            .frame(minWidth: 500 * zoom, minHeight: 400 * zoom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Drops the Settings window's title bar so the sidebar can own the top-left
/// corner: transparent bar, no title, content drawn full height under it.
/// The bar itself stays in the style mask — it's still what you drag the
/// window by, and what the traffic lights hang off.
///
/// Applied on every key/main transition, not once: the SwiftUI `Settings`
/// scene reasserts window properties when the app is deactivated and
/// reactivated, which quietly undid all of this on the first ⌘-tab away.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Deferred: on the first pass the view has no window yet, and
        // restyling a window mid-layout is the reentrancy that macOS 26
        // punishes.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func attach(to window: NSWindow) {
            apply(to: window)
            guard self.window !== window else { return }
            self.window = window
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            // Key and occlusion cover every way the scene gets a chance to
            // reassert: app switch, window reorder, space change.
            observers = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ].map { name in
                center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] note in
                    guard let window = note.object as? NSWindow else { return }
                    self?.apply(to: window)
                }
            }
        }

        /// Idempotent, so re-running it on every notification is free when
        /// nothing was undone.
        private func apply(to window: NSWindow) {
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            // The Settings scene builds its window without .resizable — a
            // holdover from preference panels being fixed-size. The panes
            // here are min-sized and stretch, so let the window follow.
            if !window.styleMask.contains(.resizable) {
                window.styleMask.insert(.resizable)
            }
            // An empty unified toolbar, for its geometry alone: it's what
            // moves the traffic lights down and in from the corner so they
            // sit on the sidebar capsule the way System Settings' do —
            // without it they hug the window's top-left at bare-titlebar
            // spacing.
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "SettingsChromeToolbar")
                toolbar.showsBaselineSeparator = false
                window.toolbar = toolbar
            }
            if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// One sidebar row: icon and title, and nothing else. No background, no
/// selected/hovered colouring, no weight change — every one of those is the
/// system's to draw on a sidebar list, and drawing them here is what used to
/// paint an opaque slab over the glass capsule and force white text onto a
/// pale accent colour.
private struct PaneRow: View {
    @Environment(\.uiZoom) private var zoom
    let pane: SettingsPane

    var body: some View {
        HStack(spacing: 7 * zoom) {
            Image(systemName: pane.icon)
                .zoomFont(12)
                .frame(width: 18 * zoom)
            Text(pane.title)
                .zoomFont(13)
            Spacer(minLength: 0)
        }
        // The one row metric that has to be asked for. A sidebar row has a
        // ~32pt floor the system won't go under (and shouldn't — that's the
        // standard row), but it won't grow with zoom on its own either, so
        // above 100% the text swells inside a selection block that doesn't.
        // 24 because the system pads a row by ~8pt on top of this: 24 + 8
        // lands on the stock 32 at 100%, so the row is the standard one up
        // to there and follows the text above it.
        .frame(height: 24 * zoom)
        .contentShape(Rectangle())
    }
}

// MARK: - Appearance

/// Zoom and avatars, which used to live only in the View menu — a menu is
/// a fine shortcut but a poor home: nothing there explains what the
/// setting does or costs.
struct AppearanceSettingsView: View {
    @Environment(\.uiZoom) private var zoom
    @AppStorage("uiZoomLevel") private var zoomLevel = UIZoom.defaultLevel
    @ObservedObject private var avatars = AvatarStore.shared

    /// Writes land on the next runloop turn, same as the ⌘=/⌘− commands:
    /// a zoom change relays out every window, and doing that inside the
    /// picker's update transaction is the reentrant-layout pattern that
    /// crashes macOS 26.
    private var deferredZoomLevel: Binding<Int> {
        Binding(
            get: { zoomLevel },
            set: { new in DispatchQueue.main.async { zoomLevel = new } }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * zoom) {
                SettingsSection(
                    title: "Interface",
                    footer: "Scales all text and layout in every window. ⌘= and ⌘− do the same from the keyboard."
                ) {
                    SettingsRow(title: "UI zoom") {
                        Picker("UI zoom", selection: deferredZoomLevel) {
                            ForEach(0..<UIZoom.levels.count, id: \.self) { level in
                                Text("\(Int(UIZoom.levels[level] * 100))%").tag(level)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        // Its own width, not a stated one. A segmented control
                        // overflows a frame narrower than its segments instead
                        // of squeezing them, and it overflows symmetrically —
                        // so a stated 280 that five labels don't fit into (any
                        // zoom under 100%) spilled out past the row's trailing
                        // padding and sat flush against the card's edge.
                        .fixedSize()
                    }
                }
                SettingsSection(
                    title: "Commit Graph",
                    footer: "On a GitLab remote, avatars come from that instance — including a self-hosted one — by matching the commit author against its user list through `glab`, so uploaded faces work with no token to paste here. Everyone else falls back to Gravatar and GitHub. This is the one feature that talks to a server you didn't configure, which is why it's off until you turn it on."
                ) {
                    SettingsRow(title: "Author avatars") {
                        Toggle("Author avatars", isOn: $avatars.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            }
            .padding(20 * zoom)
        }
    }
}
