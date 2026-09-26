import Carbon
import XCTest
@testable import EnglishCorrect

@MainActor
private final class FakeShortcutBackend: ShortcutRegistrationBackend {
    var registrations: [CorrectionShortcut] = []
    var callbacks: [(@MainActor () -> Void)?] = []
    var cancelled: [Int] = []
    var failure: Error?

    func register(_ shortcut: CorrectionShortcut, action: @escaping @MainActor () -> Void) throws -> ShortcutRegistrationToken {
        if let failure { throw failure }
        let index = callbacks.count
        registrations.append(shortcut)
        callbacks.append(action)
        return ShortcutRegistrationToken { [weak self] in
            self?.callbacks[index] = nil
            self?.cancelled.append(index)
        }
    }

    func press(_ index: Int) { callbacks[index]?() }
}

final class GlobalShortcutTests: XCTestCase {
    func testHotkeyBindingUsesExpectedModifiers() {
        XCTAssertEqual(CorrectionShortcut.optionCommandE.modifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(CorrectionShortcut.controlOptionCommandE.modifiers, UInt32(controlKey | optionKey | cmdKey))
        XCTAssertEqual(CorrectionShortcut.allCases.map(\.label), ["⌥⌘E", "⌃⌥⌘E"])
    }

    func testPressInvokesActionAndUnregisterStopsIt() async throws {
        try await MainActor.run {
            let backend = FakeShortcutBackend()
            let shortcut = GlobalShortcut(backend: backend)
            var presses = 0
            try shortcut.register(.optionCommandE) { presses += 1 }
            XCTAssertTrue(shortcut.isRegistered)
            XCTAssertEqual(shortcut.shortcut, .optionCommandE)
            backend.press(0)
            XCTAssertEqual(presses, 1)
            shortcut.unregister()
            backend.press(0)
            XCTAssertEqual(presses, 1)
            XCTAssertFalse(shortcut.isRegistered)
            XCTAssertNil(shortcut.shortcut)
            XCTAssertEqual(backend.cancelled, [0])
            shortcut.unregister()
            XCTAssertEqual(backend.cancelled, [0])
        }
    }

    func testChangingShortcutReleasesOldBindingBeforeRegisteringNewOne() async throws {
        try await MainActor.run {
            let backend = FakeShortcutBackend()
            let shortcut = GlobalShortcut(backend: backend)
            var originalPresses = 0
            var newPresses = 0
            try shortcut.register(.optionCommandE) { originalPresses += 1 }
            try shortcut.register(.controlOptionCommandE) { newPresses += 1 }
            XCTAssertEqual(backend.cancelled, [0])
            XCTAssertEqual(backend.registrations, [.optionCommandE, .controlOptionCommandE])
            XCTAssertEqual(shortcut.shortcut, .controlOptionCommandE)
            backend.press(0)
            backend.press(1)
            XCTAssertEqual(originalPresses, 0)
            XCTAssertEqual(newPresses, 1)
        }
    }

    func testConflictLeavesNoHiddenOldShortcutAndReportsAlternative() async throws {
        try await MainActor.run {
            let backend = FakeShortcutBackend()
            let shortcut = GlobalShortcut(backend: backend)
            try shortcut.register(.optionCommandE) {}
            backend.failure = GlobalShortcutError.alreadyInUse(.controlOptionCommandE)
            XCTAssertThrowsError(try shortcut.register(.controlOptionCommandE) {}) { error in
                XCTAssertTrue(error.localizedDescription.contains("⌃⌥⌘E"))
                XCTAssertTrue(error.localizedDescription.contains("already in use"))
            }
            XCTAssertFalse(shortcut.isRegistered)
            XCTAssertNil(shortcut.shortcut)
            XCTAssertEqual(backend.cancelled, [0])
        }
    }

    func testReleasingOwnerRemovesRegistrationAndCallback() async throws {
        try await MainActor.run {
            let backend = FakeShortcutBackend()
            var shortcut: GlobalShortcut? = GlobalShortcut(backend: backend)
            try shortcut?.register(.optionCommandE) {}
            weak let released = shortcut
            shortcut = nil
            XCTAssertNil(released)
            XCTAssertEqual(backend.cancelled, [0])
            XCTAssertNil(backend.callbacks[0])
        }
    }

    func testActualCarbonRegistrationRejectsCollisionAndCanReregisterAfterCleanup() async throws {
        try await MainActor.run {
            let first = GlobalShortcut()
            let second = GlobalShortcut()
            defer { first.unregister(); second.unregister() }
            do {
                try first.register(.controlOptionCommandE) {}
            } catch {
                throw XCTSkip("This environment cannot reserve the test shortcut: \(error.localizedDescription)")
            }
            XCTAssertThrowsError(try second.register(.controlOptionCommandE) {}) { error in
                guard case GlobalShortcutError.alreadyInUse(.controlOptionCommandE) = error else {
                    return XCTFail("Expected an actual Carbon hot-key conflict, got \(error)")
                }
            }
            first.unregister()
            try second.register(.controlOptionCommandE) {}
            XCTAssertTrue(second.isRegistered)
        }
    }
}
