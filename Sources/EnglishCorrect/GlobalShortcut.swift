import Carbon
import Foundation

/// These combinations use the E key's physical position, matching macOS hot keys.
enum CorrectionShortcut: String, CaseIterable, Identifiable {
    case optionCommandE
    case controlOptionCommandE

    var id: String { rawValue }
    var label: String {
        switch self {
        case .optionCommandE: return "⌥⌘E"
        case .controlOptionCommandE: return "⌃⌥⌘E"
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .optionCommandE: return UInt32(optionKey | cmdKey)
        case .controlOptionCommandE: return UInt32(controlKey | optionKey | cmdKey)
        }
    }
}

enum GlobalShortcutError: LocalizedError {
    case alreadyInUse(CorrectionShortcut)
    case handlerFailed(OSStatus)
    case registrationFailed(CorrectionShortcut, OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyInUse(let shortcut):
            return "\(shortcut.label) is already in use. Choose the other shortcut in English Correct."
        case .handlerFailed(let status):
            return "The keyboard shortcut could not start (error \(status)). Restart English Correct and try again."
        case .registrationFailed(let shortcut, let status):
            return "\(shortcut.label) could not be registered (error \(status)). Choose the other shortcut or restart English Correct."
        }
    }
}

/// Owns cleanup so a shortcut also unregisters if its owner is released. Carbon's
/// registration APIs are not thread safe; even a last release elsewhere cleans up
/// on the main actor, retaining the callback context until its handler is removed.
final class ShortcutRegistrationToken {
    private var cleanup: (@MainActor () -> Void)?

    init(cleanup: @escaping @MainActor () -> Void) {
        self.cleanup = cleanup
    }

    @MainActor func cancel() {
        let action = cleanup
        cleanup = nil
        action?()
    }

    deinit {
        guard let cleanup else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { cleanup() }
        } else {
            Task { @MainActor in cleanup() }
        }
    }
}

@MainActor
protocol ShortcutRegistrationBackend {
    func register(_ shortcut: CorrectionShortcut, action: @escaping @MainActor () -> Void) throws -> ShortcutRegistrationToken
}

@MainActor
final class GlobalShortcut {
    private let backend: ShortcutRegistrationBackend
    private var registration: ShortcutRegistrationToken?
    private(set) var shortcut: CorrectionShortcut?
    var isRegistered: Bool { registration != nil }

    init(backend: ShortcutRegistrationBackend? = nil) {
        self.backend = backend ?? CarbonShortcutBackend()
    }

    func register(_ shortcut: CorrectionShortcut, action: @escaping @MainActor () -> Void) throws {
        // Always release the old binding before trying its replacement. A failed
        // replacement is visibly unavailable instead of leaving a hidden binding.
        unregister()
        registration = try backend.register(shortcut, action: action)
        self.shortcut = shortcut
    }

    func unregister() {
        registration?.cancel()
        registration = nil
        shortcut = nil
    }
}

@MainActor
private final class ShortcutCallbackContext {
    let identifier: EventHotKeyID
    var action: (@MainActor () -> Void)?

    init(identifier: EventHotKeyID, action: @escaping @MainActor () -> Void) {
        self.identifier = identifier
        self.action = action
    }

    func receive(_ identifier: EventHotKeyID) -> OSStatus {
        guard identifier.signature == self.identifier.signature,
              identifier.id == self.identifier.id,
              let action else { return OSStatus(eventNotHandledErr) }
        action()
        return noErr
    }
}

@MainActor
final class CarbonShortcutBackend: ShortcutRegistrationBackend {
    private static var nextID: UInt32 = 0

    func register(_ shortcut: CorrectionShortcut, action: @escaping @MainActor () -> Void) throws -> ShortcutRegistrationToken {
        Self.nextID &+= 1
        let identifier = EventHotKeyID(signature: 0x456E4372, id: Self.nextID) // EnCr
        let context = ShortcutCallbackContext(identifier: identifier, action: action)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            // The application event target dispatches Carbon keyboard events on
            // the main thread. The registration token keeps this context alive.
            return MainActor.assumeIsolated {
                Unmanaged<ShortcutCallbackContext>.fromOpaque(userData).takeUnretainedValue().receive(identifier)
            }
        }, 1, &eventType, Unmanaged.passUnretained(context).toOpaque(), &handler)
        guard handlerStatus == noErr, let handler else {
            throw GlobalShortcutError.handlerFailed(handlerStatus)
        }

        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_E), shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard status == noErr, let hotKey else {
            RemoveEventHandler(handler)
            if status == eventHotKeyExistsErr { throw GlobalShortcutError.alreadyInUse(shortcut) }
            throw GlobalShortcutError.registrationFailed(shortcut, status)
        }
        return ShortcutRegistrationToken {
            context.action = nil
            UnregisterEventHotKey(hotKey)
            RemoveEventHandler(handler)
        }
    }
}
