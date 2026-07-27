import AppKit
import SwiftUI

/// SwiftUI has no right-click gesture, so an AppKit event monitor reports
/// one for a row's bounds. The event is passed on untouched — the context
/// menu still opens; we only want to know which row it belongs to.
///
/// A monitor rather than a hit-tested overlay: anything placed on top of a
/// row to catch the click would also swallow its taps and its menu.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    final class Coordinator {
        var onRightClick: (() -> Void)?
        weak var view: NSView?
        var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window
                else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                if view.bounds.contains(point) { self.onRightClick?() }
                return event // never consumed: the menu must still open
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.onRightClick = onRightClick
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onRightClick = onRightClick
        context.coordinator.install()
    }
}

/// Marks the row a context menu belongs to. Without it the menu appears
/// detached from everything — every list in the app has actions that are
/// destructive on the wrong row, and "which one did I click?" is not a
/// question a menu should leave open.
///
/// Cleared on `NSMenu.didEndTracking`, so the mark lasts exactly as long
/// as the menu and never lingers.
struct ContextMenuTarget: ViewModifier {
    let id: String
    @ObservedObject var repo: RepoState

    func body(content: Content) -> some View {
        content
            .background(RightClickCatcher { repo.contextTarget = id })
            .background(
                Rectangle()
                    .fill(Color.primary.opacity(repo.contextTarget == id ? 0.12 : 0))
            )
    }
}

extension View {
    /// Highlight this row while its context menu is open.
    func contextTarget(_ id: String, _ repo: RepoState) -> some View {
        modifier(ContextMenuTarget(id: id, repo: repo))
    }
}
