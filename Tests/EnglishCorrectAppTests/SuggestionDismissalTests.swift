import XCTest
@testable import EnglishCorrect

@MainActor
private final class DismissalBackendStub: SuggestionDismissalBackend {
    private(set) var registrations = 0
    private(set) var cancellations = 0
    private(set) var actions: [@MainActor () -> Void] = []
    private(set) var activeRegistration: Int?
    var shouldFail = false

    func registerDismissal(action: @escaping @MainActor () -> Void) throws -> ShortcutRegistrationToken {
        if shouldFail { throw TestError.conflict }
        let index = actions.count
        actions.append(action)
        activeRegistration = index
        registrations += 1
        return ShortcutRegistrationToken { [weak self] in
            guard let self else { return }
            if self.activeRegistration == index { self.activeRegistration = nil }
            self.cancellations += 1
        }
    }

    func pressEscape() {
        guard let activeRegistration else { return }
        actions[activeRegistration]()
    }

    func deliverPreviouslyQueuedCallback(at index: Int) {
        actions[index]()
    }

    enum TestError: Error { case conflict }
}

@MainActor
final class SuggestionDismissalTests: XCTestCase {
    func testEscapeIsReservedOnlyUntilDeactivated() {
        let backend = DismissalBackendStub()
        let shortcut = SuggestionDismissalShortcut(backend: backend)
        var dismissals = 0

        XCTAssertFalse(shortcut.isRegistered)
        shortcut.activate { dismissals += 1 }
        XCTAssertTrue(shortcut.isRegistered)
        backend.pressEscape()
        XCTAssertEqual(dismissals, 1)

        shortcut.deactivate()
        backend.pressEscape()
        backend.deliverPreviouslyQueuedCallback(at: 0)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(backend.cancellations, 1)
        XCTAssertFalse(shortcut.isRegistered)
        XCTAssertNil(shortcut.errorMessage)

        shortcut.deactivate()
        XCTAssertEqual(backend.cancellations, 1)
    }

    func testReplacingPopupReleasesOldBindingAndRejectsItsQueuedCallbacks() {
        let backend = DismissalBackendStub()
        let shortcut = SuggestionDismissalShortcut(backend: backend)
        var oldDismissals = 0
        var newDismissals = 0

        shortcut.activate { oldDismissals += 1 }
        shortcut.activate { newDismissals += 1 }

        XCTAssertEqual(backend.registrations, 2)
        XCTAssertEqual(backend.cancellations, 1)
        XCTAssertTrue(shortcut.isRegistered)
        backend.deliverPreviouslyQueuedCallback(at: 0)
        XCTAssertEqual(oldDismissals, 0)
        XCTAssertEqual(newDismissals, 0)
        backend.pressEscape()
        XCTAssertEqual(newDismissals, 1)
    }

    func testConflictReleasesPreviousBindingAndExplainsCloseFallback() {
        let backend = DismissalBackendStub()
        let shortcut = SuggestionDismissalShortcut(backend: backend)
        shortcut.activate { XCTFail("Old popup must not receive a queued Escape") }
        backend.shouldFail = true

        shortcut.activate { XCTFail("Unavailable Escape must not dismiss a popup") }

        XCTAssertFalse(shortcut.isRegistered)
        XCTAssertNil(backend.activeRegistration)
        XCTAssertEqual(backend.cancellations, 1)
        XCTAssertTrue(shortcut.errorMessage?.contains("Escape is unavailable") == true)
        XCTAssertTrue(shortcut.errorMessage?.contains("close button") == true)
        backend.deliverPreviouslyQueuedCallback(at: 0)

        backend.shouldFail = false
        var dismissals = 0
        shortcut.activate { dismissals += 1 }
        XCTAssertTrue(shortcut.isRegistered)
        XCTAssertNil(shortcut.errorMessage)
        backend.pressEscape()
        XCTAssertEqual(dismissals, 1)
    }

    func testReleasingOwnerUnregistersEscapeAndRejectsRetainedCallback() {
        let backend = DismissalBackendStub()
        var shortcut: SuggestionDismissalShortcut? = SuggestionDismissalShortcut(backend: backend)
        shortcut?.activate { XCTFail("A released shortcut must not receive Escape") }
        XCTAssertTrue(shortcut?.isRegistered == true)

        shortcut = nil

        XCTAssertNil(backend.activeRegistration)
        XCTAssertEqual(backend.cancellations, 1)
        backend.deliverPreviouslyQueuedCallback(at: 0)
    }
}
