import SwiftUI

/// "Glassify" — an opt-in, all-in look that turns Envy's opaque chrome into
/// frosted Liquid Glass panels floating over the window's (deepened) backdrop
/// blur. Purely visual: every control, gesture, and layout stays exactly as it
/// is; only the surfaces change.
///
/// Threaded through the view tree as an environment value so any chrome view —
/// including NoteEditorView, which ContentView doesn't own directly — can read
/// it without a new init parameter.
private struct GlassifyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var glassify: Bool {
        get { self[GlassifyKey.self] }
        set { self[GlassifyKey.self] = newValue }
    }
}

extension View {
    /// A large chrome panel (the list's search/sort block, the editor body):
    /// opaque window background normally; a frosted material in Glassify so the
    /// backdrop reads through it.
    @ViewBuilder
    func chromePanel(_ glassify: Bool) -> some View {
        if glassify {
            background(.ultraThinMaterial)
        } else {
            background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// A chrome bar (footer, editor title bar): the system bar material
    /// normally; a Liquid Glass bar in Glassify.
    @ViewBuilder
    func chromeBar(_ glassify: Bool) -> some View {
        if glassify {
            glassEffect(.regular, in: Rectangle())
        } else {
            background(.bar)
        }
    }

    /// The topmost chrome panel — the list's search/sort header. Same as
    /// `chromePanel`, but in Glassify its frosted material extends up past the
    /// top safe area to fill under the (now transparent, full-size-content)
    /// title bar, so the title-bar strip reads continuously with the header
    /// instead of showing the darker native title-bar material.
    @ViewBuilder
    func chromeHeaderPanel(_ glassify: Bool) -> some View {
        if glassify {
            background(Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .top))
        } else {
            background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
