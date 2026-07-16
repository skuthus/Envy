import Foundation

/// Whether option-clicking a `[[wikilink]]` or backlink opens its
/// hover-preview popover. Deliberately option-click only, not hover — an
/// earlier hover-triggered version conflicted with the pre-existing
/// ⌘-click-to-navigate gesture (a popover could be open from a passing
/// hover exactly when the user tried to ⌘-click through it, which is what
/// caused a "no application set to open the URL" failure when the two
/// interactions collided). Control-click was tried first instead of option,
/// but control-click is macOS's traditional secondary-click/right-click
/// equivalent — it collided with the standard context menu instead.
/// Option-click has no competing system meaning: it's just a plain modifier
/// flag on an ordinary click, so it never competes with anything else.
enum LinkPreviewTrigger: String, CaseIterable, Identifiable {
    case off
    case optionClick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .optionClick: "Option-Click"
        }
    }
}
