import Carbon

@MainActor
final class GlobalShortcuts {
    private var registrations: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let action: (UInt32) -> Void
    private(set) var unavailable: [UInt32] = []

    init(action: @escaping (UInt32) -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x41534858 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
            let id = identifier.id
            Task { @MainActor in manager.action(id) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { unavailable = [1, 2, 3]; return }

        for (id, key) in [(UInt32(1), kVK_ANSI_5), (UInt32(2), kVK_ANSI_6), (UInt32(3), kVK_ANSI_7)] {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey | cmdKey),
                                            EventHotKeyID(signature: 0x41534858, id: id),
                                            GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { registrations.append(reference) }
            else { unavailable.append(id) }
        }
    }

    func unregister() {
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
