import Carbon.HIToolbox
import AppKit

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    var handler: (() -> Void)?

    func register(keyCode: UInt32 = UInt32(kVK_Return), modifiers: UInt32 = UInt32(optionKey | cmdKey)) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x564C4354), id: 1)
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().handler?()
            return noErr
        }, 1, &eventSpec, selfPointer, &eventHandlerRef)

        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        hotKeyRef = nil
        eventHandlerRef = nil
    }

    deinit { unregister() }
}
