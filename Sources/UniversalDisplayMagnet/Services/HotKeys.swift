import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts via Carbon (no Accessibility permission needed).
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { HotKeys.shared.actions[id.id]?() }
                return noErr
            }, 1, &spec, nil, &handler)
    }

    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)

    /// Key + Carbon modifier mask (⌃⌥⌘ by default). Returns false when the
    /// combination is already taken by another app.
    @discardableResult
    func register(keyCode: Int, modifiers: UInt32 = HotKeys.defaultModifiers, _ action: @escaping () -> Void) -> Bool {
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), modifiers, EventHotKeyID(signature: OSType(0x4442_4B21), id: id), GetApplicationEventTarget(), 0,
            &ref)
        if let ref { refs.append(ref) }
        return status == noErr
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }
}
