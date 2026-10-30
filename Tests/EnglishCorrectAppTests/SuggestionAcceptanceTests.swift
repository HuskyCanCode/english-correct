import XCTest
@testable import EnglishCorrect

@MainActor
final class AcceptanceBackendStub: SuggestionAcceptanceBackend {
    var action: (@MainActor () -> Void)?
    var registrations = 0
    var cancellations = 0
    var shouldFail = false

    func registerAcceptance(action: @escaping @MainActor () -> Void) throws -> ShortcutRegistrationToken {
        if shouldFail { throw TestError.conflict }
        registrations += 1
        self.action = action
        return ShortcutRegistrationToken { [weak self] in
            self?.action = nil
            self?.cancellations += 1
        }
    }
    func pressReturn() { action?() }
    enum TestError: Error { case conflict }
}

@MainActor
final class SuggestionAcceptanceTests: XCTestCase {
    func testReturnIsRegisteredOnlyUntilDeactivated() {
        let backend = AcceptanceBackendStub()
        let shortcut = SuggestionAcceptanceShortcut(backend: backend)
        var accepts = 0
        XCTAssertFalse(shortcut.isRegistered)
        shortcut.activate { accepts += 1 }
        XCTAssertTrue(shortcut.isRegistered)
        backend.pressReturn()
        XCTAssertEqual(accepts, 1)
        shortcut.deactivate()
        backend.pressReturn()
        XCTAssertEqual(accepts, 1)
        XCTAssertEqual(backend.cancellations, 1)
        XCTAssertFalse(shortcut.isRegistered)
    }

    func testConflictProvidesFallbackAndReleasingOwnerUnregistersReturn() {
        let backend = AcceptanceBackendStub()
        var shortcut: SuggestionAcceptanceShortcut? = SuggestionAcceptanceShortcut(backend: backend)
        backend.shouldFail = true
        shortcut?.activate { XCTFail() }
        XCTAssertFalse(shortcut?.isRegistered ?? true)
        XCTAssertTrue(shortcut?.errorMessage?.contains("Use Apply") == true)
        backend.shouldFail = false
        shortcut?.activate {}
        XCTAssertTrue(shortcut?.isRegistered == true)
        shortcut = nil
        XCTAssertNil(backend.action)
        XCTAssertEqual(backend.cancellations, 1)
    }
}
