import SwiftUI
import Carbon.HIToolbox

// Carbon.HIToolbox declares its own `EventModifiers` type (a UInt16
// typealias for the classic Carbon Event Manager), which collides with
// SwiftUI's — every reference in this file has to say `SwiftUI.EventModifiers`
// explicitly or the compiler picks the wrong one and everything downstream
// (including files that don't even import Carbon) fails to type-check.

/// A single key + modifier combination. Stores both the character (what
/// SwiftUI's `.keyboardShortcut(_:modifiers:)` needs for menu items) and the
/// raw keyCode (what Carbon's RegisterEventHotKey needs for the global
/// summon hotkey, and what the "Center Window" local event monitor matches
/// against) — captured together from the same NSEvent when recording, so
/// there's never a mismatch between the two.
struct ShortcutBinding: Codable, Equatable {
    var character: String
    var keyCode: Int
    var modifiers: Int

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(character.first ?? " ")
    }

    var eventModifiers: SwiftUI.EventModifiers {
        SwiftUI.EventModifiers(rawValue: modifiers)
    }

    /// Carbon's RegisterEventHotKey modifier bitmask, for the global
    /// summon hotkey — a different representation than SwiftUI's
    /// EventModifiers or AppKit's NSEvent.ModifierFlags.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if eventModifiers.contains(.command) { result |= UInt32(cmdKey) }
        if eventModifiers.contains(.option) { result |= UInt32(optionKey) }
        if eventModifiers.contains(.control) { result |= UInt32(controlKey) }
        if eventModifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// A human-readable rendering like "⌘⇧L" or "⌥→".
    var displayString: String {
        var parts = ""
        if eventModifiers.contains(.control) { parts += "⌃" }
        if eventModifiers.contains(.option) { parts += "⌥" }
        if eventModifiers.contains(.shift) { parts += "⇧" }
        if eventModifiers.contains(.command) { parts += "⌘" }
        parts += Self.displayCharacter(for: character.first ?? " ")
        return parts
    }

    private static func displayCharacter(for char: Character) -> String {
        switch char {
        case KeyEquivalent.delete.character: return "⌫"
        case KeyEquivalent.leftArrow.character: return "←"
        case KeyEquivalent.rightArrow.character: return "→"
        case KeyEquivalent.upArrow.character: return "↑"
        case KeyEquivalent.downArrow.character: return "↓"
        case KeyEquivalent.return.character: return "↩"
        case KeyEquivalent.escape.character: return "⎋"
        case KeyEquivalent.tab.character: return "⇥"
        case " ": return "Space"
        default: return String(char).uppercased()
        }
    }

    /// A spelled-out rendering like "Command + Shift + L" — used in the
    /// Shortcuts settings tab, where symbols packed tightly together (⌘⇧L)
    /// read as cramped; the compact `displayString` is still used in the
    /// About page's reference sheet, where a dense table of many entries is
    /// the point.
    var verboseDisplayString: String {
        var parts: [String] = []
        if eventModifiers.contains(.control) { parts.append("Control") }
        if eventModifiers.contains(.option) { parts.append("Option") }
        if eventModifiers.contains(.shift) { parts.append("Shift") }
        if eventModifiers.contains(.command) { parts.append("Command") }
        parts.append(Self.verboseCharacterName(for: character.first ?? " "))
        return parts.joined(separator: " + ")
    }

    private static func verboseCharacterName(for char: Character) -> String {
        switch char {
        case KeyEquivalent.delete.character: return "Delete"
        case KeyEquivalent.leftArrow.character: return "Left Arrow"
        case KeyEquivalent.rightArrow.character: return "Right Arrow"
        case KeyEquivalent.upArrow.character: return "Up Arrow"
        case KeyEquivalent.downArrow.character: return "Down Arrow"
        case KeyEquivalent.return.character: return "Return"
        case KeyEquivalent.escape.character: return "Escape"
        case KeyEquivalent.tab.character: return "Tab"
        case " ": return "Space"
        default: return String(char).uppercased()
        }
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case newNote
    case deleteNote
    case toggleLayout
    case bold
    case italic
    case zoomIn
    case zoomOut
    case actualSize
    case nextFolder
    case previousFolder
    case centerWindow
    case summonApp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newNote: "New Note"
        case .deleteNote: "Delete Note"
        case .toggleLayout: "Toggle Layout"
        case .bold: "Bold"
        case .italic: "Italic"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .nextFolder: "Next Folder"
        case .previousFolder: "Previous Folder"
        case .centerWindow: "Center Window"
        case .summonApp: "Show/Hide Envy (works from any app)"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .newNote:
            ShortcutBinding(character: "n", keyCode: kVK_ANSI_N, modifiers: SwiftUI.EventModifiers.command.rawValue)
        case .deleteNote:
            ShortcutBinding(character: String(KeyEquivalent.delete.character), keyCode: kVK_Delete, modifiers: SwiftUI.EventModifiers.command.rawValue)
        case .toggleLayout:
            ShortcutBinding(character: "l", keyCode: kVK_ANSI_L, modifiers: SwiftUI.EventModifiers([.command, .shift]).rawValue)
        case .bold:
            ShortcutBinding(character: "b", keyCode: kVK_ANSI_B, modifiers: SwiftUI.EventModifiers.command.rawValue)
        case .italic:
            ShortcutBinding(character: "i", keyCode: kVK_ANSI_I, modifiers: SwiftUI.EventModifiers.command.rawValue)
        case .zoomIn:
            ShortcutBinding(character: "+", keyCode: kVK_ANSI_Equal, modifiers: SwiftUI.EventModifiers.command.rawValue)
        case .zoomOut:
            ShortcutBinding(character: "-", keyCode: kVK_ANSI_Minus, modifiers: SwiftUI.EventModifiers.command.rawValue)
        case .actualSize:
            ShortcutBinding(character: "0", keyCode: kVK_ANSI_0, modifiers: SwiftUI.EventModifiers.command.rawValue)
        case .nextFolder:
            ShortcutBinding(character: String(KeyEquivalent.rightArrow.character), keyCode: kVK_RightArrow, modifiers: SwiftUI.EventModifiers.option.rawValue)
        case .previousFolder:
            ShortcutBinding(character: String(KeyEquivalent.leftArrow.character), keyCode: kVK_LeftArrow, modifiers: SwiftUI.EventModifiers.option.rawValue)
        case .centerWindow:
            ShortcutBinding(character: String(KeyEquivalent.return.character), keyCode: kVK_Return, modifiers: SwiftUI.EventModifiers.command.rawValue)
        case .summonApp:
            ShortcutBinding(character: String(KeyEquivalent.return.character), keyCode: kVK_Return, modifiers: SwiftUI.EventModifiers([.command, .option]).rawValue)
        }
    }
}

extension SwiftUI.EventModifiers {
    /// SwiftUI's EventModifiers has no public initializer from AppKit's
    /// NSEvent.ModifierFlags — translated flag by flag instead of assuming
    /// the raw bit patterns line up.
    init(_ nsFlags: NSEvent.ModifierFlags) {
        var result: SwiftUI.EventModifiers = []
        if nsFlags.contains(.command) { result.insert(.command) }
        if nsFlags.contains(.option) { result.insert(.option) }
        if nsFlags.contains(.control) { result.insert(.control) }
        if nsFlags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}
