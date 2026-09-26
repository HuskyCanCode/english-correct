import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

final class AppModelTests: XCTestCase {
    /// No view is created, so these checks catch model changes that accidentally
    /// depend on a SwiftUI onChange callback in the settings screen.
    @MainActor
    private static func withModel(_ body: (AppModel, UserDefaults) throws -> Void) throws {
        let suite = "EnglishCorrect.AppModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = Self.makeApp(defaults)
        defer { app.model = ""; app.monitor.stop() }
        XCTAssertFalse(app.enabled)
        XCTAssertTrue(app.allowedIDs.isEmpty)
        try body(app, defaults)
    }

    @MainActor
    private static func makeApp(_ defaults: UserDefaults) -> AppModel {
        // Deferred verification must never reach a real server in these
        // persistence-only tests, even if a model is edited during the test.
        AppModel(defaults: defaults, startMonitoring: false,
                 listModels: { _ in [] }, correctText: { _, _ in throw LocalAIError.invalidResponse })
    }

    @MainActor
    private static func seedSuggestions(_ app: AppModel) {
        let correction = Correction(original: app.draft, corrected: "A corrected draft.", explanation: "Grammar corrected.")
        app.draftCorrection = correction
        app.externalCorrection = correction
        app.draftBusy = true
        app.draftStatus = "An old draft result"
        app.externalStatus = "An old input result"
    }

    @MainActor
    private static func assertSuggestionsCleared(_ app: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(app.draftCorrection, file: file, line: line)
        XCTAssertNil(app.externalCorrection, file: file, line: line)
        XCTAssertFalse(app.draftBusy, file: file, line: line)
        XCTAssertEqual(app.draftStatus, "", file: file, line: line)
        XCTAssertEqual(app.externalStatus, "", file: file, line: line)
    }

    func testModelChangeClearsResultsOutsideSettingsView() async throws {
        try await MainActor.run {
            try Self.withModel { app, defaults in
                app.section = "Write"
                app.model = "old-model"
                Self.seedSuggestions(app)
                app.checkingConnection = true

                app.model = "new-model"

                Self.assertSuggestionsCleared(app)
                XCTAssertFalse(app.checkingConnection)
                XCTAssertEqual(defaults.string(forKey: "model"), "new-model")
                XCTAssertEqual(app.configuration.model, "new-model")
            }
        }
    }

    func testServerChangeClearsResultsAndDiscoveryOutsideSettingsView() async throws {
        try await MainActor.run {
            try Self.withModel { app, defaults in
                app.section = "Write"
                app.model = "selected-model"
                app.models = ["selected-model", "another-model"]
                app.checkingConnection = true
                Self.seedSuggestions(app)

                app.baseURL = "http://127.0.0.1:4321"

                Self.assertSuggestionsCleared(app)
                XCTAssertFalse(app.checkingConnection)
                XCTAssertTrue(app.models.isEmpty)
                XCTAssertEqual(app.model, "selected-model")
                XCTAssertEqual(defaults.string(forKey: "baseURL"), "http://127.0.0.1:4321")
                XCTAssertEqual(app.configuration.baseURL, "http://127.0.0.1:4321")
            }
        }
    }

    func testProviderChangeResetsProviderSpecificSettingsAndResults() async throws {
        try await MainActor.run {
            try Self.withModel { app, defaults in
                app.section = "Write"
                app.baseURL = "http://127.0.0.1:4321"
                app.model = "lm-studio-model"
                app.models = ["lm-studio-model"]
                Self.seedSuggestions(app)

                app.provider = .ollama

                Self.assertSuggestionsCleared(app)
                XCTAssertEqual(app.baseURL, LocalProvider.ollama.defaultBaseURL)
                XCTAssertEqual(app.model, "")
                XCTAssertTrue(app.models.isEmpty)
                XCTAssertEqual(defaults.string(forKey: "provider"), LocalProvider.ollama.rawValue)
                XCTAssertEqual(defaults.string(forKey: "baseURL"), LocalProvider.ollama.defaultBaseURL)
                XCTAssertEqual(defaults.string(forKey: "model"), "")
            }
        }
    }

    func testConfigurationRestoresWithoutResettingSavedServerAndModel() async throws {
        try await MainActor.run {
            try Self.withModel { app, defaults in
                app.provider = .ollama
                app.baseURL = "http://127.0.0.1:4321"
                app.model = "my-downloaded-model:latest"

                let restored = Self.makeApp(defaults)
                defer { restored.monitor.stop() }

                XCTAssertEqual(restored.configuration, app.configuration)
                XCTAssertFalse(restored.enabled)
                XCTAssertFalse(restored.monitor.isEnabled)
                XCTAssertNil(restored.draftCorrection)
                XCTAssertNil(restored.externalCorrection)
            }
        }
    }

    func testLMStudioRestoresCustomAddressWithoutLosingSavedModel() async throws {
        try await MainActor.run {
            try Self.withModel { app, defaults in
                app.baseURL = "http://127.0.0.1:4321"
                app.model = "lm-studio-local-model"

                let restored = Self.makeApp(defaults)
                defer { restored.monitor.stop() }

                XCTAssertEqual(restored.configuration, app.configuration)
                XCTAssertEqual(defaults.string(forKey: "model"), "lm-studio-local-model")
                XCTAssertFalse(restored.monitor.isEnabled)
            }
        }
    }

    func testPerAppGrantAndRevocationPersistWithoutGrantingOtherApps() async throws {
        try await MainActor.run {
            try Self.withModel { app, defaults in
                let first = AppPermission(id: "test.EnglishCorrect.AppModel.first", name: "First test editor", allowed: false)
                let second = AppPermission(id: "test.EnglishCorrect.AppModel.second", name: "Second test editor", allowed: false)
                app.setPermission(first, allowed: true)
                app.setPermission(second, allowed: false)

                XCTAssertEqual(app.allowedIDs, [first.id])
                XCTAssertEqual(app.monitor.allowedBundleIDs, [first.id])
                XCTAssertEqual(app.allowedCount, 1)
                XCTAssertFalse(app.monitor.isEnabled)

                let restored = Self.makeApp(defaults)
                defer { restored.monitor.stop() }
                XCTAssertEqual(restored.allowedIDs, [first.id])
                XCTAssertEqual(restored.permissions.count, 2)
                XCTAssertTrue(restored.runningApps.contains { $0.id == first.id && $0.allowed })
                XCTAssertTrue(restored.runningApps.contains { $0.id == second.id && !$0.allowed })
                XCTAssertFalse(restored.enabled)

                restored.setPermission(first, allowed: false)

                let afterRevocation = Self.makeApp(defaults)
                defer { afterRevocation.monitor.stop() }
                XCTAssertTrue(afterRevocation.allowedIDs.isEmpty)
                XCTAssertTrue(afterRevocation.monitor.allowedBundleIDs.isEmpty)
                XCTAssertEqual(afterRevocation.permissions.count, 2)
                XCTAssertEqual(afterRevocation.permissions.first { $0.id == first.id }?.allowed, false)
            }
        }
    }

    func testEveryLaunchStartsPausedEvenWithSavedAppPermission() async throws {
        try await MainActor.run {
            try Self.withModel { app, defaults in
                let fakeApp = AppPermission(id: "test.EnglishCorrect.AppModel.saved", name: "Saved test editor", allowed: false)
                app.setPermission(fakeApp, allowed: true)
                // Even a prior preference cannot opt the next session into reading.
                defaults.set(true, forKey: "enabled")

                let firstLaunch = Self.makeApp(defaults)
                defer { firstLaunch.monitor.stop() }
                let secondLaunch = Self.makeApp(defaults)
                defer { secondLaunch.monitor.stop() }

                for launch in [firstLaunch, secondLaunch] {
                    XCTAssertFalse(launch.enabled)
                    XCTAssertFalse(launch.monitor.isEnabled)
                    XCTAssertEqual(launch.allowedIDs, [fakeApp.id])
                    XCTAssertNil(launch.externalCorrection)
                }
            }
        }
    }

    func testDraftEditRejectsStaleApplyWithoutViewCallback() async throws {
        try await MainActor.run {
            try Self.withModel { app, _ in
                let original = "She don't like apples."
                app.draft = original
                app.draftCorrection = Correction(original: original, corrected: "She doesn't like apples.", explanation: "Subject agreement.")
                app.draft = "I prefer oranges."

                app.applyDraft()

                XCTAssertEqual(app.draft, "I prefer oranges.")
                XCTAssertNil(app.draftCorrection)
                XCTAssertFalse(app.draftBusy)
                XCTAssertEqual(app.draftStatus, "")
            }
        }
    }

    func testUnicodeEncodingChangeRejectsStaleApply() async throws {
        try await MainActor.run {
            try Self.withModel { app, _ in
                let original = "Cafe\u{301} are open."
                let edited = "Café are open."
                app.draftCorrection = Correction(original: original, corrected: "Café is open.", explanation: "Subject agreement.")
                app.draft = edited

                app.applyDraft()

                XCTAssertTrue(app.draft.utf8.elementsEqual(edited.utf8))
                XCTAssertNil(app.draftCorrection)
            }
        }
    }

    func testUnchangedDraftAppliesOnlyAfterExplicitAction() async throws {
        try await MainActor.run {
            try Self.withModel { app, _ in
                let original = "She don't like apples."
                let corrected = "She doesn't like apples."
                app.draft = original
                app.draftCorrection = Correction(original: original, corrected: corrected, explanation: "Subject agreement.")
                XCTAssertEqual(app.draft, original)

                app.applyDraft()

                XCTAssertEqual(app.draft, corrected)
                XCTAssertNil(app.draftCorrection)
                XCTAssertEqual(app.draftStatus, "Suggestion applied.")
            }
        }
    }
}
