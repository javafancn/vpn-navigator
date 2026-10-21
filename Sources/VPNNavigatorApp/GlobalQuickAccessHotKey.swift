import AppKit
import Carbon
import VPNNavigatorCore

/// Registers one explicit chord. No event taps or general keyboard monitoring.
final class GlobalQuickAccessHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var generation = 0
    private(set) var eventID = EventHotKeyID(signature: 0x564E5141, id: UInt32.random(in: 1...UInt32.max))
    private(set) var activeShortcut: QuickAccessShortcut = .disabled
    var onPressed: (() -> Void)?

    func register(_ shortcut: QuickAccessShortcut) throws {
        precondition(Thread.isMainThread)
        unregister()
        guard shortcut != .disabled else { return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalQuickAccessHotKey>.fromOpaque(context).takeUnretainedValue()
                var identity = EventHotKeyID(signature: 0, id: 0)
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, UInt32(MemoryLayout<EventHotKeyID>.size), nil, &identity) == noErr,
                    identity.signature == owner.eventID.signature, identity.id == owner.eventID.id else {
                    return OSStatus(eventNotHandledErr)
                }
                let generation = owner.generation
                DispatchQueue.main.async { [weak owner] in
                    guard let owner, owner.generation == generation, owner.activeShortcut != .disabled else { return }
                    owner.onPressed?()
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw RegistrationError(status: status) }
        }
        let key: UInt32
        switch shortcut {
        case .controlOptionCommandV: key = UInt32(kVK_ANSI_V)
        case .controlOptionCommandJ: key = UInt32(kVK_ANSI_J)
        case .controlOptionCommandSpace: key = UInt32(kVK_Space)
        case .disabled: return
        }
        let status = RegisterEventHotKey(key, UInt32(controlKey | optionKey | cmdKey), eventID,
                                        GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { reference = nil; throw RegistrationError(status: status) }
        activeShortcut = shortcut
    }
    func unregister() {
        precondition(Thread.isMainThread)
        generation += 1
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        activeShortcut = .disabled
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
    struct RegistrationError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "快捷键无法注册，可能已被占用（\(status)）。请选择其他组合或重试。" }
    }
}
