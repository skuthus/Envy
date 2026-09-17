import SwiftUI
import AppKit

/// A two-pane split view whose divider position persists across launches.
/// SwiftUI's built-in split views have no way to remember where the user
/// dragged the divider to, so this wraps a real NSSplitView directly and
/// saves/restores the first pane's fraction under `storageKey` in UserDefaults.
///
/// `isVertical` picks the axis: false (the default, and the list/editor split's
/// use) is a horizontal divider with the panes stacked top/bottom; true is a
/// vertical divider with the panes side by side. To flip a live instance
/// between the two, give it `.id(isVertical)` at the call site so it recreates
/// on the new axis rather than reconfiguring in place.
struct PersistentVSplitView<Top: View, Bottom: View>: NSViewRepresentable {
    var storageKey: String
    var defaultTopFraction: CGFloat
    var isVertical: Bool = false
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    func makeCoordinator() -> Coordinator {
        Coordinator(storageKey: storageKey, defaultTopFraction: defaultTopFraction, isVertical: isVertical)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = OpaqueDividerSplitView()
        splitView.isVertical = isVertical
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator

        let topHost = NSHostingView(rootView: top())
        let bottomHost = NSHostingView(rootView: bottom())
        splitView.addArrangedSubview(topHost)
        splitView.addArrangedSubview(bottomHost)

        context.coordinator.splitView = splitView
        context.coordinator.topHost = topHost
        context.coordinator.bottomHost = bottomHost
        // The view's bounds are still zero synchronously here, right after
        // creation, so applyInitialPositionIfNeeded() can't size the divider
        // yet — try again once this run loop tick's layout has actually
        // happened, rather than only relying on updateNSView to eventually
        // get called again (it doesn't, if nothing else changes afterward).
        DispatchQueue.main.async {
            context.coordinator.applyInitialPositionIfNeeded()
        }
        return splitView
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
        context.coordinator.topHost?.rootView = top()
        context.coordinator.bottomHost?.rootView = bottom()
        context.coordinator.applyInitialPositionIfNeeded()
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        weak var splitView: NSSplitView?
        var topHost: NSHostingView<Top>?
        var bottomHost: NSHostingView<Bottom>?

        private let storageKey: String
        private let defaultTopFraction: CGFloat
        private let isVertical: Bool
        private var didApplyInitialPosition = false

        init(storageKey: String, defaultTopFraction: CGFloat, isVertical: Bool) {
            self.storageKey = storageKey
            self.defaultTopFraction = defaultTopFraction
            self.isVertical = isVertical
        }

        /// The split's extent along its divider axis — width side by side,
        /// height stacked.
        private func extent(of view: NSView) -> CGFloat {
            isVertical ? view.bounds.width : view.bounds.height
        }

        private func firstPaneExtent(_ view: NSView) -> CGFloat {
            isVertical ? view.frame.width : view.frame.height
        }

        @MainActor
        func applyInitialPositionIfNeeded() {
            guard !didApplyInitialPosition, let splitView, extent(of: splitView) > 0 else { return }
            didApplyInitialPosition = true
            let fraction = UserDefaults.standard.object(forKey: storageKey) as? Double ?? Double(defaultTopFraction)
            let total = extent(of: splitView) - splitView.dividerThickness
            guard total > 0 else { return }
            splitView.setPosition(total * CGFloat(fraction), ofDividerAt: 0)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            // AppKit fires this once on its own during the initial layout
            // pass, before applyInitialPositionIfNeeded() has had a chance to
            // restore the saved fraction — saving unconditionally meant that
            // spurious first call overwrote a real saved position with
            // whatever arbitrary split AppKit's own initial layout produced,
            // which is why the divider never actually stuck across launches.
            guard didApplyInitialPosition, let splitView, splitView.subviews.count == 2 else { return }
            let total = extent(of: splitView) - splitView.dividerThickness
            guard total > 0 else { return }
            let fraction = firstPaneExtent(splitView.subviews[0]) / total
            UserDefaults.standard.set(Double(fraction), forKey: storageKey)
        }
    }
}

/// An NSSplitView whose divider is drawn opaque, so the 1px divider line never
/// shows the window's translucent backdrop through as a faint transparent seam
/// between an opaque editor pane and the pane beside it.
private final class OpaqueDividerSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
    }
}
