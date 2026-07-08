import SwiftUI
import AppKit

/// A top/bottom split view (like SwiftUI's VSplitView) whose divider position
/// persists across launches. SwiftUI's built-in VSplitView has no way to
/// remember where the user dragged the divider to, so this wraps a real
/// NSSplitView directly and saves/restores the top pane's fraction of height
/// under `storageKey` in UserDefaults.
struct PersistentVSplitView<Top: View, Bottom: View>: NSViewRepresentable {
    var storageKey: String
    var defaultTopFraction: CGFloat
    @ViewBuilder var top: () -> Top
    @ViewBuilder var bottom: () -> Bottom

    func makeCoordinator() -> Coordinator {
        Coordinator(storageKey: storageKey, defaultTopFraction: defaultTopFraction)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = false
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
        private var didApplyInitialPosition = false

        init(storageKey: String, defaultTopFraction: CGFloat) {
            self.storageKey = storageKey
            self.defaultTopFraction = defaultTopFraction
        }

        @MainActor
        func applyInitialPositionIfNeeded() {
            guard !didApplyInitialPosition, let splitView, splitView.bounds.height > 0 else { return }
            didApplyInitialPosition = true
            let fraction = UserDefaults.standard.object(forKey: storageKey) as? Double ?? Double(defaultTopFraction)
            let total = splitView.bounds.height - splitView.dividerThickness
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
            let total = splitView.bounds.height - splitView.dividerThickness
            guard total > 0 else { return }
            let fraction = splitView.subviews[0].frame.height / total
            UserDefaults.standard.set(Double(fraction), forKey: storageKey)
        }
    }
}
