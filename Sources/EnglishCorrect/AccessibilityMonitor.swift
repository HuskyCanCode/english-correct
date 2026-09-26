import AppKit
import ApplicationServices
import EnglishCorrectCore

struct MonitoredApplication {
    let pid: pid_t
    let bundleID: String?
    let name: String?
}

/// The narrow OS boundary allows tests to count reads without granting Accessibility.
@MainActor
protocol AccessibilityBackend {
    var isTrusted: Bool { get }
    var frontmostApplication: MonitoredApplication? { get }
    func focusedElement(for pid: pid_t) -> AXUIElement?
    func pid(of element: AXUIElement) -> pid_t?
    func read(_ attribute: String, from element: AXUIElement) -> (AXError, CFTypeRef?)
    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool
    func write(_ attribute: String, value: CFTypeRef, to element: AXUIElement) -> AXError
}

@MainActor
private final class NativeAccessibilityBackend: AccessibilityBackend {
    var isTrusted: Bool { AXIsProcessTrusted() }
    var frontmostApplication: MonitoredApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return MonitoredApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    func focusedElement(for pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let (result, value) = read(kAXFocusedUIElementAttribute, from: app)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }

    func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    func read(_ attribute: String, from element: AXUIElement) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (result, value)
    }

    func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func write(_ attribute: String, value: CFTypeRef, to element: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }
}

enum CaptureIntent {
    case automatic
    case shortcut
}

struct FieldSnapshot {
    let token: UUID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let text: String
    let frame: CGRect?
    let fullText: String
    let selectionRange: NSRange?
    let intent: CaptureIntent
    let canApply: Bool

    init(token: UUID, element: AXUIElement, pid: pid_t, bundleID: String,
         appName: String, text: String, frame: CGRect?, fullText: String? = nil,
         selectionRange: NSRange? = nil, intent: CaptureIntent = .automatic,
         canApply: Bool = true) {
        self.token = token
        self.element = element
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.text = text
        self.frame = frame
        self.fullText = fullText ?? text
        self.selectionRange = selectionRange
        self.intent = intent
        self.canApply = canApply
    }

    var id: UUID { token }
    var scopeLabel: String { selectionRange == nil ? "Entire input" : "Selected text" }

    func isSame(as other: FieldSnapshot) -> Bool {
        pid == other.pid && bundleID == other.bundleID &&
            CFEqual(element, other.element) && intent == other.intent &&
            selectionRange == other.selectionRange && canApply == other.canApply &&
            text.utf8.elementsEqual(other.text.utf8) &&
            fullText.utf8.elementsEqual(other.fullText.utf8)
    }
}

enum AccessibilityMonitorError: LocalizedError, Equatable {
    case permissionChanged
    case sourceChanged
    case invalidCorrection
    case directEditingUnsupported
    case writeFailed
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .permissionChanged:
            return "Correction is paused. Check Accessibility access and the permission for this app."
        case .sourceChanged:
            return "The input or focused app changed. Wait for a fresh suggestion before applying."
        case .invalidCorrection:
            return "This suggestion does not match the original text. Request a fresh suggestion."
        case .directEditingUnsupported:
            return "This app does not allow direct editing. Copy the suggestion and paste it into the input."
        case .writeFailed:
            return "This app could not accept the correction. Your text may be unchanged."
        case .verificationFailed:
            return "The correction was sent, but the app did not confirm the result. Check the input before continuing."
        }
    }
}

/// Reads only the focused text field of an explicitly approved application.
@MainActor
final class AccessibilityMonitor {
    var onCapture: ((FieldSnapshot?) -> Void)?
    var onStatus: ((String) -> Void)?

    var allowedBundleIDs: Set<String> = [] {
        didSet {
            if allowedBundleIDs != oldValue {
                if let lastSnapshot, !allowedBundleIDs.contains(lastSnapshot.bundleID) {
                    publish(nil)
                }
                if timer != nil { poll() }
            }
        }
    }

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { publish(nil) }
            if timer != nil { poll() }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }
    var accessibilityTrusted: Bool { backend.isTrusted }

    /// Invoke from an explicit user action. Prompting does not immediately grant trust.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var timer: Timer?
    private var lastSnapshot: FieldSnapshot?
    private var hasReportedCapture = false
    private(set) var lastCaptureStatus = "Suggestions are paused."
    private(set) var lastCaptureWasEmpty = false
    private let backend: AccessibilityBackend

    init(backend: AccessibilityBackend? = nil) {
        self.backend = backend ?? NativeAccessibilityBackend()
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        publish(nil)
        report("Input detection is stopped.")
    }

    func poll() {
        publish(captureCurrent())
    }

    func captureCurrent(intent: CaptureIntent = .automatic) -> FieldSnapshot? {
        lastCaptureWasEmpty = false
        guard isEnabled || intent == .shortcut else {
            report("Suggestions are paused.")
            return nil
        }
        guard backend.isTrusted else {
            report("Allow Accessibility access to detect input fields.")
            return nil
        }
        // Resolve the app identity before sending any Accessibility messages.
        guard let app = backend.frontmostApplication,
              app.pid != ProcessInfo.processInfo.processIdentifier,
              let bundleID = app.bundleID else {
            report("Focus an input field in another allowed app. For the draft in English Correct, use Check writing.")
            return nil
        }
        guard allowedBundleIDs.contains(bundleID) else {
            report("\(app.name ?? bundleID) is not allowed. Enable it in Allowed Apps.")
            return nil
        }
        guard let element = backend.focusedElement(for: app.pid) else {
            report("Focus an editable text field in \(app.name ?? bundleID).")
            return nil
        }
        guard backend.pid(of: element) == app.pid,
              let role = attribute(kAXRoleAttribute, of: element) as? String,
              [kAXTextFieldRole, kAXTextAreaRole].contains(role) else {
            report("The focused item is not a supported text input.")
            return nil
        }
        let (subroleResult, subrole) = backend.read(kAXSubroleAttribute, from: element)
        guard subroleResult == .success || subroleResult == .attributeUnsupported || subroleResult == .noValue else {
            report("This input is unavailable.")
            return nil
        }
        // Check protection and editability before reading the input's value.
        guard (subrole as? String) != kAXSecureTextFieldSubrole else {
            report("Suggestions are disabled for password fields.")
            return nil
        }
        guard (attribute(kAXEnabledAttribute, of: element) as? Bool) == true else {
            report("This input is disabled.")
            return nil
        }
        let canWriteValue = isSettable(kAXValueAttribute, of: element)
        guard intent == .shortcut || canWriteValue else {
            report("This input does not support direct editing.")
            return nil
        }
        guard stillPermitted(bundleID: bundleID, pid: app.pid, intent: intent) else { return nil }
        guard let fullText = attribute(kAXValueAttribute, of: element) as? String else {
            report("This app does not expose the input text.")
            return nil
        }
        guard stillPermitted(bundleID: bundleID, pid: app.pid, intent: intent) else { return nil }
        // Empty fields have nothing to review, even if the app cannot report a
        // selection for them. Keep this after all permission and field checks.
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastCaptureWasEmpty = true
            report(CorrectionTargetError.emptyInput.localizedDescription)
            return nil
        }
        // Selection offsets use UTF-16, not Swift Character indices. The pure
        // target type checks both the offsets and complete Unicode boundaries.
        guard let selection = selection(in: element, bundleID: bundleID, pid: app.pid, intent: intent) else { return nil }
        let target: CorrectionTarget
        do {
            target = try CorrectionTarget(fullText: fullText, selectedRange: selection.range)
        } catch {
            lastCaptureWasEmpty = (error as? CorrectionTargetError) == .emptyInput
            report(error.localizedDescription)
            return nil
        }
        guard intent == .shortcut || target.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            report("Keep typing. Suggestions start after three characters.")
            return nil
        }
        let canWriteSelection = target.selectedRange != nil && isSettable(kAXSelectedTextAttribute, of: element)
        guard stillPermitted(bundleID: bundleID, pid: app.pid, intent: intent) else { return nil }
        let snapshot = FieldSnapshot(
            token: UUID(), element: element, pid: app.pid,
            bundleID: bundleID, appName: app.name ?? bundleID,
            text: target.text, frame: frame(of: element), fullText: fullText,
            selectionRange: target.selectedRange, intent: intent,
            canApply: canWriteValue || canWriteSelection
        )
        report(snapshot.canApply
            ? "\(snapshot.scopeLabel) in \(snapshot.appName)."
            : "\(snapshot.scopeLabel) in \(snapshot.appName). Use Copy to paste the suggestion.")
        if let lastSnapshot, snapshot.isSame(as: lastSnapshot) { return lastSnapshot }
        return snapshot
    }

    func apply(_ correction: Correction, to snapshot: FieldSnapshot) throws {
        guard (isEnabled || snapshot.intent == .shortcut), backend.isTrusted,
              allowedBundleIDs.contains(snapshot.bundleID) else {
            publish(nil)
            throw AccessibilityMonitorError.permissionChanged
        }
        guard correction.original.utf8.elementsEqual(snapshot.text.utf8),
              correction.hasChanges,
              !correction.corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccessibilityMonitorError.invalidCorrection
        }
        guard snapshot.canApply else { throw AccessibilityMonitorError.directEditingUnsupported }
        guard let current = captureCurrent(intent: snapshot.intent), current.isSame(as: snapshot),
              stillPermitted(bundleID: snapshot.bundleID, pid: snapshot.pid, intent: snapshot.intent) else {
            publish(nil)
            throw AccessibilityMonitorError.sourceChanged
        }
        let expected: String
        do {
            let target = try CorrectionTarget(fullText: snapshot.fullText, selectedRange: snapshot.selectionRange)
            expected = try target.replacing(with: correction.corrected)
        } catch {
            throw AccessibilityMonitorError.invalidCorrection
        }
        let writeAttribute: String
        let replacement: String
        if snapshot.selectionRange != nil && isSettable(kAXSelectedTextAttribute, of: snapshot.element) {
            writeAttribute = kAXSelectedTextAttribute
            replacement = correction.corrected
        } else if isSettable(kAXValueAttribute, of: snapshot.element) {
            writeAttribute = kAXValueAttribute
            replacement = expected
        } else {
            throw AccessibilityMonitorError.directEditingUnsupported
        }
        guard stillPermitted(bundleID: snapshot.bundleID, pid: snapshot.pid, intent: snapshot.intent) else {
            publish(nil)
            throw AccessibilityMonitorError.permissionChanged
        }
        let result = backend.write(writeAttribute, value: replacement as CFString, to: snapshot.element)
        publish(nil)
        guard result == .success else { throw AccessibilityMonitorError.writeFailed }
        guard stillPermitted(bundleID: snapshot.bundleID, pid: snapshot.pid, intent: snapshot.intent),
              let confirmed = attribute(kAXValueAttribute, of: snapshot.element) as? String,
              confirmed.utf8.elementsEqual(expected.utf8) else {
            throw AccessibilityMonitorError.verificationFailed
        }
        report("Correction applied in \(snapshot.appName).")
    }

    private func publish(_ snapshot: FieldSnapshot?) {
        let same = snapshot == nil && lastSnapshot == nil ||
            snapshot.map { next in lastSnapshot.map { next.isSame(as: $0) } ?? false } == true
        guard !hasReportedCapture || !same else { return }
        lastSnapshot = snapshot
        hasReportedCapture = true
        onCapture?(snapshot)
    }

    private func report(_ message: String) {
        guard message != lastCaptureStatus else { return }
        lastCaptureStatus = message
        onStatus?(message)
    }

    private func stillPermitted(bundleID: String, pid: pid_t, intent: CaptureIntent) -> Bool {
        guard (isEnabled || intent == .shortcut), backend.isTrusted, allowedBundleIDs.contains(bundleID),
              let frontmost = backend.frontmostApplication else { return false }
        return frontmost.pid == pid && frontmost.bundleID == bundleID
    }

    private struct Selection {
        let range: NSRange?
    }

    /// An unavailable range is not evidence that no selection exists. Only an
    /// explicitly empty AXSelectedText allows a whole-input fallback.
    private func selection(in element: AXUIElement, bundleID: String, pid: pid_t,
                           intent: CaptureIntent) -> Selection? {
        let (result, value) = backend.read(kAXSelectedTextRangeAttribute, from: element)
        if result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 {
                return Selection(range: NSRange(location: range.location, length: range.length))
            }
            report("This app reported an unsupported text selection. Place the cursor or select the text again.")
            return nil
        }
        guard result == .attributeUnsupported || result == .noValue else {
            report("This app could not report the selected text. Place the cursor or select the text again.")
            return nil
        }
        guard stillPermitted(bundleID: bundleID, pid: pid, intent: intent) else { return nil }
        let (selectedResult, selectedValue) = backend.read(kAXSelectedTextAttribute, from: element)
        if selectedResult == .success, let selectedText = selectedValue as? String, selectedText.isEmpty {
            return Selection(range: nil)
        }
        report("This app does not expose a reliable text selection. Try another input field or use the Write tab.")
        return nil
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        let (result, value) = backend.read(name, from: element)
        guard result == .success else { return nil }
        return value
    }

    private func isSettable(_ name: String, of element: AXUIElement) -> Bool {
        backend.isSettable(name, on: element)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(kAXPositionAttribute, of: element),
              let sizeValue = attribute(kAXSizeAttribute, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }
}
