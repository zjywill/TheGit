import AppKit
import SwiftUI

/// Every repository this Mac knows about, on a screen of its own at the head
/// of the tab strip. Tabs are the two or three repos being worked in; this is
/// the forty on disk. Without it, closing a tab is the same as losing the
/// folder, and the only way back is a file picker and a memory of where the
/// thing lives.
///
/// Two structures over that list, and they answer different questions:
///
/// - **Projects** are found, not declared. Three folders with one origin are
///   one project — see `RepoCatalog` for why the key is the remote and not the
///   directory. Nobody has to maintain this; it's just true.
/// - **Sections** are declared. "work", "clients", "toys" is a judgement no
///   remote URL contains, so it's the user's to make, and the list draws no
///   section chrome at all until they make one.
struct RepositoriesView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    /// Section being renamed in place, and the text it's being renamed to.
    @State private var renaming: String?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    /// Folded-away projects and sections, by id — persisted, because a fold is
    /// a statement about how you want the list to look, not a scroll position.
    @AppStorage("TheGit.catalogCollapsed") private var collapsedRaw = ""

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: "\n").map(String.init))
    }

    private func toggle(_ id: String) {
        var next = collapsed
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            collapsedRaw = next.sorted().joined(separator: "\n")
        }
    }

    /// True while a filter is on, when a fold has to give way: a match hidden
    /// inside a collapsed row is a match the search failed to show.
    private var filtering: Bool {
        !filter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if appState.catalog.isEmpty {
                emptyCatalog
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        list
                    }
                    .padding(.horizontal, 12 * zoom)
                    .padding(.vertical, 8 * zoom)
                }
            }
        }
        // Every visit re-reads the folders: a branch checked out in another
        // window, or a folder moved in Finder, has to show up here without a
        // relaunch. Two file reads per folder — see RepoCatalog.
        .onAppear { appState.refreshCatalog() }
        // And again whenever the app comes back to the front, which is the
        // moment after every deletion, rename and checkout that happened
        // somewhere else. Deliberately not an FSEvents watcher: watching forty
        // repositories means watching their parent folders recursively, so
        // every build artifact and every file save in any of them would wake
        // this list — a stream that fires hundreds of times an hour to catch
        // an event that happens twice a month. Coming back to the window costs
        // eighty file reads on a background queue, once, at a moment the app
        // is already doing work.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            appState.refreshCatalog()
        }
        // Folders from Finder, which is the shortest path from "these are my
        // repos" to a list of them. A folder of repos scans; a repo is added.
        .dropDestination(for: URL.self) { urls, _ in
            appState.scan(roots: urls.filter(\.hasDirectoryPath).map(\.path))
            return true
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6 * zoom) {
            HStack(spacing: 10 * zoom) {
                VStack(alignment: .leading, spacing: 1 * zoom) {
                    Text("Repositories")
                        .zoomFont(15, weight: .semibold)
                    Text(summary)
                        .zoomFont(11)
                        .foregroundStyle(.secondary)
                        // The count changes as a scan lands; a number that
                        // slides sideways while it does reads as noise.
                        .monospacedDigit()
                        // And the digits roll rather than cut, which is what
                        // a refresh that actually found something looks like.
                        // Same treatment as the graph's change count and the
                        // commit panel's staged count.
                        .contentTransition(.numericText())
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.2),
                            value: summary
                        )
                }
                Spacer(minLength: 12 * zoom)
                filterField.frame(maxWidth: 260 * zoom)
            }
            HStack(spacing: 8 * zoom) {
                if let notice = appState.scanResult {
                    scanNotice(notice)
                }
                missingNotice
            }
        }
        .padding(.horizontal, 16 * zoom)
        .padding(.vertical, 10 * zoom)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: appState.scanResult)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: appState.missingClones.count)
    }

    /// Folders that aren't there any more, said once at the top rather than
    /// only as a mark on each row: a repo deleted in Finder is the kind of
    /// thing you find out about by scrolling past it, and the rows for six of
    /// them can be six screens apart.
    ///
    /// Orange, which is this app's "needs attention" — and it offers the
    /// cleanup rather than performing it, because the row still holds the one
    /// record of where the thing used to be.
    @ViewBuilder
    private var missingNotice: some View {
        let gone = appState.missingClones
        if !gone.isEmpty {
            HStack(spacing: 6 * zoom) {
                Image(systemName: "exclamationmark.triangle.fill").zoomFont(10)
                Text(gone.count == 1
                    ? "1 folder is no longer on disk"
                    : "\(gone.count) folders are no longer on disk")
                    .zoomFont(11)
                Button("Remove Them") { appState.removeMissingFromCatalog() }
                    .buttonStyle(.link)
                    .zoomFont(11, weight: .medium)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8 * zoom)
            .padding(.vertical, 3 * zoom)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
            .help(gone.map(\.displayPath).joined(separator: "\n"))
            .transition(.opacity)
        }
    }

    /// What a scan did, in one line, dismissed by clicking it. Not an alert:
    /// the outcome of a button the user just pressed doesn't need a modal to
    /// interrupt the list it just changed.
    private func scanNotice(_ text: String) -> some View {
        HStack(spacing: 6 * zoom) {
            Image(systemName: "checkmark.circle").zoomFont(10)
            Text(text).zoomFont(11)
            Image(systemName: "xmark").zoomFont(8).foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8 * zoom)
        .padding(.vertical, 3 * zoom)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .contentShape(Capsule())
        .onTapGesture { appState.scanResult = nil }
        .help("Dismiss")
        .transition(.opacity)
    }

    /// Projects and folders are different counts, and that difference is the
    /// whole subject of this screen — so it says both, but only once they
    /// actually differ, since "7 projects · 7 folders" is one fact twice.
    private var summary: String {
        if appState.scanning { return "Scanning…" }
        let projects = appState.catalog.count
        let folders = appState.catalog.reduce(0) { $0 + $1.clones.count }
        guard projects > 0 else { return "Nothing here yet" }
        let head = "\(projects) project\(projects == 1 ? "" : "s")"
        // Tabs, not the Dashboard's wall: the dots down the left of this list
        // mean "has a tab", and the count beside them has to mean the same.
        let open = appState.openTabIDs.count
        let tail = open > 0 ? " · \(open) open" : ""
        guard folders != projects else { return head + tail }
        return head + " · \(folders) folders" + tail
    }

    private var filterField: some View {
        HStack(spacing: 6 * zoom) {
            Image(systemName: "magnifyingglass")
                .zoomFont(11)
                .foregroundStyle(filterFocused ? Color.accentColor : .secondary)
            TextField("Search repositories", text: $filter)
                .textFieldStyle(.plain)
                .zoomFont(12)
                .focused($filterFocused)
                // Esc clears first and only gives up focus once it's empty,
                // so one key both undoes the search and leaves the field.
                .onExitCommand {
                    if filter.isEmpty { filterFocused = false } else { filter = "" }
                }
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").zoomFont(11)
                }
                .buttonStyle(.pressEffect)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8 * zoom)
        .frame(height: 24 * zoom)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(
                filterFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1),
                lineWidth: 1
            )
        )
        .animation(.easeOut(duration: 0.12), value: filterFocused)
    }

    // MARK: - List

    /// What the list is showing, after the filter. Matched against every field
    /// on screen — project, owner, host, folder, branch, path — because any of
    /// them is a plausible thing to half-remember about a repo.
    private func matches(_ project: RepoCatalog.Project) -> RepoCatalog.Project? {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return project }
        let heading = [project.name, project.owner, project.host]
            .compactMap { $0?.lowercased() }
        if heading.contains(where: { $0.contains(query) }) { return project }
        // A project whose own name misses can still be reached by one of its
        // folders, and then only that folder is worth showing.
        let clones = project.clones.filter { clone in
            clone.name.lowercased().contains(query)
                || clone.path.lowercased().contains(query)
                || (clone.branch?.lowercased().contains(query) ?? false)
        }
        guard !clones.isEmpty else { return nil }
        var narrowed = project
        narrowed.clones = clones
        return narrowed
    }

    private var shelves: [RepoCatalog.Shelf] {
        appState.catalogShelves.compactMap { shelf in
            let projects = shelf.projects.compactMap(matches)
            // An empty section still draws while nothing is being searched —
            // it's the band you just made and are about to drag repos into.
            // Under a filter it's noise: it matched nothing.
            guard !projects.isEmpty || (!filtering && shelf.isSection) else { return nil }
            var narrowed = shelf
            narrowed.projects = projects
            return narrowed
        }
    }

    @ViewBuilder
    private var list: some View {
        let shown = shelves
        if shown.isEmpty {
            Text("No repositories match “\(filter)”")
                .zoomFont(12)
                .foregroundStyle(.tertiary)
                .padding(.leading, 10 * zoom)
                .padding(.top, 8 * zoom)
        } else {
            ForEach(shown) { shelf in
                shelfView(shelf)
            }
        }
    }

    @ViewBuilder
    private func shelfView(_ shelf: RepoCatalog.Shelf) -> some View {
        let banded = !appState.catalogSections.isEmpty
        let isCollapsed = !filtering && collapsed.contains(shelf.id)
        VStack(alignment: .leading, spacing: 0) {
            if banded {
                SectionHeaderRow(
                    shelf: shelf,
                    isCollapsed: isCollapsed,
                    renaming: renaming == shelf.id,
                    draftName: $draftName,
                    renameFocus: $renameFocused,
                    toggle: { toggle(shelf.id) },
                    beginRename: {
                        draftName = shelf.name ?? ""
                        renaming = shelf.id
                        renameFocused = true
                    },
                    commitRename: {
                        appState.renameCatalogSection(id: shelf.id, to: draftName)
                        renaming = nil
                    },
                    cancelRename: { renaming = nil }
                )
            }
            if !isCollapsed {
                ForEach(shelf.projects) { project in
                    ProjectBlock(
                        project: project,
                        isCollapsed: !filtering && collapsed.contains(project.id),
                        toggle: { toggle(project.id) }
                    )
                }
                if shelf.projects.isEmpty && banded {
                    Text("Drag repositories here")
                        .zoomFont(11)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CatalogMetrics.gutter * zoom + 10 * zoom)
                        .frame(height: CatalogMetrics.row * zoom)
                }
            }
        }
        // The whole band takes the drop, not just its header: aiming at a 26pt
        // strip is a different task from dropping a repo "in with those ones".
        .dropDestination(for: DraggedProject.self) { items, _ in
            for item in items {
                appState.assignProject(item.id, toSection: shelf.isSection ? shelf.id : nil)
            }
            return !items.isEmpty
        } isTargeted: { targeted in
            dropTarget = targeted ? shelf.id : (dropTarget == shelf.id ? nil : dropTarget)
        }
        .background(
            RoundedRectangle(cornerRadius: CatalogMetrics.card * zoom, style: .continuous)
                .fill(Color.accentColor.opacity(dropTarget == shelf.id ? 0.10 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: CatalogMetrics.card * zoom, style: .continuous)
                        .strokeBorder(
                            Color.accentColor.opacity(dropTarget == shelf.id ? 0.5 : 0),
                            lineWidth: 1
                        )
                )
        )
        // Arriving is the answer to the pointer and has to be immediate;
        // leaving can fade. Same asymmetry as every row in the app.
        .animation(
            dropTarget == shelf.id ? nil : .easeOut(duration: 0.12),
            value: dropTarget
        )
        .padding(.bottom, banded ? 6 * zoom : 0)
    }

    @State private var dropTarget: String?

    /// First launch, or a list someone emptied: the one thing worth offering
    /// is the thing that fills it.
    private var emptyCatalog: some View {
        VStack(spacing: 10 * zoom) {
            Image(systemName: "folder")
                .zoomFont(28, weight: .light)
                .foregroundStyle(.tertiary)
            Text("No repositories yet")
                .zoomFont(13, weight: .medium)
            Text("Point this at the folder your repositories live in — every "
                + "Git repository inside it is added, grouped by project, "
                + "without opening any of them.")
                .zoomFont(11)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380 * zoom)
            HStack(spacing: 8 * zoom) {
                Button("Scan a Folder…") { appState.scanFolderPanel() }
                    .disabled(appState.scanning)
                Button("Open Repository…") { appState.openRepoPanel() }
            }
            .padding(.top, 2 * zoom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Column widths and row metrics for the repository list. Split out because
/// the list only reads as a table if every row agrees on them — and because
/// each one is a judgement about how much of a name, an owner or a branch is
/// worth showing before the next column starts.
enum CatalogMetrics {
    /// One row. The macOS list row, which is what every other list in this app
    /// uses — see SidebarMetrics.
    static let row: CGFloat = 26
    /// The leading column: a disclosure chevron or an open/closed dot.
    static let gutter: CGFloat = 16
    /// Indent for a folder under its project.
    static let indent: CGFloat = 18
    /// The owner column. Enough for a GitHub org, truncating past that.
    static let owner: CGFloat = 110
    /// The branch column. Long branch names are the norm on the repos this was
    /// built against ("feature/web-translate-doc-panel-popover-fix"), so this
    /// is generous — but bounded, or one repo's branch pushes every path on
    /// the screen out of alignment.
    static let branch: CGFloat = 190
    /// Row highlight corner, and the card corner around a section band. 6 is
    /// the app's row radius everywhere else.
    static let corner: CGFloat = 6
    static let card: CGFloat = 8
}

// MARK: - Rows

/// A user section's heading: fold, name, count, and the menu that renames or
/// removes it. Renaming happens in place rather than in a dialog — the name is
/// two words and it's already on screen, so a modal to change it would be the
/// longer way round.
private struct SectionHeaderRow: View {
    let shelf: RepoCatalog.Shelf
    let isCollapsed: Bool
    let renaming: Bool
    @Binding var draftName: String
    var renameFocus: FocusState<Bool>.Binding
    let toggle: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    let cancelRename: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6 * zoom) {
            Image(systemName: "chevron.right")
                .zoomFont(9, weight: .semibold)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: CatalogMetrics.gutter * zoom)
            if renaming, shelf.isSection {
                TextField("Section name", text: $draftName)
                    .textFieldStyle(.plain)
                    .zoomFont(11, weight: .semibold)
                    .focused(renameFocus)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .frame(maxWidth: 220 * zoom)
            } else {
                Text((shelf.name ?? "Ungrouped").uppercased())
                    .zoomFont(10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    // Small caps read as a label rather than as a name; the
                    // tracking is what keeps them from reading as one word.
                    .kerning(0.4 * zoom)
                    .lineLimit(1)
            }
            Text("\(shelf.projects.count)")
                .zoomFont(10)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8 * zoom)
            if shelf.isSection, hovering, !renaming {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis").zoomFont(11)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18 * zoom)
                .foregroundStyle(.secondary)
                .help("Section actions")
            }
        }
        .padding(.horizontal, 6 * zoom)
        .frame(height: CatalogMetrics.row * zoom)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .contextMenu { if shelf.isSection { menuItems } }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Rename", action: beginRename)
        Button("Move Up") { appState.moveCatalogSection(id: shelf.id, by: -1) }
        Button("Move Down") { appState.moveCatalogSection(id: shelf.id, by: 1) }
        Divider()
        // No confirmation: the repositories fall back into Ungrouped and
        // nothing on disk is touched, so there is nothing to be sorry about.
        Button("Delete Section") { appState.deleteCatalogSection(id: shelf.id) }
    }
}

/// A project and, when it has more than one folder on this disk, those
/// folders under it.
private struct ProjectBlock: View {
    let project: RepoCatalog.Project
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        if project.clones.count == 1, let clone = project.clones.first {
            // No header over a single child: a disclosure triangle that hides
            // exactly one row is chrome standing in for structure that isn't
            // there. The project's name and owner move onto the row itself.
            CatalogRow(project: project, clone: clone, depth: 0, isCollapsed: false, toggle: nil)
        } else {
            CatalogRow(
                project: project,
                clone: nil,
                depth: 0,
                isCollapsed: isCollapsed,
                toggle: toggle
            )
            if !isCollapsed {
                ForEach(project.clones) { clone in
                    CatalogRow(
                        project: project,
                        clone: clone,
                        depth: 1,
                        isCollapsed: false,
                        toggle: nil
                    )
                }
            }
        }
    }
}

/// One line of the list: a project, a folder of one, or a project that is
/// exactly one folder and so is both at once.
///
/// Colour-only feedback, arriving instantly and leaving on a fade — the same
/// idiom as every other list in this app (see `SidebarRow`). A full-width row
/// that scales under the pointer moves its own text out from under the cursor;
/// a row that darkens does not.
private struct CatalogRow: View {
    let project: RepoCatalog.Project
    /// Nil on the header row of a multi-folder project — which has a branch
    /// per folder and so shows none of them.
    let clone: RepoCatalog.Clone?
    let depth: Int
    let isCollapsed: Bool
    /// Set on rows that fold instead of opening.
    let toggle: (() -> Void)?

    @EnvironmentObject var appState: AppState
    @Environment(\.uiZoom) private var zoom
    @State private var hovering = false
    @State private var pressed = false

    private var isOpen: Bool { clone.map { appState.isOpen(path: $0.path) } ?? false }
    private var exists: Bool { clone?.exists ?? true }
    /// The name this row is about: the folder's when it's one of several, the
    /// project's otherwise.
    private var title: String { depth > 0 ? (clone?.name ?? project.name) : project.name }

    var body: some View {
        HStack(spacing: 8 * zoom) {
            gutter
            Text(title)
                .zoomFont(12, weight: isOpen ? .semibold : .regular)
                .foregroundStyle(exists ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            owner
            branch
            trailing
        }
        .padding(.leading, (6 + CGFloat(depth) * CatalogMetrics.indent) * zoom)
        .padding(.trailing, 8 * zoom)
        .frame(height: CatalogMetrics.row * zoom)
        .background(
            RoundedRectangle(cornerRadius: CatalogMetrics.corner * zoom, style: .continuous)
                .fill(fill)
        )
        .background { PressCatcher { pressed = $0 } }
        .contentShape(Rectangle())
        .onHover {
            hovering = $0
            // The mouse-up that clears a press can land in another window.
            if !$0 { pressed = false }
        }
        // Arriving is the answer to the pointer and has to be immediate — a
        // fade there is latency you can see. Leaving is the app talking to
        // itself, so it fades: sweeping down forty rows is otherwise forty
        // hard flashes.
        .animation(hovering ? nil : .easeOut(duration: 0.12), value: hovering)
        .animation(pressed ? nil : .easeOut(duration: 0.12), value: pressed)
        .onTapGesture(perform: activate)
        // Dragging a row moves the PROJECT, header or folder alike: a section
        // holds projects, and pulling one clone out of a group of three would
        // split a project that the remote says is one thing.
        .draggable(DraggedProject(id: project.id, name: project.name))
        .help(helpText)
        .contextMenu { menu }
    }

    private func activate() {
        if let toggle {
            toggle()
        } else if let clone {
            // A row for a folder that isn't there can't open it, and doing
            // nothing at all is the worst answer a click can give. Offer the
            // one action that might still be true: it was moved, not deleted.
            if clone.exists {
                appState.open(path: clone.path)
            } else {
                appState.relocatePanel(for: clone.path)
            }
        }
    }

    /// A chevron for a row that folds, a dot for one that opens. Both live in
    /// the same column so every name in the list starts on one edge.
    @ViewBuilder
    private var gutter: some View {
        Group {
            if toggle != nil {
                Image(systemName: "chevron.right")
                    .zoomFont(9, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            } else if !exists {
                // Orange, this app's colour for "this needs you". A grey
                // question mark reads as "unknown", and a folder that isn't
                // there is not unknown.
                Image(systemName: "exclamationmark.triangle.fill")
                    .zoomFont(9)
                    .foregroundStyle(.orange)
            } else if isOpen {
                Circle().fill(Color.accentColor)
                    .frame(width: 6 * zoom, height: 6 * zoom)
            } else {
                Circle().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
                    .frame(width: 6 * zoom, height: 6 * zoom)
            }
        }
        .frame(width: CatalogMetrics.gutter * zoom)
    }

    /// Only on the row that speaks for the project: repeating "nextim" down
    /// three indented folders says nothing the header didn't.
    @ViewBuilder
    private var owner: some View {
        Text(depth > 0 ? "" : (project.owner ?? (project.host == nil ? "local" : "")))
            .zoomFont(11)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: CatalogMetrics.owner * zoom, alignment: .leading)
            .help(project.host ?? "")
    }

    /// The branch column. The `Spacer` is load-bearing: a project header has
    /// no branch to show, and a `.frame(width:)` on an empty ViewBuilder is
    /// ignored — EmptyView takes part in no layout at all. Without something
    /// in the stack, that row silently lost its branch column and every column
    /// after it slid 190pt left of where the same column sits on every other
    /// row.
    @ViewBuilder
    private var branch: some View {
        HStack(spacing: 0) {
            if let clone, !clone.exists {
                Text("Folder missing")
                    .zoomFont(10, weight: .medium)
                    .foregroundStyle(.orange)
            } else if let name = clone?.branch {
                HStack(spacing: 3 * zoom) {
                    Image(systemName: "arrow.triangle.branch").zoomFont(8)
                    Text(clone?.detached == true ? "detached · " + name : name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .zoomFont(10, weight: .medium)
                .foregroundStyle(clone?.detached == true ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 5 * zoom)
                .padding(.vertical, 1 * zoom)
                .background(Capsule().fill(
                    (clone?.detached == true ? Color.primary : Color.accentColor).opacity(0.12)
                ))
            }
            Spacer(minLength: 0)
        }
        .frame(width: CatalogMetrics.branch * zoom, alignment: .leading)
    }

    /// The path, or — on a project header — how many folders are folded under
    /// it. One column, because both answer "what else is there to know about
    /// this row" and a list can only align so many things.
    @ViewBuilder
    private var trailing: some View {
        if let clone {
            Text(clone.displayPath)
                .zoomFont(10)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Text("\(project.clones.count) folders")
                .zoomFont(10)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Three states on one channel, deepest first — see `SidebarRow.fill`.
    private var fill: Color {
        if pressed { return Color.primary.opacity(0.12) }
        return hovering ? Color.primary.opacity(0.06) : .clear
    }

    private var helpText: String {
        if let clone {
            guard clone.exists else { return "\(clone.path) is no longer a repository" }
            return (isOpen ? "Switch to " : "Open ") + clone.path
        }
        return "\(project.clones.count) copies of \(project.name) on this Mac"
    }

    @ViewBuilder
    private var menu: some View {
        if let clone, clone.exists {
            Button(isOpen ? "Switch to Tab" : "Open") { appState.open(path: clone.path) }
            Divider()
            Button("Copy Repository Path") { RepoState.copyToPasteboard(clone.path) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: clone.path),
                ])
            }
            Divider()
        } else if let clone {
            Button("Locate…") { appState.relocatePanel(for: clone.path) }
            Button("Copy Old Path") { RepoState.copyToPasteboard(clone.path) }
            Divider()
        }
        // The menu path to what dragging does, because a drag is not
        // discoverable and not everyone can make one.
        Menu("Move to Section") {
            ForEach(appState.catalogSections) { section in
                Button(section.name) {
                    appState.assignProject(project.id, toSection: section.id)
                }
            }
            if !appState.catalogSections.isEmpty {
                Divider()
                Button("Ungrouped") { appState.assignProject(project.id, toSection: nil) }
                Divider()
            }
            Button("New Section…") {
                let id = appState.addCatalogSection(name: project.name)
                appState.assignProject(project.id, toSection: id)
            }
        }
        if let clone {
            Divider()
            Button("Remove from List") { appState.removeFromCatalog(path: clone.path) }
        } else {
            Divider()
            Button("Remove All \(project.clones.count) from List") {
                for clone in project.clones { appState.removeFromCatalog(path: clone.path) }
            }
        }
    }
}
