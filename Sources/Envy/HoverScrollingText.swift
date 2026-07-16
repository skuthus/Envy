import SwiftUI

/// A single-line label that scrolls its full text into view on hover when
/// it doesn't fit the width SwiftUI's layout actually gave it, instead of
/// falling back to native ellipsis truncation. Sized by whatever the parent
/// hands it via GeometryReader, not a fixed width — unlike
/// PinnedNotePopoverView's own HoverScrollingTitleLabel, which needs a fixed
/// box because that popup's whole width is fixed, this one is for contexts
/// (like the note editor's title bar, which shrinks as tags/due pills claim
/// more of the row) where the available width genuinely varies.
struct HoverScrollingText: View {
    let text: String
    var font: Font = .headline

    @State private var isHovering = false
    @State private var scrollOffset: CGFloat = 0
    /// The text's own true rendered width, measured directly via a
    /// background GeometryReader on the Text itself (below) rather than
    /// approximated from an NSFont guess — an approximation here and the
    /// container's real, separately-measured width being subtracted from
    /// each other doesn't cancel out the way it did in
    /// HoverScrollingTitleLabel (which measures both sides with the same
    /// approximation), so any mismatch there under- or over-shoots the
    /// scroll distance and clips the last character. Measuring the actual
    /// on-screen width removes that mismatch entirely.
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: scrollOffset)
                .background(
                    GeometryReader { textProxy in
                        Color.clear
                            .onAppear { textWidth = textProxy.size.width }
                            .onChange(of: textProxy.size.width) { _, newValue in textWidth = newValue }
                    }
                )
                .onAppear { containerWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newValue in containerWidth = newValue }
                .onChange(of: isHovering) { _, hovering in
                    guard hovering else {
                        withAnimation(.easeOut(duration: 0.2)) { scrollOffset = 0 }
                        return
                    }
                    // A tiny margin past the exact measured overflow so the
                    // very last character clears the clipped edge instead of
                    // stopping flush against it — unlike the +6 this
                    // replaced, this is just rounding slack, not compensating
                    // for an unreliable estimate.
                    let overflow = textWidth - containerWidth + 2
                    guard overflow > 0 else { return }
                    withAnimation(.linear(duration: Double(overflow) / 40).delay(0.2)) {
                        scrollOffset = -overflow
                    }
                }
        }
        .clipped()
        .onHover { isHovering = $0 }
    }
}
