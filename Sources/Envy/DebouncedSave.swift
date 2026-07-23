import Foundation

/// The one debounced-save rule shared by every editing surface (the main
/// editor, wikilink preview popover, embedded notes, the pinned-note panel).
/// This was copy-pasted per view and had already drifted — one copy lost its
/// @MainActor hop, so its save landed off the main actor while mutating view
/// @State. Central now so the delay and the actor hop can't diverge again.
///
/// 400ms: long enough to coalesce a typing burst into one disk write, short
/// enough that quitting right after typing almost never loses the tail.
@MainActor
enum DebouncedSave {
    static func schedule(replacing current: Task<Void, Never>?, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        current?.cancel()
        return Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}
