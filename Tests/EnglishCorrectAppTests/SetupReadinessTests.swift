import AppKit
import ApplicationServices
import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

@MainActor
final class SetupReadinessTests: XCTestCase {
    /// Opt-in end-to-end setup uses only a synthetic sentence and an isolated
    /// preference suite. It never changes the user's selected provider or model.
    func testAppModelSetupWithLiveLocalModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ENGLISH_CORRECT_LIVE_SETUP"] == "1" else {
            throw XCTSkip("Set ENGLISH_CORRECT_LIVE_SETUP=1 to verify setup against the running local AI server.")
        }
        let suite = "EnglishCorrect.LiveSetupReadinessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let modelID = environment["ENGLISH_CORRECT_TEST_MODEL"] ?? "qwen2.5-1.5b-instruct:2"
        defaults.set(LocalProvider.lmStudio.rawValue, forKey: "provider")
        defaults.set("http://127.0.0.1:1234", forKey: "baseURL")
        defaults.set(modelID, forKey: "model")
        let backend = SetupTestAccessibilityBackend()
        backend.isTrusted = false
        let monitor = AccessibilityMonitor(backend: backend)
        // Production discovery and correction closures are deliberately used.
        let app = AppModel(defaults: defaults, monitor: monitor, startMonitoring: false)
        defer {
            app.model = ""
            monitor.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        app.checkSetup()
        let deadline = Date().addingTimeInterval(75)
        while app.setupAIState == .checking && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(app.setupAIState, .ready)
        XCTAssertTrue(app.readyInApp)
        XCTAssertFalse(app.readyInOtherApps)
        XCTAssertFalse(app.enabled)
        XCTAssertFalse(monitor.isEnabled)
        XCTAssertFalse(app.setupCompleted)
        XCTAssertTrue(backend.operations.isEmpty)
        print("Live setup checked \(modelID): \(app.setupAIState); automatic suggestions remain paused; zero field reads.")
    }

    func testSuccessfulSetupUsesOnlyFixedSampleAndNeverReadsAnApplicationField() async throws {
        let fixture = try SetupFixture()
        defer { fixture.close() }
        XCTAssertEqual(fixture.app.setupAIState, .unchecked)
        XCTAssertFalse(fixture.app.readyInApp)
        fixture.app.checkSetup()
        XCTAssertEqual(fixture.app.setupAIState, .checking)
        try await fixture.waitForSetup()

        XCTAssertEqual(fixture.app.setupAIState, .ready)
        XCTAssertTrue(fixture.app.readyInApp)
        XCTAssertTrue(fixture.app.readyInOtherApps)
        XCTAssertEqual(fixture.client.discoveryConfigurations, [fixture.app.configuration])
        XCTAssertEqual(fixture.client.sampleRequests.map(\.text), [SetupFixture.sample])
        XCTAssertEqual(fixture.client.sampleRequests.first?.configuration, fixture.app.configuration)
        XCTAssertTrue(fixture.backend.operations.isEmpty, "Setup must not inspect any focused input.")
        XCTAssertFalse(fixture.app.enabled, "A successful sample is not consent for automatic reading.")
        XCTAssertFalse(fixture.monitor.isEnabled)
        XCTAssertFalse(fixture.app.setupCompleted)
    }

    func testMissingModelAndUnavailableSelectionCannotBecomeReady() async throws {
        for missingSelection in [true, false] {
            let fixture = try SetupFixture(model: missingSelection ? "" : SetupFixture.modelID)
            defer { fixture.close() }
            fixture.client.availableModels = []
            fixture.app.checkSetup()
            try await fixture.waitForSetup()
            assertNotReady(fixture)
            XCTAssertTrue(fixture.client.sampleRequests.isEmpty)
            XCTAssertTrue(fixture.backend.operations.isEmpty)
        }
    }

    func testServerFailureAndSampleFailureCannotBecomeReady() async throws {
        for failDiscovery in [true, false] {
            let fixture = try SetupFixture()
            defer { fixture.close() }
            if failDiscovery { fixture.client.discoveryFailure = .connectionFailed }
            else { fixture.client.sampleFailure = .invalidResponse }
            fixture.app.checkSetup()
            try await fixture.waitForSetup()
            assertNotReady(fixture)
            XCTAssertEqual(fixture.client.sampleRequests.count, failDiscovery ? 0 : 1)
            XCTAssertTrue(fixture.backend.operations.isEmpty)
        }
    }

    func testUncorrectedOrWrongOriginalSampleCannotMarkAIReady() async throws {
        for wrongOriginal in [true, false] {
            let fixture = try SetupFixture()
            defer { fixture.close() }
            if wrongOriginal { fixture.client.originalOverride = "A different request." }
            else { fixture.client.correctedSample = SetupFixture.sample }
            fixture.app.checkSetup()
            try await fixture.waitForSetup()
            assertNotReady(fixture)
            XCTAssertTrue(fixture.backend.operations.isEmpty)
        }
    }

    func testRuntimeServiceFailureRequiresRecheckButUnreadableReplyPreservesReadiness() async throws {
        for failure in [LocalAIError.connectionFailed, .invalidResponse] {
            let fixture = try SetupFixture()
            defer { fixture.close() }
            try await fixture.makeReady()
            fixture.app.finishSetup(automatic: true, inAppOnly: false)
            fixture.backend.operations.removeAll()
            fixture.client.sampleFailure = failure
            fixture.app.draft = "I has books."
            fixture.app.checkDraft()
            try await setupEventually { !fixture.app.draftBusy }
            XCTAssertEqual(fixture.app.draftStatus, failure.localizedDescription)
            XCTAssertNil(fixture.app.draftCorrection)
            XCTAssertEqual(fixture.app.draft, "I has books.")
            XCTAssertTrue(fixture.backend.operations.isEmpty)
            if failure == .connectionFailed {
                XCTAssertFalse(fixture.app.readyInApp)
                XCTAssertFalse(fixture.app.enabled)
                XCTAssertFalse(fixture.monitor.isEnabled)
            } else {
                XCTAssertEqual(fixture.app.setupAIState, .ready)
                XCTAssertTrue(fixture.app.readyInApp)
                XCTAssertTrue(fixture.app.enabled)
            }
        }
    }

    func testSettingsChangeRejectsLateModelDiscoveryAndSampleResponses() async throws {
        for holdSample in [false, true] {
            let fixture = try SetupFixture()
            defer { fixture.close() }
            fixture.client.holdDiscovery = !holdSample
            fixture.client.holdSample = holdSample
            fixture.app.checkSetup()
            try await setupEventually { holdSample ? fixture.client.pendingSampleCount == 1 : fixture.client.pendingDiscoveryCount == 1 }

            fixture.app.baseURL = "http://127.0.0.1:4321"
            XCTAssertEqual(fixture.app.setupAIState, .unchecked)
            XCTAssertFalse(fixture.app.enabled)
            if holdSample { fixture.client.finishSample() }
            else { fixture.client.finishDiscovery() }
            try await setupEventually { holdSample ? fixture.client.returnedSamples == 1 : fixture.client.returnedDiscoveries == 1 }
            await settle()

            XCTAssertEqual(fixture.app.setupAIState, .unchecked)
            XCTAssertFalse(fixture.app.readyInApp)
            XCTAssertFalse(fixture.app.readyInOtherApps)
            if !holdSample { XCTAssertTrue(fixture.client.sampleRequests.isEmpty) }
            XCTAssertTrue(fixture.backend.operations.isEmpty)
        }
    }

    func testNewerSetupResultSurvivesOlderCancellationIgnoringFailure() async throws {
        let fixture = try SetupFixture()
        defer { fixture.close() }
        fixture.client.holdSample = true
        fixture.app.checkSetup()
        try await setupEventually { fixture.client.pendingSampleCount == 1 }
        fixture.app.checkSetup()
        try await setupEventually { fixture.client.pendingSampleCount == 2 }
        fixture.client.finishSample(at: 1)
        try await setupEventually { fixture.app.setupAIState == .ready }
        fixture.client.finishSample(at: 0, failure: .connectionFailed)
        try await setupEventually { fixture.client.returnedSamples == 2 }
        await settle()
        XCTAssertEqual(fixture.app.setupAIState, .ready)
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertTrue(fixture.backend.operations.isEmpty)
    }

    func testInsideAppCompletionRequiresNoAccessibilityAllowlistOrShortcut() async throws {
        let fixture = try SetupFixture(trusted: false, allowed: false, registered: false)
        defer { fixture.close() }
        try await fixture.makeReady()
        XCTAssertTrue(fixture.app.readyInApp)
        XCTAssertFalse(fixture.app.readyInOtherApps)
        fixture.app.finishSetup(automatic: false, inAppOnly: true)
        XCTAssertTrue(fixture.app.setupCompleted)
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertFalse(fixture.monitor.isEnabled)
        XCTAssertTrue(fixture.backend.operations.isEmpty)

        fixture.app.draft = "I has books."
        fixture.client.correctedSample = "I have books."
        fixture.app.checkDraft()
        try await setupEventually { !fixture.app.draftBusy }
        XCTAssertEqual(fixture.app.draftCorrection?.corrected, "I have books.")
        XCTAssertEqual(fixture.app.draft, "I has books.", "Readiness never applies a correction automatically.")
        XCTAssertTrue(fixture.backend.operations.isEmpty)
    }

    func testManualFinishNeverEnablesAutomaticSuggestions() async throws {
        let fixture = try SetupFixture()
        defer { fixture.close() }
        try await fixture.makeReady()
        fixture.app.finishSetup(automatic: false, inAppOnly: false)
        XCTAssertTrue(fixture.app.setupCompleted)
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertFalse(fixture.monitor.isEnabled)
        XCTAssertTrue(fixture.backend.operations.isEmpty)
    }

    func testExplicitAutomaticConsentRequiresEveryReadinessCondition() async throws {
        for missing in ["ai", "permission", "allowlist", "shortcut"] {
            let fixture = try SetupFixture(trusted: missing != "permission", allowed: missing != "allowlist", registered: missing != "shortcut")
            defer { fixture.close() }
            if missing != "ai" { try await fixture.makeReady() }
            XCTAssertFalse(fixture.app.readyInOtherApps)
            fixture.app.finishSetup(automatic: true, inAppOnly: false)
            fixture.app.setAutomaticSuggestions(true)
            XCTAssertFalse(fixture.app.enabled, "Missing \(missing) must block automatic reading.")
            XCTAssertFalse(fixture.monitor.isEnabled)
            XCTAssertTrue(fixture.backend.operations.isEmpty)
        }
        let complete = try SetupFixture()
        defer { complete.close() }
        try await complete.makeReady()
        XCTAssertFalse(complete.app.enabled)
        complete.app.finishSetup(automatic: true, inAppOnly: false)
        XCTAssertTrue(complete.app.setupCompleted)
        XCTAssertTrue(complete.app.enabled)
        XCTAssertTrue(complete.monitor.isEnabled)
    }

    func testPermissionShortcutAndConfigurationRevocationPauseAutomaticSuggestions() async throws {
        for revoke in ["permission", "allowlist", "shortcut", "model", "server"] {
            let fixture = try SetupFixture()
            defer { fixture.close() }
            try await fixture.makeReady()
            fixture.app.finishSetup(automatic: true, inAppOnly: false)
            XCTAssertTrue(fixture.app.enabled)
            let existing = Correction(original: fixture.app.draft, corrected: "A reviewed draft.", explanation: "Grammar.")
            fixture.app.draftCorrection = existing
            fixture.app.externalCorrection = existing
            switch revoke {
            case "permission": fixture.backend.isTrusted = false; fixture.app.updateConsent()
            case "allowlist": fixture.app.setPermission(SetupFixture.permission, allowed: false)
            case "shortcut": fixture.app.shortcutRegistered = false
            case "model": fixture.app.model = "another-local-model"
            default: fixture.app.baseURL = "http://127.0.0.1:4321"
            }
            XCTAssertFalse(fixture.app.enabled, "Revoking \(revoke) must pause automatic suggestions.")
            XCTAssertFalse(fixture.monitor.isEnabled)
            XCTAssertFalse(fixture.app.readyInOtherApps)
            XCTAssertNil(fixture.app.externalCorrection)
            if revoke == "model" || revoke == "server" {
                XCTAssertEqual(fixture.app.setupAIState, .unchecked)
                XCTAssertNil(fixture.app.draftCorrection)
            } else {
                XCTAssertEqual(fixture.app.setupAIState, .ready, "Input permission is independent of local AI readiness.")
                XCTAssertTrue(fixture.app.readyInApp)
                XCTAssertEqual(fixture.app.draftCorrection, existing)
            }
        }
    }

    func testPermissionLossAllowsSyntheticSetupCheckToFinishWithoutFieldReads() async throws {
        for revokeOS in [true, false] {
            let fixture = try SetupFixture()
            defer { fixture.close() }
            fixture.client.holdSample = true
            fixture.app.checkSetup()
            try await setupEventually { fixture.client.pendingSampleCount == 1 }
            if revokeOS { fixture.backend.isTrusted = false; fixture.app.updateConsent() }
            else { fixture.app.setPermission(SetupFixture.permission, allowed: false) }
            fixture.client.finishSample()
            try await fixture.waitForSetup()
            XCTAssertEqual(fixture.app.setupAIState, .ready)
            XCTAssertTrue(fixture.app.readyInApp)
            XCTAssertFalse(fixture.app.readyInOtherApps)
            XCTAssertFalse(fixture.app.enabled)
            XCTAssertFalse(fixture.monitor.isEnabled)
            XCTAssertTrue(fixture.backend.operations.isEmpty)
        }
    }

    func testEveryRelaunchIsPausedAndMustRecheckAIRegardlessOfSavedCompletion() async throws {
        let fixture = try SetupFixture()
        defer { fixture.close() }
        try await fixture.makeReady()
        fixture.app.finishSetup(automatic: true, inAppOnly: false)
        fixture.defaults.set(true, forKey: "enabled")
        fixture.defaults.set(true, forKey: "automaticSuggestions")
        let operationsBeforeRelaunch = fixture.backend.operations
        let newMonitor = AccessibilityMonitor(backend: fixture.backend)
        let relaunched = AppModel(defaults: fixture.defaults, monitor: newMonitor, startMonitoring: false,
                                  listModels: { _ in XCTFail("Launch must not contact a server."); return [] },
                                  correctText: { _, _ in XCTFail("Launch must not send text."); throw LocalAIError.connectionFailed })
        defer { newMonitor.stop() }
        XCTAssertTrue(relaunched.setupCompleted)
        XCTAssertFalse(relaunched.enabled)
        XCTAssertFalse(newMonitor.isEnabled)
        XCTAssertEqual(relaunched.setupAIState, .unchecked)
        XCTAssertFalse(relaunched.readyInApp)
        XCTAssertFalse(relaunched.readyInOtherApps)
        XCTAssertEqual(relaunched.allowedIDs, [SetupFixture.permission.id])
        XCTAssertEqual(fixture.backend.operations, operationsBeforeRelaunch, "Relaunch must not inspect a field.")
    }

    func testOpeningSetupPausesMonitoringWithoutReadingInputs() async throws {
        let fixture = try SetupFixture()
        defer { fixture.close() }
        try await fixture.makeReady()
        fixture.app.finishSetup(automatic: true, inAppOnly: false)
        fixture.backend.operations.removeAll()
        fixture.app.openSetup()
        XCTAssertEqual(fixture.app.section, "Setup")
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertFalse(fixture.monitor.isEnabled)
        XCTAssertTrue(fixture.backend.operations.isEmpty)
    }

    func testSelectedModelDeletionInvalidatesPendingSetupSample() async throws {
        let fixture = try SetupFixture()
        defer { fixture.close() }
        fixture.library.refresh()
        try await setupEventually { !fixture.library.checking }
        fixture.library.requestDeletion(ModelCatalog.recommendations[0])
        let request = try XCTUnwrap(fixture.library.pendingDeletion)
        fixture.client.holdSample = true
        fixture.app.checkSetup()
        try await setupEventually { fixture.client.pendingSampleCount == 1 }
        fixture.app.prepareForModelDeletion(request)
        fixture.client.finishSample()
        try await setupEventually { fixture.client.returnedSamples == 1 }
        await settle()
        XCTAssertFalse(fixture.app.readyInApp)
        XCTAssertFalse(fixture.app.readyInOtherApps)
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertFalse(fixture.monitor.isEnabled)
        XCTAssertTrue(fixture.backend.operations.isEmpty)
    }

    private func assertNotReady(_ fixture: SetupFixture, file: StaticString = #filePath, line: UInt = #line) {
        if case .failed(let message) = fixture.app.setupAIState { XCTAssertFalse(message.isEmpty, file: file, line: line) }
        else { XCTFail("An unsuccessful readiness check must explain its failure.", file: file, line: line) }
        XCTAssertFalse(fixture.app.readyInApp, file: file, line: line)
        XCTAssertFalse(fixture.app.readyInOtherApps, file: file, line: line)
        XCTAssertFalse(fixture.app.enabled, file: file, line: line)
        XCTAssertFalse(fixture.monitor.isEnabled, file: file, line: line)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }
}

@MainActor
final class AutomaticSetupVerificationTests: XCTestCase {
    func testSelectingModelVerifiesSampleAutomaticallyWithoutEnablingOrNavigating() async throws {
        let fixture = try SetupFixture(model: "")
        defer { fixture.close() }
        fixture.app.section = "Models"
        fixture.app.model = SetupFixture.modelID
        try await setupEventually(timeoutSeconds: 2) { fixture.app.setupAIState == .ready }
        XCTAssertEqual(fixture.client.discoveryConfigurations, [fixture.app.configuration])
        XCTAssertEqual(fixture.client.sampleRequests.map(\.text), [SetupFixture.sample])
        XCTAssertEqual(fixture.client.sampleRequests.first?.configuration, fixture.app.configuration)
        assertPausedAndUnread(fixture, section: "Models")
    }

    func testSuccessfulConnectionVerifiesRetainedAndNewlySelectedModelExactlyOnce() async throws {
        for alreadySelected in [true, false] {
            let fixture = try SetupFixture(model: alreadySelected ? SetupFixture.modelID : "")
            defer { fixture.close() }
            let initialConfiguration = fixture.app.configuration
            fixture.app.section = "Write"
            fixture.app.connect()
            try await setupEventually(timeoutSeconds: 2) { fixture.app.setupAIState == .ready }
            try await Task.sleep(nanoseconds: 850_000_000)
            XCTAssertEqual(fixture.app.model, SetupFixture.modelID)
            XCTAssertFalse(fixture.app.checkingConnection)
            XCTAssertEqual(fixture.app.models, [SetupFixture.modelID])
            XCTAssertEqual(fixture.client.sampleRequests.map(\.text), [SetupFixture.sample])
            XCTAssertEqual(fixture.client.discoveryConfigurations, [initialConfiguration, fixture.app.configuration])
            assertPausedAndUnread(fixture, section: "Write")
        }
    }

    func testRapidModelAndServerEditsVerifyOnlyFinalConfiguration() async throws {
        let fixture = try SetupFixture(model: "")
        defer { fixture.close() }
        fixture.app.section = "Models"
        fixture.client.availableModels = ["final-model"]
        fixture.app.model = "first-model"
        fixture.app.baseURL = "http://127.0.0.1:4321"
        try await Task.sleep(nanoseconds: 80_000_000)
        fixture.app.model = "second-model"
        fixture.app.baseURL = "http://127.0.0.1:4322"
        fixture.app.model = "final-model"
        let final = fixture.app.configuration
        try await setupEventually(timeoutSeconds: 2) { fixture.app.setupAIState == .ready }
        XCTAssertEqual(fixture.client.discoveryConfigurations, [final])
        XCTAssertEqual(fixture.client.sampleRequests.map(\.configuration), [final])
        XCTAssertEqual(fixture.client.sampleRequests.map(\.text), [SetupFixture.sample])
        assertPausedAndUnread(fixture, section: "Models")
    }

    func testClearingSelectionCancelsQueuedAndInFlightVerification() async throws {
        for inFlight in [false, true] {
            let fixture = try SetupFixture(model: "")
            defer { fixture.close() }
            fixture.client.holdSample = inFlight
            fixture.app.model = SetupFixture.modelID
            if inFlight { try await setupEventually(timeoutSeconds: 2) { fixture.client.pendingSampleCount == 1 } }
            fixture.app.model = ""
            if inFlight {
                fixture.client.finishSample()
                try await setupEventually { fixture.client.returnedSamples == 1 }
            }
            // Observe beyond the debounce interval so a canceled timer cannot
            // quietly enqueue a second sample after the assertion.
            try await Task.sleep(nanoseconds: 850_000_000)
            XCTAssertEqual(fixture.app.setupAIState, .unchecked)
            XCTAssertFalse(fixture.app.readyInApp)
            XCTAssertEqual(fixture.client.sampleRequests.count, inFlight ? 1 : 0)
            XCTAssertEqual(fixture.client.discoveryConfigurations.count, inFlight ? 1 : 0)
            assertPausedAndUnread(fixture, section: "Write")
        }
    }

    func testExplicitCheckCancelsQueuedDuplicateVerification() async throws {
        let fixture = try SetupFixture(model: "")
        defer { fixture.close() }
        fixture.app.model = SetupFixture.modelID
        fixture.app.checkSetup()
        try await fixture.waitForSetup()
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertEqual(fixture.app.setupAIState, .ready)
        XCTAssertEqual(fixture.client.discoveryConfigurations.count, 1)
        XCTAssertEqual(fixture.client.sampleRequests.map(\.text), [SetupFixture.sample])
        assertPausedAndUnread(fixture, section: "Write")
    }

    func testSlowConnectionDiscoverySupersedesQueuedVerification() async throws {
        let fixture = try SetupFixture(model: "")
        defer { fixture.close() }
        fixture.app.model = SetupFixture.modelID
        fixture.client.holdDiscovery = true
        fixture.app.connect()
        try await setupEventually { fixture.client.pendingDiscoveryCount == 1 }
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertTrue(fixture.app.checkingConnection)
        XCTAssertEqual(fixture.client.pendingDiscoveryCount, 1)
        XCTAssertEqual(fixture.client.discoveryConfigurations.count, 1)
        XCTAssertTrue(fixture.client.sampleRequests.isEmpty)

        fixture.client.holdDiscovery = false
        fixture.client.finishDiscovery()
        try await setupEventually(timeoutSeconds: 2) { fixture.app.setupAIState == .ready }
        XCTAssertEqual(fixture.client.discoveryConfigurations.count, 2)
        XCTAssertEqual(fixture.client.sampleRequests.map(\.text), [SetupFixture.sample])
        assertPausedAndUnread(fixture, section: "Write")
    }

    func testSelectedModelDeletionCancelsQueuedVerificationBeforeItReadsServer() async throws {
        let fixture = try SetupFixture(model: "")
        defer { fixture.close() }
        fixture.app.model = SetupFixture.modelID
        fixture.library.refresh()
        try await setupEventually { !fixture.library.checking }
        fixture.library.requestDeletion(ModelCatalog.recommendations[0])
        let request = try XCTUnwrap(fixture.library.pendingDeletion)
        fixture.app.prepareForModelDeletion(request)
        try await Task.sleep(nanoseconds: 850_000_000)
        XCTAssertEqual(fixture.app.setupAIState, .unchecked)
        XCTAssertTrue(fixture.client.discoveryConfigurations.isEmpty)
        XCTAssertTrue(fixture.client.sampleRequests.isEmpty)
        assertPausedAndUnread(fixture, section: "Write")
    }

    func testOldConfigurationReplyCannotOverwriteNewVerificationFailure() async throws {
        let fixture = try SetupFixture(model: "")
        defer { fixture.close() }
        fixture.client.availableModels = ["old-model", "new-model"]
        fixture.client.holdSample = true
        fixture.app.model = "old-model"
        try await setupEventually(timeoutSeconds: 2) { fixture.client.pendingSampleCount == 1 }
        fixture.app.model = "new-model"
        try await setupEventually(timeoutSeconds: 2) { fixture.client.pendingSampleCount == 2 }
        fixture.client.finishSample(at: 1, failure: .connectionFailed)
        try await setupEventually { fixture.client.returnedSamples == 1 && fixture.app.setupAIState != .checking }
        fixture.client.finishSample(at: 0)
        try await setupEventually { fixture.client.returnedSamples == 2 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(fixture.app.setupAIState, .failed(LocalAIError.connectionFailed.localizedDescription))
        XCTAssertFalse(fixture.app.readyInApp)
        XCTAssertEqual(fixture.client.sampleRequests.map { $0.configuration.model }, ["old-model", "new-model"])
        XCTAssertEqual(fixture.client.sampleRequests.map(\.text), [SetupFixture.sample, SetupFixture.sample])
        assertPausedAndUnread(fixture, section: "Write")
    }

    private func assertPausedAndUnread(_ fixture: SetupFixture, section: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.app.enabled, file: file, line: line)
        XCTAssertFalse(fixture.monitor.isEnabled, file: file, line: line)
        XCTAssertEqual(fixture.app.section, section, file: file, line: line)
        XCTAssertTrue(fixture.backend.operations.isEmpty, file: file, line: line)
    }
}

@MainActor
private func setupEventually(timeoutSeconds: TimeInterval = 0.8, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("Expected setup state was not reached.", file: file, line: line)
    throw SetupTestError.timedOut
}

private enum SetupTestError: Error { case timedOut }

@MainActor
private final class SetupFixture {
    static let sample = "She don't like apples."
    static let modelID = "qwen2.5-1.5b-instruct"
    static let permission = AppPermission(id: SetupTestAccessibilityBackend.bundleID, name: "Setup Test Editor", allowed: true)
    let suite = "EnglishCorrect.SetupReadinessTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let backend = SetupTestAccessibilityBackend()
    let client = SetupClient()
    let monitor: AccessibilityMonitor
    let library: ModelLibrary
    let app: AppModel

    init(trusted: Bool = true, allowed: Bool = true, registered: Bool = true, model: String = "qwen2.5-1.5b-instruct") throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(model, forKey: "model")
        defaults.set(try JSONEncoder().encode([AppPermission(id: Self.permission.id, name: Self.permission.name, allowed: allowed)]), forKey: "appPermissions")
        backend.isTrusted = trusted
        monitor = AccessibilityMonitor(backend: backend)
        library = ModelLibrary(defaults: defaults, backend: SetupLibraryBackend())
        let client = client
        app = AppModel(defaults: defaults, monitor: monitor, modelLibrary: library, startMonitoring: false,
                       listModels: { config in try await client.models(config) },
                       correctText: { text, config in try await client.correct(text, config: config) })
        app.shortcutRegistered = registered
    }

    func makeReady() async throws {
        app.checkSetup()
        try await waitForSetup()
        XCTAssertEqual(app.setupAIState, .ready)
    }

    func waitForSetup() async throws { try await setupEventually { self.app.setupAIState != .checking } }

    func close() {
        app.model = ""
        app.dismissExternal()
        monitor.stop()
        client.cancelPending()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Every Accessibility operation is recorded. The fake deliberately has no
/// readable field, so setup tests cannot touch another application's input.
@MainActor
final class SetupTestAccessibilityBackend: AccessibilityBackend {
    static let bundleID = "test.EnglishCorrect.SetupEditor"
    var isTrusted = true
    var frontmostApplication: MonitoredApplication? = .init(pid: 94_001, bundleID: bundleID, name: "Setup Test Editor")
    var operations: [String] = []
    func focusedElement(for pid: pid_t) -> AXUIElement? { operations.append("focused"); return nil }
    func pid(of element: AXUIElement) -> pid_t? { operations.append("pid"); return nil }
    func read(_ attribute: String, from element: AXUIElement) -> (AXError, CFTypeRef?) { operations.append("read:\(attribute)"); return (.noValue, nil) }
    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool { operations.append("settable:\(attribute)"); return false }
    func write(_ attribute: String, value: CFTypeRef, to element: AXUIElement) -> AXError { operations.append("write:\(attribute)"); return .cannotComplete }
}

@MainActor
private final class SetupClient {
    struct Request { let text: String; let configuration: LocalAIConfiguration }
    var availableModels = [SetupFixture.modelID]
    var discoveryFailure: LocalAIError?
    var sampleFailure: LocalAIError?
    var originalOverride: String?
    var correctedSample = "She doesn't like apples."
    var discoveryConfigurations: [LocalAIConfiguration] = []
    var sampleRequests: [Request] = []
    var holdDiscovery = false
    var holdSample = false
    private var pendingDiscoveries: [CheckedContinuation<[String], Error>] = []
    private var pendingSamples: [(String, CheckedContinuation<Correction, Error>)] = []
    private(set) var returnedDiscoveries = 0
    private(set) var returnedSamples = 0
    var pendingDiscoveryCount: Int { pendingDiscoveries.count }
    var pendingSampleCount: Int { pendingSamples.count }

    func models(_ config: LocalAIConfiguration) async throws -> [String] {
        discoveryConfigurations.append(config)
        defer { returnedDiscoveries += 1 }
        if holdDiscovery { return try await withCheckedThrowingContinuation { pendingDiscoveries.append($0) } }
        if let discoveryFailure { throw discoveryFailure }
        return availableModels
    }
    func correct(_ text: String, config: LocalAIConfiguration) async throws -> Correction {
        sampleRequests.append(Request(text: text, configuration: config))
        defer { returnedSamples += 1 }
        if holdSample { return try await withCheckedThrowingContinuation { pendingSamples.append((text, $0)) } }
        if let sampleFailure { throw sampleFailure }
        return Correction(original: originalOverride ?? text, corrected: correctedSample, explanation: "Verb agreement.")
    }
    func finishDiscovery() {
        guard !pendingDiscoveries.isEmpty else { XCTFail("No held discovery."); return }
        pendingDiscoveries.removeFirst().resume(returning: availableModels)
    }
    func finishSample(at index: Int = 0, failure: LocalAIError? = nil) {
        guard pendingSamples.indices.contains(index) else { XCTFail("No held sample."); return }
        let (text, continuation) = pendingSamples.remove(at: index)
        if let failure { continuation.resume(throwing: failure) }
        else { continuation.resume(returning: Correction(original: text, corrected: correctedSample, explanation: "Verb agreement.")) }
    }
    func cancelPending() {
        let discovery = pendingDiscoveries; pendingDiscoveries.removeAll()
        let samples = pendingSamples; pendingSamples.removeAll()
        for continuation in discovery { continuation.resume(throwing: CancellationError()) }
        for (_, continuation) in samples { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class SetupLibraryBackend: ModelLibraryBackend {
    func installed(_ config: LocalAIConfiguration) async throws -> [String] { [SetupFixture.modelID] }
    func start(_ spec: DownloadSpec, config: LocalAIConfiguration) async throws -> DownloadUpdate { throw ModelDownloadError.invalidSpecification }
    func poll(_ jobID: String, config: LocalAIConfiguration) async throws -> DownloadUpdate { throw ModelDownloadError.invalidSpecification }
    func pull(_ spec: DownloadSpec, config: LocalAIConfiguration, progress: @escaping @Sendable (ModelDownloadProgress) async -> Void) async throws { throw ModelDownloadError.invalidSpecification }
    func prepare(_ id: String, config: LocalAIConfiguration) async throws -> String { id }
    func delete(_ id: String, spec: DownloadSpec, config: LocalAIConfiguration) async throws -> [String] { [id] }
}
