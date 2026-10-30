import AppKit
import ApplicationServices
import EnglishCorrectCore
import XCTest
@testable import EnglishCorrect

@MainActor
final class CorrectionUndoTests: XCTestCase {
    private func prepared() -> (AccessibilityMonitor, UndoAccessibilityBackend) {
        let backend = UndoAccessibilityBackend()
        let monitor = AccessibilityMonitor(backend: backend)
        monitor.allowedBundleIDs = [UndoAccessibilityBackend.bundleID]
        monitor.isEnabled = true
        return (monitor, backend)
    }

    private func accept(_ monitor: AccessibilityMonitor, corrected: String = "She went home.",
                        intent: CaptureIntent = .automatic) throws -> AppliedCorrection {
        let snapshot = try XCTUnwrap(monitor.captureCurrent(intent: intent))
        return try monitor.apply(Correction(original: snapshot.text, corrected: corrected, explanation: "Past tense."),
                                 to: snapshot)
    }

    func testWholeInputUndoRestoresExactUnicodeBytesAndPlacesCaretAtOriginalEnd() async throws {
        let (monitor, backend) = prepared()
        defer { monitor.stop() }
        let original = "Cafe\u{0301} 👩🏽‍💻\nShe go home. 👍🏽"
        backend.text = original
        let receipt = try accept(monitor, corrected: "Café 👩🏽‍💻\nShe went home. 👍🏽")
        XCTAssertEqual(receipt.appName, "Undo Fixture")
        XCTAssertTrue(monitor.canUndo(receipt))
        backend.selectedRange = NSRange(location: 3, length: 2)

        try monitor.undo(receipt)

        XCTAssertTrue(backend.text.utf8.elementsEqual(original.utf8))
        XCTAssertEqual(backend.selectedRange, NSRange(location: original.utf16.count, length: 0))
        XCTAssertEqual(backend.textWrites, [kAXValueAttribute, kAXValueAttribute])
        XCTAssertFalse(monitor.canUndo(receipt))
        XCTAssertThrowsError(try monitor.undo(receipt)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
        }
        XCTAssertEqual(backend.textWrites.count, 2, "A consumed receipt cannot repeat the text write.")
    }

    func testSelectedUndoRestoresSurroundingBytesAndCaretAfterOriginalPassage() async throws {
        for selectedWritable in [false, true] {
            let (monitor, backend) = prepared()
            defer { monitor.stop() }
            let prefix = "👩🏽‍💻 Cafe\u{0301}\n"
            let passage = "She go home. 👍🏽"
            let suffix = "\nKeep café exactly."
            let original = prefix + passage + suffix
            backend.text = original
            backend.selectedRange = NSRange(location: prefix.utf16.count, length: passage.utf16.count)
            backend.selectedTextWritable = selectedWritable
            let receipt = try accept(monitor, corrected: "She went home. 👍🏽", intent: .shortcut)
            backend.selectedRange = NSRange(location: 0, length: 0)
            backend.operations.removeAll()

            XCTAssertTrue(monitor.canUndo(receipt), "Undo need not keep the old selected passage active.")
            XCTAssertFalse(backend.operations.contains("read:\(kAXSelectedTextRangeAttribute)"))
            try monitor.undo(receipt)

            XCTAssertTrue(backend.text.utf8.elementsEqual(original.utf8))
            XCTAssertEqual(backend.selectedRange, NSRange(location: prefix.utf16.count + passage.utf16.count, length: 0))
            XCTAssertEqual(backend.textWrites, [selectedWritable ? kAXSelectedTextAttribute : kAXValueAttribute,
                                               kAXValueAttribute])
        }
    }

    func testUndoRejectsTypingAndCanonicallyEqualButByteDifferentInput() async throws {
        for changed in ["Café is good. More typing.", "Cafe\u{0301} is good."] {
            let (monitor, backend) = prepared()
            defer { monitor.stop() }
            let receipt = try accept(monitor, corrected: "Café is good.")
            backend.text = changed
            backend.textWrites.removeAll()

            XCTAssertFalse(monitor.canUndo(receipt))
            XCTAssertThrowsError(try monitor.undo(receipt)) {
                XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
            }
            XCTAssertTrue(backend.text.utf8.elementsEqual(changed.utf8))
            XCTAssertTrue(backend.textWrites.isEmpty)
        }
    }

    func testChangedAppFieldPIDRoleSecureOrDisabledFieldCannotBeUndone() async throws {
        for change in ["app", "bundle", "field", "pid", "role", "secure", "disabled", "unavailable protection"] {
            let (monitor, backend) = prepared()
            defer { monitor.stop() }
            let receipt = try accept(monitor)
            switch change {
            case "app": backend.frontmostApplication = .init(pid: 92_002, bundleID: "other.app", name: "Other")
            case "bundle": backend.frontmostApplication = .init(pid: 92_001, bundleID: "other.app", name: "Other")
            case "field": backend.focused = AXUIElementCreateApplication(92_002)
            case "pid": backend.elementPID = 92_002
            case "role": backend.role = kAXButtonRole
            case "secure": backend.subrole = kAXSecureTextFieldSubrole
            case "disabled": backend.enabled = false
            default: backend.subroleError = .cannotComplete
            }
            backend.operations.removeAll()
            backend.textWrites.removeAll()

            XCTAssertFalse(monitor.canUndo(receipt), change)
            XCTAssertThrowsError(try monitor.undo(receipt), change)
            XCTAssertTrue(backend.textWrites.isEmpty, change)
            XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"), change)
        }
    }

    func testRevokedTrustAllowlistOrAutomaticPermissionPreventsAllUndoReads() async throws {
        for change in ["trust", "allowlist", "paused"] {
            let (monitor, backend) = prepared()
            defer { monitor.stop() }
            let receipt = try accept(monitor)
            switch change {
            case "trust": backend.isTrusted = false
            case "allowlist": monitor.allowedBundleIDs = []
            default: monitor.isEnabled = false
            }
            backend.operations.removeAll()
            backend.textWrites.removeAll()

            XCTAssertFalse(monitor.canUndo(receipt), change)
            XCTAssertThrowsError(try monitor.undo(receipt)) {
                XCTAssertEqual($0 as? AccessibilityMonitorError, .permissionChanged, change)
            }
            XCTAssertTrue(backend.operations.isEmpty, change)
            XCTAssertTrue(backend.textWrites.isEmpty, change)
        }
    }

    func testShortcutUndoWorksWhileAutomaticSuggestionsRemainPaused() async throws {
        let (monitor, backend) = prepared()
        defer { monitor.stop() }
        monitor.isEnabled = false
        let original = backend.text
        let receipt = try accept(monitor, intent: .shortcut)

        XCTAssertTrue(monitor.canUndo(receipt))
        try monitor.undo(receipt)

        XCTAssertEqual(backend.text, original)
        XCTAssertFalse(monitor.isEnabled)
    }

    func testSelectedTextOnlyEditorCannotUndoBySelectingAllOrRewritingSelection() async throws {
        let (monitor, backend) = prepared()
        defer { monitor.stop() }
        backend.text = "Keep this. She go home."
        backend.selectedRange = (backend.text as NSString).range(of: "She go home.")
        backend.valueWritable = false
        backend.selectedTextWritable = true
        let receipt = try accept(monitor, intent: .shortcut)
        let accepted = backend.text
        backend.textWrites.removeAll()
        backend.caretWrites = 0

        XCTAssertFalse(monitor.canUndo(receipt))
        XCTAssertThrowsError(try monitor.undo(receipt)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .directEditingUnsupported)
        }
        XCTAssertEqual(backend.text, accepted)
        XCTAssertTrue(backend.textWrites.isEmpty)
        XCTAssertEqual(backend.caretWrites, 0)
    }

    func testPermissionOrProtectionChangingDuringMetadataCheckPreventsTextRead() async throws {
        for change in ["trust", "allowlist", "secure", "disabled", "field", "typing"] {
            let (monitor, backend) = prepared()
            defer { monitor.stop() }
            let receipt = try accept(monitor)
            backend.operations.removeAll()
            backend.textWrites.removeAll()
            backend.onValueSettable = {
                backend.onValueSettable = nil
                switch change {
                case "trust": backend.isTrusted = false
                case "allowlist": monitor.allowedBundleIDs = []
                case "secure": backend.subrole = kAXSecureTextFieldSubrole
                case "disabled": backend.enabled = false
                case "field": backend.focused = AXUIElementCreateApplication(92_002)
                default: backend.text += " More."
                }
            }

            XCTAssertThrowsError(try monitor.undo(receipt), change)
            XCTAssertTrue(backend.textWrites.isEmpty, change)
            if change != "typing" {
                XCTAssertFalse(backend.operations.contains("read:\(kAXValueAttribute)"), change)
            }
        }
    }

    func testChangedSourceDuringFinalReadRejectsUndoWithoutWrite() async throws {
        let (monitor, backend) = prepared()
        defer { monitor.stop() }
        let receipt = try accept(monitor)
        backend.textWrites.removeAll()
        var valueReads = 0
        backend.onValueRead = {
            valueReads += 1
            if valueReads == 2 { backend.text += " New typing." }
        }

        XCTAssertThrowsError(try monitor.undo(receipt)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
        }
        XCTAssertEqual(backend.text, "She went home. New typing.")
        XCTAssertTrue(backend.textWrites.isEmpty)
    }

    func testTypingProcessedByFinalFocusQueryCannotBeOverwrittenByUndo() async throws {
        let (monitor, backend) = prepared()
        defer { monitor.stop() }
        let receipt = try accept(monitor)
        backend.textWrites.removeAll()
        var focusReads = 0
        backend.onFocusRead = {
            focusReads += 1
            // Undo validates its target twice, with three focus queries each.
            // Emulate typing handled during the last query before writing.
            if focusReads == 6 { backend.text += " Keep my new typing." }
        }

        XCTAssertThrowsError(try monitor.undo(receipt)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .sourceChanged)
        }
        XCTAssertEqual(focusReads, 6)
        XCTAssertEqual(backend.text, "She went home. Keep my new typing.")
        XCTAssertTrue(backend.textWrites.isEmpty)
    }

    func testProtectionChangingAtFinalFocusQueryPreventsValueReadAndUndo() async throws {
        let (monitor, backend) = prepared()
        defer { monitor.stop() }
        let receipt = try accept(monitor)
        backend.operations.removeAll()
        backend.textWrites.removeAll()
        var focusReads = 0
        backend.onFocusRead = {
            focusReads += 1
            if focusReads == 6 { backend.subrole = kAXSecureTextFieldSubrole }
        }

        XCTAssertThrowsError(try monitor.undo(receipt))
        XCTAssertEqual(focusReads, 6)
        XCTAssertEqual(backend.operations.filter { $0 == "read:\(kAXValueAttribute)" }.count, 1,
                       "Only the first validation may read text; the final protected field must not.")
        XCTAssertTrue(backend.textWrites.isEmpty)
    }

    func testFailedOrUnverifiedApplyNeverReturnsReceipt() async throws {
        for failWrite in [false, true] {
            let (monitor, backend) = prepared()
            defer { monitor.stop() }
            if failWrite { backend.textWriteResult = .cannotComplete }
            else { backend.replacementOverride = "Unexpected editor value." }
            var receipt: AppliedCorrection?

            XCTAssertThrowsError(receipt = try accept(monitor)) {
                XCTAssertEqual($0 as? AccessibilityMonitorError, failWrite ? .writeFailed : .verificationFailed)
            }
            XCTAssertNil(receipt)
            XCTAssertEqual(backend.textWrites.count, 1)
            XCTAssertEqual(backend.caretWrites, 0)
        }
    }

    func testFailedOrUnverifiedUndoNeverRetriesTextOrMovesCaret() async throws {
        for failWrite in [false, true] {
            let (monitor, backend) = prepared()
            defer { monitor.stop() }
            let receipt = try accept(monitor)
            backend.textWrites.removeAll()
            backend.caretWrites = 0
            if failWrite { backend.textWriteResult = .cannotComplete }
            else { backend.replacementOverride = "Unexpected editor value." }

            XCTAssertThrowsError(try monitor.undo(receipt)) {
                XCTAssertEqual($0 as? AccessibilityMonitorError, failWrite ? .writeFailed : .verificationFailed)
            }
            XCTAssertEqual(backend.textWrites, [kAXValueAttribute])
            XCTAssertEqual(backend.caretWrites, 0)
        }
    }

    func testFieldBecomingSecureDuringUndoWritePreventsVerificationTextRead() async throws {
        let (monitor, backend) = prepared()
        defer { monitor.stop() }
        let receipt = try accept(monitor)
        backend.operations.removeAll()
        backend.textWrites.removeAll()
        backend.caretWrites = 0
        backend.onTextWrite = { backend.subrole = kAXSecureTextFieldSubrole }

        XCTAssertThrowsError(try monitor.undo(receipt)) {
            XCTAssertEqual($0 as? AccessibilityMonitorError, .verificationFailed)
        }
        XCTAssertEqual(backend.textWrites, [kAXValueAttribute])
        XCTAssertEqual(backend.caretWrites, 0)
        let writeIndex = try XCTUnwrap(backend.operations.firstIndex(of: "write:\(kAXValueAttribute)"))
        XCTAssertFalse(backend.operations.dropFirst(writeIndex + 1).contains("read:\(kAXValueAttribute)"),
                       "Verification must not read input after its protection changes.")
    }

    func testUndoOfferValidationDoesNotPublishOrChangeStatus() async throws {
        let (monitor, backend) = prepared()
        defer { monitor.stop() }
        let receipt = try accept(monitor)
        let status = monitor.lastCaptureStatus
        var captures = 0
        var statuses = 0
        monitor.onCapture = { _ in captures += 1 }
        monitor.onStatus = { _ in statuses += 1 }
        XCTAssertTrue(monitor.canUndo(receipt))
        backend.isTrusted = false
        XCTAssertFalse(monitor.canUndo(receipt))
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(statuses, 0)
        XCTAssertEqual(monitor.lastCaptureStatus, status)
    }

    func testOfferCheckPreservesCaretJobAndUndoCancelsOldJobWithoutRewritingText() async throws {
        let clock = UndoCaretClock()
        let backend = UndoAccessibilityBackend()
        let monitor = AccessibilityMonitor(backend: backend, waitForCaretUpdate: { try await clock.wait($0) })
        defer { monitor.stop(); clock.finishAll() }
        monitor.allowedBundleIDs = [UndoAccessibilityBackend.bundleID]
        monitor.isEnabled = true
        let original = backend.text
        let revised = "She went home. 👩🏽‍💻"
        let receipt = try accept(monitor, corrected: revised)
        await waitUntil { clock.delays.count == 1 }

        XCTAssertTrue(monitor.canUndo(receipt))
        backend.selectedRange = NSRange(location: 0, length: 0)
        clock.finishFirst()
        await waitUntil { clock.delays.count == 2 }
        XCTAssertEqual(backend.selectedRange.location, revised.utf16.count,
                       "Read-only Undo checks must not cancel the accepted correction's caret task.")

        try monitor.undo(receipt)
        await waitUntil { clock.delays.count == 3 }
        backend.selectedRange = NSRange(location: 0, length: 0)
        clock.finishFirst() // The old, cancelled task deliberately ignores cancellation while waiting.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(backend.selectedRange.location, 0, "The old correction cannot move the restored caret.")
        clock.finishFirst()
        await waitUntil { backend.selectedRange.location == original.utf16.count }
        XCTAssertTrue(backend.text.utf8.elementsEqual(original.utf8))
        XCTAssertEqual(backend.textWrites, [kAXValueAttribute, kAXValueAttribute])
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(predicate(), "Caret task did not reach its expected state.", file: file, line: line)
    }
}

@MainActor
private final class UndoCaretClock {
    var delays: [Double] = []
    private var continuations: [CheckedContinuation<Void, Error>] = []

    func wait(_ seconds: Double) async throws {
        delays.append(seconds)
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func finishFirst() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func finishAll() {
        while !continuations.isEmpty { finishFirst() }
    }
}

/// Inert AX handles with explicit read/write hooks; no messages reach an app.
@MainActor
private final class UndoAccessibilityBackend: AccessibilityBackend {
    static let bundleID = "test.english-correct.undo"
    var isTrusted = true
    var frontmostApplication: MonitoredApplication? = .init(pid: 92_001, bundleID: bundleID, name: "Undo Fixture")
    var focused: AXUIElement? = AXUIElementCreateApplication(92_001)
    var elementPID: pid_t? = 92_001
    var role = kAXTextAreaRole
    var subrole: String?
    var subroleError: AXError = .noValue
    var enabled = true
    var valueWritable = true
    var selectedTextWritable = false
    var text = "She go home."
    var selectedRange = NSRange(location: 0, length: 0)
    var operations: [String] = []
    var textWrites: [String] = []
    var caretWrites = 0
    var textWriteResult: AXError = .success
    var replacementOverride: String?
    var onValueSettable: (() -> Void)?
    var onValueRead: (() -> Void)?
    var onFocusRead: (() -> Void)?
    var onTextWrite: (() -> Void)?

    func focusedElement(for pid: pid_t) -> AXUIElement? {
        operations.append("focus")
        onFocusRead?()
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
        case kAXValueAttribute:
            onValueRead?()
            return (.success, text as CFString)
        case kAXSelectedTextRangeAttribute:
            var range = CFRange(location: selectedRange.location, length: selectedRange.length)
            return (.success, AXValueCreate(.cfRange, &range))
        case kAXSelectedTextAttribute:
            guard let range = Range(selectedRange, in: text) else { return (.illegalArgument, nil) }
            return (.success, String(text[range]) as CFString)
        default: return (.attributeUnsupported, nil)
        }
    }

    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        operations.append("settable:\(attribute)")
        switch attribute {
        case kAXValueAttribute:
            onValueSettable?()
            return valueWritable
        case kAXSelectedTextAttribute: return selectedTextWritable
        case kAXSelectedTextRangeAttribute: return true
        default: return false
        }
    }

    func write(_ attribute: String, value: CFTypeRef, to element: AXUIElement) -> AXError {
        operations.append("write:\(attribute)")
        if attribute == kAXSelectedTextRangeAttribute {
            caretWrites += 1
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return .illegalArgument }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return .illegalArgument }
            selectedRange = NSRange(location: range.location, length: range.length)
            return .success
        }
        textWrites.append(attribute)
        guard textWriteResult == .success else { return textWriteResult }
        guard let replacement = value as? String else { return .illegalArgument }
        if let replacementOverride { text = replacementOverride }
        else if attribute == kAXSelectedTextAttribute {
            guard let range = Range(selectedRange, in: text) else { return .illegalArgument }
            text.replaceSubrange(range, with: replacement)
        } else if attribute == kAXValueAttribute { text = replacement }
        else { return .attributeUnsupported }
        selectedRange = NSRange(location: 0, length: 0)
        onTextWrite?()
        return .success
    }
}
