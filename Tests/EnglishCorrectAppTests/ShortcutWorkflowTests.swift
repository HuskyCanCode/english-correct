import AppKit
import ApplicationServices
import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

@MainActor
final class ShortcutWorkflowTests: XCTestCase {
    /// Opt-in integration: synthetic text goes to the existing loopback server;
    /// no real application input or Accessibility permission is used.
    func testLiveLocalModelChecksWholeInputAndSelectedSentenceWhilePaused() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ENGLISH_CORRECT_LIVE_SHORTCUT_TEST"] == "1" else {
            throw XCTSkip("Set ENGLISH_CORRECT_LIVE_SHORTCUT_TEST=1 to test the running local AI server.")
        }
        let model = environment["ENGLISH_CORRECT_TEST_MODEL"] ?? "qwen2.5-1.5b-instruct:2"
        let fixture = try await ShortcutFixture(liveModel: model)
        defer { fixture.close() }
        let prefix = "I is happy. "
        let selected = "She go to school yesterday."
        let wholeInput = prefix + selected
        fixture.backend.text = wholeInput
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertFalse(fixture.monitor.isEnabled)

        fixture.app.triggerShortcut()
        await waitUntil(timeoutSeconds: 75) { !fixture.app.externalBusy }
        let wholeCorrection = try XCTUnwrap(fixture.app.externalCorrection, fixture.app.externalStatus)
        XCTAssertEqual(fixture.client.requests.map(\.text), [wholeInput])
        XCTAssertEqual(wholeCorrection.original, wholeInput)
        XCTAssertTrue(wholeCorrection.corrected.contains("I am happy"), wholeCorrection.corrected)
        XCTAssertTrue(wholeCorrection.corrected.contains("She went to school yesterday"), wholeCorrection.corrected)
        XCTAssertEqual(fixture.backend.text, wholeInput)
        XCTAssertTrue(fixture.backend.writes.isEmpty)
        fixture.app.applyExternal()
        XCTAssertEqual(fixture.backend.text, wholeCorrection.corrected)

        // Leave the first sentence deliberately wrong. Only the selected second
        // sentence may be sent to the model or replaced in the input.
        fixture.backend.text = wholeInput
        fixture.backend.selection = NSRange(location: prefix.utf16.count, length: selected.utf16.count)
        fixture.backend.selectionSettable = true
        fixture.backend.writes.removeAll()
        fixture.app.triggerShortcut()
        await waitUntil(timeoutSeconds: 75) { !fixture.app.externalBusy }
        let selectedCorrection = try XCTUnwrap(fixture.app.externalCorrection, fixture.app.externalStatus)
        XCTAssertEqual(fixture.client.requests.map(\.text), [wholeInput, selected])
        XCTAssertEqual(selectedCorrection.original, selected)
        XCTAssertEqual(selectedCorrection.corrected, "She went to school yesterday.")
        XCTAssertEqual(fixture.app.externalScope, "Selected text")
        XCTAssertEqual(fixture.backend.text, wholeInput)
        fixture.app.applyExternal()
        XCTAssertEqual(fixture.backend.writes, [kAXSelectedTextAttribute])
        XCTAssertTrue(fixture.backend.text.utf8.elementsEqual((prefix + selectedCorrection.corrected).utf8))
        XCTAssertFalse(fixture.app.enabled)
        print("Live shortcut model: \(model); whole input: \(wholeCorrection.corrected); selected-only result: \(fixture.backend.text)")
    }

    func testShortcutChecksWholeInputAndAppliesOnlyAfterUserActionWhilePaused() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertFalse(fixture.monitor.isEnabled)

        fixture.app.triggerShortcut()

        XCTAssertTrue(fixture.app.externalBusy)
        XCTAssertEqual(fixture.app.externalScope, "Entire input")
        await waitUntil { fixture.app.externalCorrection != nil }
        XCTAssertEqual(fixture.client.requests.map(\.text), ["She go yesterday."])
        XCTAssertEqual(fixture.client.requests.first?.configuration.model, "test-local-model")
        XCTAssertEqual(fixture.backend.text, "She go yesterday.")
        XCTAssertTrue(fixture.backend.writes.isEmpty)
        XCTAssertTrue(fixture.app.externalCanApply)
        XCTAssertFalse(fixture.app.externalBusy)

        fixture.app.applyExternal()

        XCTAssertEqual(fixture.backend.text, "She went yesterday.")
        XCTAssertEqual(fixture.backend.writes, [kAXValueAttribute])
        XCTAssertNil(fixture.app.externalCorrection)
        XCTAssertFalse(fixture.app.enabled)
    }

    func testSelectedPassageAloneIsSentAndAppliedAtItsExactOffsets() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        let sentence = "She go yesterday."
        let prefix = "Cafe\u{0301} 😊 " + sentence + "\n"
        let suffix = "\nPRIVATE SUFFIX " + sentence
        fixture.backend.text = prefix + sentence + suffix
        fixture.backend.selection = NSRange(location: prefix.utf16.count, length: sentence.utf16.count)
        fixture.backend.selectionSettable = true

        fixture.app.triggerShortcut()
        await waitUntil { fixture.app.externalCorrection != nil }

        XCTAssertEqual(fixture.client.requests.map(\.text), [sentence])
        XCTAssertEqual(fixture.app.externalScope, "Selected text")
        XCTAssertTrue(fixture.backend.writes.isEmpty)

        fixture.app.applyExternal()

        XCTAssertEqual(fixture.backend.writes, [kAXSelectedTextAttribute])
        XCTAssertTrue(fixture.backend.text.utf8.elementsEqual((prefix + "She went yesterday." + suffix).utf8))
    }

    func testAutomaticPausedPollCannotClearPendingManualRequestOrItsResult() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.client.holdResponses = true
        fixture.app.triggerShortcut()
        await waitUntil { fixture.client.pendingCount == 1 }

        fixture.monitor.poll()

        XCTAssertTrue(fixture.app.externalBusy)
        XCTAssertEqual(fixture.app.externalScope, "Entire input")
        fixture.client.finish()
        await waitUntil { fixture.app.externalCorrection != nil }
        fixture.monitor.poll()
        XCTAssertEqual(fixture.app.externalCorrection?.corrected, "She went yesterday.")
        XCTAssertFalse(fixture.app.enabled)
    }

    func testUnchangedManualResultStaysVisibleAsNoChanges() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.client.correctedText = nil
        fixture.app.triggerShortcut()
        await waitUntil { !fixture.app.externalBusy }

        XCTAssertEqual(fixture.client.requests.count, 1)
        XCTAssertNil(fixture.app.externalCorrection)
        XCTAssertEqual(fixture.app.externalStatus, "Looks good. No changes suggested.")
        XCTAssertEqual(fixture.app.externalScope, "Entire input")
        XCTAssertTrue(fixture.backend.writes.isEmpty)
    }

    func testDeniedOSOrAppPermissionNeverReadsTextOrCallsModel() async throws {
        for deniedOS in [true, false] {
            let fixture = try await ShortcutFixture(allowed: deniedOS)
            defer { fixture.close() }
            fixture.backend.isTrusted = !deniedOS
            fixture.backend.operations.removeAll()
            fixture.app.triggerShortcut()
            await settle()

            XCTAssertTrue(fixture.client.requests.isEmpty)
            XCTAssertTrue(fixture.backend.operations.isEmpty)
            XCTAssertFalse(fixture.app.externalBusy)
            XCTAssertNil(fixture.app.externalCorrection)
            XCTAssertTrue(fixture.app.externalNeedsSetup)
            XCTAssertFalse(fixture.app.externalStatus.isEmpty)

            var openedSettings = false
            fixture.app.onOpenSettings = { openedSettings = true }
            fixture.app.openExternalSettings()

            XCTAssertTrue(openedSettings)
            XCTAssertEqual(fixture.app.section, "Setup")
            XCTAssertFalse(fixture.app.externalNeedsSetup)
            XCTAssertTrue(fixture.client.requests.isEmpty)
        }
    }

    func testModelFailureIsVisibleAndDoesNotChangeInput() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.client.failure = .connectionFailed
        fixture.app.triggerShortcut()
        await waitUntil { !fixture.app.externalBusy }

        XCTAssertEqual(fixture.app.externalStatus, LocalAIError.connectionFailed.localizedDescription)
        XCTAssertTrue(fixture.app.externalNeedsSetup)
        XCTAssertFalse(fixture.app.readyInApp)
        XCTAssertFalse(fixture.app.readyInOtherApps)
        XCTAssertFalse(fixture.app.enabled)
        XCTAssertNil(fixture.app.externalCorrection)
        XCTAssertEqual(fixture.backend.text, "She go yesterday.")
        XCTAssertTrue(fixture.backend.writes.isEmpty)

        let configuration = fixture.app.configuration
        var openedSettings = false
        fixture.app.onOpenSettings = { openedSettings = true }
        fixture.app.openExternalSettings()

        XCTAssertTrue(openedSettings)
        XCTAssertEqual(fixture.app.section, "Setup")
        XCTAssertFalse(fixture.app.externalNeedsSetup)
        XCTAssertEqual(fixture.app.configuration, configuration)
        XCTAssertEqual(fixture.backend.text, "She go yesterday.")
        XCTAssertTrue(fixture.backend.writes.isEmpty)
    }

    func testUnreadableModelReplyOpensModelsWithoutChangingConfigurationOrInput() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        let configuration = fixture.app.configuration
        let input = fixture.backend.text
        fixture.client.failure = .invalidResponse
        fixture.app.triggerShortcut()
        await waitUntil { !fixture.app.externalBusy }

        XCTAssertEqual(fixture.app.externalStatus, LocalAIError.invalidResponse.localizedDescription)
        XCTAssertTrue(fixture.app.externalNeedsSetup)
        XCTAssertTrue(fixture.app.readyInApp, "An unreadable reply does not invalidate the already verified local server.")
        XCTAssertNil(fixture.app.externalCorrection)
        XCTAssertEqual(fixture.client.requests.count, 1)
        var settingsOpens = 0
        fixture.app.onOpenSettings = { settingsOpens += 1 }

        fixture.app.openExternalSettings()

        XCTAssertEqual(settingsOpens, 1)
        XCTAssertEqual(fixture.app.section, "Models")
        XCTAssertEqual(fixture.app.configuration, configuration)
        XCTAssertEqual(fixture.defaults.string(forKey: "provider"), configuration.provider.rawValue)
        XCTAssertEqual(fixture.defaults.string(forKey: "model"), configuration.model)
        XCTAssertEqual(fixture.backend.text, input)
        XCTAssertTrue(fixture.backend.writes.isEmpty)
        XCTAssertFalse(fixture.app.externalNeedsSetup)
        XCTAssertEqual(fixture.client.requests.count, 1, "Opening Models must not send the input again.")
        XCTAssertFalse(fixture.app.enabled)
    }

    func testChangedSelectionFocusInputOrAccessRejectsCancellationIgnoringResponse() async throws {
        let changes: [(ShortcutFixture) -> Void] = [
            { $0.backend.selection = NSRange(location: 0, length: 3) },
            { $0.backend.focused = AXUIElementCreateApplication(93_002) },
            { $0.backend.text = "New text typed while waiting." },
            { $0.backend.isTrusted = false },
            { $0.app.setPermission(ShortcutFixture.permission, allowed: false) },
            { $0.backend.frontmostApplication = MonitoredApplication(pid: 93_002, bundleID: "test.other", name: "Other") }
        ]
        for change in changes {
            let fixture = try await ShortcutFixture()
            defer { fixture.close() }
            fixture.client.holdResponses = true
            fixture.app.triggerShortcut()
            await waitUntil { fixture.client.pendingCount == 1 }

            change(fixture)
            fixture.app.validateManualTarget()

            XCTAssertFalse(fixture.app.externalBusy)
            XCTAssertNil(fixture.app.externalCorrection)
            fixture.client.finish()
            await waitUntil { fixture.client.returnedResponses == 1 }
            await settle()
            XCTAssertNil(fixture.app.externalCorrection)
            XCTAssertFalse(fixture.app.externalBusy)
            XCTAssertTrue(fixture.backend.writes.isEmpty)
        }
    }

    func testChangingModelCancelsPendingManualRequestAndRejectsLateResult() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.client.holdResponses = true
        fixture.app.triggerShortcut()
        await waitUntil { fixture.client.pendingCount == 1 }

        fixture.app.model = "another-local-model"

        XCTAssertFalse(fixture.app.externalBusy)
        XCTAssertNil(fixture.app.externalCorrection)
        XCTAssertEqual(fixture.app.externalStatus, "")
        fixture.client.finish()
        await waitUntil { fixture.client.returnedResponses == 1 }
        await settle()
        XCTAssertNil(fixture.app.externalCorrection)
        XCTAssertTrue(fixture.backend.writes.isEmpty)
    }

    func testNewerShortcutResultSurvivesOlderCancellationIgnoringResponse() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.client.holdResponses = true
        fixture.app.triggerShortcut()
        await waitUntil { fixture.client.pendingCount == 1 }
        fixture.backend.text = "I has books."
        fixture.app.triggerShortcut()
        await waitUntil { fixture.client.pendingCount == 2 }

        fixture.client.finish(at: 1, corrected: "I have books.")
        await waitUntil { fixture.app.externalCorrection?.corrected == "I have books." }
        fixture.client.finish(at: 0, corrected: "She went yesterday.")
        await waitUntil { fixture.client.returnedResponses == 2 }
        await settle()

        XCTAssertEqual(fixture.app.externalCorrection?.original, "I has books.")
        XCTAssertEqual(fixture.app.externalCorrection?.corrected, "I have books.")
        XCTAssertFalse(fixture.app.externalBusy)
        fixture.app.applyExternal()
        XCTAssertEqual(fixture.backend.text, "I have books.")
    }

    func testSelectionChangedAfterSuggestionRejectsApplyWithoutTimer() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.app.triggerShortcut()
        await waitUntil { fixture.app.externalCorrection != nil }
        fixture.backend.selection = NSRange(location: 4, length: 2)

        fixture.app.applyExternal()

        XCTAssertTrue(fixture.backend.writes.isEmpty)
        XCTAssertEqual(fixture.backend.text, "She go yesterday.")
        XCTAssertNil(fixture.app.externalCorrection)
        XCTAssertFalse(fixture.app.externalStatus.isEmpty)
    }

    func testDismissCancelsPendingRequestAndKeepsLateResultHidden() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.client.holdResponses = true
        fixture.app.triggerShortcut()
        await waitUntil { fixture.client.pendingCount == 1 }

        fixture.app.dismissExternal()
        fixture.client.finish()
        await waitUntil { fixture.client.returnedResponses == 1 }
        await settle()

        XCTAssertNil(fixture.app.externalCorrection)
        XCTAssertEqual(fixture.app.externalStatus, "")
        XCTAssertEqual(fixture.app.externalScope, "")
        XCTAssertFalse(fixture.app.externalBusy)
    }

    func testShortcutSupportsOneCharacterInputWithoutEnablingAutomaticChecks() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.backend.text = "i"
        fixture.client.correctedText = "I"
        fixture.app.triggerShortcut()
        await waitUntil { fixture.app.externalCorrection != nil }

        XCTAssertEqual(fixture.client.requests.map(\.text), ["i"])
        XCTAssertEqual(fixture.app.externalCorrection?.corrected, "I")
        XCTAssertFalse(fixture.app.enabled)
        fixture.app.applyExternal()
        XCTAssertEqual(fixture.backend.text, "I")
    }

    func testUnsupportedDirectEditingStillShowsSuggestionWithoutApply() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.backend.valueSettable = false
        fixture.app.triggerShortcut()
        await waitUntil { fixture.app.externalCorrection != nil }

        XCTAssertEqual(fixture.app.externalCorrection?.corrected, "She went yesterday.")
        XCTAssertFalse(fixture.app.externalCanApply)
        XCTAssertTrue(fixture.app.externalStatus.contains("Copy"))
        fixture.app.applyExternal()
        XCTAssertTrue(fixture.backend.writes.isEmpty)
    }

    func testBlankShortcutNeverReviewsOrBuildsAPopup() async throws {
        for text in ["", " \t\n", "\u{00A0}\u{2003}\n"] {
            let fixture = try await ShortcutFixture()
            defer { fixture.close() }
            let panel = attachHiddenPanel(to: fixture)
            let initialView = panel.panel.contentView
            fixture.backend.text = text

            fixture.app.triggerShortcut()
            await settle()

            assertQuiet(fixture)
            XCTAssertTrue(fixture.client.requests.isEmpty)
            XCTAssertTrue(panel.panel.contentView === initialView, "A blank shortcut must not build even a guidance popup.")
        }
    }

    func testWhitespaceSelectionDoesNotReviewTheSurroundingSentence() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.backend.text = "She go.   I has books."
        fixture.backend.selection = NSRange(location: 7, length: 3)
        fixture.app.triggerShortcut()
        await settle()

        assertQuiet(fixture)
        XCTAssertTrue(fixture.client.requests.isEmpty)
    }

    func testClearingPendingManualReviewDismissesWithoutChangedInputPopup() async throws {
        for text in ["", " \n\t"] {
            let fixture = try await ShortcutFixture()
            defer { fixture.close() }
            let panel = attachHiddenPanel(to: fixture)
            fixture.client.holdResponses = true
            fixture.app.triggerShortcut()
            await waitUntil { fixture.client.pendingCount == 1 }
            let loadingView = panel.panel.contentView

            fixture.backend.text = text
            fixture.app.validateManualTarget()
            assertQuiet(fixture)
            XCTAssertTrue(panel.panel.contentView === loadingView, "Clearing must hide the popup, not replace it with a changed-input message.")

            fixture.client.finish()
            await waitUntil { fixture.client.returnedResponses == 1 }
            await settle()
            assertQuiet(fixture)
            XCTAssertEqual(fixture.client.requests.count, 1)
            XCTAssertTrue(panel.panel.contentView === loadingView, "A late response must not recreate the popup.")
        }
    }

    func testEmptyFieldAtResponseTimeStaysQuietBeforeValidationTimerRuns() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.client.holdResponses = true
        fixture.app.triggerShortcut()
        await waitUntil { fixture.client.pendingCount == 1 }
        fixture.backend.text = ""
        fixture.client.finish()
        await waitUntil { fixture.client.returnedResponses == 1 }
        await settle()

        assertQuiet(fixture)
    }

    func testClearingReadySuggestionAllowsFreshReviewAfterTypingAgain() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.app.triggerShortcut()
        await waitUntil { fixture.app.externalCorrection != nil }
        fixture.backend.text = ""
        fixture.app.validateManualTarget()
        assertQuiet(fixture)

        fixture.backend.text = "I has books."
        fixture.client.correctedText = "I have books."
        fixture.app.triggerShortcut()
        await waitUntil { fixture.app.externalCorrection != nil }
        XCTAssertEqual(fixture.client.requests.map(\.text), ["She go yesterday.", "I has books."])
        XCTAssertEqual(fixture.app.externalCorrection?.corrected, "I have books.")
    }

    func testDeletingInStagesDoesNotLeaveAChangedInputNotice() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        let panel = attachHiddenPanel(to: fixture)
        fixture.app.triggerShortcut()
        await waitUntil { fixture.app.externalCorrection != nil }
        let suggestionView = panel.panel.contentView

        for text in ["She go", "She", ""] {
            fixture.backend.text = text
            fixture.app.validateManualTarget()
            fixture.monitor.poll()
            assertQuiet(fixture)
            XCTAssertTrue(panel.panel.contentView === suggestionView, "Deleting must not leave a replacement status popup.")
        }
        XCTAssertEqual(fixture.client.requests.count, 1)
    }

    func testApplyAndCopyAfterClearingAreQuietAndNeverWrite() async throws {
        for apply in [true, false] {
            let fixture = try await ShortcutFixture()
            defer { fixture.close() }
            let panel = attachHiddenPanel(to: fixture)
            fixture.app.triggerShortcut()
            await waitUntil { fixture.app.externalCorrection != nil }
            let suggestionView = panel.panel.contentView
            fixture.backend.text = ""

            if apply { fixture.app.applyExternal() }
            else { fixture.app.copyExternal() }

            assertQuiet(fixture)
            XCTAssertTrue(panel.panel.contentView === suggestionView)
            XCTAssertEqual(fixture.backend.text, "")
        }
    }

    func testAutomaticReviewClearsAndIgnoresLateReplyForBlankInput() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        fixture.backend.text = " \n"
        fixture.app.setAutomaticSuggestions(true)
        fixture.monitor.poll()
        await settle()
        assertQuiet(fixture)
        XCTAssertTrue(fixture.client.requests.isEmpty)

        fixture.backend.text = "She go yesterday."
        fixture.client.holdResponses = true
        fixture.monitor.poll()
        await waitUntil(timeoutSeconds: 2) { fixture.client.pendingCount == 1 }
        fixture.backend.text = ""
        fixture.monitor.poll()
        assertQuiet(fixture)
        fixture.client.finish()
        await waitUntil { fixture.client.returnedResponses == 1 }
        await settle()
        assertQuiet(fixture)
        XCTAssertEqual(fixture.client.requests.count, 1)
    }

    func testBlankDraftNeverStartsReview() async throws {
        let fixture = try await ShortcutFixture()
        defer { fixture.close() }
        for text in ["", " \t\n"] {
            fixture.app.draft = text
            fixture.app.checkDraft()
            XCTAssertFalse(fixture.app.draftBusy)
            XCTAssertNil(fixture.app.draftCorrection)
            XCTAssertEqual(fixture.app.draftStatus, "")
        }
    }

    private func attachHiddenPanel(to fixture: ShortcutFixture) -> SuggestionPanel {
        _ = NSApplication.shared
        let panel = SuggestionPanel(model: fixture.app, presentsWindows: false)
        fixture.app.panel = panel
        return panel
    }

    private func assertQuiet(_ fixture: ShortcutFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(fixture.app.externalCorrection, file: file, line: line)
        XCTAssertFalse(fixture.app.externalBusy, file: file, line: line)
        XCTAssertFalse(fixture.app.externalNeedsSetup, file: file, line: line)
        XCTAssertFalse(fixture.app.externalCanApply, file: file, line: line)
        XCTAssertEqual(fixture.app.externalStatus, "", file: file, line: line)
        XCTAssertEqual(fixture.app.externalScope, "", file: file, line: line)
        XCTAssertTrue(fixture.backend.writes.isEmpty, file: file, line: line)
        XCTAssertFalse(fixture.app.panel?.panel.isVisible ?? false, file: file, line: line)
    }

    private func waitUntil(timeoutSeconds: TimeInterval = 1,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "The expected shortcut state was not reached.", file: file, line: line)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class ShortcutFixture {
    static let permission = AppPermission(id: ShortcutBackend.bundleID, name: "Test Editor", allowed: true)
    let suite = "EnglishCorrect.ShortcutWorkflowTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let backend: ShortcutBackend
    let monitor: AccessibilityMonitor
    let client: ShortcutClient
    let app: AppModel

    init(allowed: Bool = true, liveModel: String? = nil) async throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(liveModel ?? "test-local-model", forKey: "model")
        defaults.set(LocalProvider.lmStudio.rawValue, forKey: "provider")
        defaults.set("http://127.0.0.1:1234", forKey: "baseURL")
        defaults.set(try JSONEncoder().encode([
            AppPermission(id: Self.permission.id, name: Self.permission.name, allowed: allowed)
        ]), forKey: "appPermissions")
        backend = ShortcutBackend()
        monitor = AccessibilityMonitor(backend: backend)
        client = ShortcutClient()
        client.useLiveModel = liveModel != nil
        let client = client
        let selectedModel = liveModel ?? "test-local-model"
        app = AppModel(defaults: defaults, monitor: monitor, startMonitoring: false,
                       listModels: { configuration in
            if liveModel != nil { return try await LocalAIClient(configuration: configuration).models() }
            return [selectedModel]
        }, correctText: { text, configuration in
            // Setup's fixed sample is separate from field-review request counts.
            // The opt-in live fixture checks its sample against the real server.
            if text == "She don't like apples." {
                if liveModel != nil { return try await LocalAIClient(configuration: configuration).correct(text) }
                return Correction(original: text, corrected: "She doesn't like apples.", explanation: "Verb agreement.")
            }
            return try await client.correct(text, configuration: configuration)
        })
        app.shortcutRegistered = true
        app.checkSetup()
        let deadline = Date().addingTimeInterval(liveModel == nil ? 1 : 75)
        while app.setupAIState == .checking && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(app.setupAIState, .ready, "The shortcut fixture must pass the same readiness check as the app.")
        guard app.setupAIState == .ready else { throw LocalAIError.invalidResponse }
    }

    func close() {
        app.model = ""
        app.dismissExternal()
        monitor.stop()
        client.cancelPending()
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Deliberately ignores Task cancellation until the test delivers a response,
/// exercising stale-result rejection rather than relying on cooperative servers.
@MainActor
private final class ShortcutClient {
    struct Request {
        let text: String
        let configuration: LocalAIConfiguration
    }
    var requests: [Request] = []
    var holdResponses = false
    var useLiveModel = false
    var correctedText: String? = "She went yesterday."
    var failure: LocalAIError?
    private var pending: [(String, CheckedContinuation<Correction, Error>)] = []
    private(set) var returnedResponses = 0
    var pendingCount: Int { pending.count }

    func correct(_ text: String, configuration: LocalAIConfiguration) async throws -> Correction {
        requests.append(Request(text: text, configuration: configuration))
        defer { returnedResponses += 1 }
        if useLiveModel { return try await LocalAIClient(configuration: configuration).correct(text) }
        if holdResponses {
            return try await withCheckedThrowingContinuation { pending.append((text, $0)) }
        }
        if let failure { throw failure }
        return Correction(original: text, corrected: correctedText ?? text, explanation: "Grammar corrected.")
    }

    func finish(at index: Int = 0, corrected: String = "She went yesterday.") {
        guard pending.indices.contains(index) else { XCTFail("No held request to finish."); return }
        let (text, continuation) = pending.remove(at: index)
        continuation.resume(returning: Correction(original: text, corrected: corrected, explanation: "Grammar corrected."))
    }

    func cancelPending() {
        let unfinished = pending
        pending.removeAll()
        for (_, continuation) in unfinished { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private final class ShortcutBackend: AccessibilityBackend {
    static let bundleID = "test.EnglishCorrect.ShortcutEditor"
    var isTrusted = true
    var frontmostApplication: MonitoredApplication? = MonitoredApplication(pid: 93_001, bundleID: bundleID, name: "Test Editor")
    var focused = AXUIElementCreateApplication(93_001)
    var text = "She go yesterday."
    var selection = NSRange(location: 0, length: 0)
    var valueSettable = true
    var selectionSettable = false
    var operations: [String] = []
    var writes: [String] = []

    func focusedElement(for pid: pid_t) -> AXUIElement? {
        operations.append("focused")
        return focused
    }

    func pid(of element: AXUIElement) -> pid_t? {
        operations.append("pid")
        return 93_001
    }

    func read(_ attribute: String, from element: AXUIElement) -> (AXError, CFTypeRef?) {
        operations.append("read:\(attribute)")
        switch attribute {
        case kAXRoleAttribute: return (.success, kAXTextAreaRole as CFString)
        case kAXSubroleAttribute: return (.attributeUnsupported, nil)
        case kAXEnabledAttribute: return (.success, kCFBooleanTrue)
        case kAXValueAttribute: return (.success, text as CFString)
        case kAXSelectedTextRangeAttribute:
            var range = CFRange(location: selection.location, length: selection.length)
            return (.success, AXValueCreate(.cfRange, &range))
        default: return (.attributeUnsupported, nil)
        }
    }

    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        operations.append("settable:\(attribute)")
        if attribute == kAXValueAttribute { return valueSettable }
        if attribute == kAXSelectedTextAttribute { return selectionSettable }
        return false
    }

    func write(_ attribute: String, value: CFTypeRef, to element: AXUIElement) -> AXError {
        writes.append(attribute)
        guard let replacement = value as? String else { return .illegalArgument }
        if attribute == kAXValueAttribute {
            text = replacement
        } else if attribute == kAXSelectedTextAttribute {
            text = (text as NSString).replacingCharacters(in: selection, with: replacement)
        } else {
            return .attributeUnsupported
        }
        return .success
    }
}
