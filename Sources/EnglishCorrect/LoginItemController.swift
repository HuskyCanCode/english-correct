import Combine
import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case off
    case enabled
    case requiresApproval
    case unavailable

    static func forMainApp(systemStatus: SMAppService.Status, isApplicationBundle: Bool) -> LoginItemStatus {
        guard isApplicationBundle else { return .unavailable }
        switch systemStatus {
        case .notRegistered: return .off
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:
            // A valid app may be unknown to ServiceManagement until its first
            // registration. Do not hide opt-in or register merely to probe it.
            // Apple DTS: https://developer.apple.com/forums/thread/719862
            return .off
        @unknown default: return .unavailable
        }
    }
}

/// The system boundary is injectable so tests never change real login items.
@MainActor
protocol LoginItemBackend {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: LoginItemStatus
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    @Published private var promptAnswered: Bool

    private let defaults: UserDefaults
    private let backend: any LoginItemBackend
    private var unresolvedDesiredState: Bool?
    private static let promptAnsweredKey = "loginItemPromptAnswered"

    init(defaults: UserDefaults = .standard, backend: (any LoginItemBackend)? = nil) {
        self.defaults = defaults
        let backend = backend ?? SystemLoginItemBackend()
        self.backend = backend
        self.status = backend.status
        self.promptAnswered = defaults.bool(forKey: Self.promptAnsweredKey)
    }

    var shouldAsk: Bool { !promptAnswered && status == .off }
    var isEnabled: Bool { status == .enabled }

    var statusMessage: String {
        switch status {
        case .off:
            return "English Correct will open only when you launch it."
        case .enabled:
            return "English Correct will open when you log in to your Mac."
        case .requiresApproval:
            return "Approval is needed in System Settings → General → Login Items before English Correct can open at login."
        case .unavailable:
            return "Launch at login is unavailable for this copy of English Correct. Open the installed app and try again."
        }
    }

    /// Call only for an explicit user choice. Startup and refresh are read-only.
    func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        recordChoice()
        errorMessage = nil
        unresolvedDesiredState = nil
        status = backend.status

        // An existing registration that needs approval must be approved in
        // System Settings, not repeatedly registered by this app.
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && status == .off { return }
        guard status != .unavailable else {
            errorMessage = "macOS cannot find a usable app for launch at login. Open English Correct from Applications and try again."
            unresolvedDesiredState = enabled
            return
        }

        isChanging = true
        defer { isChanging = false }
        var operationError: Error?
        do {
            if enabled { try backend.register() }
            else { try backend.unregister() }
        } catch {
            operationError = error
        }

        // Never display a requested preference as if macOS had accepted it.
        status = backend.status
        if hasReachedDesiredState(enabled) {
            // Another system update can complete the request even when the API
            // reports an error (for example, an already-registered race).
            errorMessage = nil
        } else if let operationError {
            let action = enabled ? "turn on" : "turn off"
            errorMessage = "Could not \(action) launch at login. \(operationError.localizedDescription)"
        } else if enabled && status != .enabled && status != .requiresApproval {
            errorMessage = "macOS did not enable launch at login. Try again or check Login Items in System Settings."
        } else if !enabled && status != .off {
            errorMessage = "macOS has not confirmed that launch at login is off. Try again or check Login Items in System Settings."
        }
        if errorMessage != nil { unresolvedDesiredState = enabled }
    }

    /// Not now is remembered independently of macOS's actual registration.
    func deferChoice() { recordChoice() }

    /// Refreshes external changes without retrying registration. An unresolved
    /// error remains visible until macOS actually reaches the requested state.
    func refresh() {
        status = backend.status
        if let desired = unresolvedDesiredState, hasReachedDesiredState(desired) {
            errorMessage = nil
            unresolvedDesiredState = nil
        }
    }

    /// Opening settings is a separate explicit action; registration never opens it.
    func openSystemSettings() { backend.openSystemSettings() }

    private func hasReachedDesiredState(_ enabled: Bool) -> Bool {
        status == (enabled ? .enabled : .off)
    }

    private func recordChoice() {
        promptAnswered = true
        defaults.set(true, forKey: Self.promptAnsweredKey)
    }
}

@MainActor
private final class SystemLoginItemBackend: LoginItemBackend {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus {
        // A bare SwiftPM executable is not an installable login-item app.
        let isApplicationBundle = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        guard isApplicationBundle else { return .unavailable }
        return .forMainApp(systemStatus: service.status, isApplicationBundle: isApplicationBundle)
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
