import AppKit

/// A plain NSScrollView, except it doesn't start claiming scroll-wheel
/// events the instant the mouse crosses into its bounds — only once the
/// mouse has rested there for dwellThreshold. Before that, scroll events
/// are handed to the nearest enclosing NSScrollView instead. Without this,
/// scrolling through the host note past an embedded note's own box hijacks
/// the scroll the moment the cursor merely passes over it, even though the
/// user's clearly still scrolling the *host* document, not that specific
/// embed. Only used where MarkdownTextView is itself nested inside another
/// scrollable region (see allowsScrollPassthrough) — every other caller
/// (the main editor, the pinned popup, preview popovers) is its own
/// top-level scrollable surface with nothing above it to hand off to.
///
/// Walking `superview` (not the responder chain via `nextResponder`) to
/// find that enclosing scroll view — `superview` is unambiguous even
/// across the SwiftUI hosting bridge in between (an NSHostingView's own
/// content still has to sit somewhere in the real AppKit view hierarchy to
/// render or receive events at all), which the responder chain crossing
/// that same bridge turned out not to be reliably.
final class NestedAwareScrollView: NSScrollView {
    private var mouseEnteredAt: Date?
    private var hoverTrackingArea: NSTrackingArea?
    /// Short enough that deliberately scrolling through an embed still
    /// feels immediate once you've paused on it; long enough that a scroll
    /// gesture already in progress on the host note, whose cursor merely
    /// passes over an embed along the way, doesn't get momentarily
    /// hijacked the instant it crosses the embed's bounds.
    private static let dwellThreshold: TimeInterval = 0.6

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if mouseEnteredAt == nil { mouseEnteredAt = Date() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouseEnteredAt = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let dwelled = mouseEnteredAt.map { Date().timeIntervalSince($0) >= Self.dwellThreshold } ?? false
        guard dwelled else {
            forwardToEnclosingScrollView(event)
            return
        }
        super.scrollWheel(with: event)
    }

    private func forwardToEnclosingScrollView(_ event: NSEvent) {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? NSScrollView, scrollView !== self {
                scrollView.scrollWheel(with: event)
                return
            }
            candidate = view.superview
        }
    }
}
