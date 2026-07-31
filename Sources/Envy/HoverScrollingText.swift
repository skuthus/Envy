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
                    // for an unreliable estimate. Decide whether to scroll on
                    // the *real* overflow, before adding that slack — otherwise
                    // a title that fits exactly (its slot equals its own width)
                    // reads as 2pt over and scrolls a hair on hover.
                    guard textWidth > containerWidth + 0.5 else { return }
                    let overflow = textWidth - containerWidth + 2
                    withAnimation(.linear(duration: Double(overflow) / 40).delay(0.2)) {
                        scrollOffset = -overflow
                    }
                }
        }
        .clipped()
        // Same trailing fade the file list's titles carry: a clipped title
        // reads as "continues" rather than a hard cut. Present only when the
        // text genuinely overflows, and lifted while hovering — the scroll
        // reveals the end, and a fade over it would hide the last characters.
        .mask(
            HStack(spacing: 0) {
                Rectangle().fill(Color.black)
                LinearGradient(
                    colors: [Color.black, Color.black.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: (textWidth > containerWidth + 0.5 && !isHovering) ? 18 : 0)
            }
            .animation(.easeOut(duration: 0.2), value: isHovering)
        )
        .onHover { isHovering = $0 }
    }
}

/// A hover-scrolling label that sizes to its text's *natural* width and
/// only clips (and scrolls) when the row can't give it that much — so an
/// element placed right after it (the note list's trailing folder dot)
/// hugs the end of the title when it fits, and sits at the clipped
/// boundary when it doesn't. HoverScrollingText fills whatever width it's
/// offered, which pushes a following element to the far edge; this one
/// doesn't.
///
/// A hidden, ordinary truncating Text drives the layout: it reports the
/// title's natural width, and shrinks under HStack pressure exactly like a
/// plain title would, so the slot is always min(natural, available). The
/// visible, scrolling copy is overlaid within whatever width that measures
/// out.
struct HuggingScrollingText: View {
    let text: String
    var font: Font = .body

    @State private var isHovering = false
    @State private var scrollOffset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) {
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
                                    .onChange(of: textProxy.size.width) { _, v in textWidth = v }
                            }
                        )
                        .onAppear { containerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, v in containerWidth = v }
                        .frame(height: proxy.size.height, alignment: .leading)
                }
                .clipped()
                // Fades the clipped edge so it reads as "continues" rather
                // than a hard cut. Only when the text actually overflows, and
                // not while hovering — then the scroll itself reveals the
                // end, and a fade over it would hide the last characters. The
                // 0-width gradient when off keeps the mask always present so
                // the transition animates rather than snaps.
                .mask(
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.black)
                        LinearGradient(
                            colors: [Color.black, Color.black.opacity(0)],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: (textWidth > containerWidth + 1 && !isHovering) ? 18 : 0)
                    }
                    .animation(.easeOut(duration: 0.2), value: isHovering)
                )
            }
            .onChange(of: isHovering) { _, hovering in
                guard hovering else {
                    withAnimation(.easeOut(duration: 0.2)) { scrollOffset = 0 }
                    return
                }
                // Scroll only when the title genuinely doesn't fit. Testing
                // the *real* overflow before the +2 slack is the fix for a
                // title that fits exactly (this view's slot is its own natural
                // width) reading as 2pt over and scrolling a hair on hover.
                guard textWidth > containerWidth + 0.5 else { return }
                let overflow = textWidth - containerWidth + 2
                withAnimation(.linear(duration: Double(overflow) / 40).delay(0.2)) {
                    scrollOffset = -overflow
                }
            }
            .onHover { isHovering = $0 }
    }
}
