import AppKit
import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

@MainActor
final class FirstLaunchSetupTests: XCTestCase {
    func testCleanPreferencesPresentSetupOnceAndPersistLaunchImmediately() async throws {
        try await withDefaults { defaults in
            let (first, firstBackend) = makeApp(defaults)
            XCTAssertEqual(first.section, "Setup")
            XCTAssertTrue(defaults.bool(forKey: "hasLaunchedBefore"))
            XCTAssertFalse(first.setupCompleted)
            XCTAssertFalse(first.enabled)
            XCTAssertTrue(firstBackend.operations.isEmpty)

            // Completion is deliberately omitted: seeing setup once is enough.
            let (second, secondBackend) = makeApp(defaults)
            XCTAssertEqual(second.section, "Write")
            XCTAssertFalse(second.setupCompleted)
            XCTAssertFalse(second.enabled)
            XCTAssertTrue(secondBackend.operations.isEmpty)
        }
    }

    func testUnfinishedOrFailedFirstSetupDoesNotReopenOnNextLaunch() async throws {
        try await withDefaults { defaults in
            let (first, _) = makeApp(defaults)
            first.checkSetup()
            assertFailed(first)
            XCTAssertFalse(first.setupCompleted)

            let (returning, backend) = makeApp(defaults)
            XCTAssertEqual(returning.section, "Write")
            returning.checkSetup()
            assertFailed(returning)
            XCTAssertEqual(returning.section, "Write", "A missing model must not navigate a returning user back to setup.")
            XCTAssertFalse(returning.setupCompleted)
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testEachExistingKnownPreferenceMigratesToWriteWithoutLaunchMarker() async throws {
        let storedPreferences: [(String, Any)] = [
            ("appPermissions", Data("[]".utf8)),
            ("provider", LocalProvider.ollama.rawValue),
            ("baseURL", "http://127.0.0.1:1234"),
            ("model", ""),
            ("correctionShortcut", CorrectionShortcut.optionCommandE.rawValue),
            ("setupGuideCompleted", false)
        ]
        for (key, value) in storedPreferences {
            try await withDefaults { defaults in
                defaults.set(value, forKey: key)
                XCTAssertNil(defaults.object(forKey: "hasLaunchedBefore"))
                let (app, backend) = makeApp(defaults)
                XCTAssertEqual(app.section, "Write", "An existing \(key) preference marks an existing user even if its value is empty or false.")
                XCTAssertTrue(defaults.bool(forKey: "hasLaunchedBefore"))
                XCTAssertFalse(app.enabled)
                XCTAssertTrue(backend.operations.isEmpty)
            }
        }
    }

    func testUnrelatedPreferenceDoesNotSuppressFirstLaunchSetup() async throws {
        try await withDefaults { defaults in
            defaults.set("unrelated-value", forKey: "test.unrelatedPreference")
            let (app, backend) = makeApp(defaults)
            XCTAssertEqual(app.section, "Setup")
            XCTAssertTrue(defaults.bool(forKey: "hasLaunchedBefore"))
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testStoredLaunchMarkerReturnsToWriteWithoutCompletedSetup() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: "hasLaunchedBefore")
            let (app, backend) = makeApp(defaults)
            XCTAssertEqual(app.section, "Write")
            XCTAssertFalse(app.setupCompleted)
            XCTAssertEqual(app.setupAIState, .unchecked)
            XCTAssertFalse(app.enabled)
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testCompletedExistingUserReturnsToWriteAndStaysPaused() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: "setupGuideCompleted")
            let (app, backend) = makeApp(defaults)
            XCTAssertEqual(app.section, "Write")
            XCTAssertTrue(app.setupCompleted)
            XCTAssertTrue(defaults.bool(forKey: "hasLaunchedBefore"))
            XCTAssertFalse(app.enabled)
            XCTAssertFalse(app.monitor.isEnabled)
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testReturningUserServerFailureStaysOnWrite() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: "hasLaunchedBefore")
            defaults.set("synthetic-local-model", forKey: "model")
            var discoveryCalls = 0
            let (app, backend) = makeApp(defaults, listModels: { _ in
                discoveryCalls += 1
                throw LocalAIError.connectionFailed
            })
            XCTAssertEqual(app.section, "Write")
            app.checkSetup()
            for _ in 0..<200 {
                if app.setupAIState != .checking { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            assertFailed(app)
            XCTAssertEqual(discoveryCalls, 1)
            XCTAssertEqual(app.section, "Write")
            XCTAssertFalse(app.enabled)
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testReturningUserBlockedActionsDoNotAutomaticallyOpenSetup() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: "hasLaunchedBefore")
            let (app, backend) = makeApp(defaults)
            app.setAutomaticSuggestions(true)
            XCTAssertFalse(app.enabled)
            XCTAssertFalse(app.monitor.isEnabled)
            XCTAssertEqual(app.section, "Write")

            app.draft = "She go to school."
            app.checkDraft()
            XCTAssertEqual(app.section, "Write")
            XCTAssertFalse(app.draftBusy)
            XCTAssertNil(app.draftCorrection)
            XCTAssertFalse(app.draftStatus.isEmpty, "Blocked checking should explain its state in place.")
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testExplicitOpenSetupStillWorksWithoutChangingFutureLaunchDestination() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: "hasLaunchedBefore")
            let (app, backend) = makeApp(defaults)
            XCTAssertEqual(app.section, "Write")
            app.openSetup()
            XCTAssertEqual(app.section, "Setup")
            XCTAssertFalse(app.enabled)
            XCTAssertTrue(backend.operations.isEmpty)
            let (returning, _) = makeApp(defaults)
            XCTAssertEqual(returning.section, "Write")
        }
    }

    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let suite = "EnglishCorrect.FirstLaunchSetupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    private func makeApp(_ defaults: UserDefaults,
                         listModels: @escaping (LocalAIConfiguration) async throws -> [String] = { _ in [] }) -> (AppModel, SetupTestAccessibilityBackend) {
        let backend = SetupTestAccessibilityBackend()
        backend.isTrusted = false
        let monitor = AccessibilityMonitor(backend: backend)
        let app = AppModel(defaults: defaults, monitor: monitor, startMonitoring: false,
                           listModels: listModels, correctText: { _, _ in
            XCTFail("First-launch navigation tests must not send text to a model.")
            throw LocalAIError.invalidResponse
        })
        return (app, backend)
    }

    private func assertFailed(_ app: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        if case .failed(let message) = app.setupAIState { XCTAssertFalse(message.isEmpty, file: file, line: line) }
        else { XCTFail("The missing model or server error must be reported.", file: file, line: line) }
        XCTAssertFalse(app.readyInApp, file: file, line: line)
    }
}
