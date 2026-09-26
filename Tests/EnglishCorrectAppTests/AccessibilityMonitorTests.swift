import AppKit
import ApplicationServices
import XCTest
import EnglishCorrectCore
@testable import EnglishCorrect

@MainActor
final class AccessibilityMonitorTests: XCTestCase {
    private func prepared() -> (AccessibilityMonitor, FakeAccessibilityBackend) {
        let backend = FakeAccessibilityBackend()
        let monitor = AccessibilityMonitor(backend: backend)
        monitor.allowedBundleIDs = [FakeAccessibilityBackend.bundleID]
        monitor.isEnabled = true
        return (monitor, backend)
    }

    private func correction(_ snapshot: FieldSnapshot, corrected: String = "She went to school yesterday.") -> Correction {
        Correction(original: snapshot.text, corrected: corrected, explanation: "Past tense.")
    }

    func testPausedDetectionMakesNoAccessibilityReads() async {
        let backend = FakeAccessibilityBackend()
        let monitor = AccessibilityMonitor(backend: backend)
        monitor.allowedBundleIDs = [FakeAccessibilityBackend.bundleID]
        XCTAssertNil(monitor.captureCurrent())
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testBlankPermittedFieldIsQuietEvenWhenSelectionIsUnavailable() async {
        for intent in [CaptureIntent.automatic, .shortcut] {
            let (monitor, backend) = prepared()
            backend.text = " \n\t"
            backend.selectionError = .attributeUnsupported
            backend.selectedTextError = .attributeUnsupported

            XCTAssertNil(monitor.captureCurrent(intent: intent))
            XCTAssertTrue(monitor.lastCaptureWasEmpty)
            XCTAssertFalse(backend.operations.contains("read:\(kAXSelectedTextRangeAttribute)"))
        }
    }

    func testBlankCaptureDoesNotSuppressLaterPermissionOrSelectionErrors() async {
        let (monitor, backend) = prepared()
        backend.text = ""
        XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
        XCTAssertTrue(monitor.lastCaptureWasEmpty)

        backend.isTrusted = false
        backend.operations.removeAll()
        XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
        XCTAssertFalse(monitor.lastCaptureWasEmpty)
        XCTAssertTrue(backend.operations.isEmpty)

        backend.isTrusted = true
        backend.text = "She go yesterday."
        backend.selectedRange = NSRange(location: 100, length: 2)
        XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
        XCTAssertFalse(monitor.lastCaptureWasEmpty)
    }

    func testOSPermissionDeniedMakesNoAccessibilityReads() async {
        let (monitor, backend) = prepared()
        backend.isTrusted = false
        XCTAssertNil(monitor.captureCurrent())
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testUnapprovedAppMakesNoAccessibilityReads() async {
        let (monitor, backend) = prepared()
        monitor.allowedBundleIDs = []
        XCTAssertNil(monitor.captureCurrent())
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testUnknownOrOwnAppMakesNoAccessibilityReads() async {
        for app in [
            nil,
            MonitoredApplication(pid: 91_001, bundleID: nil, name: "Unknown"),
            MonitoredApplication(pid: ProcessInfo.processInfo.processIdentifier,
                                 bundleID: FakeAccessibilityBackend.bundleID, name: "Self")
        ] {
            let (monitor, backend) = prepared()
            backend.frontmostApplication = app
            XCTAssertNil(monitor.captureCurrent())
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testPasswordIsRejectedBeforeTextOrEditabilityReads() async {
        let (monitor, backend) = prepared()
        backend.subrole = kAXSecureTextFieldSubrole
        XCTAssertNil(monitor.captureCurrent())
        XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"))
        XCTAssertFalse(backend.operations.contains("settable"))
    }

    func testReadOnlyAndDisabledFieldsAreRejectedBeforeTextReads() async {
        for disabled in [false, true] {
            let (monitor, backend) = prepared()
            backend.enabled = !disabled
            backend.settable = disabled
            XCTAssertNil(monitor.captureCurrent())
            XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"))
        }
    }

    func testUnsupportedOrUnverifiableFieldIsRejectedBeforeTextRead() async {
        for mode in 0..<3 {
            let (monitor, backend) = prepared()
            if mode == 0 { backend.role = kAXButtonRole }
            if mode == 1 { backend.subroleError = .cannotComplete }
            if mode == 2 { backend.elementPID = 91_099 }
            XCTAssertNil(monitor.captureCurrent())
            XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"))
        }
    }

    func testSecureAndEditableChecksPrecedeTextRead() async throws {
        let (monitor, backend) = prepared()
        let snapshot = try XCTUnwrap(monitor.captureCurrent())
        XCTAssertEqual(snapshot.text, backend.text)
        let secure = try XCTUnwrap(backend.operations.firstIndex(of: "read:\(kAXSubroleAttribute)"))
        let enabled = try XCTUnwrap(backend.operations.firstIndex(of: "read:\(kAXEnabledAttribute)"))
        let editable = try XCTUnwrap(backend.operations.firstIndex(of: "settable"))
        let text = try XCTUnwrap(backend.operations.firstIndex(of: "read:\(kAXValueAttribute)"))
        XCTAssertLessThan(secure, enabled)
        XCTAssertLessThan(enabled, editable)
        XCTAssertLessThan(editable, text)
    }

    func testPermissionRevokedDuringMetadataReadPreventsTextRead() async {
        let (monitor, backend) = prepared()
        backend.onSettable = { backend.isTrusted = false }
        XCTAssertNil(monitor.captureCurrent())
        XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"))
    }

    func testAppOptOutDuringMetadataReadPreventsTextRead() async {
        let (monitor, backend) = prepared()
        backend.onSettable = { monitor.allowedBundleIDs = [] }
        XCTAssertNil(monitor.captureCurrent())
        XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"))
    }

    func testCallbacksOnlyPublishChangesAndClearOnRevocation() async throws {
        let (monitor, backend) = prepared()
        var received: [FieldSnapshot?] = []
        monitor.onCapture = { received.append($0) }
        monitor.poll()
        monitor.poll()
        XCTAssertEqual(received.count, 1)
        let first = try XCTUnwrap(received[0])
        XCTAssertEqual(monitor.captureCurrent()?.token, first.token)
        backend.isTrusted = false
        monitor.poll()
        monitor.poll()
        XCTAssertEqual(received.count, 2)
        XCTAssertNil(received[1])
    }

    func testChangedTextAndChangedFieldPreventWrites() async throws {
        for changeField in [false, true] {
            let (monitor, backend) = prepared()
            let snapshot = try XCTUnwrap(monitor.captureCurrent())
            if changeField { backend.focused = AXUIElementCreateApplication(91_002) }
            else { backend.text = "New text typed while the model was responding." }
            XCTAssertThrowsError(try monitor.apply(correction(snapshot), to: snapshot)) {
                XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
            }
            XCTAssertFalse(backend.operations.contains("write"))
        }
    }

    func testAppSwitchPreventsWritingToOldApp() async throws {
        let (monitor, backend) = prepared()
        let snapshot = try XCTUnwrap(monitor.captureCurrent())
        backend.frontmostApplication = MonitoredApplication(pid: 91_002, bundleID: "test.other", name: "Other")
        XCTAssertThrowsError(try monitor.apply(correction(snapshot), to: snapshot)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
        }
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testPermissionRevocationPreventsApplyWithoutReadingTextAgain() async throws {
        for revokeOS in [false, true] {
            let (monitor, backend) = prepared()
            let snapshot = try XCTUnwrap(monitor.captureCurrent())
            backend.operations.removeAll()
            if revokeOS { backend.isTrusted = false } else { monitor.allowedBundleIDs = [] }
            XCTAssertThrowsError(try monitor.apply(correction(snapshot), to: snapshot)) {
                XCTAssertEqual($0 as? AccessibilityMonitorError, .permissionChanged)
            }
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testFieldBecomingSecurePreventsApplyAndTextRead() async throws {
        let (monitor, backend) = prepared()
        let snapshot = try XCTUnwrap(monitor.captureCurrent())
        backend.subrole = kAXSecureTextFieldSubrole
        backend.operations.removeAll()
        XCTAssertThrowsError(try monitor.apply(correction(snapshot), to: snapshot))
        XCTAssertFalse(backend.operations.contains("write"))
        XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"))
    }

    func testUnicodeNormalizationChangeCountsAsChangedSource() async throws {
        let (monitor, backend) = prepared()
        backend.text = "caf\u{00E9} is nice"
        let snapshot = try XCTUnwrap(monitor.captureCurrent())
        backend.text = "cafe\u{0301} is nice"
        XCTAssertEqual(snapshot.text, backend.text, "Swift equality normalizes these strings.")
        let newer = try XCTUnwrap(monitor.captureCurrent())
        XCTAssertFalse(snapshot.isSame(as: newer), "The monitor must compare original bytes.")
        XCTAssertThrowsError(try monitor.apply(correction(snapshot), to: snapshot)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
        }
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testNormalizedButByteDifferentCorrectionOriginalIsRejected() async throws {
        let (monitor, backend) = prepared()
        backend.text = "caf\u{00E9} is nice"
        let snapshot = try XCTUnwrap(monitor.captureCurrent())
        let response = Correction(original: "cafe\u{0301} is nice", corrected: "The café is nice.", explanation: "Article.")
        XCTAssertThrowsError(try monitor.apply(response, to: snapshot)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .invalidCorrection)
        }
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testSuccessfulApplyPreservesExactUnicodeAndNewlinesAndVerifiesWrite() async throws {
        let (monitor, backend) = prepared()
        let snapshot = try XCTUnwrap(monitor.captureCurrent())
        let updated = "She went to school yesterday.\nCafé 👩🏽‍💻 is open."
        try monitor.apply(correction(snapshot, corrected: updated), to: snapshot)
        XCTAssertTrue(backend.text.utf8.elementsEqual(updated.utf8))
        XCTAssertEqual(backend.operations.filter { $0 == "write" }.count, 1)
        XCTAssertEqual(backend.operations.last, "read:\(kAXValueAttribute)")
    }

    func testWriteFailureAndReadbackMismatchProduceErrors() async throws {
        for failWrite in [false, true] {
            let (monitor, backend) = prepared()
            let snapshot = try XCTUnwrap(monitor.captureCurrent())
            if failWrite { backend.writeResult = .cannotComplete }
            else { backend.replacementOverride = "cafe\u{0301} is good" }
            XCTAssertThrowsError(try monitor.apply(correction(snapshot, corrected: "caf\u{00E9} is good"), to: snapshot)) {
                XCTAssertEqual($0 as? AccessibilityMonitorError, failWrite ? .writeFailed : .verificationFailed)
            }
        }
    }

    func testInputLengthLimits() async {
        for text in [" a ", "\n\t ", String(repeating: "a", count: 4_001)] {
            let (monitor, backend) = prepared()
            backend.text = text
            XCTAssertNil(monitor.captureCurrent())
        }
    }

    func testShortcutCapturesAndAppliesWhileAutomaticSuggestionsArePaused() async throws {
        let (monitor, backend) = prepared()
        monitor.isEnabled = false
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertEqual(snapshot.intent, .shortcut)
        XCTAssertEqual(snapshot.scopeLabel, "Entire input")
        XCTAssertEqual(snapshot.fullText, backend.text)
        XCTAssertNil(snapshot.selectionRange)
        try monitor.apply(correction(snapshot), to: snapshot)
        XCTAssertEqual(backend.text, "She went to school yesterday.")
        XCTAssertFalse(monitor.isEnabled)
    }

    func testShortcutNeverBypassesAppOrAccessibilityPermission() async {
        for denyOS in [false, true] {
            let (monitor, backend) = prepared()
            monitor.isEnabled = false
            if denyOS { backend.isTrusted = false } else { monitor.allowedBundleIDs = [] }
            XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
            XCTAssertTrue(backend.operations.isEmpty)
        }
    }

    func testShortcutPasswordAndDisabledFieldsNeverReadTextOrSelection() async {
        for password in [false, true] {
            let (monitor, backend) = prepared()
            if password { backend.subrole = kAXSecureTextFieldSubrole } else { backend.enabled = false }
            XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
            XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"))
            XCTAssertFalse(backend.operations.contains("read:\(kAXSelectedTextAttribute)"))
            XCTAssertFalse(backend.operations.contains("read:\(kAXSelectedTextRangeAttribute)"))
        }
    }

    func testSelectedSentenceUsesUTF16OffsetsAndSendsOnlySelectedText() async throws {
        let (monitor, backend) = prepared()
        backend.text = "👩🏽‍💻 Café is open. She go to school yesterday.\nKeep this exactly."
        backend.selectedRange = (backend.text as NSString).range(of: "She go to school yesterday.")
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertEqual(snapshot.text, "She go to school yesterday.")
        XCTAssertEqual(snapshot.fullText, backend.text)
        XCTAssertEqual(snapshot.selectionRange, backend.selectedRange)
        XCTAssertEqual(snapshot.scopeLabel, "Selected text")
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.selectionRange).location, 18)
    }

    func testAutomaticDetectionAlsoRespectsSelectedText() async throws {
        let (monitor, backend) = prepared()
        backend.text = "Keep this. She go home. Keep that."
        backend.selectedRange = (backend.text as NSString).range(of: "She go home.")
        let snapshot = try XCTUnwrap(monitor.captureCurrent())
        XCTAssertEqual(snapshot.text, "She go home.")
        XCTAssertEqual(snapshot.intent, .automatic)
    }

    func testSelectedTextCanBeReadFromLongInputWithoutSendingSurroundingText() async throws {
        let (monitor, backend) = prepared()
        backend.text = String(repeating: "Untouched text. ", count: 1_000) + "She go home."
        backend.selectedRange = (backend.text as NSString).range(of: "She go home.")
        XCTAssertEqual(monitor.captureCurrent(intent: .shortcut)?.text, "She go home.")
        backend.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
    }

    func testInvalidSelectionRangesNeverFallBackToEntireInput() async {
        for range in [NSRange(location: 1, length: 1),
                      NSRange(location: 0, length: 100), NSRange(location: 100, length: 0)] {
            let (monitor, backend) = prepared()
            backend.text = "😀She go home."
            backend.selectedRange = range
            XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
            XCTAssertFalse(backend.operations.contains("write"))
        }
    }

    func testVeryShortSelectionWorksForShortcutWithoutFallingBackToEntireInput() async throws {
        let (monitor, backend) = prepared()
        backend.selectedRange = NSRange(location: 0, length: 2)
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertEqual(snapshot.text, "Sh")
        XCTAssertEqual(snapshot.selectionRange, NSRange(location: 0, length: 2))
        XCTAssertNil(monitor.captureCurrent())
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testUnknownSelectionWithSelectedTextIsRejectedInsteadOfUsingFullInput() async {
        let (monitor, backend) = prepared()
        backend.selectionError = .attributeUnsupported
        backend.selectedTextOverride = "school"
        XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
        XCTAssertTrue(monitor.lastCaptureStatus.contains("reliable text selection"))
        XCTAssertTrue(backend.operations.contains("read:\(kAXSelectedTextAttribute)"))
    }

    func testUnknownSelectionWithNoSelectedTextAttributeIsRejected() async {
        let (monitor, backend) = prepared()
        backend.selectionError = .attributeUnsupported
        backend.selectedTextError = .attributeUnsupported
        XCTAssertNil(monitor.captureCurrent(intent: .shortcut))
    }

    func testExplicitlyEmptySelectedTextAllowsWholeInputWithoutRange() async throws {
        let (monitor, backend) = prepared()
        backend.selectionError = .attributeUnsupported
        backend.selectedTextOverride = ""
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertNil(snapshot.selectionRange)
        XCTAssertEqual(snapshot.text, backend.text)
    }

    func testNonzeroCaretWithNoSelectionStillTargetsEntireInput() async throws {
        let (monitor, backend) = prepared()
        backend.selectedRange = NSRange(location: 4, length: 0)
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertNil(snapshot.selectionRange)
        XCTAssertEqual(snapshot.text, backend.text)
    }

    func testSelectedApplyPreservesSurroundingBytesWithBothSupportedWriteMethods() async throws {
        for selectedWritable in [false, true] {
            let (monitor, backend) = prepared()
            backend.selectedTextSettable = selectedWritable
            backend.text = "Café 👩🏽‍💻\nShe go home.\nCafe\u{0301} stays untouched."
            backend.selectedRange = (backend.text as NSString).range(of: "She go home.")
            let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
            try monitor.apply(correction(snapshot, corrected: "She goes home."), to: snapshot)
            let expected = "Café 👩🏽‍💻\nShe goes home.\nCafe\u{0301} stays untouched."
            XCTAssertTrue(backend.text.utf8.elementsEqual(expected.utf8))
            XCTAssertEqual(backend.writtenAttributes, [selectedWritable ? kAXSelectedTextAttribute : kAXValueAttribute])
        }
    }

    func testSelectedTextOnlyWritableInputSupportsShortcutApply() async throws {
        let (monitor, backend) = prepared()
        backend.settable = false
        backend.selectedTextSettable = true
        backend.text = "Keep this. She go home."
        backend.selectedRange = (backend.text as NSString).range(of: "She go home.")
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertTrue(snapshot.canApply)
        try monitor.apply(correction(snapshot, corrected: "She goes home."), to: snapshot)
        XCTAssertEqual(backend.text, "Keep this. She goes home.")
        XCTAssertEqual(backend.writtenAttributes, [kAXSelectedTextAttribute])
    }

    func testReadOnlyShortcutSupportsSuggestionButNeverWrites() async throws {
        let (monitor, backend) = prepared()
        backend.settable = false
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertFalse(snapshot.canApply)
        XCTAssertTrue(monitor.lastCaptureStatus.contains("Use Copy"))
        XCTAssertThrowsError(try monitor.apply(correction(snapshot), to: snapshot)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .directEditingUnsupported)
        }
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testSelectedTextWritableWithoutSelectionDoesNotEnableWholeInputWrites() async throws {
        let (monitor, backend) = prepared()
        backend.settable = false
        backend.selectedTextSettable = true
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertFalse(snapshot.canApply)
        XCTAssertThrowsError(try monitor.apply(correction(snapshot), to: snapshot))
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testMovingSelectionToIdenticalTextInvalidatesSuggestion() async throws {
        let (monitor, backend) = prepared()
        backend.text = "She go home. She go home."
        backend.selectedRange = NSRange(location: 0, length: 12)
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        backend.selectedRange = NSRange(location: 13, length: 12)
        XCTAssertThrowsError(try monitor.apply(correction(snapshot, corrected: "She goes home."), to: snapshot)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
        }
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testChangingSurroundingTextInvalidatesSelectedSuggestion() async throws {
        let (monitor, backend) = prepared()
        backend.text = "She go home. Keep this."
        backend.selectedRange = NSRange(location: 0, length: 12)
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        backend.text = "She go home. New words."
        XCTAssertThrowsError(try monitor.apply(correction(snapshot, corrected: "She goes home."), to: snapshot)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
        }
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testDeselectingBeforeApplyInvalidatesSelectedSuggestion() async throws {
        let (monitor, backend) = prepared()
        backend.selectedRange = NSRange(location: 0, length: 6)
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        backend.selectedRange = NSRange(location: 6, length: 0)
        XCTAssertThrowsError(try monitor.apply(correction(snapshot, corrected: "She went"), to: snapshot)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
        }
        XCTAssertFalse(backend.operations.contains("write"))
    }

    func testShortcutRevocationStillPreventsApplyWhilePaused() async throws {
        let (monitor, backend) = prepared()
        monitor.isEnabled = false
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        monitor.allowedBundleIDs = []
        backend.operations.removeAll()
        XCTAssertThrowsError(try monitor.apply(correction(snapshot), to: snapshot)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .permissionChanged)
        }
        XCTAssertTrue(backend.operations.isEmpty)
    }

    func testAutomaticPollingDoesNotChangeManualSnapshotIdentity() async throws {
        let (monitor, _) = prepared()
        let manual = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        monitor.poll()
        let afterPoll = try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))
        XCTAssertTrue(manual.isSame(as: afterPoll))
        XCTAssertFalse(manual.isSame(as: try XCTUnwrap(monitor.captureCurrent())))
        monitor.isEnabled = false
        monitor.poll()
        XCTAssertTrue(manual.isSame(as: try XCTUnwrap(monitor.captureCurrent(intent: .shortcut))))
    }
}

/// Creates inert AX handles, but never sends an Accessibility message to any app.
@MainActor
private final class FakeAccessibilityBackend: AccessibilityBackend {
    static let bundleID = "test.english-correct.fixture"
    var isTrusted = true
    var frontmostApplication: MonitoredApplication? = .init(pid: 91_001, bundleID: bundleID, name: "Test Fixture")
    var focused: AXUIElement? = AXUIElementCreateApplication(91_001)
    var elementPID: pid_t? = 91_001
    var role = kAXTextFieldRole
    var subrole: String? = nil
    var subroleError: AXError = .noValue
    var enabled = true
    var settable = true
    var selectedTextSettable = false
    var text = "She go to school yesterday."
    var selectedRange = NSRange(location: 0, length: 0)
    var selectionError: AXError = .success
    var selectedTextError: AXError = .success
    var selectedTextOverride: String?
    var operations: [String] = []
    var writeResult: AXError = .success
    var replacementOverride: String?
    var onSettable: (() -> Void)?
    var writtenAttributes: [String] = []

    func focusedElement(for pid: pid_t) -> AXUIElement? {
        operations.append("focus")
        return focused
    }

    func pid(of element: AXUIElement) -> pid_t? {
        operations.append("pid")
        return elementPID
    }

    func read(_ attribute: String, from element: AXUIElement) -> (AXError, CFTypeRef?) {
        operations.append("read:\(attribute)")
        switch attribute {
        case kAXRoleAttribute: return (.success, role as CFString)
        case kAXSubroleAttribute:
            if let subrole { return (.success, subrole as CFString) }
            return (subroleError, nil)
        case kAXEnabledAttribute: return (.success, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        case kAXValueAttribute: return (.success, text as CFString)
        case kAXSelectedTextRangeAttribute:
            guard selectionError == .success else { return (selectionError, nil) }
            var range = CFRange(location: selectedRange.location, length: selectedRange.length)
            return (.success, AXValueCreate(.cfRange, &range))
        case kAXSelectedTextAttribute:
            guard selectedTextError == .success else { return (selectedTextError, nil) }
            if let selectedTextOverride { return (.success, selectedTextOverride as CFString) }
            guard let range = Range(selectedRange, in: text) else { return (.illegalArgument, nil) }
            return (.success, String(text[range]) as CFString)
        default: return (.attributeUnsupported, nil)
        }
    }

    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        operations.append("settable")
        onSettable?()
        return attribute == kAXSelectedTextAttribute ? selectedTextSettable : settable
    }

    func write(_ attribute: String, value: CFTypeRef, to element: AXUIElement) -> AXError {
        operations.append("write")
        writtenAttributes.append(attribute)
        if writeResult == .success {
            if let replacementOverride { text = replacementOverride }
            else if attribute == kAXSelectedTextAttribute, let range = Range(selectedRange, in: text) {
                text.replaceSubrange(range, with: value as? String ?? "")
            } else { text = value as? String ?? "" }
        }
        return writeResult
    }
}
