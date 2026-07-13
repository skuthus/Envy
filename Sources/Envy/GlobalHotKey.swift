import Carbon.HIToolbox
import AppKit

/// Registers one or more system-wide (works-from-any-app) keyboard
/// shortcuts via Carbon's RegisterEventHotKey, each identified by its own
/// `id`. Deliberately one shared Carbon event handler for every hotkey
/// registered on this instance, rather than installing a separate
/// InstallEventHandler per hotkey — Carbon calls handlers on the same
/// event target in a chain and stops propagating the moment one returns
/// noErr, which this callback always does, so a second independently
/// installed handler would silently swallow every hotkey the first one
/// owns (or vice versa, depending on install order). Dispatching by id
/// from inside one shared handler sidesteps that entirely.
final class GlobalHotKey {
    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    // Set via direct subscript assignment (hotKey.handlers[id] = { ... }) at
    // each call site rather than taken as a register(...) parameter — a
    // plain assignment, unlike passing a self-capturing closure as a
    // function argument, doesn't trip Swift 6's "sending self risks a data
    // race" check for a non-Sendable delegate class like AppDelegate.
    var handlers: [UInt32: () -> Void] = [:]

    private static let signature = OSType(0x564C4354)

    /// Registers (or re-registers, replacing any previous binding under
    /// the same `id`) a global hotkey's key combination. Set
    /// `handlers[id]` separately (before or after) to supply what it does.
    // Only touches hotKeyRefs, deliberately never `handlers` — callers are
    // free to set handlers[id] either before or after calling register(id:),
    // e.g. re-registering an updated key combination for an id whose
    // handler was set once at launch and never needs to change again.
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        installEventHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs[id] = ref
    }

    /// Fully removes a hotkey and its handler — unlike register(id:...)
    /// re-registering the same id, this is for when the id itself is being
    /// retired for good.
    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventSpec, selfPointer, &eventHandlerRef)
    }

    deinit {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
