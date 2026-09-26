import Foundation
import ServiceManagement
import XCTest
@testable import EnglishCorrect

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testNotFoundInstalledMainAppOffersFirstChoiceWhileBareExecutableStaysUnavailable() async throws {
        // This pure mapping constructs no SMAppService. macOS can return
        // notFound for a main app that has simply never registered before.
        let installedStatus = LoginItemStatus.forMainApp(systemStatus: .notFound, isApplicationBundle: true)
        XCTAssertEqual(installedStatus, .off)
        XCTAssertEqual(LoginItemStatus.forMainApp(systemStatus: .notFound, isApplicationBundle: false), .unavailable)
        try withDefaults { defaults in
            let backend = FakeLoginItemBackend(status: installedStatus)
            let controller = LoginItemController(defaults: defaults, backend: backend)
            XCTAssertTrue(controller.shouldAsk)
            XCTAssertFalse(controller.isEnabled)
            XCTAssertTrue(backend.mutations.isEmpty)

            controller.setEnabled(true)

            XCTAssertEqual(backend.mutations, ["register"])
            XCTAssertTrue(controller.isEnabled)
            XCTAssertFalse(controller.shouldAsk)
            XCTAssertNil(controller.errorMessage)
        }
    }

    func testInitializationAndRefreshOnlyReadStatusAndAskOnlyForUnansweredOffState() async throws {
        for state in [LoginItemStatus.off, .enabled, .requiresApproval, .unavailable] {
            try withDefaults { defaults in
                let backend = FakeLoginItemBackend(status: state)
                let controller = LoginItemController(defaults: defaults, backend: backend)
                XCTAssertEqual(controller.status, state)
                XCTAssertEqual(controller.isEnabled, state == .enabled)
                XCTAssertEqual(controller.shouldAsk, state == .off)
                XCTAssertFalse(controller.isChanging)
                controller.refresh()
                controller.refresh()
                XCTAssertTrue(backend.mutations.isEmpty)
                XCTAssertEqual(backend.settingsOpens, 0)
                XCTAssertGreaterThanOrEqual(backend.statusReads, 3)
            }
        }
    }

    func testDeferringChoicePersistsWithoutRegisteringAndSuppressesNextLaunchPrompt() async throws {
        try withDefaults { defaults in
            let backend = FakeLoginItemBackend(status: .off)
            let first = LoginItemController(defaults: defaults, backend: backend)
            XCTAssertTrue(first.shouldAsk)
            first.deferChoice()
            XCTAssertFalse(first.shouldAsk)
            XCTAssertTrue(defaults.bool(forKey: "loginItemPromptAnswered"))
            XCTAssertFalse(first.isEnabled)

            let returning = LoginItemController(defaults: defaults, backend: backend)
            XCTAssertFalse(returning.shouldAsk)
            XCTAssertEqual(returning.status, .off)
            XCTAssertTrue(backend.mutations.isEmpty)
            XCTAssertEqual(backend.settingsOpens, 0)
        }
    }

    func testExplicitEnableUsesBackendReadbackWithoutOptimisticEnabledState() async throws {
        try withDefaults { defaults in
            let backend = FakeLoginItemBackend(status: .off)
            let controller = LoginItemController(defaults: defaults, backend: backend)
            backend.onRegister = {
                XCTAssertTrue(controller.isChanging)
                XCTAssertFalse(controller.isEnabled, "Registration has not returned yet.")
                XCTAssertEqual(controller.status, .off)
            }
            defer { backend.onRegister = nil }
            controller.setEnabled(true)
            XCTAssertEqual(backend.mutations, ["register"])
            XCTAssertEqual(controller.status, .enabled)
            XCTAssertTrue(controller.isEnabled)
            XCTAssertFalse(controller.isChanging)
            XCTAssertNil(controller.errorMessage)
            XCTAssertFalse(controller.shouldAsk)
            XCTAssertTrue(defaults.bool(forKey: "loginItemPromptAnswered"))
            controller.setEnabled(true)
            XCTAssertEqual(backend.mutations, ["register"], "Already enabled must not register twice.")
        }
    }

    func testSuccessfulMutationWithoutDesiredReadbackDoesNotClaimSuccess() async throws {
        for enabling in [true, false] {
            try withDefaults { defaults in
                let original: LoginItemStatus = enabling ? .off : .enabled
                let backend = FakeLoginItemBackend(status: original)
                backend.registrationResult = original
                backend.unregistrationResult = original
                let controller = LoginItemController(defaults: defaults, backend: backend)
                controller.setEnabled(enabling)
                XCTAssertEqual(controller.status, original)
                XCTAssertEqual(controller.isEnabled, original == .enabled)
                XCTAssertFalse(controller.isChanging)
                XCTAssertFalse(try XCTUnwrap(controller.errorMessage).isEmpty)
                XCTAssertEqual(backend.mutations, [enabling ? "register" : "unregister"])
            }
        }
    }

    func testRequiresApprovalIsDistinctFromEnabledAndRepeatedEnableDoesNotReregister() async throws {
        try withDefaults { defaults in
            let backend = FakeLoginItemBackend(status: .off)
            backend.registrationResult = .requiresApproval
            let controller = LoginItemController(defaults: defaults, backend: backend)
            let offMessage = controller.statusMessage
            controller.setEnabled(true)
            XCTAssertEqual(controller.status, .requiresApproval)
            XCTAssertFalse(controller.isEnabled)
            XCTAssertFalse(controller.shouldAsk)
            XCTAssertNotEqual(controller.statusMessage, offMessage)
            XCTAssertNil(controller.errorMessage)
            controller.setEnabled(true)
            XCTAssertEqual(backend.mutations, ["register"])
            XCTAssertEqual(backend.settingsOpens, 0, "Registration must not silently open Settings.")
            controller.openSystemSettings()
            XCTAssertEqual(backend.settingsOpens, 1)
            XCTAssertEqual(backend.mutations, ["register"])
        }
    }

    func testRegistrationAndUnregistrationErrorsRemainVisibleAndStatusStaysAuthoritative() async throws {
        for enabling in [true, false] {
            try withDefaults { defaults in
                let original: LoginItemStatus = enabling ? .off : .enabled
                let backend = FakeLoginItemBackend(status: original)
                if enabling { backend.registrationError = FakeLoginItemError.denied }
                else { backend.unregistrationError = FakeLoginItemError.denied }
                let controller = LoginItemController(defaults: defaults, backend: backend)
                controller.setEnabled(enabling)
                let reportedError = try XCTUnwrap(controller.errorMessage)
                XCTAssertTrue(reportedError.contains(FakeLoginItemError.denied.localizedDescription))
                XCTAssertEqual(controller.status, original)
                XCTAssertEqual(controller.isEnabled, original == .enabled)
                XCTAssertFalse(controller.isChanging)
                controller.refresh()
                XCTAssertEqual(controller.errorMessage, reportedError,
                               "Refreshing status must not erase an operation error.")
                XCTAssertEqual(backend.mutations, [enabling ? "register" : "unregister"])
            }
        }
    }

    func testExplicitDisableUnregistersEnabledOrPendingItemOnce() async throws {
        for original in [LoginItemStatus.enabled, .requiresApproval] {
            try withDefaults { defaults in
                let backend = FakeLoginItemBackend(status: original)
                let controller = LoginItemController(defaults: defaults, backend: backend)
                controller.setEnabled(false)
                XCTAssertEqual(backend.mutations, ["unregister"])
                XCTAssertEqual(controller.status, .off)
                XCTAssertFalse(controller.isEnabled)
                XCTAssertFalse(controller.shouldAsk)
                XCTAssertNil(controller.errorMessage)
                controller.setEnabled(false)
                XCTAssertEqual(backend.mutations, ["unregister"], "Already off must not unregister twice.")
            }
        }
    }

    func testRefreshClearsFailedOperationOnceExternalStateReachesRequestedResult() async throws {
        for enabling in [true, false] {
            try withDefaults { defaults in
                let backend = FakeLoginItemBackend(status: enabling ? .off : .enabled)
                if enabling { backend.registrationError = FakeLoginItemError.denied }
                else { backend.unregistrationError = FakeLoginItemError.denied }
                let controller = LoginItemController(defaults: defaults, backend: backend)
                controller.setEnabled(enabling)
                XCTAssertNotNil(controller.errorMessage)

                backend.currentStatus = enabling ? .enabled : .off
                controller.refresh()

                XCTAssertEqual(controller.isEnabled, enabling)
                XCTAssertEqual(controller.status, backend.currentStatus)
                XCTAssertNil(controller.errorMessage, "A resolved failure must not contradict the current system status.")
                XCTAssertEqual(backend.mutations, [enabling ? "register" : "unregister"], "Refresh must not retry the OS mutation.")
                XCTAssertEqual(backend.settingsOpens, 0)
            }
        }
    }

    func testExternalSystemChangesAreReflectedWithoutControllerMutations() async throws {
        try withDefaults { defaults in
            let backend = FakeLoginItemBackend(status: .off)
            let controller = LoginItemController(defaults: defaults, backend: backend)
            for state in [LoginItemStatus.enabled, .requiresApproval, .off] {
                backend.currentStatus = state
                controller.refresh()
                XCTAssertEqual(controller.status, state)
                XCTAssertEqual(controller.isEnabled, state == .enabled)
            }
            XCTAssertTrue(backend.mutations.isEmpty)
            XCTAssertEqual(backend.settingsOpens, 0)
        }
    }

    func testExplicitActionsCheckCurrentSystemStateBeforeAvoidingDuplicates() async throws {
        try withDefaults { defaults in
            let backend = FakeLoginItemBackend(status: .off)
            let controller = LoginItemController(defaults: defaults, backend: backend)
            backend.currentStatus = .enabled
            controller.setEnabled(true)
            XCTAssertTrue(controller.isEnabled)
            backend.currentStatus = .off
            controller.setEnabled(false)
            XCTAssertFalse(controller.isEnabled)
            XCTAssertTrue(backend.mutations.isEmpty, "Stale controller state must not cause redundant OS mutations.")
        }
    }

    func testUnavailableServiceCannotMutateOrClaimEnabled() async throws {
        try withDefaults { defaults in
            let backend = FakeLoginItemBackend(status: .unavailable)
            let controller = LoginItemController(defaults: defaults, backend: backend)
            controller.setEnabled(true)
            XCTAssertEqual(controller.status, .unavailable)
            XCTAssertFalse(controller.isEnabled)
            XCTAssertFalse(try XCTUnwrap(controller.errorMessage).isEmpty)
            controller.setEnabled(false)
            XCTAssertTrue(backend.mutations.isEmpty)
            XCTAssertEqual(backend.settingsOpens, 0)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "EnglishCorrect.LoginItemControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}

/// This fake is the only login-item backend any test above creates. It never
/// calls ServiceManagement, changes login items, or opens system preferences.
@MainActor
private final class FakeLoginItemBackend: LoginItemBackend {
    var currentStatus: LoginItemStatus
    var registrationResult: LoginItemStatus = .enabled
    var unregistrationResult: LoginItemStatus = .off
    var registrationError: Error?
    var unregistrationError: Error?
    var onRegister: (() -> Void)?
    private(set) var statusReads = 0
    private(set) var mutations: [String] = []
    private(set) var settingsOpens = 0

    init(status: LoginItemStatus) { currentStatus = status }
    var status: LoginItemStatus { statusReads += 1; return currentStatus }
    func register() throws {
        mutations.append("register")
        onRegister?()
        if let registrationError { throw registrationError }
        currentStatus = registrationResult
    }
    func unregister() throws {
        mutations.append("unregister")
        if let unregistrationError { throw unregistrationError }
        currentStatus = unregistrationResult
    }
    func openSystemSettings() { settingsOpens += 1 }
}

private enum FakeLoginItemError: LocalizedError {
    case denied
    var errorDescription: String? { "The synthetic login-item request was denied." }
}
